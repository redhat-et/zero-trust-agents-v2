#!/usr/bin/env bash
# Shared helpers for scenario scripts. Driver-neutral: everything
# backend-specific (gateway endpoint, sandbox lifecycle, SVID fetches,
# URL variables) lives in scripts/drivers/lib-${ZT2_DRIVER}.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT/.zt2-state}"
mkdir -p "$STATE_DIR"

ZT2_DRIVER="${ZT2_DRIVER:-podman}"
DRIVER_FILE="$ROOT/scripts/drivers/lib-${ZT2_DRIVER}.sh"
if [[ ! -f "$DRIVER_FILE" ]]; then
    printf "unknown ZT2_DRIVER '%s' (no driver file at %s)\n" "$ZT2_DRIVER" "$DRIVER_FILE" >&2
    exit 1
fi
# shellcheck source=drivers/lib-podman.sh
source "$DRIVER_FILE"

# sandbox_spiffe_id ID — the SPIFFE ID of sandbox ID, identical across
# drivers (the trust domain and sandbox path are deployment-wide
# constants, not per-driver).
sandbox_spiffe_id() {
    echo "spiffe://openshell.local/openshell/sandbox/$1"
}

sandbox_id() {
    # Capture before parsing: awk's early exit closes the pipe and the
    # openshell CLI panics on the broken stdout, which pipefail turns
    # into a failed poll on Linux.
    local out
    out="$("${OS[@]}" sandbox get "$1" 2>/dev/null)" || return 1
    awk '/Id:/ {print $2; exit}' <<<"$out"
}

# create_sandbox NAME PROVIDER -- creates a long-lived sandbox and prints
# its ID. sandbox create blocks on the bootstrap command, so run it
# detached and poll for readiness.
create_sandbox() {
    local name="$1" provider="$2"
    "${OS[@]}" sandbox delete "$name" >/dev/null 2>&1 || true
    sleep 3
    pre_create_cleanup "$name"
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

scenario_header() {
    printf "\n%s\n  %s\n%s\n" "──────────────────────────────────────────────" "$1" "──────────────────────────────────────────────"
}
