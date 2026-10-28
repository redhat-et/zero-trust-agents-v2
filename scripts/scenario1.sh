#!/usr/bin/env bash
# Scenario 1: Alice's sandbox with engineering capability fetches an
# engineering doc. Expected: ALLOWED — alice is in engineering.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 1: Alice (engineering+finance) x engineering capability -> engineering doc"

SUBJECT_TOKEN="$(curl -fsS "$ISSUER_LOCAL/demo-subject-token?user=alice" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
"${OS[@]}" provider create --name alice-eng-s1-$$ --type zt2-alice-engineering-v2 \
    --credential "subject_token=${SUBJECT_TOKEN}" >/dev/null

ID="$(create_sandbox alice-s1 alice-eng-s1-$$)"
register_sandbox "$ID" >/dev/null
echo "  sandbox: $ID (SPIFFE ID registered)"

sandbox_curl alice-s1 "$ENGINEERING_URL/documents/DOC-001" "Engineering Roadmap"
echo "$SANDBOX_CURL_OUTPUT" | head -3
pass "sandbox fetched DOC-001 through the full token-exchange chain"
