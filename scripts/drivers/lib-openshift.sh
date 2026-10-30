#!/usr/bin/env bash
# OpenShift driver for the scenario harness. Sourced by scripts/lib.sh
# when ZT2_DRIVER=openshift. Same contract as lib-podman.sh; the state
# file ($STATE_DIR/openshift.env, written by
# deploy/openshift/setup.sh) provides the gateway Route and the local
# subject-token minter port.
set -euo pipefail

# shellcheck source=/dev/null
[[ -f "$STATE_DIR/openshift.env" ]] && source "$STATE_DIR/openshift.env"
: "${ZT2_GATEWAY_ROUTE:?ZT2_GATEWAY_ROUTE not set (run deploy/openshift/setup.sh)}"

OS=(openshell --gateway zt2 --gateway-endpoint "https://$ZT2_GATEWAY_ROUTE")

# In-sandbox URLs: sandbox pods resolve in-cluster service DNS.
ENGINEERING_URL="http://document-engineering.zt-demo.svc:8080"
HR_URL="http://document-hr.zt-demo.svc:8080"

# Host-side URLs via lazily-started oc port-forwards. PIDs are recorded
# for teardown; the minter forward belongs to setup.sh and is only
# adopted here.
DEMO_SUBJECT_URL="http://127.0.0.1:${TOKEN_ISSUER_DEMO_HOST_PORT:-18090}"
ISSUER_LOCAL_PORT="${ZT2_ISSUER_LOCAL_PORT:-18080}"
ISSUER_LOCAL="http://127.0.0.1:$ISSUER_LOCAL_PORT"
ENGINEERING_LOCAL_PORT="${ZT2_ENGINEERING_LOCAL_PORT:-18101}"
ENGINEERING_LOCAL="http://127.0.0.1:$ENGINEERING_LOCAL_PORT"
FINANCE_LOCAL_PORT="${ZT2_FINANCE_LOCAL_PORT:-18102}"
FINANCE_LOCAL="http://127.0.0.1:$FINANCE_LOCAL_PORT"

# ensure_forward PORT RESOURCE — start a port-forward unless one is
# already recorded and alive for this port.
ensure_forward() {
    local port="$1" resource="$2"
    local pidfile="$STATE_DIR/forward-$port.pid"
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        return 0
    fi
    oc -n zt-demo port-forward "$resource" "${port}:8080" >/dev/null 2>&1 &
    echo $! >"$pidfile"
    for _ in $(seq 1 15); do
        curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 && return 0
        sleep 2
    done
    printf "port-forward %s (%s) did not become ready\n" "$port" "$resource" >&2
    return 1
}

pre_create_cleanup() {
    oc -n zt2-sandboxes delete sandbox "$1" --ignore-not-found >/dev/null 2>&1 || true
}

# register_sandbox ID — no registration entries on Kubernetes: the
# ClusterSPIFFEID mints the SVID via pod attestation. Wait until the
# SVID is actually obtainable, because the supervisor caches a failed
# token grant (same lesson as Stage 1's sleep 3).
register_sandbox() {
    local id="$1"
    for _ in $(seq 1 20); do
        if [[ -n "$(fetch_supervisor_svid "$id" 2>/dev/null || true)" ]]; then
            echo "SPIFFE ID        : spiffe://openshell.local/openshell/sandbox/$id (attested)"
            return 0
        fi
        sleep 3
    done
    echo "SVID for sandbox $id did not become obtainable" >&2
    return 1
}

# supervisor_logs ID — print the supervisor container's logs.
supervisor_logs() {
    oc -n zt2-sandboxes logs -l "openshell.ai/sandbox-id=$1" -c supervisor 2>&1
}

