#!/usr/bin/env bash
# Scenario 11: agent-to-agent call through the full chain. Alice's
# assistant (A) asks the engineering analyst (B) to review DOC-001.
# Expected: ALLOWED. A's supervisor mints an engineering-analyst final
# token; B verifies it and logs the claims.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 11: Alice's assistant calls the engineering analyst"

require_agent_env
trap 'stop_relay eng-analyst; stop_relay alice-a2a' EXIT

echo "  == agent B: create, expose, publish =="
agent_provider "eng-analyst-prov-$$" zt2-engineering-analyst-v2 alice
B_ID="$(create_agent_service eng-analyst "eng-analyst-prov-$$" 8000)"
register_sandbox "$B_ID" >/dev/null
publish_a2a_peer eng-analyst 8000

echo "  == agent A: create =="
remove_sandbox alice-a2a
remove_sandbox alice-a2a-2
rm -f "$STATE_DIR/relay-alice-a2a.pid"
render_alice_a2a_profile

agent_provider "alice-a2a-prov-$$" zt2-alice-a2a-v2 alice
A_ID="$(create_agent_service alice-a2a "alice-a2a-prov-$$" 8000)"
register_sandbox "$A_ID" >/dev/null

echo "  == configs: B's caller allowlist is A's exact SVID =="
write_agent_config "$ROOT/agents/engineering-analyst" "$STATE_DIR/a2a/b" \
    "$(sandbox_spiffe_id "$A_ID")"
sandbox_upload eng-analyst "$STATE_DIR/a2a/b/agent" "$WORKSPACE_DIR" >/dev/null
start_docsclaw_serve eng-analyst

PEER_URL="$(peer_url "$A2A_HOST" "$A2A_PORT")"
HR_PEER_URL="$(peer_url "$A2A_HOST" "$A2A_HR_PORT")"
write_agent_config "$ROOT/agents/doc-assistant" "$STATE_DIR/a2a/a" "" \
    "$PEER_URL" "$HR_PEER_URL"
sandbox_upload alice-a2a "$STATE_DIR/a2a/a/agent" "$WORKSPACE_DIR" >/dev/null

echo "  == A asks B =="
if ! sandbox_ask alice-a2a \
    "Ask the engineering-analyst peer to review document DOC-001 and summarize it." ""; then
    fail "A's a2a_call to B did not succeed"
fi
show_trace
[[ -n "$SANDBOX_ASK_OUTPUT" ]] || fail "A returned an empty answer"

if [[ "$SANDBOX_ASK_TRACE" != *a2a_call* ]]; then
    fail "A's trace does not show the a2a_call tool"
fi
echo "  A's trace shows the a2a_call"

echo "  == B's verification log =="
B_LOG="$(agent_log eng-analyst)"
AUTH_LINE="$(echo "$B_LOG" | grep 'request authenticated' | tail -1)"
[[ -n "$AUTH_LINE" ]] || fail "B logged no authenticated request"
echo "  $AUTH_LINE"
A_SVID="$(sandbox_spiffe_id "$A_ID")"
for claim in "\"sub\":\"alice\"" "\"azp\":\"$A_SVID\"" \
    "\"scope\":\"engineering\"" "engineering-analyst"; do
    if [[ "$AUTH_LINE" != *"$claim"* ]]; then
        fail "B's authenticated request does not show $claim"
    fi
done

if [[ "$B_LOG" == *jwks_unavailable* ]]; then
    fail "B reported jwks_unavailable"
fi

pass "A reached B, B verified sub=alice, azp=A's SVID, scope=engineering, aud=engineering-analyst"
