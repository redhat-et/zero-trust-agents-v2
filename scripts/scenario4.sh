#!/usr/bin/env bash
# Scenario 4: Carol's sandbox with hr capability fetches an hr doc.
# Expected: ALLOWED — carol is in hr.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 4: Carol (hr) x hr capability -> hr doc"

SUBJECT_TOKEN="$(curl -fsS "$ISSUER_LOCAL/demo-subject-token?user=carol" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
"${OS[@]}" provider create --name carol-hr-prov-s4-$$ --type zt2-carol-hr-v2 \
    --credential "subject_token=${SUBJECT_TOKEN}" >/dev/null

ID="$(create_sandbox carol-s4 carol-hr-prov-s4-$$)"
register_sandbox "$ID" >/dev/null
echo "  sandbox: $ID (SPIFFE ID registered)"

sandbox_curl carol-s4 "$HR_URL/documents/DOC-004" "HR Guidelines"
echo "$SANDBOX_CURL_OUTPUT" | head -3
pass "carol's sandbox fetched DOC-004 through the full token-exchange chain"
