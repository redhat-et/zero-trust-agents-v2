#!/usr/bin/env bash
# OpenShift driver for the scenario harness. Sourced by scripts/lib.sh
# when ZT2_DRIVER=openshift. Same contract as lib-podman.sh; the state
# file ($STATE_DIR/openshift.env, written by
# deploy/openshift/setup.sh) provides the gateway Route and the local
# subject-token minter port.
set -euo pipefail

# shellcheck source=/dev/null
[[ -f "$STATE_DIR/openshift.env" ]] && source "$STATE_DIR/openshift.env"
: "${ZT2_GATEWAY_ROUTE:?ZT2_GATEWAY_ROUTE not set (run deploy/openshift/setup.sh)}"

OS=(openshell --gateway zt2 --gateway-endpoint "https://$ZT2_GATEWAY_ROUTE")

# In-sandbox URLs: sandbox pods resolve in-cluster service DNS — and
# the sandbox resolver has no search domains, so full FQDNs are
# required (short .svc forms NXDOMAIN inside sandboxes).
ENGINEERING_URL="http://document-engineering.zt-demo.svc.cluster.local:8080"
HR_URL="http://document-hr.zt-demo.svc.cluster.local:8080"

# Host-side URLs via lazily-started oc port-forwards. PIDs are recorded
# for teardown; the minter forward belongs to setup.sh and is only
# adopted here.
DEMO_SUBJECT_URL="http://127.0.0.1:${TOKEN_ISSUER_DEMO_HOST_PORT:-18090}"
ISSUER_LOCAL_PORT="${ZT2_ISSUER_LOCAL_PORT:-18080}"
ISSUER_LOCAL="http://127.0.0.1:$ISSUER_LOCAL_PORT"
ENGINEERING_LOCAL_PORT="${ZT2_ENGINEERING_LOCAL_PORT:-18101}"
ENGINEERING_LOCAL="http://127.0.0.1:$ENGINEERING_LOCAL_PORT"
FINANCE_LOCAL_PORT="${ZT2_FINANCE_LOCAL_PORT:-18102}"
FINANCE_LOCAL="http://127.0.0.1:$FINANCE_LOCAL_PORT"

# ensure_forward PORT RESOURCE — start a port-forward unless one is
# already recorded and alive for this port.
ensure_forward() {
    local port="$1" resource="$2"
    local pidfile="$STATE_DIR/forward-$port.pid"
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        return 0
    fi
    oc -n zt-demo port-forward "$resource" "${port}:8080" >/dev/null 2>&1 &
    echo $! >"$pidfile"
    for _ in $(seq 1 15); do
        curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 && return 0
        sleep 2
    done
    printf "port-forward %s (%s) did not become ready\n" "$port" "$resource" >&2
    return 1
}

pre_create_cleanup() {
    oc -n zt2-sandboxes delete sandbox "$1" --ignore-not-found >/dev/null 2>&1 || true
}

# register_sandbox ID — no registration entries on Kubernetes: the
# ClusterSPIFFEID mints the SVID via pod attestation. Wait until the
# SVID is actually obtainable, because the supervisor caches a failed
# token grant (same lesson as Stage 1's sleep 3).
register_sandbox() {
    local id="$1"
    for _ in $(seq 1 20); do
        if [[ -n "$(fetch_supervisor_svid "$id" 2>/dev/null || true)" ]]; then
            echo "SPIFFE ID        : spiffe://openshell.local/openshell/sandbox/$id (attested)"
            return 0
        fi
        sleep 3
    done
    echo "SVID for sandbox $id did not become obtainable" >&2
    return 1
}

# supervisor_logs ID — print the supervisor container's logs.
supervisor_logs() {
    oc -n zt2-sandboxes logs -l "openshell.ai/sandbox-id=$1" -c supervisor 2>&1
}

# svid_helper POD_NAME SPIFFE_ID ANNOTATION... — apply the helper pod
# manifest, wait for it to finish, print its logs, and return success
# only if the pod Succeeded. The helper runs spire-agent api fetch jwt
# with the CSI-mounted Workload API socket in the sandbox namespace,
# so SPIRE attributes the fetch to the identity the annotations
# select; the fetch IS the container command (the spire-agent image is
# distroless -- no shell to keep alive), so the pod terminating is the
# fetch finishing. There is no container watcher on Kubernetes: the
# helper cannot delete the real sandbox (the Podman WARNING does not
# apply).
svid_helper() {
    local pod="$1" spiffe_id="$2"; shift 2
    local annotations="" a k v
    for a in "$@"; do
        k="${a%%=*}"; v="${a#*=}"
        annotations+="    $k: \"$v\"
"
    done
    # awk via ENVIRON (not -v): the annotation block is multiline and
    # both BSD sed and BSD awk reject newlines in substitution values.
    ANN="$annotations" awk -v pod="$pod" -v sid="$spiffe_id" '
        BEGIN { ann = ENVIRON["ANN"] }
        { gsub(/@POD_NAME@/, pod); gsub(/@ANNOTATIONS@/, ann); gsub(/@SPIFFE_ID@/, sid); print }
    ' "$ROOT/deploy/openshift/svid-helper.yaml" |
        oc -n zt2-sandboxes apply -f - >/dev/null
    local phase=""
    for _ in $(seq 1 30); do
        phase="$(oc -n zt2-sandboxes get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
        sleep 2
    done
    oc -n zt2-sandboxes logs "$pod" 2>/dev/null || true
    oc -n zt2-sandboxes delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
    [[ "$phase" == "Succeeded" ]]
}

