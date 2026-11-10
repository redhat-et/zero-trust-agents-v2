#!/usr/bin/env bash
# Shared helpers for the OpenShift deploy scripts, mirroring the
# conventions of deploy/podman/spire/common.sh.
set -euo pipefail

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf "required command '%s' not found\n" "$1" >&2
        exit 1
    }
}

require_oc() {
    require_cmd oc
    if ! oc whoami >/dev/null 2>&1; then
        printf "not logged in to an OpenShift cluster (run: oc login)\n" >&2
        exit 1
    fi
}

# wait_rollout NS RESOURCE — block until the resource is available.
wait_rollout() {
    oc -n "$1" rollout status "$2" --timeout=300s >/dev/null
}

# state_set VAR VALUE — append an export line to the state file
# ($STATE_DIR/openshift.env), replacing any earlier definition.
STATE_FILE="${STATE_DIR:-$ROOT/.zt2-state}/openshift.env"
state_set() {
    mkdir -p "$(dirname "$STATE_FILE")"
    # The redirect must bind to grep (not to the `|| true` fallback):
    # `grep ... > tmp || true` keeps existing lines in tmp; a missing
    # state file leaves tmp empty, which is also correct.
    {
        grep -v "^export $1=" "$STATE_FILE" 2>/dev/null || true
        printf 'export %s="%s"\n' "$1" "$2"
    } >"$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# profile_dept PROFILE — the department endpoint a profile targets
# (mirrors profile_dept in the Stage 1 setup: alice-hr targets the
# engineering service with an hr capability — the denial scenario).
profile_dept() {
    case "$1" in
        carol-hr | carol-hr-analyst) echo hr ;;
        *) echo engineering ;;
    esac
}

# substitute_profile FILE DEPT — write the substituted profile to
# stdout: @DOC_HOST@ -> document-<dept> FQDN, @DOC_PORT@ -> 8080, and
# the entire @ALLOWED_IPS@ line is DELETED (a sed blanking would
# leave a whitespace-only line — valid YAML, silently wrong profile).
# The FQDN must be fully qualified: the sandbox's DNS proxy matches
# endpoint hosts exactly and the workload's resolver has no search
# domains (the short .svc form NXDOMAINs inside sandboxes).
substitute_profile() {
    awk -v host="document-$2.zt-demo.svc.cluster.local" -v port="8080" \
        -v issuer_host="${ZT2_ISSUER_EGRESS_HOST:-token-issuer.zt-demo.svc.cluster.local}" \
        -v issuer_port="8080" \
        -v a2a_host="${ZT2_A2A_HOST:-openshell.openshell.svc.cluster.local}" \
        -v a2a_port="${ZT2_A2A_PORT:-8080}" \
        -v model_host="${MODEL_HOST:-}" \
        -v model_port="${MODEL_PORT:-443}" '
        /@ALLOWED_IPS@/ { next }
        {
            gsub(/@DOC_HOST@/, host); gsub(/@DOC_PORT@/, port)
            gsub(/@ISSUER_HOST@/, issuer_host); gsub(/@ISSUER_PORT@/, issuer_port)
            gsub(/@A2A_HOST@/, a2a_host); gsub(/@A2A_PORT@/, a2a_port)
            gsub(/@MODEL_HOST@/, model_host); gsub(/@MODEL_PORT@/, model_port)
            print
        }
    ' "$1"
}

# kill_pidfile PIDFILE — kill the process recorded in a pidfile, but
# only after confirming it is still one of our port-forwards: a stale
# PID can be reused by an unrelated process, and signaling it blind
# would terminate that process. The pidfile is removed either way.
kill_pidfile() {
    local pid
    pid="$(cat "$1" 2>/dev/null)" || return 0
    [[ -n "$pid" ]] || return 0
    if ps -p "$pid" -o command= 2>/dev/null | grep -q "port-forward"; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$1"
}
