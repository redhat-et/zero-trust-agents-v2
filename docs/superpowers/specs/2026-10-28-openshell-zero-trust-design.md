# Zero Trust Agents v2 — Design

Date: 2026-10-28
Status: Approved design (pre-implementation)

## Intent and why

An educational demo, successor to [zero-trust-agent-demo](https://github.com/redhat-et/zero-trust-agent-demo) (v1), that shows zero-trust identity for AI agent systems where **the agent is an OpenShell sandbox**. v1 used Kagenti, AuthBridge, and OPA; v2 replaces that stack with OpenShell's native identity machinery: SPIFFE workload identity on sandboxes, and RFC 8693 token exchange through the OpenShell gateway. The audience is Red Hat customers evaluating production AI workloads on OpenShift; the format is a hands-on lab with curl-driven scenarios, not slides or a dashboard.

The motivation for the rewrite: v1 enforced permission intersection with OPA at request time. v2 shows the same security property enforced **cryptographically at token-mint time** — a sandbox only receives a scoped, short-lived token if (a) its SPIFFE ID is known to the issuer and (b) a user's delegation intersects the sandbox's capabilities.

## Goals

- Reproduce and adapt the upstream OpenShell examples
  `examples/spiffe-token-grant-demo` (client_credentials) and
  `examples/spiffe-token-exchange-demo` (token_exchange) from the local
  clone at `~/work/repos/OpenShell`.
- Stage 1: run the full identity chain locally with Podman on macOS,
  building on the upstream podman variant (SPIRE server, agent, OIDC
  discovery provider).
- Stage 2: deploy the same scenarios on an OpenShift cluster where
  OpenShell is installed (per a teammate's install how-to the user has).
- Preserve v1's business story: users with departments (Alice =
  Engineering+Finance, Bob = Finance+Admin, Carol = HR), document access
  by department, agents with capability scopes, delegation requires
  permission intersection.
- Scenario-driven README in v1's style: ✅/❌ permission-matrix tables,
  curl commands a reader can run themselves.

## Non-goals

- No OPA — intersection is enforced by the token issuer, not a policy
  engine at request time.
- No web dashboard in the first release (curl-driven; dashboard may come
  later).
- No Kagenti, AuthBridge, or A2A protocol.
- No CI/image publishing until the demo works end-to-end on OpenShift.

## Anti-goals

- Retrofitting v1's repo — v2 is a clean repo with clean history.
- Sandboxes ever holding long-lived user credentials.

## Concept mapping (v1 → v2)

| v1 concept | v2 mechanism |
|---|---|
| User (Alice/Bob/Carol) | Stored `subject_token` in the OpenShell provider profile — the RFC 8693 input. Launching a sandbox "as Alice" means the gateway exchanges her token. |
| Agent | OpenShell sandbox with a SPIFFE ID (`spiffe://.../openshell/sandbox/<id>`). |
| Agent capabilities | Scopes requested in the final token exchange (`engineering`, `finance`, `hr`). |
| Permission intersection | Enforced by the token issuer at mint time: user departments ∩ sandbox capabilities must be non-empty for the requested scope. |
| OPA policy check | Audience + scope validation on the final bearer token at the protected service. |
| Protected documents | Department-scoped document service (reborn v1 document-service) requiring a final token with the right audience and scope. |

## Token flow (per upstream spiffe-token-exchange-demo)

1. Sandbox curls the document service.
2. Supervisor fetches the sandbox's SPIFFE JWT-SVID.
3. Supervisor requests an intermediate token from the gateway.
4. Gateway verifies the supervisor SVID against SPIRE OIDC/JWKS, fetches
   its own gateway JWT-SVID, and exchanges the stored user subject token
   at the token issuer. Intermediate audience = supervisor SPIFFE ID.
5. Supervisor exchanges the intermediate token for the final scoped
   access token (this is where intersection is enforced).
6. Supervisor injects the final token into the outbound request.

## Demo scenarios

| # | Scenario | Result |
|---|---|---|
| 1 | Alice's sandbox with engineering capability fetches engineering doc | ✅ Allowed |
| 2 | Alice's sandbox with hr capability fetches engineering doc | ❌ Denied (no intersection) |
| 3 | Sandbox without user delegation fetches any doc | ❌ Denied (no token minted) |
| 4 | Carol's sandbox with hr capability fetches hr doc | ✅ Allowed |
| 5 | **Rogue sandbox** — SPIFFE ID not registered/known to the issuer requests an intermediate token | ❌ Denied at gateway (SVID verification fails; nothing is minted) |
| 6 | Replay/audience attack — token scoped for one service used against another | ❌ Denied (audience check) |

Scenario 5 (the rogue-sandbox deny) is a headline addition over v1: it
demonstrates that workload identity is the root of trust, not
credentials the sandbox could have stolen.

## Architecture

```text
┌──────────────┐   1. curl    ┌──────────────┐
│   OpenShell  │─────────────▶│  Document    │
│   sandbox    │              │  Service     │
│ (SPIFFE ID)  │              │ (per-dept)   │
└──────┬───────┘              └──────▲───────┘
       │ supervisor                  │ final bearer token
       │ 2. SVID                     │ (scope = dept)
       ▼                             │
┌──────────────┐   3. intermediate ┌─┴────────────┐  5. exchange  ┌─────────────┐
│  OpenShell   │◀──token request── │  Supervisor  │──────────────▶│   Token     │
│   gateway    │                   └──────────────┘               │   Issuer    │
│ (SPIFFE ID)  │──4. exchange user subject token + gateway SVID──▶│ (verifies   │
└──────────────┘                                                  │  SPIFFE IDs)│
                                                                  └─────────────┘
```

Components to build (all Go, per user preference; upstream examples are
Node.js — rewriting in Go):

- `token-issuer/` — issues demo user subject tokens, performs gateway
  intermediate exchange, verifies SPIFFE IDs against SPIRE JWKS,
  performs supervisor final exchange enforcing intersection.
- `document-service/` — protected resource server; validates audience +
  scope on the final token; serves department-tagged sample documents
  (reuse v1's `sample-documents/`).
- `deploy/podman/` — SPIRE server/agent/OIDC-discovery configs and
  scripts, adapted from upstream
  `examples/spiffe-token-exchange-demo/podman/`.
- `deploy/openshift/` — manifests for stage 2 (kustomize base +
  overlay, mirroring v1's structure).
- `scripts/` — setup and demo-driving scripts (one per scenario where
  practical, like v1's `demo-credential-gateway.sh`).
- Docs mirroring v1: `README.md` (scenario matrix + quick start),
  `docs/ARCHITECTURE.md`, `docs/DEMO_SCENARIOS.md`,
  `docs/LEARNING_GUIDE.md`.

The client_credentials grant (upstream `spiffe-token-grant-demo`) is
exercised as an early/optional lab module — it demonstrates the simpler
"SVID proves the sandbox, gateway mints a token" flow before layering
RFC 8693 on top.

## Constraints

- Local stage runs on the user's Mac with Podman (note from prior
  work: podman machine version must match client version; OpenShell
  gateway state DB lives under `~/.local/state`).
- OpenShift stage targets a cluster the user has; OpenShell install
  follows the teammate's how-to document (obtain and reference it during
  implementation).
- Upstream SPIFFE ID prefixes assumed: gateway
  `spiffe://openshell.local/ns/openshell/sa/`, supervisor
  `spiffe://openshell.local/openshell/sandbox/` — must be made
  configurable per environment.
- Repo conventions per the user's global CLAUDE.md: feature branches
  with conventional prefixes, squash-merge PRs, `git commit -s`,
  `Assisted-By` trailer for AI attribution, docs under 500 lines
  (user-facing), local lint before commit.

## Decisions made by the user

- Business story reused from v1; permission intersection preserved as
  the core security property.
- New standalone repo (this one), published to GitHub later; v1's repo
  stays untouched.
- Podman-first, then OpenShift; OpenShift is the demo's final target.
- Include the rogue-sandbox deny scenario (5) and audience/replay check
  (6).
- Go for the services; no OPA; no dashboard in the first release.

## Resolved during builder review (verified against upstream code)

- **The issuer exists upstream** — `examples/spiffe-token-exchange-demo/k8s/token-issuer.js`
  (342 lines, Node.js) defines the full protocol surface: a `/token`
  endpoint, demo subject-token issuance, gateway intermediate exchange,
  supervisor final exchange, and SPIRE JWKS verification. Our Go
  `token-issuer/` is a port of these semantics plus the new
  intersection check (upstream only requires `requested scope includes
  audience`; departments ∩ capabilities is our addition).
- **Scope/audience selection is profile-configured, not
  sandbox-chosen.** Upstream `provider-profile.yaml` declares
  `token_grant.audience_overrides` mapping each protected host to its
  audience + scopes; the supervisor performs steps 2/4/5 automatically
  when the sandbox curls a declared endpoint. So "sandbox with
  capability X" = the provider profile used to launch it, and users are
  modeled as per-user profiles (each storing that user's subject token).
  This is the right security story: capabilities never come from the
  sandbox's own request.
- **Token claim schema:** departments are embedded in the subject token
  we mint (we control the schema — `sub` = user, plus a `departments`
  claim); the intermediate token preserves `sub`/`scope` and binds
  `azp`/`client_id` to the gateway SVID, as upstream does; the final
  token carries `azp` = supervisor SPIFFE ID. Intersection is checked
  at final-exchange time: `user.departments ∩ requested scope`.
- **Rogue-sandbox scenario mechanics (my call, confirm):** deny at
  authorization, not signature verification — a rogue workload can hold
  a validly-signed SVID, so the issuer/gateway must check the SPIFFE ID
  against the registered prefix/entries (upstream does exactly this
  with `sub.startsWith(SUPERVISOR_TRUST_DOMAIN_PREFIX)`). The headline
  is "unregistered identity → no token," with signature verification as
  the layer beneath it.
- **Stage-1 runtime:** everything in Podman containers, mirroring the
  upstream podman variant (SPIRE server/agent/OIDC + demo services),
  driven from macOS via the OpenShell CLI.
- **GitHub org/name:** decided at publish time; use a placeholder
  module path (`github.com/redhat-et/zero-trust-agents-v2` tentatively)
  until then.

## Still left to the builder

- Exact OpenShell provider-profile schema for users-as-subject-tokens
  (start from upstream `provider-profile.yaml` files).
- SPIRE registration entries and trust-domain configuration per stage.
- Issuer data model for users/departments (static YAML is fine for a
  demo; port v1's user definitions).
- OpenShift manifests: namespace, routes vs port-forward, image
  building strategy for the Go services.
- Sample-documents licensing/derivation from v1 (both Apache-2.0, same
  author — attribution note suffices).

## Open questions for the user

None remaining. Both resolved:

1. The teammate's install how-to is
   `docs/OPENCLAW_ON_OPENSHELL.md`; it pins OpenShell **0.1.3**
   (image `0.1.3-rhaiv.3`) with an mTLS client bundle for CLI
   access. Stage-2 planning must verify the SPIFFE/SPIRE integration
   against this version — notably, the user's podman gateway experience
   is with 0.1.6, so expect some drift between versions.
2. Confirmed by the user: the rogue-sandbox deny headlines
   authorization (unregistered SPIFFE ID), with signature verification
   as the underlying layer.
