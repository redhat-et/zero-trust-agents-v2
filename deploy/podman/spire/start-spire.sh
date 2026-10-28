#!/usr/bin/env bash
# Adapted from OpenShell examples/spiffe-token-exchange-demo/podman/spire
# (NVIDIA, Apache-2.0): starts server + OIDC provider, then the agent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd podman
require_cmd curl
require_cmd awk

if [[ -z "$SPIRE_STATE_DIR" ]]; then
    SPIRE_STATE_DIR="$(mktemp -d)"
fi

if ! PODMAN_SOCKET="$(detect_podman_socket)"; then
    printf "could not find a Podman API socket; set PODMAN_SOCKET\n" >&2
    exit 1
fi

reset_env_file
ensure_network

server_dir="${SPIRE_STATE_DIR}/server"
agent_dir="${SPIRE_STATE_DIR}/agent"
mount_dir="${SPIRE_STATE_DIR}/mounts"
server_conf_mount="${mount_dir}/server.conf"
oidc_conf_mount="${mount_dir}/oidc-discovery-provider.conf"
agent_conf_mount="${mount_dir}/agent.conf"
server_socket_host_path="${server_dir}/private/api.sock"
SPIRE_AGENT_SOCKET_HOST_PATH="${SPIRE_AGENT_SOCKET_HOST_PATH:-${agent_dir}/sockets/agent.sock}"

mkdir -p "${server_dir}/data" "${server_dir}/private" "${agent_dir}/data" \
    "${agent_dir}/sockets" "$mount_dir"
chmod 0777 "$SPIRE_STATE_DIR" "$server_dir" "${server_dir}/data" \
    "${server_dir}/private" "$agent_dir" "${agent_dir}/data" "${agent_dir}/sockets"
copy_config "${SCRIPT_DIR}/server.conf" "$server_conf_mount"
copy_config "${SCRIPT_DIR}/oidc-discovery-provider.conf" "$oidc_conf_mount"
copy_config "${SCRIPT_DIR}/agent.conf" "$agent_conf_mount"

if [[ "$CLEANUP_EXISTING" == "1" ]]; then
    cleanup_container "$SPIRE_AGENT_CONTAINER"
    cleanup_container "$SPIRE_OIDC_CONTAINER"
    cleanup_container "$SPIRE_SERVER_CONTAINER"
fi

printf "Starting SPIRE server container: %s\n" "$SPIRE_SERVER_CONTAINER" >&2
run podman run -d \
    --name "$SPIRE_SERVER_CONTAINER" \
    --network "$PODMAN_NETWORK" \
    --network-alias spire-server \
    -v "${server_conf_mount}:/run/spire/config/server.conf:ro,z" \
    -v "${server_dir}:/run/spire/server:z" \
    "$SPIRE_SERVER_IMAGE" \
    -config /run/spire/config/server.conf

if ! wait_for_socket "$server_socket_host_path" "SPIRE server API socket"; then
    podman logs "$SPIRE_SERVER_CONTAINER" >&2 || true
    exit 1
fi

printf "Starting SPIRE OIDC discovery provider container: %s\n" "$SPIRE_OIDC_CONTAINER" >&2
run podman run -d \
    --name "$SPIRE_OIDC_CONTAINER" \
    --network "$PODMAN_NETWORK" \
    --network-alias spire-oidc \
    -p "127.0.0.1:${OIDC_PORT}:8080" \
    -v "${oidc_conf_mount}:/run/spire/config/oidc-discovery-provider.conf:ro,z" \
    -v "${server_dir}/private:/run/spire/server/private:z" \
    "$SPIRE_OIDC_IMAGE" \
    -config /run/spire/config/oidc-discovery-provider.conf

if ! wait_for_http "http://127.0.0.1:${OIDC_PORT}/keys" "SPIRE OIDC discovery provider"; then
    podman logs "$SPIRE_OIDC_CONTAINER" >&2 || true
    exit 1
fi

join_token="$(
    podman exec "$SPIRE_SERVER_CONTAINER" "$SPIRE_SERVER_BIN" token generate \
        -socketPath /run/spire/server/private/api.sock \
        -spiffeID "$SPIRE_AGENT_PARENT_ID" |
        awk '/Token:/ { print $2; exit }'
)"
if [[ -z "$join_token" ]]; then
    printf "failed to generate SPIRE agent join token\n" >&2
    exit 1
fi

printf "Starting SPIRE agent container: %s\n" "$SPIRE_AGENT_CONTAINER" >&2
run podman run -d \
    --name "$SPIRE_AGENT_CONTAINER" \
    --network "$PODMAN_NETWORK" \
    --pid=host \
    --security-opt label=disable \
    -v "${agent_conf_mount}:/run/spire/config/agent.conf:ro,z" \
    -v "${agent_dir}:/run/spire/agent:z" \
    -v "$(podman_socket_volume "$PODMAN_SOCKET" /run/podman/podman.sock)" \
    "$SPIRE_AGENT_IMAGE" \
    -config /run/spire/config/agent.conf -joinToken "$join_token"

if ! wait_for_socket "$SPIRE_AGENT_SOCKET_HOST_PATH" "SPIRE agent Workload API socket"; then
    podman logs "$SPIRE_AGENT_CONTAINER" >&2 || true
    exit 1
fi

write_env_line SPIRE_STATE_DIR "$SPIRE_STATE_DIR"
write_env_line SPIRE_AGENT_SOCKET_HOST_PATH "$SPIRE_AGENT_SOCKET_HOST_PATH"

printf "\nSPIRE is up.\n"
printf "  containers: %s %s %s\n" "$SPIRE_SERVER_CONTAINER" "$SPIRE_AGENT_CONTAINER" "$SPIRE_OIDC_CONTAINER" >&2
printf "  agent Workload API socket: %s\n" "$SPIRE_AGENT_SOCKET_HOST_PATH"
printf "  OIDC JWKS: http://127.0.0.1:%s/keys\n" "$OIDC_PORT"
if [[ -n "$SPIRE_ENV_FILE" ]]; then
    printf "  environment file: %s\n" "$SPIRE_ENV_FILE"
fi
