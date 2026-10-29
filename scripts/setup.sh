#!/usr/bin/env bash
# One-command demo setup: SPIRE, OpenShell gateway, demo services, and
# provider profiles. Restarts containers, reuses state, and clears stale
# demo profiles so re-running against a dirty environment works.
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

# Profiles are immutable per ID, so a stale zt2-* profile from an earlier
# run breaks import. Clear the dependency chain (sandboxes -> providers ->
# profiles) first; sandbox deletion is async, so wait for it before
# deleting the providers attached to them.
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
    if "${OS[@]}" profile list 2>/dev/null | awk 'NR>1 && $1 ~ /^zt2-/ {found=1} END {exit !found}'; then
        echo "warning: some zt2-* profiles could not be deleted; import may fail" >&2
    fi
fi

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
