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
STATE_DIR="${STATE_DIR:-$(mktemp -d)}"

# The issuer's URL as seen from the gateway/sandboxes on the network.
# Plain HTTP token endpoints pass OpenShell profile lint only for
# loopback or *.svc hosts, hence the .svc alias. The issuer is published
# on host port 8080 and the VM maps token-issuer.zt-demo.svc to
# host.containers.internal, so the supervisor (host netns) and the
# gateway (zt2 network) both resolve the same name and port.
TOKEN_ISSUER_BASE_URL="${TOKEN_ISSUER_BASE_URL:-http://token-issuer.zt-demo.svc:8080}"
TOKEN_ISSUER_HOST_PORT="${TOKEN_ISSUER_HOST_PORT:-8080}"

# Document services are published on distinct host ports and reached via
# host.containers.internal (the supervisor's netns cannot resolve podman
# network aliases, and the sandbox's policy DNS resolves declared
# endpoint hosts through the supervisor's system resolver).
DOC_PORTS=("18101" "18102" "18103" "18104" "18105")
DOC_DEPTS=("engineering" "finance" "admin" "hr" "public")

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
    -p "$(doc_publish_addr)${TOKEN_ISSUER_HOST_PORT}:8080" \
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

if ! wait_for_http "http://127.0.0.1:${TOKEN_ISSUER_HOST_PORT}/healthz" "token issuer"; then
    podman logs "$TOKEN_ISSUER_CONTAINER" >&2 || true
    exit 1
fi

for i in "${!DOC_DEPTS[@]}"; do
    dept="${DOC_DEPTS[$i]}"
    port="${DOC_PORTS[$i]}"
    printf "Starting document service: %s (host port %s)\n" "zt2-document-${dept}" "$port" >&2
    run podman run -d \
        --name "zt2-document-${dept}" \
        --network "$NETWORK" \
        --network-alias "document-${dept}" \
        -p "$(doc_publish_addr)${port}:8080" \
        -e "ACCESS_TOKEN_SECRET=${ACCESS_TOKEN_SECRET}" \
        -e "ACCESS_TOKEN_ISSUER=${TOKEN_ISSUER_BASE_URL}" \
        -e "DEPARTMENT=${dept}" \
        -e "PORT=:8080" \
        "${IMAGE_PREFIX}/document-service"
done

# Map the issuer's .svc name for the supervisor's netns: the token
# endpoint's host must pass profile lint (.svc shape), and the
# supervisor — on the podman VM's host network (macOS) or the host
# netns (Linux) — cannot resolve podman network aliases. Upstream's
# README sanctions a hosts entry for exactly this case.
if [[ "$ZT2_HOST_OS" == "linux" ]]; then
    if ! grep -q "token-issuer.zt-demo.svc" /etc/hosts; then
        printf "Adding token-issuer.zt-demo.svc to /etc/hosts (sudo)\n" >&2
        if ! sudo sh -c "echo '$(doc_endpoint_ip) token-issuer.zt-demo.svc' >> /etc/hosts"; then
            printf "warning: could not edit /etc/hosts; the supervisor may fail to resolve the issuer\n" >&2
        fi
    fi
else
    if ! podman machine ssh "grep -q token-issuer.zt-demo.svc /etc/hosts" 2>/dev/null; then
        printf "Adding token-issuer.zt-demo.svc to the podman VM's /etc/hosts\n" >&2
        podman machine ssh "sudo sh -c 'echo 192.168.127.254 token-issuer.zt-demo.svc >> /etc/hosts'"
    fi
fi

# 0600 on every run: the redirect alone won't tighten an existing file.
(umask 077 && printf "%s\n" "$ACCESS_TOKEN_SECRET" >"${STATE_DIR}/access-token-secret")
chmod 600 "${STATE_DIR}/access-token-secret"
doc_summary="$(doc_endpoint_ip) ports 18101-18105 (engineering|finance|admin|hr|public)"
printf "\nDemo services are up.\n"
printf "  token issuer: http://127.0.0.1:%s (network alias token-issuer.zt-demo.svc)\n" "$TOKEN_ISSUER_HOST_PORT"
printf "  document services: %s
" "$doc_summary"
printf "  shared secret written to %s\n" "${STATE_DIR}/access-token-secret"
