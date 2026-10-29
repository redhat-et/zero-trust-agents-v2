#!/usr/bin/env bash
# Shared helpers for scenario scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT/.zt2-state}"
mkdir -p "$STATE_DIR"

# setup.sh writes the SPIRE state paths (including the agent's Workload
# API socket) to <state>/spire.env; source it when the caller hasn't.
if [[ (-z "${SPIRE_AGENT_SOCKET_HOST_PATH:-}" || -z "${ZT2_HOST_IP:-}") &&
    -f "$STATE_DIR/spire.env" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_DIR/spire.env"
    export SPIRE_STATE_DIR SPIRE_AGENT_SOCKET_HOST_PATH ZT2_HOST_IP
fi
OS=(openshell --gateway zt2 --gateway-endpoint http://127.0.0.1:18083)
# shellcheck source=../deploy/podman/spire/common.sh
source "$ROOT/deploy/podman/spire/common.sh"
ENGINEERING_URL="http://$(doc_endpoint_host engineering):$(doc_endpoint_port engineering)"
HR_URL="http://$(doc_endpoint_host hr):$(doc_endpoint_port hr)"
ISSUER_LOCAL="http://127.0.0.1:8080"

sandbox_id() {
    # Capture before parsing: awk's early exit closes the pipe and the
    # openshell CLI panics on the broken stdout, which pipefail turns
    # into a failed poll on Linux.
    local out
    out="$("${OS[@]}" sandbox get "$1" 2>/dev/null)" || return 1
    awk '/Id:/ {print $2; exit}' <<<"$out"
}

register_sandbox() {
    local id="$1" out
    out="$(TRUST_DOMAIN=openshell.local SPIRE_SERVER_CONTAINER=zt2-spire-server \
        bash "$ROOT/deploy/podman/spire/register-sandbox.sh" "$id" 2>/dev/null)" || return 1
    # grep's exit status would abort the caller under set -e on a
    # non-match; capture-then-parse keeps that a normal empty result.
    grep "SPIFFE ID" <<<"$out" | head -1 || true
    # Let the entry reach the agent's cache before the first sandbox
    # request: the supervisor caches a failed token grant, so a request
    # racing entry registration fails every later retry too. (Gating on
    # fetch_svid is not an option — see its comment.)
    sleep 3
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
#
# WARNING: the probe container carries the sandbox's labels, and the
# gateway's container watcher treats any container with them as the
# sandbox — when the probe exits, the watcher deletes the real sandbox.
# Only call this once the sandbox is no longer needed.
fetch_svid() {
    local spiffe_id="$1"; shift
    local args=()
    for label in "$@"; do
        args+=(--label "$label")
    done
    local token=""
    for _ in $(seq 1 10); do
        local svid_out
        if svid_out="$(timeout 90 podman run --rm --entrypoint /opt/spire/bin/spire-agent \
            "${args[@]}" \
            -v "${SPIRE_AGENT_SOCKET_HOST_PATH:?}:${SPIRE_AGENT_SOCKET_HOST_PATH}:z" \
            ghcr.io/spiffe/spire-agent:1.12.4 \
            api fetch jwt -socketPath "$SPIRE_AGENT_SOCKET_HOST_PATH" \
            -audience "http://token-issuer.zt-demo.svc:8080" \
            -spiffeID "$spiffe_id" 2>/dev/null)"; then
            token="$(awk '/^\t/ {print $1; exit}' <<<"$svid_out")"
        fi
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
