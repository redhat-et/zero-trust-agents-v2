#!/usr/bin/env bash
# Scenario 6: audience/replay attack — a final token scoped for the
# engineering service used against the finance service. Expected: DENIED
# by the audience check. The sandbox never sees its injected token (the
# supervisor adds it to the outbound request), so the replay is staged
# out-of-band: mint a token via direct /token calls using registered
# SVIDs, then curl the wrong service from the host.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 6: engineering-scoped token replayed against the finance service"

# Use the scenario-1 sandbox's registered supervisor SVID if present;
# otherwise create and register one.
ID="$(sandbox_id alice-s1 2>/dev/null || true)"
if [[ -z "$ID" ]]; then
    SUBJECT_TOKEN="$(curl -fsS "$ISSUER_LOCAL/demo-subject-token?user=alice" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
    "${OS[@]}" provider create --name "alice-eng-s6-$$" --type zt2-alice-engineering-v2 \
        --credential "subject_token=${SUBJECT_TOKEN}" >/dev/null
    ID="$(create_sandbox alice-s1 "alice-eng-s6-$$")"
    register_sandbox "$ID" >/dev/null
fi
SANDBOX_SPIFFE_ID="spiffe://openshell.local/openshell/sandbox/$ID"
echo "  supervisor SVID: $SANDBOX_SPIFFE_ID"

GW_SVID="$(fetch_svid "spiffe://openshell.local/openshell/gateway/demo" "openshell.spiffe-demo=gateway")"
SUP_SVID="$(fetch_svid "$SANDBOX_SPIFFE_ID" "openshell.ai/sandbox-id=$ID" "openshell.managed=true")"
if [[ -z "$GW_SVID" || -z "$SUP_SVID" ]]; then
    fail "could not fetch gateway/supervisor SVIDs"
fi

SUBJECT_TOKEN="$(curl -fsS "$ISSUER_LOCAL/demo-subject-token?user=alice" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

# Intermediate exchange as the gateway.
INTERMEDIATE="$(curl -fsS -X POST "$ISSUER_LOCAL/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
    -d "client_assertion=$GW_SVID" \
    -d "subject_token=$SUBJECT_TOKEN" \
    -d "audience=$SANDBOX_SPIFFE_ID" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

# Final exchange as the supervisor, scoped for engineering.
FINAL="$(curl -fsS -X POST "$ISSUER_LOCAL/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
    -d "client_assertion=$SUP_SVID" \
    -d "subject_token=$INTERMEDIATE" \
    -d "audience=engineering" -d "scope=engineering" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
echo "  final token minted (audience=engineering, scope=engineering)"

# Sanity: the token works against the engineering service.
STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $FINAL" \
    "http://127.0.0.1:18101/documents/DOC-001")"
if [[ "$STATUS" != "200" ]]; then
    fail "sanity check failed: engineering token got $STATUS from engineering service"
fi
echo "  sanity: token works against engineering service (200)"

# The attack: replay the same token against the finance service.
# DOC-005 is RequiredDepartments [finance, engineering], so the scope
# check would pass with scope=engineering — only the audience check can
# deny, making this assertion specifically about audience binding.
STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $FINAL" \
    "http://127.0.0.1:18102/documents/DOC-005")"
BODY="$(curl -s -H "Authorization: Bearer $FINAL" "http://127.0.0.1:18102/documents/DOC-005")"

if [[ "$STATUS" == "403" && "$BODY" == *"invalid_audience"* ]]; then
    pass "finance service rejected the engineering-audience token with 403 invalid_audience"
else
    fail "expected 403 invalid_audience from finance service, got $STATUS: $BODY"
fi
