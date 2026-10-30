#!/usr/bin/env bash
# Podman driver for the scenario harness. Sourced by scripts/lib.sh when
# ZT2_DRIVER=podman (the default). Defines the driver contract: the OS
# array, host/sandbox URL variables, sandbox lifecycle helpers, and the
# SVID fetch helpers. Everything here is Podman-specific; the scenario
# scripts go through lib.sh and never call podman directly.
set -euo pipefail

# setup.sh writes the SPIRE state paths (including the agent's Workload
# API socket) to <state>/spire.env; source it when the caller hasn't.
if [[ (-z "${SPIRE_AGENT_SOCKET_HOST_PATH:-}" || -z "${ZT2_HOST_IP:-}" ||
    -z "${TOKEN_ISSUER_DEMO_HOST_PORT:-}") && -f "$STATE_DIR/spire.env" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_DIR/spire.env"
    export SPIRE_STATE_DIR SPIRE_AGENT_SOCKET_HOST_PATH ZT2_HOST_IP \
        TOKEN_ISSUER_DEMO_HOST_PORT
fi
OS=(openshell --gateway zt2 --gateway-endpoint http://127.0.0.1:18083)
# shellcheck source=../../deploy/podman/spire/common.sh
source "$ROOT/deploy/podman/spire/common.sh"
ENGINEERING_URL="http://$(doc_endpoint_host engineering):$(doc_endpoint_port engineering)"
HR_URL="http://$(doc_endpoint_host hr):$(doc_endpoint_port hr)"
# Host-side URLs: the services are published on loopback only
# (start-services.sh), and the nip.io host that in-sandbox containers
# use is not reachable from the laptop on macOS (it lives inside the
# Podman VM).
ENGINEERING_LOCAL="http://127.0.0.1:$(doc_endpoint_port engineering)"
FINANCE_LOCAL="http://127.0.0.1:$(doc_endpoint_port finance)"
ISSUER_LOCAL="http://127.0.0.1:8080"
# The unauthenticated subject-token minter is served on the issuer's
# loopback-only listener (see start-services.sh).
DEMO_SUBJECT_URL="http://127.0.0.1:${TOKEN_ISSUER_DEMO_HOST_PORT:-8090}"

pre_create_cleanup() {
    podman ps -a --filter "name=$1" -q | xargs -r podman rm -f >/dev/null 2>&1 || true
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

# supervisor_logs ID — print the supervisor container's logs for sandbox
# ID (scenario 3 greps them for the failed token grant).
supervisor_logs() {
    local sup
    sup="$(podman ps -a --filter "label=openshell.ai/sandbox-id=$1" \
        --format '{{.Names}}' | grep supervisor)"
    podman logs "$sup" 2>&1
}

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

fetch_gateway_svid() {
    fetch_svid "spiffe://openshell.local/openshell/gateway/demo" "openshell.spiffe-demo=gateway"
}

fetch_supervisor_svid() {
    fetch_svid "spiffe://openshell.local/openshell/sandbox/$1" \
        "openshell.ai/sandbox-id=$1" "openshell.managed=true"
}

# fetch_rogue_svid — register a rogue entry (a validly-signed SVID at a
# SPIFFE path the issuer's supervisor prefix check rejects) and fetch
# it. Returns non-zero if SPIRE refuses, which scenario 5 treats as a
# pass on drivers whose attestation policy would not mint it at all.
fetch_rogue_svid() {
    local spiffe_id="spiffe://openshell.local/rogue/workload/1"
    TRUST_DOMAIN=openshell.local \
    SANDBOX_SPIFFE_ID="$spiffe_id" \
    SPIRE_AGENT_PARENT_ID="spiffe://openshell.local/openshell/spire-agent/demo" \
    SPIRE_SERVER_CONTAINER=zt2-spire-server \
    SANDBOX_SELECTORS="docker:label:zt2.rogue:true" \
        bash "$ROOT/deploy/podman/spire/register-sandbox.sh" "rogue-workload-1" 2>/dev/null || true
    fetch_svid "$spiffe_id" "zt2.rogue=true"
}
