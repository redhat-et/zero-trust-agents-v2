#!/usr/bin/env bash
# Self-test for the OpenShift profile substitution contract in
# deploy/openshift/lib.sh (substitute_profile): @DOC_HOST@ ->
# document-<dept>.zt-demo.svc, @DOC_PORT@ -> 8080, and the entire
# @ALLOWED_IPS@ line is DELETED (a sed blanking would leave a
# whitespace-only line — valid YAML, silently wrong profile).
#
# Asserts both that the result parses as YAML and that each endpoints
# block has exactly one entry with the expected host: the parse alone
# would not catch the whitespace-line failure mode.
#
# POSIX-ish on purpose (no associative arrays): the README documents a
# macOS laptop workflow, where /usr/bin/env bash is 3.2.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$(dirname "$HERE")/lib.sh"

# The assertions need mikefarah yq v4 syntax.
if ! yq --version 2>/dev/null | grep -q 'version v4\.'; then
    printf "mikefarah yq v4 required (found: %s)\n" "$(yq --version 2>/dev/null || echo none)" >&2
    exit 1
fi

fail() { printf "  \033[31m❌ FAIL\033[0m %s\n" "$1"; exit 1; }
pass() { printf "  \033[32m✅ PASS\033[0m %s\n" "$1"; }

for profile in alice-engineering alice-hr carol-hr nodelegation; do
    dept="$(profile_dept "$profile")"
    expected_host="document-${dept}.zt-demo.svc.cluster.local"
    out="$(substitute_profile "$HERE/$profile.yaml.in" "$dept")"

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
        fail "$profile: endpoint host is '$host', expected $expected_host"
    fi
    port="$(yq '.endpoints[0].port' - <<<"$out")"
    if [[ "$port" != "8080" ]]; then
        fail "$profile: endpoint port is $port, expected 8080"
    fi
    pass "$profile: valid YAML, single endpoint $expected_host:8080"
done
