#!/usr/bin/env bash
# Start the token issuer and per-department document services on the
# shared podman network. One ACCESS_TOKEN_SECRET is generated (upstream
# demo.sh pattern) and shared by every container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../spire/common.sh
source "${SCRIPT_DIR}/../spire/common.sh"

require_cmd podman
require_cmd openssl

IMAGE_PREFIX="${IMAGE_PREFIX:-localhost/zt2}"
NETWORK="${PODMAN_NETWORK}"
TOKEN_ISSUER_CONTAINER="${TOKEN_ISSUER_CONTAINER:-zt2-token-issuer}"
TOKEN_ISSUER_PORT="${TOKEN_ISSUER_PORT:-18090}"
STATE_DIR="${STATE_DIR:-$(mktemp -d)}"

# The issuer's URL as seen from the gateway/sandboxes on the network.
# Plain HTTP token endpoints pass OpenShell profile lint only for
# loopback or *.svc hosts, hence the .svc alias.
TOKEN_ISSUER_BASE_URL="${TOKEN_ISSUER_BASE_URL:-http://token-issuer.zt-demo.svc:8080}"

ACCESS_TOKEN_SECRET="${ACCESS_TOKEN_SECRET:-$(openssl rand -hex 32)}"
export ACCESS_TOKEN_SECRET

ensure_network
mkdir -p "$STATE_DIR"

cleanup_container "$TOKEN_ISSUER_CONTAINER"
for dept in engineering finance admin hr public; do
    cleanup_container "zt2-document-${dept}"
done

printf "Starting token issuer: %s\n" "$TOKEN_ISSUER_CONTAINER" >&2
run podman run -d \
    --name "$TOKEN_ISSUER_CONTAINER" \
    --network "$NETWORK" \
    --network-alias token-issuer.zt-demo.svc \
    -p "127.0.0.1:${TOKEN_ISSUER_PORT}:8080" \
    -v "${REPO_ROOT}/config/users.yaml:/config/users.yaml:ro,z" \
    -e "ACCESS_TOKEN_SECRET=${ACCESS_TOKEN_SECRET}" \
    -e "ACCESS_TOKEN_ISSUER=${TOKEN_ISSUER_BASE_URL}" \
    -e "JWT_SVID_AUDIENCE=${TOKEN_ISSUER_BASE_URL}" \
    -e "SPIRE_JWKS_URI=http://spire-oidc:8080/keys" \
    -e "SPIRE_ISSUER=http://spire-oidc:8080" \
    -e "GATEWAY_TRUST_DOMAIN_PREFIX=spiffe://${TRUST_DOMAIN}/openshell/gateway/" \
    -e "SUPERVISOR_TRUST_DOMAIN_PREFIX=spiffe://${TRUST_DOMAIN}/openshell/sandbox/" \
    -e "PORT=:8080" \
    -e "USERS_FILE=/config/users.yaml" \
    "${IMAGE_PREFIX}/token-issuer"

if ! wait_for_http "http://127.0.0.1:${TOKEN_ISSUER_PORT}/healthz" "token issuer"; then
    podman logs "$TOKEN_ISSUER_CONTAINER" >&2 || true
    exit 1
fi

for dept in engineering finance admin hr public; do
    printf "Starting document service: %s\n" "zt2-document-${dept}" >&2
    run podman run -d \
        --name "zt2-document-${dept}" \
        --network "$NETWORK" \
        --network-alias "document-${dept}" \
        -e "ACCESS_TOKEN_SECRET=${ACCESS_TOKEN_SECRET}" \
        -e "ACCESS_TOKEN_ISSUER=${TOKEN_ISSUER_BASE_URL}" \
        -e "DEPARTMENT=${dept}" \
        -e "PORT=:8080" \
        "${IMAGE_PREFIX}/document-service"
done

printf "%s\n" "$ACCESS_TOKEN_SECRET" >"${STATE_DIR}/access-token-secret"
printf "\nDemo services are up.\n"
printf "  token issuer: http://127.0.0.1:%s (network alias token-issuer.zt-demo.svc)\n" "$TOKEN_ISSUER_PORT"
printf "  document services: document-engineering|finance|admin|hr|public :8080\n"
printf "  shared secret written to %s\n" "${STATE_DIR}/access-token-secret"
