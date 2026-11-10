# Agent-to-agent walkthrough

A hands-on walkthrough of the agent-to-agent (A2A) part of the demo: two
DocsClaw agents in separate sandboxes, the profile wiring that lets one
reach the other, and the token that B verifies before it will answer. It
complements `docs/DEMO_WALKTHROUGH.md` (the single-agent runtime),
`docs/ARCHITECTURE.md` (the A2A flow diagram) and `docs/DEMO_SCENARIOS.md`
(what each scenario proves).

Status: written against the Podman path on macOS, 2026-11-10; the
OpenShift differences are in `docs/DEMO_WALKTHROUGH_OPENSHIFT.md`.

## What changes from the single-agent demo

The single-agent scenarios stop at a document service. A2A adds a second
sandbox, so one more boundary has to authenticate:

```text
single agent:   sandbox ──▶ document service     (resource verifies the token)
agent to agent: sandbox A ──▶ sandbox B ──▶ document service
                             (B verifies the caller, then acts as itself)
```

Two consequences shape everything else:

- **B authenticates A itself.** B's `inbound_auth` checks the token's
  `iss`, `aud`, `required_scopes` and an exact `azp` allowlist. A's
  supervisor mints that token on the way out; B fetches the issuer's
  JWKS through its own supervisor to verify the signature.
- **B acts with its own delegation.** A's token stops at B. B's document
  fetches use B's provider profile, not A's token. Nested `act`
  delegation is on the roadmap (`docs/PRODUCTION_RECOMMENDATIONS.md`).

The three layers from `DEMO_WALKTHROUGH.md` are unchanged; A2A just needs
each of them on both sides.

## The cast

| Role | Sandbox | Profile | Acts as | What it proves |
| ---- | ------- | ------- | ------- | -------------- |
| A | `alice-a2a` | `zt2-alice-a2a-v2` | Alice, engineering + a peer | The caller |
| B | `eng-analyst` | `zt2-engineering-analyst-v2` | Alice, engineering | The callee that verifies |
| C | `hr-analyst` | `zt2-carol-hr-analyst-v2` | Carol, hr | The wrong-audience peer (scenario 14) |
| A2 | `alice-a2a-2` | `zt2-alice-a2a-v2` | Alice, engineering | A caller outside B's allowlist (scenario 15) |

A and A2 are deliberately the same profile. Scenario 15 needs a caller
that *can* obtain a valid token but is *not* in B's `allowed_callers`, so
the denial isolates the caller allowlist rather than the issuer or the
profile.

## The token B sees

A2A reuses the three-token chain. The only new part is the final token's
audience and the supervisor's decision to mint it for a peer host:

| Claim | Value for an A→B call | Why it matters |
| ----- | --------------------- | -------------- |
| `aud` | `[engineering-analyst, account]` | B serves that audience; a document service would not |
| `scope` | `engineering` | The intersection, unchanged |
| `azp` | `spiffe://openshell.local/openshell/sandbox/<A's id>` | B's caller allowlist matches this exactly |
| `iss` | `http://token-issuer.zt-demo.svc:8080` | Must equal B's configured issuer, including `:8080` |
| `demo_token_use` | `final` | Only a final token is accepted |

In this deployment the supervisor's SVID and the sandbox's SVID resolve
to the same string, `spiffe://openshell.local/openshell/sandbox/<id>`;
only the supervisor mounts the Workload API socket, which is what lets it
fetch the token. That is why the allowlist can name the sandbox ID and
still match `azp`.

## How the token gets the right audience

A's profile has an `audience_overrides` entry for B's host. Without it the
supervisor would mint an `engineering` token, which B rejects with
`403 invalid_audience`.

```yaml
audience_overrides:
  - host: @A2A_HOST@
    port: @A2A_PORT@
    audience: engineering-analyst
    scopes: [engineering]
```

The same profile lists B's host as an endpoint with `access: read-write`,
because A2A is a `POST`. A read-only endpoint fails at A's supervisor with
`403 policy_denied` before the request ever leaves the sandbox.

## The three profiles

**A — `alice-a2a`.** Two endpoints: the engineering document service and
B's exposed host, both read-write; an audience override for each; and the
`docsclaw` binary so the agent, not just curl, may use them. The peer
endpoint carries a runtime URL, so the profile is rendered per run rather
than imported once at setup.

**B — `engineering-analyst`.** Two endpoints: the engineering document
service (read-write) and the issuer's JWKS host (read-only). The JWKS
entry is ordinary egress through B's own supervisor; without it every
inbound verification is `503 jwks_unavailable`. No peer endpoints — B is
a callee, not a caller.

**C — `carol-hr-analyst`.** Carol's hr grant, the hr document service and
the JWKS host, with `inbound_auth.audience: hr-analyst` and
`required_scopes: [hr]`. It exists to be the wrong audience for a token
minted for B.

## B's inbound check

```yaml
inbound_auth:
  enabled: true
  issuer: http://token-issuer.zt-demo.svc:8080   # exact, including :8080
  jwks_url: @JWKS_URL@                            # full FQDN on OpenShift
  audience: engineering-analyst
  required_scopes: [engineering]
  allowed_callers:
    - @CALLER_SVID@                               # A's exact sandbox ID
```

Three details are easy to get wrong:

- `iss` is a literal string match against the deployment's
  `ACCESS_TOKEN_ISSUER`. A trailing slash or a missing `:8080` fails every
  request with `invalid_issuer`.
- `allowed_callers` is the exact SVID, not the `…/sandbox/` prefix. The
  prefix would admit every sandbox and scenario 15 could not distinguish a
  caller.
- Sandbox IDs are per-run UUIDs, so B's config is rendered and uploaded at
  run time, never baked into the image.

## Configuration grants the tool, policy decides the reach

A's agent config lists **two** peers:

```yaml
a2a_peers:
  - name: engineering-analyst
    url: @PEER_URL@
  - name: hr-analyst
    url: @HR_PEER_URL@
```

A's *profile* has an endpoint only for B. Scenario 12 is the gap between
the two: the agent is allowed to attempt the hr call, and its supervisor
refuses it before egress. This is the same lesson as the single-agent
prompt-injection scenario, one layer out.

## Bootstrap order

The steps depend on each other because B's allowlist needs A's ID and A's
config needs B's URL. The harness runs them in this order:

1. Create B and read its sandbox ID.
2. Expose B's agent port through the gateway.
3. Render and import A's profile with B's reachable host and port.
4. Create A and read its sandbox ID.
5. Render and upload B's config with A's exact SVID.
6. Start `docsclaw serve --host 0.0.0.0` in B.
7. Render and upload A's config with B's URL.
8. Ask A.

`--host 0.0.0.0` matters: with inbound auth on, DocsClaw binds loopback by
default, which the service proxy cannot reach.

## Running scenarios 11–15

The numbers follow the integration plan, so scenarios 7–10 (Stage A,
single-agent DocsClaw) do not exist here; the gap is explained in
`docs/DEMO_SCENARIOS.md`.

The agent scenarios need a model endpoint. They exit 2 rather than report
a result they never tested when it is missing.

```bash
export LLM_API_KEY=...                       # never on argv
export LLM_BASE_URL=https://api.enmaas.devshift.net/v1
export LLM_MODEL=...                         # model served there
scripts/scenario11.sh                        # ... through scenario15.sh
```

| # | What happens | Expected | Where to look |
| - | ------------ | -------- | ------------- |
| 11 | A asks B to review DOC-001 | allow | A's trace shows `a2a_call`; B logs the verified request |
| 12 | A (prompt-injected) tries the hr analyst | deny | A's trace shows the attempt and the supervisor refusal |
| 13 | A direct call to B with no token | `401 missing_token` | B's own response |
| 14 | An engineering-analyst token replayed at the hr analyst | `403 invalid_audience` | The hr analyst's response |
| 15 | A second Alice sandbox outside B's allowlist | `403 caller_not_allowed` | B's response |

Scenarios 13 and 15 are model-free; 11, 12 and 14 need the model.

### What scenario 11 prints

B's log line is the evidence that the whole chain worked:

```text
"request authenticated" sub="alice" azp="spiffe://…/sandbox/<A's id>"
  scope="engineering" aud="engineering-analyst account"
```

If that line is missing, the request was refused; if `jwks_unavailable`
appears instead, B's profile is missing the issuer endpoint.

## How A reaches B

This is the part that differs by driver, and the part most likely to
confuse a presenter. A's profile endpoint and B's exposed URL must name
the same destination that the gateway routes.

| Driver | What A dials | Why |
| ------ | ------------ | --- |
| Podman | `openshell forward service` relay on the host, `18800` | The gateway's `.openshell.localhost` URL resolves to loopback inside the VM, which the supervisor refuses |
| OpenShift | the gateway Route with `Host: <service authority>` | The authority is not resolvable in-cluster; the Route is |

Scenario 13 always calls the exposed URL from the laptop, so it needs the
form that works from outside the cluster too. On OpenShift that is the
Route plus the `Host` header (`service_curl`); details and the in-cluster
limitation are in `docs/DEMO_WALKTHROUGH_OPENSHIFT.md`.

## Gotchas

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| `403 policy_denied` at A before egress | Peer endpoint is `access: read-only` | A2A uses `POST`; set `read-write` |
| `503 jwks_unavailable` in B | Issuer JWKS host missing from B's profile | Add it, read-only |
| Every inbound request `invalid_issuer` | `issuer` string differs from `ACCESS_TOKEN_ISSUER` | Use the exact value, including `:8080` |
| `403 caller_not_allowed` for the intended caller | Allowlist has the prefix, or a stale sandbox ID | Use the exact `spiffe://…/sandbox/<id>` for this run |
| `sandbox upload` fails on OpenShift | Uploading to `/workspace`, which is read-only there | Use the driver's workspace (`/sandbox`); see the OpenShift doc |
| Sandbox never starts on OpenShift | The DocsClaw image is arm64 or mislabeled | Build a real `linux/amd64` image |
| A returns a tool error instead of an answer | Peer URL unreachable, or wrong port | Check A's trace for the actual dial target |

## Next steps

- Run scenario 12 next to scenario 11: the same two agents, one denied by
  policy rather than by verification.
- Compare the `azp` in B's log with `sandbox get <A>` — the allowlist is
  that exact string.
- Read `docs/PRODUCTION_RECOMMENDATIONS.md` for request-bound delegation,
  which removes the "B acts as itself" simplification.
