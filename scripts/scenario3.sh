#!/usr/bin/env bash
# Scenario 3: sandbox without user delegation. Expected: DENIED — no
# subject token is stored, so the gateway has nothing to exchange and no
# token is ever minted.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario_header "Scenario 3: sandbox without user delegation -> engineering doc"

# The nodelegation profile declares subject_token as optional, so the
# provider can exist without a credential.
"${OS[@]}" provider create --name nodeleg-s3-$$ --type zt2-nodelegation-v2 >/dev/null

ID="$(create_sandbox alice-s3 nodeleg-s3-$$)"
register_sandbox "$ID" >/dev/null
echo "  sandbox: $ID (SPIFFE ID registered, no user delegation)"

# Sanity first: the document service itself must be healthy, so a deny
# can only come from the missing delegation.
HEALTH="$(curl -s --max-time 5 http://127.0.0.1:18101/healthz || true)"
if [[ "$HEALTH" != "ok" ]]; then
    fail "document service unhealthy — cannot attribute a deny to the missing delegation"
fi
echo "  sanity: document service healthy"

# The request must be denied by the supervisor's proxy (502, empty body)
# because the token grant fails — and the supervisor must log exactly
# that. A stopped document service would not produce this warn: the
# grant fails before any upstream connection is attempted.
RESP="$("${OS[@]}" sandbox exec --name alice-s3 --no-tty -- \
    curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    "$ENGINEERING_URL/documents/DOC-001" 2>&1 || true)"
if [[ "$RESP" != "502" ]]; then
    fail "expected the proxy to deny with 502 (no token minted), got: $RESP"
fi
echo "  sandbox request denied at the proxy (502)"

SUPERVISOR="$(podman ps -a --filter "label=openshell.ai/sandbox-id=$ID" \
    --format '{{.Names}}' | grep supervisor)"
if podman logs "$SUPERVISOR" 2>&1 | grep -q "Token grant failed"; then
    pass "supervisor logged 'Token grant failed' — no credential to exchange, no token minted"
else
    fail "no 'Token grant failed' entry in supervisor logs for $SUPERVISOR"
fi
