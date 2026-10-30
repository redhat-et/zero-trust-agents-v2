#!/usr/bin/env bash
# One-command OpenShift setup: SPIRE (hardened charts), Agent Sandbox
# controller, OpenShell gateway (Kubernetes compute driver, Route),
# the zt-demo services, and provider profiles. Idempotent: safe to
# re-run against an existing installation.
#
# Assumes: oc logged in to a ROSA/OpenShift >= 4.19 cluster, helm 3,
# the openshell CLI on PATH, and the v2 images already pushed to
# quay.io (deploy/openshift/build-images.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export STATE_DIR="${STATE_DIR:-$ROOT/.zt2-state}"
# shellcheck source=deploy/openshift/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd helm
require_cmd openshell
require_cmd curl
require_cmd python3
require_oc

ZT2_QUAY_NS="${ZT2_QUAY_NS:-panni}"
ZT2_IMAGE_TAG="${ZT2_IMAGE_TAG:-v2}"
SPIRE_CHART_VERSION="${SPIRE_CHART_VERSION:-0.29.0}"
SPIRE_CRDS_VERSION="${SPIRE_CRDS_VERSION:-0.5.0}"

echo "== 0/7 prechecks =="
# Landlock requires OpenShift 4.19+ (OpenShell runtime requirement).
MINOR="$(oc get clusterversion -o jsonpath='{.items[0].status.history[0].version}' | cut -d. -f2)"
if [[ "${MINOR:-0}" -lt 19 ]]; then
    printf "OpenShift 4.%s found; 4.19+ required (Landlock)\n" "$MINOR" >&2
    exit 1
fi

# Private quay.io repos need a pull secret in the namespaces that run
# our images (openshell does not pull zt2 images, but zt-demo does;
# checking both keeps the message simple). Fail fast instead of
# letting pods sit in ImagePullBackOff.
ensure_pull_secret() {
    local ns="$1"
    if oc -n "$ns" get secret zt2-quay >/dev/null 2>&1; then
        return 0
    fi
    # Build it from the local podman auth.json if possible.
    local auth_json="${XDG_CONFIG_HOME:-$HOME/.config}/containers/auth.json"
    if [[ -f "$auth_json" ]] && command -v yq >/dev/null 2>&1; then
        local b64auth
        b64auth="$(yq -r '.auths["quay.io"].auth // ""' "$auth_json")"
        if [[ -n "$b64auth" ]]; then
            printf '{"auths":{"quay.io":{"auth":"%s"}}}' "$b64auth" |
                oc -n "$ns" create secret docker-registry zt2-quay \
                    --from-file=.dockerconfigjson=/dev/stdin >/dev/null &&
                return 0
        fi
    fi
    printf "quay.io pull secret 'zt2-quay' missing in namespace %s.\n" "$ns" >&2
    printf "Fix (after podman login quay.io):\n" >&2
    printf "  oc -n %s create secret docker-registry zt2-quay \\\n" "$ns" >&2
    printf "    --from-file=.dockerconfigjson=<(podman login --get-login quay.io >/dev/null; cat \$XDG_CONFIG_HOME/containers/auth.json)\n" >&2
    printf "or make the quay.io/%s/zt2-* repos public.\n" "$ZT2_QUAY_NS" >&2
    exit 1
}

echo "== 1/7 SPIRE (hardened charts) =="
helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/ >/dev/null 2>&1 || true
helm repo update spiffe >/dev/null
helm upgrade --install spire-crds spiffe/spire-crds --version "$SPIRE_CRDS_VERSION" \
    -n spire --create-namespace --wait
# Wait for the CRDs to be established before the server release (which
# applies ClusterSPIFFEIDs) races them.
oc wait --for=condition=Established crd/clusterspiffeids.spire.spiffe.io --timeout=120s
helm upgrade --install spire spiffe/spire --version "$SPIRE_CHART_VERSION" \
    -n spire -f "$ROOT/deploy/openshift/spire/values.yaml" --wait

echo "== 2/7 Agent Sandbox controller =="
oc apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/sandbox.yaml
oc -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=300s

echo "== 3/7 OpenShell gateway =="
oc create namespace openshell >/dev/null 2>&1 || true
oc create namespace zt2-sandboxes >/dev/null 2>&1 || true
ensure_pull_secret openshell
ensure_pull_secret zt-demo
APPS_DOMAIN="$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}')"
ROUTE_HOST="zt2-gateway.${APPS_DOMAIN}"
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    -n openshell -f "$ROOT/deploy/openshift/openshell/values.yaml" \
    --set openshiftRoute.host="$ROUTE_HOST" \
    --set "pkiInitJob.serverDnsNames[0]=$ROUTE_HOST" \
    --wait
oc -n openshell rollout status statefulset/openshell --timeout=300s
wait_route() {
    for _ in $(seq 1 30); do
        if curl -fsS --max-time 5 "https://$ROUTE_HOST/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    printf "gateway Route %s did not become healthy\n" "$ROUTE_HOST" >&2
    return 1
}
wait_route

echo "== 4/7 zt-demo services =="
oc apply -f "$ROOT/deploy/openshift/zt-demo/namespace.yaml"
if ! oc -n zt-demo get secret zt2-secrets >/dev/null 2>&1; then
    ACCESS_TOKEN_SECRET="$(openssl rand -hex 32)"
    printf '%s' "$ACCESS_TOKEN_SECRET" >"$STATE_DIR/access-token-secret"
    oc -n zt-demo create secret generic zt2-secrets \
        --from-literal=access-token-secret="$ACCESS_TOKEN_SECRET" >/dev/null
