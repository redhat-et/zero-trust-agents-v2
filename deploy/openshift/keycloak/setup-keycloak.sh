#!/usr/bin/env bash
# Stand up the Keycloak identity plane for the zt-demo namespace.
# Idempotent: safe to re-run on a temporary cluster or an existing one.
#
# The image is pinned to a digest resolved at run time, so the same
# script reproduces the same build on every cluster. Every Keycloak
# image we can run bundles an OpenJDK affected by CVE-2026-114938
# (Java4Shell); the mitigation is in the manifest and verify-keycloak.sh
# fails the run if it did not reach the JVM.
#
# --with-spiffe becomes meaningful in Task 2 (SPIFFE IdP sidecar);
# today it only prints a notice.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export STATE_DIR="${STATE_DIR:-$ROOT/.zt2-state}"
# shellcheck source=deploy/openshift/lib.sh
source "$ROOT/deploy/openshift/lib.sh"

require_oc
require_cmd python3
require_cmd openssl

NAMESPACE="${ZT2_KEYCLOAK_NAMESPACE:-zt-demo}"
REALM="${ZT2_KEYCLOAK_REALM:-zt}"
IMAGE="${ZT2_KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.8.2}"
DIR="$ROOT/deploy/openshift/keycloak"

WITH_SPIFFE=0
RESET=0
for arg in "$@"; do
    case "$arg" in
        --with-spiffe) WITH_SPIFFE=1 ;;
        --reset) RESET=1 ;;
        *)
            printf "unknown argument: %s (use --with-spiffe, --reset)\n" "$arg" >&2
            exit 2
            ;;
    esac
done

echo "== resolving $IMAGE to a digest =="
# The tag is a multi-arch manifest list; the demo cluster is amd64, and
# pinning the arch-specific digest is what makes the run reproducible.
info="$(oc image info "$IMAGE" --filter-by-os=linux/amd64 -o json)" ||
    { printf "cannot inspect %s (registry access or manifest-list resolution failed)\n" "$IMAGE" >&2; exit 1; }
resolved="$(printf '%s' "$info" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("digest") or d.get("image", {}).get("digest", ""))
')"
[[ -n "$resolved" ]] ||
    { printf "could not resolve a digest for %s\n" "$IMAGE" >&2; exit 1; }
if [[ -n "${ZT2_KEYCLOAK_IMAGE_DIGEST:-}" && "$ZT2_KEYCLOAK_IMAGE_DIGEST" != "$resolved" ]]; then
    printf "digest mismatch: %s resolves to %s, ZT2_KEYCLOAK_IMAGE_DIGEST is %s\n" \
        "$IMAGE" "$resolved" "$ZT2_KEYCLOAK_IMAGE_DIGEST" >&2
    exit 1
fi
PINNED="${IMAGE}@${resolved}"
echo "pinned: $PINNED"

echo "== namespace and credentials =="
oc create namespace "$NAMESPACE" >/dev/null 2>&1 || true
if ! oc -n "$NAMESPACE" get secret keycloak-admin >/dev/null 2>&1; then
    password="$(openssl rand -hex 16)"
    oc -n "$NAMESPACE" create secret generic keycloak-admin \
        --from-literal=password="$password" >/dev/null
fi

if [[ "$RESET" == "1" ]]; then
    # Realm import is one-shot: an existing realm is never re-imported.
    # Dropping the PVC is the only way to pick up a changed export.
    echo "== reset: dropping Keycloak state =="
    oc -n "$NAMESPACE" scale deployment/keycloak --replicas=0 >/dev/null 2>&1 || true
    oc -n "$NAMESPACE" wait --for=delete pod -l app=keycloak --timeout=120s >/dev/null 2>&1 || true
    oc -n "$NAMESPACE" delete pvc keycloak-data --ignore-not-found >/dev/null
fi

echo "== realm import ConfigMap =="
oc -n "$NAMESPACE" create configmap keycloak-realm \
    --from-file=realm-zt.json="$DIR/realm-zt.json" \
    --dry-run=client -o yaml |
    oc apply -f - >/dev/null

echo "== Keycloak =="
sed "s|@KEYCLOAK_IMAGE@|$PINNED|" "$DIR/keycloak.yaml" |
    oc apply -f - >/dev/null
oc -n "$NAMESPACE" rollout status deployment/keycloak --timeout=300s

if ! oc -n "$NAMESPACE" get route keycloak >/dev/null 2>&1; then
    oc -n "$NAMESPACE" expose svc/keycloak >/dev/null
fi
route="$(oc -n "$NAMESPACE" get route keycloak -o jsonpath='{.spec.host}')"

issuer="http://keycloak.${NAMESPACE}.svc:8080/realms/${REALM}"
state_set ZT2_KEYCLOAK_ISSUER "$issuer"
state_set ZT2_KEYCLOAK_TOKEN_URL "${issuer}/protocol/openid-connect/token"
state_set ZT2_KEYCLOAK_JWKS_URL "${issuer}/protocol/openid-connect/certs"
state_set ZT2_KEYCLOAK_ROUTE "$route"

if [[ "$WITH_SPIFFE" == "1" ]]; then
    echo "== SPIFFE identity provider =="
    echo "notice: --with-spiffe is a no-op until the sidecar patch lands"
fi

"$DIR/verify-keycloak.sh"

cat <<EOF

Keycloak ready.
  issuer:  $issuer
  route:   https://$route (laptop-side token acquisition)
  realm:   $REALM (imported once; delete PVC keycloak-data to re-import)
EOF
