# Demo scenarios

Each scenario is a script in `scripts/` — run them after `scripts/setup.sh`.
Every script prints what it does and exits non-zero if the result differs
from the expectation.

## Scenario numbering

Scenario numbers are a stable index rather than a contiguous count: the
7–10 range is reserved for the single-agent stage, so numbers do not shift
when scenarios are added:

| Range | Stage | What it covers | Status here |
| ----- | ----- | -------------- | ----------- |
| 1–6 | v1 lineage | curl sandboxes, the exchange chain, mint-time and resource denies | implemented |
| 7–10 | Stage A | single-agent DocsClaw: summarise, deny, prompt injection, Carol's path | planned, not implemented |
| 11–15 | Stage B | agent-to-agent between DocsClaw sandboxes | implemented |

Scenarios 7–10 belong to the single-agent stage and are not implemented in
this repository; the numbers stay reserved so scenario references remain
stable. The Stage A *helpers* (the agent definition, the `create_sandbox`
image parameter, `sandbox_ask`) do exist, which is what the Stage B
scenarios use.

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

Setup the demo platform. The script creates:

- a SPIRE service that is responsible for creating workload identities (SPIFFE IDs) for agents
  ([`deploy/podman/spire/start-spire.sh`](../deploy/podman/spire/start-spire.sh))
- an OpenShell gateway in a Podman container
  ([`deploy/podman/scripts/start-gateway.sh`](../deploy/podman/scripts/start-gateway.sh))
- a token issuer reimplemented from the upstream example
  ([`deploy/podman/scripts/start-services.sh`](../deploy/podman/scripts/start-services.sh))
- document services for different departments
  ([`deploy/podman/scripts/start-services.sh`](../deploy/podman/scripts/start-services.sh))
- provider profiles
  ([`deploy/podman/profiles/`](../deploy/podman/profiles/))

```bash
scripts/setup.sh          # SPIRE + gateway + services + profiles
scripts/scenario1.sh      # ... through scenario6.sh
scripts/teardown.sh
```

## Running on OpenShift

The same scenarios run against a ROSA/OpenShift 4.19+ cluster with the
Kubernetes compute driver — the production-representative path.
Prerequisites: `oc` logged in, Helm 3, the `openshell` CLI, and the
service images pushed to quay.io
(`deploy/openshift/build-images.sh`, run from a linux/amd64 host).
If the quay repositories are private, `setup.sh` creates the
`zt2-quay` pull secret in-cluster from your local podman
credentials automatically.

```bash
deploy/openshift/build-images.sh
deploy/openshift/setup.sh   # SPIRE + gateway + services + profiles
ZT2_DRIVER=openshift scripts/scenario1.sh      # ... through scenario6.sh
deploy/openshift/teardown.sh
```

The differences from the Podman path:

- Agent identity comes from `ClusterSPIFFEID` workload attestation
  (one unique SVID per sandbox pod) instead of manual SPIRE
  registration entries.
- Scenario scripts run on your laptop against the gateway's OpenShift
  Route; sandbox pods reach the document services via in-cluster DNS,
  the laptop reaches them via `oc port-forward`.
- Scenario 5's rogue identity is refused by the attestation policy
  itself (no SVID is minted), which is the pass condition on this
  driver — a stronger demonstration than the issuer-side 401.

## What each scenario proves

1. **Allowed path** — the full chain: the sandbox's curl is intercepted
   by its supervisor, which fetches the sandbox's SPIFFE JWT-SVID, asks
   the gateway to exchange the stored user subject token for an
   intermediate token (audience = the sandbox's SPIFFE ID), exchanges
   that for a final scoped token, and injects it into the outbound
   request. The document service validates audience + scope.
2. **Permission intersection** — same user, wrong capability: the issuer
   returns `403 insufficient_department_permissions` and no token is
   minted. The script also drives the exchange directly against the
   issuer so you can see the deny at the mint point.
3. **No delegation** — the sandbox is launched from a profile whose
   `subject_token` credential is absent. The gateway has nothing to
   exchange; the request never carries a token.
4. **Another allowed path** — Carol and hr, proving the matrix is
   data-driven, not hardcoded.
5. **Rogue workload** — a container with a *validly signed* SVID whose
   SPIFFE ID (`spiffe://openshell.local/rogue/workload/1`) is not under
   the registered supervisor prefix. The issuer rejects the client
   assertion (`401 invalid_client_assertion`) before looking at any
   token: workload identity is the root of trust, not credentials a
   sandbox could have stolen. SPIRE cannot issue outside its trust
   domain, so "rogue" here means an unregistered path inside it.
6. **Audience binding** — a valid engineering-scoped token replayed
   against the finance service: `403 invalid_audience`. The sandbox
   never sees its injected token, so the replay is staged out-of-band
   with direct `/token` calls.

## Agent-to-agent scenarios (11–15)

Scenarios 11–15 run DocsClaw agents inside the v2 stack and let one
agent call another over A2A. The agent image and provider profile are
Stage A artifacts; the model endpoint is supplied by the environment.

```bash
export LLM_API_KEY=...                       # MaaS key, never on argv
export LLM_BASE_URL=https://api.enmaas.devshift.net/v1
export LLM_MODEL=...                         # model name served there
scripts/scenario11.sh                        # ... through scenario15.sh
```

Agent A is Alice's assistant; agent B is the engineering analyst; the
hr analyst is the negative peer. Every agent verifies its own callers:
the issuer's JWKS is part of each agent's egress profile, and a missing
JWKS endpoint shows up as `503 jwks_unavailable` rather than a silent
allow.

| # | What happens | Result | Enforced by |
|---|---|---|---|
| 11 | A asks B to review DOC-001 | ✅ | Full chain; B logs `sub`, `azp`, `scope`, `aud` |
| 12 | A (prompt-injected) tries the hr analyst | ❌ | A's supervisor: no endpoint for that host |
| 13 | A direct call to B with no token | ❌ 401 `missing_token` | B itself |
| 14 | An engineering-analyst token replayed at the hr analyst | ❌ 403 `invalid_audience` | The hr analyst |
| 15 | A second Alice sandbox outside B's caller allowlist | ❌ 403 `caller_not_allowed` | B's allowlist on `azp` |

Scenario 13 is the teaching point for A2A: the platform forwards
credentials, but it does not authenticate service traffic for you. Every
hop verifies.

Two implementation notes for presenters:

- **A reaches B through a host-published relay**, not the gateway's
  `.openshell.localhost` service URL. On the Podman driver that name
  resolves to loopback inside the VM, which the supervisor refuses as an
  upstream destination. The service URL is still what scenario 13 uses
  from the laptop, and it is what the OpenShift path would use.
- **B fetches documents with its own profile**, not with the caller's
  token. Request-bound delegation is on the roadmap
  (`docs/PRODUCTION_RECOMMENDATIONS.md`).

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