# svid_helper POD_NAME ANNOTATION... — apply the helper pod manifest
# with the given annotations substituted, wait for it, echo its name.
# The helper runs spire-agent with the CSI-mounted Workload API socket
# in the sandbox namespace, so SPIRE attributes the fetch to the
# identity the annotations select. There is no container watcher on
# Kubernetes: the helper cannot delete the real sandbox (the Podman
# WARNING does not apply).
svid_helper() {
    local pod="$1"; shift
    local annotations="" a k v
    for a in "$@"; do
        k="${a%%=*}"; v="${a#*=}"
        annotations+="    $k: \"$v\"
"
    done
    # awk via ENVIRON (not -v): the annotation block is multiline and
    # both BSD sed and BSD awk reject newlines in substitution values.
    ANN="$annotations" awk -v pod="$pod" '
        BEGIN { ann = ENVIRON["ANN"] }
        { gsub(/@POD_NAME@/, pod); gsub(/@ANNOTATIONS@/, ann); print }
    ' "$ROOT/deploy/openshift/svid-helper.yaml" |
        oc -n zt2-sandboxes apply -f - >/dev/null
    oc -n zt2-sandboxes wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null
}

svid_helper_fetch() {
    # svid_helper_fetch POD_NAME SPIFFE_ID — run the JWT-SVID fetch
    # inside a ready helper pod and print the token.
    oc -n zt2-sandboxes exec "$1" -- \
        /opt/spire/bin/spire-agent api fetch jwt \
        -socketPath /spiffe-workload-api/spire-agent.sock \
        -audience "http://token-issuer.zt-demo.svc:8080" \
        -spiffeID "$2" 2>/dev/null |
        awk '/^\t/ {print $1; exit}'
}

fetch_supervisor_svid() {
    local id="$1" token=""
    svid_helper "zt2-svid-$id" "openshell.ai/sandbox-id=$id" || return 1
    token="$(svid_helper_fetch "zt2-svid-$id" "spiffe://openshell.local/openshell/sandbox/$id")" || true
    oc -n zt2-sandboxes delete pod "zt2-svid-$id" --ignore-not-found >/dev/null 2>&1 || true
    [[ -n "$token" ]] || return 1
    echo "$token"
}

# fetch_gateway_svid — NO helper pod: a selector-matched helper is the
# impersonation the trust-tier separation exists to prevent. Attach an
# ephemeral spire-agent container to the real gateway pod instead,
# sharing its CSI-mounted Workload API socket.
fetch_gateway_svid() {
    local gw_spiffe_id="spiffe://openshell.local/ns/openshell/sa/openshell"
    oc debug -n openshell statefulset/openshell --image=ghcr.io/spiffe/spire-agent:1.12.4 -- \
        /opt/spire/bin/spire-agent api fetch jwt \
        -socketPath /spiffe-workload-api/spire-agent.sock \
        -audience "http://token-issuer.zt-demo.svc:8080" \
        -spiffeID "$gw_spiffe_id" 2>/dev/null |
        awk '/^\t/ {print $1; exit}'
}

# fetch_rogue_svid — request a rogue SPIFFE ID from a helper pod the
# attestation policy deliberately does not match; SPIRE must refuse.
# Returns non-zero, which scenario 5 treats as a pass.
fetch_rogue_svid() {
    svid_helper "zt2-svid-rogue" "zt2.rogue=true" || return 1
    local out=""
    out="$(svid_helper_fetch "zt2-svid-rogue" "spiffe://openshell.local/rogue/workload/1")" || true
    oc -n zt2-sandboxes delete pod "zt2-svid-rogue" --ignore-not-found >/dev/null 2>&1 || true
    if [[ -n "$out" ]]; then
        echo "$out"
        return 0
    fi
    return 1
}

# Host-side forwards the scenario scripts need (every scenario talks to
# the issuer; 3 and 6 talk to the document services). Started eagerly
# here so the scenario scripts can use the URL variables directly.
ensure_forward "$ISSUER_LOCAL_PORT" service/token-issuer
ensure_forward "$ENGINEERING_LOCAL_PORT" service/document-engineering
ensure_forward "$FINANCE_LOCAL_PORT" service/document-finance
