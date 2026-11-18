#!/usr/bin/env bash
# Verify the Keycloak identity plane for the OpenShift demo.
# Every assertion exits non-zero on failure, so this doubles as the
# post-setup gate and a rerun check on a temporary cluster.
#
# Assertions:
#   1. the Deployment is rolled out
#   2. CVE-2026-114938 mitigation is active in the running JVM
#   3. the discovery document reports the canonical in-cluster issuer
#   4. a password grant for alice yields sub, groups and department scope
#
# Idempotency of setup-keycloak.sh is checked by running that script
# twice; this verifier does not call it (that would recurse).
set -euo pipefail

NAMESPACE="${ZT2_KEYCLOAK_NAMESPACE:-zt-demo}"
REALM="${ZT2_KEYCLOAK_REALM:-zt}"
LOCAL_PORT="${ZT2_KEYCLOAK_LOCAL_PORT:-18081}"
EXPECTED_ISSUER="${ZT2_KEYCLOAK_ISSUER:-http://keycloak.${NAMESPACE}.svc:8080/realms/${REALM}}"
TOKEN_URL="http://127.0.0.1:${LOCAL_PORT}/realms/${REALM}/protocol/openid-connect/token"
DISCOVERY_URL="http://127.0.0.1:${LOCAL_PORT}/realms/${REALM}/.well-known/openid-configuration"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'ok: %s\n' "$*"
}

echo "== 1/4 deployment rollout =="
oc -n "$NAMESPACE" rollout status deployment/keycloak --timeout=300s

echo "== 2/4 CVE-2026-114938 mitigation =="
# jcmd is authoritative; /proc/1/cmdline proves the flag reached the
# JVM command line when jcmd is absent from the image.
flag="$(oc -n "$NAMESPACE" exec deploy/keycloak -- sh -c \
    'jcmd 1 VM.flags -all 2>/dev/null | grep -F "UseBASE64Intrinsics" ||
     tr "\0" "\n" < /proc/1/cmdline | grep -F -- "-XX:-UseBASE64Intrinsics"' 2>/dev/null || true)"
if [[ -z "$flag" ]]; then
    fail "UseBASE64Intrinsics flag not found in the running JVM; CVE-2026-114938 is unmitigated"
fi
if [[ "$flag" =~ UseBASE64Intrinsics[[:space:]]*=[[:space:]]*false || "$flag" == *"-XX:-UseBASE64Intrinsics"* ]]; then
    pass "UseBASE64Intrinsics disabled (${flag})"
else
    fail "UseBASE64Intrinsics is not disabled: ${flag}"
fi

echo "== 3/4 discovery issuer =="
oc -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/keycloak "${LOCAL_PORT}:8080" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "$DISCOVERY_URL" >/dev/null 2>&1 && break
    sleep 2
done
issuer="$(curl -fsS --max-time 5 "$DISCOVERY_URL" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])')"
[[ "$issuer" == "$EXPECTED_ISSUER" ]] ||
    fail "issuer is '$issuer', expected '$EXPECTED_ISSUER'"
pass "issuer is $issuer"

echo "== 4/4 alice password grant =="
token="$(curl -fsS --max-time 10 -X POST "$TOKEN_URL" \
    -d grant_type=password \
    -d client_id=login-alice \
    -d username=alice \
    -d password=alice \
    -d scope=openid |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
python3 - "$token" <<'PY'
import base64
import json
import sys

payload = sys.argv[1].split(".")[1]
payload += "=" * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))

def need(condition, message):
    if not condition:
        sys.exit("FAIL: " + message)

need(claims.get("sub") == "alice", f"sub is {claims.get('sub')!r}, expected 'alice'")
groups = claims.get("groups") or []
need("engineering" in groups and "finance" in groups,
     f"groups are {groups!r}, expected engineering and finance")
scope = claims.get("scope", "").split()
need("engineering" in scope, f"scope is {scope!r}, expected engineering")
print("ok: token claims", json.dumps({"sub": claims["sub"], "groups": groups, "scope": scope}))
PY

echo "verify-keycloak: PASS"
