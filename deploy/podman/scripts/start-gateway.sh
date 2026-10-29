#!/usr/bin/env bash
# Start the OpenShell gateway as a container, register its SPIFFE entry,
# and wait until healthy. Adapted from OpenShell
# examples/spiffe-token-exchange-demo/podman/demo.sh (NVIDIA, Apache-2.0).
#
# The gateway must run as a container on macOS: the SPIRE agent's
# Workload API socket lives inside the podman machine VM, so a
# host-native gateway cannot reach it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../spire/common.sh
source "${SCRIPT_DIR}/../spire/common.sh"

require_cmd podman
require_cmd openssl
require_cmd curl

GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-zt2-gateway}"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/gateway:0.1.6}"
GATEWAY_PORT="${GATEWAY_PORT:-18083}"
GATEWAY_HEALTH_PORT="${GATEWAY_HEALTH_PORT:-18084}"
GATEWAY_NAME="${GATEWAY_NAME:-zt2}"
GATEWAY_ENDPOINT="${GATEWAY_ENDPOINT:-http://127.0.0.1:${GATEWAY_PORT}}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-}"
STATE_DIR="${STATE_DIR:-$(mktemp -d)}"

if [[ -z "${SPIRE_AGENT_SOCKET_HOST_PATH:-}" ]]; then
    printf "SPIRE_AGENT_SOCKET_HOST_PATH is required (set by spire/start-spire.sh)\n" >&2
    exit 1
fi
if ! PODMAN_SOCKET="$(detect_podman_socket)"; then
    printf "could not find a Podman API socket; set PODMAN_SOCKET\n" >&2
    exit 1
fi

# The socket path must be identical inside and outside the gateway
# container: the SPIRE entry selector references it and the gateway
# passes it to sandboxes.
podman_socket_in_container="/run/podman/podman.sock"

gateway_dir="${STATE_DIR}/gateway"
jwt_dir="${gateway_dir}/jwt"
config_path="${gateway_dir}/gateway.toml"
mkdir -p "$jwt_dir"

if [[ ! -s "${jwt_dir}/signing.pem" ]]; then
    openssl genpkey -algorithm ed25519 -out "${jwt_dir}/signing.pem" >/dev/null 2>&1
    openssl pkey -in "${jwt_dir}/signing.pem" -pubout -out "${jwt_dir}/public.pem" >/dev/null 2>&1
    openssl rand -hex 8 >"${jwt_dir}/kid"
fi

sandbox_image_line=""
if [[ -n "$SANDBOX_IMAGE" ]]; then
    sandbox_image_line="default_image = \"${SANDBOX_IMAGE}\""
fi

cat >"$config_path" <<EOF
[openshell]
version = 2

[openshell.gateway]
bind_address = "0.0.0.0:8080"
health_bind_address = "0.0.0.0:8081"
log_level = "info"
compute_driver = "podman"
disable_tls = true

[openshell.gateway.auth]
allow_unauthenticated_users = true

[openshell.gateway.gateway_jwt]
signing_key_path = "${jwt_dir}/signing.pem"
public_key_path = "${jwt_dir}/public.pem"
kid_path = "${jwt_dir}/kid"
gateway_id = "zt2-demo"
ttl_secs = 3600

[openshell.drivers.podman]
socket_path = "${podman_socket_in_container}"
network_name = "${PODMAN_NETWORK}"
# Sandboxes' supervisor containers run on the podman VM's host network,
# so the gateway must be advertised as host.containers.internal:<port>.
grpc_endpoint = "http://host.containers.internal:${GATEWAY_PORT}"
image_pull_policy = "if_not_present"
health_check_interval_secs = 10
stop_timeout_secs = 30
provider_spiffe_workload_api_socket = "${SPIRE_AGENT_SOCKET_HOST_PATH}"
${sandbox_image_line}
EOF

ensure_network
cleanup_container "$GATEWAY_CONTAINER"

printf "Starting OpenShell gateway container: %s\n" "$GATEWAY_CONTAINER" >&2
run podman run -d \
    --name "$GATEWAY_CONTAINER" \
    --network "$PODMAN_NETWORK" \
    --network-alias "$GATEWAY_CONTAINER" \
    --label openshell.spiffe-demo=gateway \
    --user 0 \
    --security-opt label=disable \
    -p "127.0.0.1:${GATEWAY_PORT}:8080" \
    -p "127.0.0.1:${GATEWAY_HEALTH_PORT}:8081" \
    -v "$(podman_socket_volume "$PODMAN_SOCKET" "$podman_socket_in_container")" \
    -v "${SPIRE_AGENT_SOCKET_HOST_PATH}:${SPIRE_AGENT_SOCKET_HOST_PATH}:z" \
    -v "${gateway_dir}:${gateway_dir}:z" \
    -e "OPENSHELL_GATEWAY_CONFIG=${config_path}" \
    -e "OPENSHELL_DB_URL=sqlite:${gateway_dir}/gateway.db?mode=rwc" \
    -e "OPENSHELL_GATEWAY_SPIFFE_WORKLOAD_API_SOCKET=${SPIRE_AGENT_SOCKET_HOST_PATH}" \
    -e "XDG_DATA_HOME=${gateway_dir}/data" \
    -e "HOME=${gateway_dir}" \
    "$GATEWAY_IMAGE" \
    --config "$config_path"

gateway_ready=0
for _ in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:${GATEWAY_HEALTH_PORT}/readyz" >/dev/null 2>&1 ||
        curl -fsS "http://127.0.0.1:${GATEWAY_HEALTH_PORT}/healthz" >/dev/null 2>&1; then
        gateway_ready=1
        break
    fi
    sleep 0.5
done
if [[ "$gateway_ready" != "1" ]]; then
    podman logs "$GATEWAY_CONTAINER" >&2 || true
    printf "OpenShell gateway did not become ready at health port %s\n" "$GATEWAY_HEALTH_PORT" >&2
    exit 1
fi

# Register the gateway's SPIFFE entry. On macOS the gateway runs as a
# container, so the selector is the container label — not unix:uid,
# which would compute the macOS uid against a root container.
TRUST_DOMAIN="$TRUST_DOMAIN" \
    GATEWAY_SELECTORS="docker:label:openshell.spiffe-demo:gateway" \
    SPIRE_AGENT_PARENT_ID="$SPIRE_AGENT_PARENT_ID" \
    SPIRE_SERVER_CONTAINER="$SPIRE_SERVER_CONTAINER" \
    bash "${SCRIPT_DIR}/../spire/register-gateway.sh"

printf "\nOpenShell gateway is up.\n"
printf "  container: %s\n" "$GATEWAY_CONTAINER"
printf "  endpoint: %s (gateway name '%s')\n" "$GATEWAY_ENDPOINT" "$GATEWAY_NAME"
printf "  config: %s\n" "$config_path"
