#!/usr/bin/env bash
# Scenario 2: Alice's sandbox with hr capability fetches an engineering
# doc. Expected: DENIED — alice's departments (engineering, finance) do
# not intersect the hr capability, so no token carries the engineering
# scope. The intersection is enforced at token-mint time.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 2: Alice (engineering+finance) x hr capability -> engineering doc"

SUBJECT_TOKEN="$(curl -fsS "$DEMO_SUBJECT_URL/demo-subject-token?user=alice" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
"${OS[@]}" provider create --name alice-hr-prov-s2-$$ --type zt2-alice-hr-v2 \
    --credential "subject_token=${SUBJECT_TOKEN}" >/dev/null

ID="$(create_sandbox alice-s2 alice-hr-prov-s2-$$)"
register_sandbox "$ID" >/dev/null
echo "  sandbox: $ID (SPIFFE ID registered)"

# The request must be denied at the supervisor's proxy (502) because the
# token grant fails; the issuer-side proof below pins the exact reason.
RESP="$("${OS[@]}" sandbox exec --name alice-s2 --no-tty -- \
    curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    "$ENGINEERING_URL/documents/DOC-001" 2>&1 || true)"
if [[ "$RESP" != "502" ]]; then
    if [[ "$RESP" == "200" ]]; then
        fail "sandbox unexpectedly fetched the engineering doc"
    fi
    fail "expected the proxy to deny with 502, got: $RESP"
fi
pass "request denied at the proxy — no token minted with an engineering scope for an hr-only capability"

# Issuer-side proof: drive the exact exchange the supervisor would make
# (alice's subject token -> intermediate -> final with hr scope) and
# observe the intersection deny directly.
echo "  issuer-side proof (final exchange: alice + hr scope + engineering audience):"
GW_SVID="$(fetch_gateway_svid)"
SUP_SVID="$(fetch_supervisor_svid "$ID")"
INTERMEDIATE="$(curl -fsS -X POST "$ISSUER_LOCAL/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
    -d "client_assertion=$GW_SVID" -d "subject_token=$SUBJECT_TOKEN" \
    -d "audience=spiffe://openshell.local/openshell/sandbox/$ID" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ISSUER_LOCAL/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
    -d "client_assertion=$SUP_SVID" -d "subject_token=$INTERMEDIATE" \
    -d "audience=engineering" -d "scope=hr")"
BODY="$(curl -s -X POST "$ISSUER_LOCAL/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
    -d "client_assertion=$SUP_SVID" -d "subject_token=$INTERMEDIATE" \
    -d "audience=engineering" -d "scope=hr")"
if [[ "$STATUS" == "403" && "$BODY" == *"insufficient_department_permissions"* ]]; then
    pass "issuer returned 403 insufficient_department_permissions — the intersection is enforced at mint time"
else
    fail "expected 403 insufficient_department_permissions, got $STATUS: $BODY"
fi
