#!/usr/bin/env bash
# Prove Keycloak authenticates clients by SPIFFE JWT-SVID end to end.
#
# Positive: a real gateway SVID from the cluster is accepted as a
# client_assertion and yields an access token.
# Negative: a tampered assertion (sub rewritten, signature no longer
# matches) is rejected with 401 invalid_client.
#
# This needs SPIRE (CSI driver, agent, OIDC provider) and an `openshell`
# namespace with an `openshell` ServiceAccount; the full setup.sh creates
# both. The foreign-trust-domain rejection is covered by the podman spike
# — one cluster has one SPIFFE trust domain, so it cannot be re-minted
# here without a second deployment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export STATE_DIR="${STATE_DIR:-$ROOT/.zt2-state}"

NAMESPACE="${ZT2_KEYCLOAK_NAMESPACE:-zt-demo}"
REALM="${ZT2_KEYCLOAK_REALM:-zt}"
LOCAL_PORT="${ZT2_KEYCLOAK_LOCAL_PORT:-18081}"
SVID_AUDIENCE="${ZT2_SVID_AUDIENCE:-http://keycloak.${NAMESPACE}.svc:8080/realms/${REALM}}"
TOKEN_URL="http://127.0.0.1:${LOCAL_PORT}/realms/${REALM}/protocol/openid-connect/token"
GATEWAY_SPIFFE_ID="spiffe://openshell.local/ns/openshell/sa/openshell"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

echo "== fetching the gateway SVID (audience $SVID_AUDIENCE) =="
oc -n openshell delete pod zt2-gw-svid --ignore-not-found >/dev/null 2>&1 || true
sed "s|@SVID_AUDIENCE@|$SVID_AUDIENCE|" "$ROOT/deploy/openshift/svid-helper-gateway.yaml" |
    oc -n openshell apply -f - >/dev/null
phase=""
for _ in $(seq 1 40); do
    phase="$(oc -n openshell get pod zt2-gw-svid -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 2
done
[[ "$phase" == "Succeeded" ]] ||
    fail "gateway SVID helper ended in phase '$phase'; run: oc -n openshell logs zt2-gw-svid"
svid="$(oc -n openshell logs zt2-gw-svid 2>/dev/null | awk '/^\t/ {print $1; exit}')"
oc -n openshell delete pod zt2-gw-svid --ignore-not-found >/dev/null 2>&1 || true
[[ -n "$svid" ]] || fail "helper printed no JWT-SVID"
echo "ok: SVID fetched (${#svid} bytes)"

echo "== client_credentials with the SVID =="
oc -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/keycloak "${LOCAL_PORT}:8080" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "http://127.0.0.1:${LOCAL_PORT}/realms/${REALM}/.well-known/openid-configuration" >/dev/null 2>&1 && break
    sleep 2
done

status="$(curl -sS -o /tmp/kc-spiffe-ok.json -w '%{http_code}' -X POST "$TOKEN_URL" \
    -d grant_type=client_credentials \
    -d client_id="$GATEWAY_SPIFFE_ID" \
    -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe \
    -d client_assertion="$svid")"
if [[ "$status" != "200" ]]; then
    oc -n "$NAMESPACE" logs deploy/keycloak --tail=40 2>/dev/null |
        grep -iE 'spiffe|jwks|bundle|invalid|error' | tail -10 >&2 || true
    fail "client_credentials returned $status: $(cat /tmp/kc-spiffe-ok.json)"
fi
python3 -c 'import json,sys; d=json.load(open("/tmp/kc-spiffe-ok.json")); sys.exit(0 if d.get("access_token") else 1)' ||
    fail "200 response carried no access_token"
echo "ok: Keycloak issued a token for $GATEWAY_SPIFFE_ID"

echo "== tampered assertion is rejected =="
tampered="$(python3 - "$svid" <<'PY'
import base64
import json
import sys

header, payload, signature = sys.argv[1].split(".")
payload += "=" * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
claims["sub"] = "spiffe://evil.example/ns/x/sa/y"
body = json.dumps(claims, separators=(",", ":")).encode()
print(f"{header}.{base64.urlsafe_b64encode(body).rstrip(b'=').decode()}.{signature}")
PY
)"
status="$(curl -sS -o /tmp/kc-spiffe-bad.json -w '%{http_code}' -X POST "$TOKEN_URL" \
    -d grant_type=client_credentials \
    -d client_id="$GATEWAY_SPIFFE_ID" \
    -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe \
    -d client_assertion="$tampered")"
[[ "$status" == "401" ]] ||
    fail "tampered assertion returned $status, expected 401: $(cat /tmp/kc-spiffe-bad.json)"
grep -q 'invalid_client' /tmp/kc-spiffe-bad.json ||
    fail "tampered assertion did not return invalid_client: $(cat /tmp/kc-spiffe-bad.json)"
echo "ok: tampered assertion rejected with 401 invalid_client"

rm -f /tmp/kc-spiffe-ok.json /tmp/kc-spiffe-bad.json
echo "verify-spiffe-auth: PASS"
