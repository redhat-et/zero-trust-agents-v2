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
    grep -v "^export $1=" "$STATE_FILE" 2>/dev/null || true >"$STATE_FILE.tmp"
    printf 'export %s="%s"\n' "$1" "$2" >>"$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# profile_dept PROFILE — the department endpoint a profile targets
# (mirrors profile_dept in the Stage 1 setup: alice-hr targets the
# engineering service with an hr capability — the denial scenario).
profile_dept() {
    case "$1" in
        carol-hr) echo hr ;;
        *) echo engineering ;;
    esac
}
