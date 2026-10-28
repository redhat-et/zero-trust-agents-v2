#!/usr/bin/env bash
# Scenario 3: sandbox without user delegation. Expected: DENIED — no
# subject token is stored, so the gateway has nothing to exchange and no
# token is ever minted.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 3: sandbox without user delegation -> engineering doc"

# The nodelegation profile declares subject_token as optional, so the
# provider can exist without a credential.
"${OS[@]}" provider create --name nodeleg-s3-$$ --type zt2-nodelegation-v2 >/dev/null

ID="$(create_sandbox alice-s3 nodeleg-s3-$$)"
register_sandbox "$ID" >/dev/null
echo "  sandbox: $ID (SPIFFE ID registered, no user delegation)"

if output="$("${OS[@]}" sandbox exec --name alice-s3 --no-tty -- \
    curl -sS --max-time 20 "$ENGINEERING_URL/documents/DOC-001" 2>&1)"; then
    if [[ "$output" == *"Engineering Roadmap"* ]]; then
        fail "sandbox without delegation unexpectedly fetched the doc: $output"
    fi
fi
pass "request denied — no token minted without a delegated user subject token"
