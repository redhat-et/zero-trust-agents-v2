#!/usr/bin/env bash
# One-command demo setup: SPIRE, OpenShell gateway, demo services, and
# provider profiles. Idempotent-ish: restarts containers, reuses state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STATE_DIR="${STATE_DIR:-$ROOT/.zt2-state}"
mkdir -p "$STATE_DIR"
export SPIRE_ENV_FILE="${SPIRE_ENV_FILE:-$STATE_DIR/spire.env}"

echo "== 1/5 SPIRE (server, agent, OIDC discovery) =="
PODMAN_NETWORK=zt2 CLEANUP_EXISTING=1 bash "$ROOT/deploy/podman/spire/start-spire.sh"

# shellcheck source=/dev/null
source "$SPIRE_ENV_FILE"
export SPIRE_STATE_DIR SPIRE_AGENT_SOCKET_HOST_PATH

echo "== 2/5 OpenShell gateway =="
bash "$ROOT/deploy/podman/scripts/start-gateway.sh"

echo "== 3/5 demo services (token issuer, document services) =="
bash "$ROOT/deploy/podman/scripts/start-services.sh"

echo "== 4/5 provider profiles =="
OS=(openshell --gateway zt2 --gateway-endpoint http://127.0.0.1:18083)
for profile in alice-engineering alice-hr carol-hr nodelegation; do
    "${OS[@]}" profile lint -f "$ROOT/deploy/podman/profiles/$profile.yaml" | tail -1
    "${OS[@]}" profile import -f "$ROOT/deploy/podman/profiles/$profile.yaml" | tail -1
done

echo "== 5/5 smoke test =="
SUBJECT_TOKEN="$(curl -fsS "http://127.0.0.1:8080/demo-subject-token?user=alice" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
echo "subject token minted for alice: ${SUBJECT_TOKEN:0:30}..."
"${OS[@]}" provider create --name alice-eng --type zt2-alice-engineering-v2 \
    --credential "subject_token=${SUBJECT_TOKEN}" 2>&1 | tail -1

cat <<EOF

Demo environment ready.
  token issuer:   http://127.0.0.1:8080 (alias token-issuer.zt-demo.svc)
  doc services:   192.168.127.254.nip.io ports 18101-18105 (eng|fin|adm|hr|public)
  gateway:        http://127.0.0.1:18083 (name zt2)
  shared secret:  $STATE_DIR/access-token-secret

Run scenarios: scripts/scenario1.sh .. scenario6.sh
EOF
