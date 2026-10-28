#!/usr/bin/env bash
# Scenario 5: rogue sandbox — a workload with a validly-signed SVID whose
# SPIFFE ID is not registered under the supervisor prefix. Expected:
# DENIED at the issuer's SVID verification (401 invalid_client_assertion)
# — workload identity is the root of trust, not credentials the sandbox
# could have stolen.
#
# SPIRE will not issue an SVID outside its own trust domain, so "rogue"
# means a non-registered path INSIDE the trust domain:
# spiffe://openshell.local/rogue/workload/1, registered against a
# dedicated container label.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 5: rogue sandbox (unregistered SPIFFE ID) requests a token"

ROGUE_SPIFFE_ID="spiffe://openshell.local/rogue/workload/1"
echo "  registering rogue entry: $ROGUE_SPIFFE_ID"

TRUST_DOMAIN=openshell.local \
SANDBOX_SPIFFE_ID="$ROGUE_SPIFFE_ID" \
SPIRE_AGENT_PARENT_ID="spiffe://openshell.local/openshell/spire-agent/demo" \
SPIRE_SERVER_CONTAINER=zt2-spire-server \
SANDBOX_SELECTORS="docker:label:zt2.rogue:true" \
    bash "$ROOT/deploy/podman/spire/register-sandbox.sh" "rogue-workload-1" 2>/dev/null || true

ROGUE_SVID="$(fetch_svid "$ROGUE_SPIFFE_ID" "zt2.rogue=true")"
if [[ -z "$ROGUE_SVID" ]]; then
    fail "could not fetch a rogue SVID (SPIRE registration or fetch failed)"
fi
echo "  rogue SVID fetched (${#ROGUE_SVID} chars, validly signed by SPIRE)"

# Attempt the intermediate exchange directly at the issuer, with a valid
# subject token so the only thing that can deny is the rogue SVID.
SUBJECT_TOKEN="$(curl -fsS "$ISSUER_LOCAL/demo-subject-token?user=alice" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ISSUER_LOCAL/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
    -d "client_assertion=$ROGUE_SVID" \
    -d "subject_token=$SUBJECT_TOKEN" \
    -d "audience=spiffe://openshell.local/openshell/sandbox/whatever")"
BODY="$(curl -s -X POST "$ISSUER_LOCAL/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
    -d "client_assertion=$ROGUE_SVID" \
    -d "subject_token=$SUBJECT_TOKEN" \
    -d "audience=spiffe://openshell.local/openshell/sandbox/whatever")"

if [[ "$STATUS" == "401" && "$BODY" == *"invalid_client_assertion"* ]]; then
    pass "issuer rejected the rogue SVID with 401 invalid_client_assertion — nothing minted"
else
    fail "expected 401 invalid_client_assertion for rogue SVID, got $STATUS: $BODY"
fi
