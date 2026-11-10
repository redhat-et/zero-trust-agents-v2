#!/usr/bin/env bash
# Scenario 14: replay across peers. A final token minted for the
# engineering analyst is presented to the hr analyst. Expected: DENIED by
# the hr analyst with 403 invalid_audience. Sandboxes never see their
# injected tokens, so the token is minted out of band the same way
# scenario 6 mints one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 14: an engineering-analyst token replayed at the hr analyst"

echo "  == agent C: the hr analyst =="
agent_provider "carol-hr-prov-14-$$" zt2-carol-hr-analyst-v2 carol
C_ID="$(create_sandbox hr-analyst "carol-hr-prov-14-$$" "$AGENT_IMAGE")"
register_sandbox "$C_ID" >/dev/null
"${OS[@]}" service expose hr-analyst 8000 agent \
    --authorization-mode bearer-passthrough >/dev/null

write_agent_config "$ROOT/agents/hr-analyst" "$STATE_DIR/a2a/c" \
    "spiffe://openshell.local/openshell/sandbox/not-the-replay-caller"
sandbox_upload hr-analyst "$STATE_DIR/a2a/c/agent" /workspace >/dev/null
start_docsclaw_serve hr-analyst

# The replay is issued from this host, so it goes through the service URL
# the gateway publishes locally, not the sandbox relay.
TARGET="$(service_url hr-analyst agent)"
TARGET="${TARGET%/}"
[[ -n "$TARGET" ]] || fail "the gateway reports no URL for hr-analyst/agent"
wait_for_health "$TARGET" || fail "the hr analyst is not answering on its service URL"

# The mint needs a supervisor SVID, and on Podman fetching one deletes
# that sandbox, so it gets a throwaway of its own.
echo "  == sacrificial sandbox for the out-of-band mint =="
agent_provider "alice-eng-prov-14-$$" zt2-alice-engineering-v2 alice
MINT_ID="$(create_sandbox mint-s14 "alice-eng-prov-14-$$")"
register_sandbox "$MINT_ID" >/dev/null

TOKEN="$(mint_final_token "$MINT_ID" engineering-analyst engineering alice)"
printf "\nMinted token claims:\n"
decode_jwt "$TOKEN"

BODY="$(curl -sS -m 15 -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"role":"user","parts":[{"kind":"text","text":"summarize DOC-004"}],"messageId":"m1","kind":"message"}}}' \
    "$TARGET/a2a")"
STATUS="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{}}' "$TARGET/a2a")"

if [[ "$STATUS" == "403" && "$BODY" == *invalid_audience* ]]; then
    pass "the hr analyst refused the engineering-analyst token with 403 invalid_audience"
else
    fail "expected 403 invalid_audience from the hr analyst, got $STATUS: $BODY"
fi
