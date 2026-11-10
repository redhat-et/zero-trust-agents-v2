#!/usr/bin/env bash
# Scenario 15: caller allowlist. A second Alice sandbox holds the same
# engineering-analyst capability as A but is not in B's allowed_callers,
# so B refuses it. Expected: 403 caller_not_allowed at B. A second Alice
# sandbox is used rather than Bob because Bob has no engineering
# department: the issuer would refuse his final token before B is reached,
# which would test the issuer instead of the caller allowlist.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 15: a sandbox outside B's caller allowlist"

trap 'stop_relay eng-analyst' EXIT

echo "  == agent B =="
agent_provider "eng-analyst-prov-15-$$" zt2-engineering-analyst-v2 alice
B_ID="$(create_sandbox eng-analyst "eng-analyst-prov-15-$$" "$AGENT_IMAGE")"
register_sandbox "$B_ID" >/dev/null
start_relay eng-analyst 8000 "$A2A_PORT"

remove_sandbox alice-a2a
remove_sandbox alice-a2a-2
rm -f "$STATE_DIR/relay-alice-a2a.pid"
render_alice_a2a_profile

# Neither Alice sandbox runs the agent here: the scenario is about which
# caller B admits, and a plain curl caller exercises exactly that.
echo "  == agent A (the only allowed caller) =="
agent_provider "alice-a2a-prov-15-$$" zt2-alice-a2a-v2 alice
A_ID="$(create_sandbox alice-a2a "alice-a2a-prov-15-$$")"
register_sandbox "$A_ID" >/dev/null

echo "  == agent A2: same capability, not in the allowlist =="
agent_provider "alice-a2a-prov-15b-$$" zt2-alice-a2a-v2 alice
A2_ID="$(create_sandbox alice-a2a-2 "alice-a2a-prov-15b-$$")"
register_sandbox "$A2_ID" >/dev/null

write_agent_config "$ROOT/agents/engineering-analyst" "$STATE_DIR/a2a/b" \
    "$(sandbox_spiffe_id "$A_ID")"
sandbox_upload eng-analyst "$STATE_DIR/a2a/b/agent" /workspace >/dev/null
start_docsclaw_serve eng-analyst

TARGET="$(peer_url "$A2A_HOST" "$A2A_PORT")"

# A2's supervisor mints a valid engineering-analyst token; only the caller
# allowlist can refuse it. curl runs inside A2, so the 192.168 address is
# the sandbox's route to this host, not the laptop's.
RAW="$("${OS[@]}" sandbox exec --name alice-a2a-2 --no-tty -- \
    curl -sS -m 30 -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"role":"user","parts":[{"kind":"text","text":"review DOC-001"}],"messageId":"m1","kind":"message"}}}' \
    -w '\n%{http_code}' "${TARGET}a2a")"
STATUS="${RAW##*$'\n'}"
BODY="${RAW%$'\n'*}"

if [[ "$STATUS" == "403" && "$BODY" == *caller_not_allowed* ]]; then
    pass "B refused the second Alice sandbox with 403 caller_not_allowed"
else
    fail "expected 403 caller_not_allowed at B, got $STATUS: $BODY"
fi
