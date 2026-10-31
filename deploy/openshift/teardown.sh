#!/usr/bin/env bash
# Tear down the OpenShift demo: CLI state (sandboxes, providers,
# profiles), port-forwards, Helm releases, and namespaces. Leaves the
# spire CRDs and the agent-sandbox-system namespace unless --all is
# given (CRD deletion is cluster-wide and slow).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export STATE_DIR="${STATE_DIR:-$ROOT/.zt2-state}"
# shellcheck source=deploy/openshift/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_oc

ALL=0
[[ "${1:-}" == "--all" ]] && ALL=1
# Must match the manifest setup.sh applied (deleting a different
# version's CRDs would leave resources behind).
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v1.0.9}"

echo "== port-forwards =="
if [[ -f "$STATE_DIR/openshift-forward.pid" ]]; then
    kill "$(cat "$STATE_DIR/openshift-forward.pid")" 2>/dev/null || true
    rm -f "$STATE_DIR/openshift-forward.pid"
fi
# Forwards started by the scenario-harness driver (lib-openshift.sh).
for pidfile in "$STATE_DIR"/forward-*.pid; do
    [[ -f "$pidfile" ]] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
done

echo "== sandboxes, providers, profiles =="
if [[ -f "$STATE_DIR/openshift.env" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_DIR/openshift.env"
fi
OS=(openshell --gateway zt2 --gateway-endpoint "https://${ZT2_GATEWAY_ROUTE:-unset}")
if "${OS[@]}" status >/dev/null 2>&1; then
    for sbx in $("${OS[@]}" sandbox list 2>/dev/null | awk 'NR>1 {print $1}'); do
        "${OS[@]}" sandbox delete "$sbx" >/dev/null 2>&1 || true
    done
    for prov in $("${OS[@]}" provider list 2>/dev/null | awk 'NR>1 {print $1}'); do
        "${OS[@]}" provider delete "$prov" >/dev/null 2>&1 || true
    done
    # Profiles are immutable per ID: a leftover breaks the next setup.
    for prof in $("${OS[@]}" profile list 2>/dev/null | awk 'NR>1 && $1 ~ /^zt2-/ {print $1}'); do
        if ! "${OS[@]}" profile delete "$prof" >/dev/null 2>&1; then
            printf "warning: failed to delete profile %s (the next setup will fail if it persists)\n" "$prof" >&2
        fi
    done
else
    echo "gateway not reachable; skipping CLI state cleanup"
fi

echo "== helm releases =="
helm -n openshell uninstall openshell >/dev/null 2>&1 || true
helm -n spire uninstall spire >/dev/null 2>&1 || true

echo "== namespaces =="
oc delete namespace zt-demo zt2-sandboxes >/dev/null 2>&1 || true

if [[ "$ALL" == "1" ]]; then
    helm -n spire uninstall spire-crds >/dev/null 2>&1 || true
    oc delete crd clusterspiffeids.spire.spiffe.io >/dev/null 2>&1 || true
    oc delete namespace spire openshell agent-sandbox-system >/dev/null 2>&1 || true
    oc delete -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox.yaml" >/dev/null 2>&1 || true
else
    echo "leaving spire CRDs, spire/openshell namespaces, and agent-sandbox-system (use --all to remove)"
fi

echo "teardown complete"