fi
oc apply -f "$ROOT/deploy/openshift/zt-demo/token-issuer.yaml"
oc apply -f "$ROOT/deploy/openshift/zt-demo/document-services.yaml"
oc apply -f "$ROOT/deploy/openshift/zt-demo/networkpolicy.yaml"
wait_rollout zt-demo deployment/token-issuer
for dept in engineering finance admin hr public; do
    wait_rollout zt-demo "deployment/document-$dept"
done

echo "== 5/7 subject-token minter port-forward =="
# The unauthenticated /demo-subject-token listener is reached ONLY via
# port-forward to the pod -- never a Route or Service.
DEMO_PORT="${ZT2_DEMO_LOCAL_PORT:-18090}"
if [[ -f "$STATE_DIR/openshift-forward.pid" ]] &&
    kill -0 "$(cat "$STATE_DIR/openshift-forward.pid")" 2>/dev/null; then
    kill "$(cat "$STATE_DIR/openshift-forward.pid")" 2>/dev/null || true
fi
oc -n zt-demo port-forward deployment/token-issuer "${DEMO_PORT}:8090" >/dev/null 2>&1 &
FORWARD_PID=$!
echo "$FORWARD_PID" >"$STATE_DIR/openshift-forward.pid"
trap 'kill "$FORWARD_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
    curl -fsS --max-time 2 "http://127.0.0.1:${DEMO_PORT}/healthz" >/dev/null 2>&1 && break
    sleep 2
done

echo "== 6/7 provider profiles =="
OS=(openshell --gateway zt2 --gateway-endpoint "https://$ROUTE_HOST")
if ! "${OS[@]}" status >/dev/null 2>&1; then
    openshell gateway add "https://$ROUTE_HOST" --name zt2 >/dev/null
fi
# Profiles are immutable per ID: clear the dependency chain (sandboxes
# -> providers -> profiles) from any earlier run first.
if "${OS[@]}" profile list 2>/dev/null | awk 'NR>1 && $1 ~ /^zt2-/ {found=1} END {exit !found}'; then
    echo "removing stale demo state (sandboxes, providers, profiles)"
    for sbx in $("${OS[@]}" sandbox list 2>/dev/null | awk 'NR>1 {print $1}'); do
        "${OS[@]}" sandbox delete "$sbx" >/dev/null 2>&1 || true
    done
    for _ in $(seq 1 20); do
        [[ -z "$("${OS[@]}" sandbox list 2>/dev/null | awk 'NR>1 {print $1}')" ]] && break
        sleep 3
    done
    for prov in $("${OS[@]}" provider list 2>/dev/null | awk 'NR>1 {print $1}'); do
        "${OS[@]}" provider delete "$prov" >/dev/null 2>&1 || true
    done
    for prof in $("${OS[@]}" profile list 2>/dev/null | awk 'NR>1 && $1 ~ /^zt2-/ {print $1}'); do
        "${OS[@]}" profile delete "$prof" >/dev/null 2>&1 || true
    done
fi
profile_out_dir="${STATE_DIR}/openshift-profiles"
mkdir -p "$profile_out_dir"
for profile in alice-engineering alice-hr carol-hr nodelegation; do
    dept="$(profile_dept "$profile")"
    # Same substitution contract as profiles/test-substitution.sh: the
    # @ALLOWED_IPS@ line is DELETED, not blanked.
    awk -v host="document-${dept}.zt-demo.svc" -v port="8080" '
        /@ALLOWED_IPS@/ { next }
        { gsub(/@DOC_HOST@/, host); gsub(/@DOC_PORT@/, port); print }
    ' "$ROOT/deploy/openshift/profiles/$profile.yaml.in" \
        >"$profile_out_dir/$profile.yaml"
    "${OS[@]}" profile lint -f "$profile_out_dir/$profile.yaml" | tail -1
    "${OS[@]}" profile import -f "$profile_out_dir/$profile.yaml" | tail -1
done

echo "== 7/7 smoke test =="
SUBJECT_TOKEN="$(curl -fsS "http://127.0.0.1:${DEMO_PORT}/demo-subject-token?user=alice" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
echo "subject token minted for alice: ${SUBJECT_TOKEN:0:30}..."
"${OS[@]}" provider create --name alice-eng --type zt2-alice-engineering-v2 \
    --credential "subject_token=${SUBJECT_TOKEN}" 2>&1 | tail -1

state_set ZT2_DRIVER openshift
state_set ZT2_GATEWAY_ROUTE "$ROUTE_HOST"
state_set TOKEN_ISSUER_DEMO_HOST_PORT "$DEMO_PORT"
state_set ZT2_STATE_DIR "$STATE_DIR"

# The port-forward must outlive this script; disarm the EXIT trap.
trap - EXIT

cat <<EOF

OpenShift demo environment ready.
  gateway:        https://$ROUTE_HOST (name zt2, registered)
  token issuer:   http://token-issuer.zt-demo.svc:8080 (in-cluster)
  doc services:   document-{engineering,finance,admin,hr,public}.zt-demo.svc:8080
  minter forward: http://127.0.0.1:${DEMO_PORT} (pid $FORWARD_PID)
  state:          $STATE_DIR/openshift.env

Run scenarios: ZT2_DRIVER=openshell scripts/scenario{1..6}.sh
EOF
