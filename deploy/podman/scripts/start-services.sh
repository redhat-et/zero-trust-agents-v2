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
# loopback or *.svc hosts, hence the .svc alias. The alias itself is
# unresolvable where it matters — the supervisor (network=host) and,
# via aardvark's upstream forwarding, the gateway — so a hosts entry
# maps it to the published-port address on each OS: the podman VM's
# gateway on macOS, the host's LAN address on Linux.
TOKEN_ISSUER_BASE_URL="${TOKEN_ISSUER_BASE_URL:-http://token-issuer.zt-demo.svc:8080}"
TOKEN_ISSUER_HOST_PORT="${TOKEN_ISSUER_HOST_PORT:-8080}"

# The unauthenticated demo-subject-token endpoint is served on a second
# listener (DEMO_LISTEN_ADDR, :8090 in the image) published loopback
# only: the main port is published on the LAN for the gateway's
# authenticated /token exchange, and must not carry the token minter.
TOKEN_ISSUER_DEMO_HOST_PORT="${TOKEN_ISSUER_DEMO_HOST_PORT:-8090}"
export TOKEN_ISSUER_DEMO_HOST_PORT
write_env_line TOKEN_ISSUER_DEMO_HOST_PORT "$TOKEN_ISSUER_DEMO_HOST_PORT"

# Document services are published on distinct host ports: the
# supervisor's netns cannot resolve podman network aliases, and the
# sandbox's policy DNS resolves declared endpoint hosts through the
# supervisor's system resolver.
DOC_DEPTS=("engineering" "finance" "admin" "hr" "public")

# publish_flags HOST_PORT — podman -p flags for a container's 8080.
# Loopback always (host-side health checks in the scenario scripts);
# on Linux also the host's LAN address, where the supervisor and the
# sandbox policy DNS reach the service. Binding all interfaces instead
# would expose the unauthenticated demo issuer to the LAN.
publish_flags() {
    local port="$1"
    printf -- "-p 127.0.0.1:%s:8080" "$port"
    if [[ "$ZT2_HOST_OS" == "linux" ]]; then
        printf " -p %s:%s:8080" "$(doc_endpoint_ip)" "$port"
    fi
}

ACCESS_TOKEN_SECRET="${ACCESS_TOKEN_SECRET:-$(openssl rand -hex 32)}"
export ACCESS_TOKEN_SECRET

ensure_network
mkdir -p "$STATE_DIR"

cleanup_container "$TOKEN_ISSUER_CONTAINER"
for dept in "${DOC_DEPTS[@]}"; do
    cleanup_container "zt2-document-${dept}"
done
printf "Starting token issuer: %s\n" "$TOKEN_ISSUER_CONTAINER" >&2
# shellcheck disable=SC2046
run podman run -d \
    --name "$TOKEN_ISSUER_CONTAINER" \
    --network "$NETWORK" \
    --network-alias token-issuer.zt-demo.svc \
    $(publish_flags "$TOKEN_ISSUER_HOST_PORT") \
    -p "127.0.0.1:${TOKEN_ISSUER_DEMO_HOST_PORT}:8090" \
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

if ! wait_for_http "http://127.0.0.1:${TOKEN_ISSUER_HOST_PORT}/healthz" "token issuer (main)"; then
    podman logs "$TOKEN_ISSUER_CONTAINER" >&2 || true
    exit 1
fi
if ! wait_for_http "http://127.0.0.1:${TOKEN_ISSUER_DEMO_HOST_PORT}/healthz" "token issuer (demo)"; then
    podman logs "$TOKEN_ISSUER_CONTAINER" >&2 || true
    exit 1
fi

for dept in "${DOC_DEPTS[@]}"; do
    port="$(doc_endpoint_port "$dept")"
    printf "Starting document service: %s (host port %s)\n" "zt2-document-${dept}" "$port" >&2
    # shellcheck disable=SC2046
    run podman run -d \
        --name "zt2-document-${dept}" \
        --network "$NETWORK" \
        --network-alias "document-${dept}" \
        $(publish_flags "$port") \
        -e "ACCESS_TOKEN_SECRET=${ACCESS_TOKEN_SECRET}" \
        -e "ACCESS_TOKEN_ISSUER=${TOKEN_ISSUER_BASE_URL}" \
        -e "DEPARTMENT=${dept}" \
        -e "PORT=:8080" \
        "${IMAGE_PREFIX}/document-service"
done

# Map the issuer's .svc name (see TOKEN_ISSUER_BASE_URL above).
# Match the full line, not just the hostname: a stale entry pointing
# at an old host IP must be rewritten, not skipped. On Linux the entry
# is load-bearing for every token exchange, so a failed edit is fatal.
if [[ "$ZT2_HOST_OS" == "linux" ]]; then
    issuer_hosts_line="$(doc_endpoint_ip) token-issuer.zt-demo.svc"
    if ! grep -qF "$issuer_hosts_line" /etc/hosts; then
        printf "Setting %s in /etc/hosts (sudo)\n" "$issuer_hosts_line" >&2
        sudo sed -i "/token-issuer.zt-demo.svc/d" /etc/hosts
        if ! sudo sh -c "echo '$issuer_hosts_line' >> /etc/hosts"; then
            printf "could not edit /etc/hosts; token exchange cannot work without the issuer entry\n" >&2
            exit 1
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
printf "\nDemo services are up.\n"
printf "  token issuer: http://127.0.0.1:%s (network alias token-issuer.zt-demo.svc)\n" "$TOKEN_ISSUER_HOST_PORT"
printf "  subject-token mint (loopback only): http://127.0.0.1:%s\n" "$TOKEN_ISSUER_DEMO_HOST_PORT"
printf "  document services: %s ports 18101-18105 (engineering|finance|admin|hr|public)\n" "$(doc_endpoint_ip)"
printf "  shared secret written to %s\n" "${STATE_DIR}/access-token-secret"
