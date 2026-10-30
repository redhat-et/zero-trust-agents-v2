#!/usr/bin/env bash
# Self-test for the OpenShift profile substitution contract that
# deploy/openshift/setup.sh implements: @DOC_HOST@ ->
# document-<dept>.zt-demo.svc, @DOC_PORT@ -> 8080, and the entire
# @ALLOWED_IPS@ line is DELETED (a sed blanking would leave a
# whitespace-only line — valid YAML, silently wrong profile).
#
# Asserts both that the result parses as YAML and that each endpoints
# block has exactly one entry with the expected host: the parse alone
# would not catch the whitespace-line failure mode.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# profile -> department (mirrors the Podman profiles)
declare -A DEPT=(
    [alice-engineering]=engineering
    [alice-hr]=hr
    [carol-hr]=hr
    [nodelegation]=engineering
)

# substitute FILE DEPT — the exact transformation setup.sh performs.
substitute() {
    awk -v host="document-$2.zt-demo.svc" -v port="8080" '
        /@ALLOWED_IPS@/ { next }
        { gsub(/@DOC_HOST@/, host); gsub(/@DOC_PORT@/, port); print }
    ' "$1"
}

fail() { printf "  \033[31m❌ FAIL\033[0m %s\n" "$1"; exit 1; }
pass() { printf "  \033[32m✅ PASS\033[0m %s\n" "$1"; }

for profile in "${!DEPT[@]}"; do
    dept="${DEPT[$profile]}"
    expected_host="document-${dept}.zt-demo.svc"
    out="$(substitute "$HERE/$profile.yaml.in" "$dept")"

    # 1. no placeholder survives
    if grep -q '@[A-Z_]*@' <<<"$out"; then
        fail "$profile: unsubstituted placeholder remains"
    fi

    # 2. parses as YAML
    if ! yq eval '.' - <<<"$out" >/dev/null 2>&1; then
        fail "$profile: substituted profile is not valid YAML"
    fi

    # 3. exactly one endpoint entry with the expected host (and no
    #    empty entries from a blanked @ALLOWED_IPS@ line)
    n="$(yq '.endpoints | length' - <<<"$out")"
    if [[ "$n" != "1" ]]; then
        fail "$profile: expected 1 endpoint entry, got $n"
    fi
    host="$(yq '.endpoints[0].host' - <<<"$out")"
    if [[ "$host" != "$expected_host" ]]; then
        fail "$profile: endpoint host is '$host', expected '$expected_host'"
    fi
    port="$(yq '.endpoints[0].port' - <<<"$out")"
    if [[ "$port" != "8080" ]]; then
        fail "$profile: endpoint port is '$port', expected 8080"
    fi
    pass "$profile: valid YAML, single endpoint $expected_host:8080"
done
