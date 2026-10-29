# Demo scenarios

Each scenario is a script in `scripts/` — run them after `scripts/setup.sh`.
Every script prints what it does and exits non-zero if the result differs
from the expectation.

## Permission matrix

Users and their departments (from `config/users.yaml`):

| User   | Departments          |
|--------|----------------------|
| Alice  | engineering, finance |
| Bob    | finance, admin       |
| Carol  | hr                   |

A sandbox's **capability** is the scope its provider profile requests
(`deploy/podman/profiles/`); the **audience** names the target service.
A token is minted only if the user's departments intersect the requested
scope — the intersection is the token's scope, enforced at mint time by
the token issuer.

| # | User  | Capability | Target          | Result | Why |
|---|-------|------------|-----------------|--------|-----|
| 1 | Alice | engineering | engineering doc | ✅ | engineering ∈ Alice's departments |
| 2 | Alice | hr          | engineering doc | ❌ | hr ∉ {engineering, finance} — no token minted |
| 3 | —     | engineering | engineering doc | ❌ | no user delegation — nothing to exchange |
| 4 | Carol | hr          | hr doc          | ✅ | hr ∈ Carol's departments |
| 5 | rogue | —           | any             | ❌ | SPIFFE ID not under the supervisor prefix — rejected at SVID verification |
| 6 | Alice | engineering | finance doc     | ❌ | token audience is engineering — finance service rejects it |

## Running

```console
scripts/setup.sh          # SPIRE + gateway + services + profiles
scripts/scenario1.sh      # ... through scenario6.sh
scripts/teardown.sh
```

## What each scenario proves

1. **Allowed path** — the full chain: the sandbox's curl is intercepted
   by its supervisor, which fetches the sandbox's SPIFFE JWT-SVID, asks
   the gateway to exchange the stored user subject token for an
   intermediate token (audience = the sandbox's SPIFFE ID), exchanges
   that for a final scoped token, and injects it into the outbound
   request. The document service validates audience + scope.
1. **Permission intersection** — same user, wrong capability: the issuer
   returns `403 insufficient_department_permissions` and no token is
   minted. The script also drives the exchange directly against the
   issuer so you can see the deny at the mint point.
1. **No delegation** — the sandbox is launched from a profile whose
   `subject_token` credential is absent. The gateway has nothing to
   exchange; the request never carries a token.
1. **Another allowed path** — Carol and hr, proving the matrix is
   data-driven, not hardcoded.
1. **Rogue workload** — a container with a *validly signed* SVID whose
   SPIFFE ID (`spiffe://openshell.local/rogue/workload/1`) is not under
   the registered supervisor prefix. The issuer rejects the client
   assertion (`401 invalid_client_assertion`) before looking at any
   token: workload identity is the root of trust, not credentials a
   sandbox could have stolen. SPIRE cannot issue outside its trust
   domain, so "rogue" here means an unregistered path inside it.
1. **Audience binding** — a valid engineering-scoped token replayed
   against the finance service: `403 invalid_audience`. The sandbox
   never sees its injected token, so the replay is staged out-of-band
   with direct `/token` calls.

## Try it yourself

Mint a subject token as any user and inspect its claims:

```console
$ curl -s "http://127.0.0.1:8080/demo-subject-token?user=alice" |
    python3 -c 'import json,sys,base64;
    t=json.load(sys.stdin)["access_token"].split(".")[1];
    print(json.dumps(json.loads(base64.urlsafe_b64decode(t+"="*(-len(t)%4))),indent=2))'
```

Drive an exchange by hand (scenario 6 does this end-to-end): fetch the
gateway's SVID, POST to `/token` with
`grant_type=urn:ietf:params:oauth:grant-type:token-exchange` and
`client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe`,
then exchange the intermediate the same way as the supervisor.
