#!/usr/bin/env bash
# Scenario 13: no token at all. The engineering analyst is reachable on
# its service URL, and a caller with no bearer token is refused by the
# agent itself. The platform forwards credentials; it does not
# authenticate service traffic for you. Every hop verifies.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 13: a direct call to the engineering analyst with no token"

agent_provider "eng-analyst-prov-13-$$" zt2-engineering-analyst-v2 alice
B_ID="$(create_sandbox eng-analyst "eng-analyst-prov-13-$$" "$AGENT_IMAGE")"
register_sandbox "$B_ID" >/dev/null
"${OS[@]}" service expose eng-analyst 8000 agent \
    --authorization-mode bearer-passthrough >/dev/null

# The caller allowlist never runs without a token, so the allowlist value
# is irrelevant here; keep it a prefix rather than inventing an SVID.
write_agent_config "$ROOT/agents/engineering-analyst" "$STATE_DIR/a2a/b" \
    "spiffe://openshell.local/openshell/sandbox/this-call-has-no-token"
sandbox_upload eng-analyst "$STATE_DIR/a2a/b/agent" /workspace >/dev/null
start_docsclaw_serve eng-analyst

URL="$(service_url eng-analyst agent)"
URL="${URL%/}"
[[ -n "$URL" ]] || fail "the gateway reports no URL for eng-analyst/agent"
echo "  service URL: $URL"

# The service route needs a moment after the gateway registers it, and the
# sandbox health server can answer 502 until docsclaw is listening, so
# poll rather than sampling once.
RESPONSE=""
for _ in $(seq 1 30); do
    RESPONSE="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$URL/health" || true)"
    if [[ "$RESPONSE" == "200" ]]; then
        break
    fi
    sleep 2
done
[[ "$RESPONSE" == "200" ]] || fail "the exposed URL is not reachable from this host ($RESPONSE)"
echo "  the exposed URL is reachable from the laptop (/health 200)"

BODY="$(curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"role":"user","parts":[{"kind":"text","text":"review DOC-001"}],"messageId":"m1","kind":"message"}}}' \
    "$URL/a2a")"
STATUS="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{}}' "$URL/a2a")"

if [[ "$STATUS" == "401" && "$BODY" == *missing_token* ]]; then
    pass "B refused the tokenless call with 401 missing_token"
else
    fail "expected 401 missing_token from B, got $STATUS: $BODY"
fi