fetch_supervisor_svid() {
    local token
    token="$(svid_helper "zt2-svid-$1" \
        "spiffe://openshell.local/openshell/sandbox/$1" \
        "openshell.ai/sandbox-id=$1" |
        awk '/^\t/ {print $1; exit}')" || return 1
    [[ -n "$token" ]] || return 1
    echo "$token"
}

# fetch_gateway_svid — a helper pod in the openshell namespace running
# AS the gateway's ServiceAccount: the SA-based ClusterSPIFFEID mints
# the gateway identity for it. This needs the RBAC to create pods in
# openshell and use its service account — the same trust an ephemeral
# debug container on the gateway pod needs, and nothing a sandbox
# holds. (An oc debug ephemeral container was tried first: the agent's
# container locator cannot reliably attribute ephemeral containers, so
# the fetch fails.)
fetch_gateway_svid() {
    oc -n openshell delete pod zt2-gw-svid --ignore-not-found >/dev/null 2>&1 || true
    oc -n openshell apply -f "$ROOT/deploy/openshift/svid-helper-gateway.yaml" >/dev/null
    local phase=""
    for _ in $(seq 1 30); do
        phase="$(oc -n openshell get pod zt2-gw-svid -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
        sleep 2
    done
    local token
    token="$(oc -n openshell logs zt2-gw-svid 2>/dev/null |
        awk '/^\t/ {print $1; exit}')" || true
    oc -n openshell delete pod zt2-gw-svid --ignore-not-found >/dev/null 2>&1 || true
    [[ -n "$token" ]] || return 1
    echo "$token"
}

# fetch_rogue_svid — request a rogue SPIFFE ID from a helper pod the
# attestation policy deliberately does not match. Exit codes:
#   0 + token on stdout  — SPIRE minted the rogue SVID (issuer must
#                          reject it; scenario 5's issuer-401 path)
#   1                    — SPIRE refused (attestation policy held)
#   2                    — indeterminate (infrastructure failure);
#                          scenario 5 must FAIL, not pass
fetch_rogue_svid() {
    local out token
    out="$(svid_helper "zt2-svid-rogue" \
        "spiffe://openshell.local/rogue/workload/1" \
        "zt2.rogue=true")" || true
    if [[ -z "$out" ]]; then
        printf "fetch_rogue_svid: indeterminate (no helper output)\n" >&2
        return 2
    fi
    token="$(awk '/^\t/ {print $1; exit}' <<<"$out")"
    if [[ -n "$token" ]]; then
        echo "$token"
        return 0
    fi
    if grep -q "no identity issued" <<<"$out"; then
        return 1
    fi
    printf "fetch_rogue_svid: indeterminate (unexpected helper output)\n" >&2
    return 2
}

# Host-side forwards the scenario scripts need (every scenario talks to
# the issuer; 3 and 6 talk to the document services). Started eagerly
# here so the scenario scripts can use the URL variables directly.
ensure_forward "$ISSUER_LOCAL_PORT" service/token-issuer
ensure_forward "$ENGINEERING_LOCAL_PORT" service/document-engineering
ensure_forward "$FINANCE_LOCAL_PORT" service/document-finance

# The minter forward is owned by setup.sh, but it dies when the issuer
# rolls (a new pod replaces the forward's target) — restart it if the
# listener is gone.
DEMO_PORT="${TOKEN_ISSUER_DEMO_HOST_PORT:-18090}"
if ! curl -fsS --max-time 2 "http://127.0.0.1:${DEMO_PORT}/healthz" >/dev/null 2>&1; then
    kill "$(cat "$STATE_DIR/openshift-forward.pid" 2>/dev/null)" 2>/dev/null || true
    oc -n zt-demo port-forward deployment/token-issuer "${DEMO_PORT}:8090" >/dev/null 2>&1 &
    echo $! >"$STATE_DIR/openshift-forward.pid"
    for _ in $(seq 1 15); do
        curl -fsS --max-time 2 "http://127.0.0.1:${DEMO_PORT}/healthz" >/dev/null 2>&1 && break
        sleep 2
    done
fi
