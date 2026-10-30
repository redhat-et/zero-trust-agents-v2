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

# On Podman the rogue SVID can be minted (the entry is registered
# against a dedicated container label) and the issuer must reject it;
# on Kubernetes the attestation policy refuses to issue it at all.
# Both outcomes are a pass — the identity check holds either way.
if ! ROGUE_SVID="$(fetch_rogue_svid)"; then
    pass "SPIRE refused to issue an identity outside the attestation policy — nothing to present"
    exit 0
fi
echo "  rogue SVID fetched (${#ROGUE_SVID} chars, validly signed by SPIRE)"

# Attempt the intermediate exchange directly at the issuer, with a valid
# subject token so the only thing that can deny is the rogue SVID.
SUBJECT_TOKEN="$(curl -fsS "$DEMO_SUBJECT_URL/demo-subject-token?user=alice" |
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
