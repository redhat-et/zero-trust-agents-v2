#!/usr/bin/env bash
# Shared helpers for scenario scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT/.zt2-state}"
mkdir -p "$STATE_DIR"

# setup.sh writes the SPIRE state paths (including the agent's Workload
# API socket) to <state>/spire.env; source it when the caller hasn't.
if [[ -z "${SPIRE_AGENT_SOCKET_HOST_PATH:-}" && -f "$STATE_DIR/spire.env" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_DIR/spire.env"
    export SPIRE_STATE_DIR SPIRE_AGENT_SOCKET_HOST_PATH
fi
OS=(openshell --gateway zt2 --gateway-endpoint http://127.0.0.1:18083)
ENGINEERING_URL="http://192.168.127.254.nip.io:18101"
HR_URL="http://192.168.127.254.nip.io:18104"
ISSUER_LOCAL="http://127.0.0.1:8080"

sandbox_id() {
    "${OS[@]}" sandbox get "$1" | awk '/Id:/ {print $2; exit}'
}

register_sandbox() {
    local id="$1"
    TRUST_DOMAIN=openshell.local SPIRE_SERVER_CONTAINER=zt2-spire-server \
        bash "$ROOT/deploy/podman/spire/register-sandbox.sh" "$id" 2>/dev/null |
        grep "SPIFFE ID" | head -1
}

# create_sandbox NAME PROVIDER -- creates a long-lived sandbox and prints
# its ID. sandbox create blocks on the bootstrap command, so run it
# detached and poll for readiness.
create_sandbox() {
    local name="$1" provider="$2"
    "${OS[@]}" sandbox delete "$name" >/dev/null 2>&1 || true
    sleep 3
    podman ps -a --filter "name=$name" -q | xargs -r podman rm -f >/dev/null 2>&1 || true
    nohup "${OS[@]}" sandbox create --name "$name" \
        --from docker.io/curlimages/curl:latest \
        --provider "$provider" --keep --no-tty -- sleep infinity \
        >"$STATE_DIR/$name-create.log" 2>&1 &
    for _ in $(seq 1 60); do
        if id="$(sandbox_id "$name" 2>/dev/null)" && [[ -n "$id" ]]; then
            echo "$id"
            return 0
        fi
        sleep 2
    done
    echo "sandbox $name did not become ready; see $STATE_DIR/$name-create.log" >&2
    return 1
}

# sandbox_curl NAME URL EXPECTED_SUBSTRING [ATTEMPTS] — curl from inside
# the sandbox, retrying while the SVID propagates. Sets SANDBOX_CURL_OUTPUT.
sandbox_curl() {
    local name="$1" url="$2" expected="$3" attempts="${4:-18}"
    local output=""
    for i in $(seq 1 "$attempts"); do
        if output="$("${OS[@]}" sandbox exec --name "$name" --no-tty -- \
            curl -sS --max-time 15 "$url" 2>&1)"; then
            if [[ "$output" == *"$expected"* ]]; then
                SANDBOX_CURL_OUTPUT="$output"
                return 0
            fi
        fi
        sleep 2
    done
    echo "timed out waiting for $url to return '$expected'; last output:" >&2
    echo "$output" >&2
    return 1
}

pass() { printf "  \033[32m✅ PASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m❌ FAIL\033[0m %s\n" "$1"; exit 1; }

# fetch_svid SPIFFE_ID LABEL... — fetch a JWT-SVID out-of-band. SPIRE
# attributes the fetch to the calling process, so the fetch must run in
# a container carrying the entry's docker label selector. Retries while
# the registration propagates to the agent.
fetch_svid() {
    local spiffe_id="$1"; shift
    local args=()
    for label in "$@"; do
        args+=(--label "$label")
    done
    local token=""
    for _ in $(seq 1 10); do
        token="$(timeout 90 podman run --rm --entrypoint /opt/spire/bin/spire-agent \
            "${args[@]}" \
            -v "${SPIRE_AGENT_SOCKET_HOST_PATH:?}:${SPIRE_AGENT_SOCKET_HOST_PATH}:z" \
            ghcr.io/spiffe/spire-agent:1.12.4 \
            api fetch jwt -socketPath "$SPIRE_AGENT_SOCKET_HOST_PATH" \
            -audience "http://token-issuer.zt-demo.svc:8080" \
            -spiffeID "$spiffe_id" 2>/dev/null | awk '/^\t/ {print $1; exit}')"
        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi
        sleep 3
    done
    return 1
}

scenario_header() {
    printf "\n%s\n  %s\n%s\n" "──────────────────────────────────────────────" "$1" "──────────────────────────────────────────────"
}
