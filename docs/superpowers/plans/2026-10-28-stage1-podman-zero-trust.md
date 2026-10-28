# Zero Trust Agents v2 — Stage 1 (Podman) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the full zero-trust identity chain (SPIFFE sandbox identity → RFC 8693 token exchange → permission-intersection mint) locally with Podman on macOS, driving all six demo scenarios with curl.

**Architecture:** Two Go services — `token-issuer` (port of upstream `token-issuer.js` semantics plus the departments∩capabilities intersection check) and `document-service` (port of v1's service, now validating final-token audience+scope instead of calling OPA). SPIRE server/agent/OIDC-discovery run as Podman containers adapted from upstream `examples/spiffe-token-exchange-demo/podman/`. Per-user OpenShell provider profiles model users-as-subject-tokens; per-endpoint `audience_overrides` model sandbox capabilities.

**Tech Stack:** Go ≥1.22 (stdlib-first: `net/http` with method+pattern routing, `log/slog`, `crypto`; `gopkg.in/yaml.v3` for config), Podman, SPIRE, OpenShell CLI.

**Spec:** `docs/superpowers/specs/2026-10-28-openshell-zero-trust-design.md`

**Out of scope (follow-up plan):** Stage 2 OpenShift deployment (`deploy/openshift/`). This plan delivers Stage 1 end-to-end.

## Global Constraints

- Module path `github.com/redhat-et/zero-trust-agents-v2` (placeholder until publish). `go.mod` pins `go 1.22`+ (needed for `GET /documents/{id}` pattern routing).
- Go conventions per `~/.claude/go-conventions.md`: prefer stdlib, `log/slog`, minimal deps. Only external dep allowed: `gopkg.in/yaml.v3`.
- Repo conventions per user's global CLAUDE.md: work on a feature branch (`feature/stage1-podman-demo`), `git commit -s` with `Signed-off-by: Pavel Anni <panni@redhat.com>`, `Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>` trailer, no `Co-Authored-By`. Run `golangci-lint run` before each commit. Squash-merge PR at the end.
- License: Apache-2.0 with attribution notes for derived NVIDIA (upstream examples) and v1 code.
- Users (verbatim from v1 `user-service/internal/store/users.go`): alice = engineering+finance, bob = finance+admin, carol = hr.
- Documents: the 7 v1 documents (DOC-001…DOC-007, departments engineering/finance/admin/hr/public) — port from `~/work/zero-trust-agent-demo/document-service/internal/store/documents.go`.
- Token claim schema: subject token `sub`=user + `departments` claim + `demo_token_use: user_subject`; intermediate `demo_token_use: intermediate`, `aud`=supervisor SPIFFE ID, `azp`/`client_id`=gateway SPIFFE ID, TTL 300s; final `demo_token_use: final`, `azp`/`client_id`=supervisor SPIFFE ID, TTL 300s, **`scope` = the intersection result, never the requested scope**. All signed HS256 with a shared `ACCESS_TOKEN_SECRET` (mirrors upstream demo).
- SPIFFE prefixes (configurable; **Podman defaults**, not the k8s ones baked into `token-issuer.js` — upstream `demo.sh:487-488` overrides them): gateway `spiffe://openshell.local/openshell/gateway/`, supervisor `spiffe://openshell.local/openshell/sandbox/`.
- SPIRE issuer/JWKS: keep upstream's `http://spire-oidc:8080` exactly (agreed by `server.conf jwt_issuer`, OIDC provider config, and issuer env — renaming costs three coordinated files plus CA setup for no Stage 1 benefit).
- Token endpoint host: `http://token-issuer.zt-demo.svc` — OpenShell profile lint (`crates/openshell-core/src/oauth.rs:309-312`) allows plain-HTTP token endpoints only for loopback or 3-label `*.svc` / 5-label `*.svc.cluster.local` hosts; `token-issuer.zt-demo.local` would be rejected. Used identically for `token_endpoint`, `jwt_svid_audience`, and `ACCESS_TOKEN_ISSUER`. Document-service hosts are bare aliases (`document-engineering` etc.) like upstream's `alpha-exchange` — endpoints are not linted this way.
- Capability model: **audience comes from the target host (per `audience_overrides`), scopes come from the sandbox's capability** (the profile's `scopes` list). Intersection is `user.departments ∩ requested scopes`, checked at final exchange; it *replaces* upstream's `requestedScopes.includes(audience)` check.
- Scopes/departments share one vocabulary: `engineering`, `finance`, `admin`, `hr`.
- One `ACCESS_TOKEN_SECRET` shared across issuer + all document-service containers: generated once in `scripts/setup.sh` via `openssl rand -hex 32`, exported to every container (upstream `demo.sh` pattern).
- Upstream references live at `~/work/repos/OpenShell/examples/spiffe-token-exchange-demo/` and `.../spiffe-token-grant-demo/`; v1 at `~/work/zero-trust-agent-demo/`.

## Review Focus

Failure modes the spec implies but task tests may not exercise; each pinned to its owning task:

1. **Expired subject token at intermediate exchange** → 401 `invalid_subject_token`, not a panic or a minted token (Task 4).
2. **Final-exchange request with empty scope list** → 403 `insufficient_department_permissions` (empty intersection), never a token with inherited scope (Task 5).
3. **Subject token passed where an intermediate is expected** (and vice versa, including unrecognized `demo_token_use` values) → 401/403 with a specific error, never 500 (Tasks 4, 5).
4. **Document request with a valid final token but wrong audience** (scoped for engineering, sent to finance endpoint) → 403, not 404 (Task 6).
5. **JWT header claiming `alg: none` or an unexpected alg** on the HS256 path → rejected before any payload trust; signature compared with `hmac.Equal` (Task 2). The classic forgery — unacceptable in a zero-trust teaching demo.
6. **SVID with valid signature but unregistered SPIFFE prefix** (e.g. `spiffe://evil.local/...` in unit tests; `spiffe://openshell.local/rogue/workload/1` live — SPIRE won't issue outside its trust domain without federation) → 401 at SVID verification, nothing minted (Task 4).

---

### Task 1: Repo scaffolding

**Files:**
- Create: `go.mod`, `LICENSE`, `.gitignore`, `Makefile`, `README.md` (stub)
- Create: `internal/config/config.go`, `internal/config/config_test.go`, `config/users.yaml`

**Interfaces:**
- Produces: `config.Load(path string) (*Config, error)` — env overrides applied *inside* `Load` (not exposed as fields):

```go
type User struct{ ID, Name string; Departments []string }
type Config struct {
    Users              []User  // from users.yaml
    GatewayPrefix      string  // env GATEWAY_TRUST_DOMAIN_PREFIX, default "spiffe://openshell.local/openshell/gateway/"
    SupervisorPrefix   string  // env SUPERVISOR_TRUST_DOMAIN_PREFIX, default "spiffe://openshell.local/openshell/sandbox/"
    SPIREIssuer        string  // env SPIRE_ISSUER, default "http://spire-oidc:8080"
    JWKSURI            string  // env SPIRE_JWKS_URI, default SPIREIssuer + "/keys"
    SVIDAudience       string  // env JWT_SVID_AUDIENCE, default "http://token-issuer.zt-demo.svc"
    TokenIssuer        string  // env ACCESS_TOKEN_ISSUER, default "http://token-issuer.zt-demo.svc"
    ListenAddr         string  // env PORT, default ":8080"
}
// ACCESS_TOKEN_SECRET read by Load; empty → error.
```

- Produces: `config/users.yaml` with the three v1 users above.

- [ ] **Step 1: Create the feature branch** — `git checkout -b feature/stage1-podman-demo`.
- [ ] **Step 2: Write failing test** — `config.Load` on a temp YAML with one user returns that user; each env override beats its default; missing `ACCESS_TOKEN_SECRET` returns error.
- [ ] **Step 3: Run test to verify it fails** — `go test ./internal/config/`; expected: no Go module / undefined symbol.
- [ ] **Step 4: Implement** — `go mod init github.com/redhat-et/zero-trust-agents-v2`, `go 1.22`, add `gopkg.in/yaml.v3`, implement `Load`, write `config/users.yaml`, Apache-2.0 `LICENSE`, `.gitignore`, `Makefile` targets `lint`/`test`.
- [ ] **Step 5: Run test to verify it passes.**
- [ ] **Step 6: Commit** — `chore: scaffold repo with config loading` (with sign-off + Assisted-By trailers).

### Task 2: JWT sign/verify core (`internal/tokens`)

**Files:**
- Create: `internal/tokens/tokens.go`, `internal/tokens/tokens_test.go`

**Interfaces:**
- Consumes: `config.Config` (secret, issuer).
- Produces:

```go
type Claims map[string]any // JWT payload
func Sign(secret string, claims Claims) (string, error)
func Verify(secret string, token string) (Claims, error) // checks alg == HS256, exp, iss
func Parse(token string) (Claims, error)                 // no signature check (for tests)
const (
    UseUserSubject  = "user_subject"
    UseIntermediate = "intermediate"
    UseFinal        = "final"
)
```

- [ ] **Step 1: Write failing tests** — sign→verify round-trip returns the claims; tampered payload fails; expired `exp` fails; wrong secret fails; **header `alg: none` and `alg: RS256` both fail with an alg error** (Review Focus 5).
- [ ] **Step 2: Run tests to verify they fail.**
- [ ] **Step 3: Implement** — HS256 with `crypto/hmac` + `crypto/sha256`, compare signatures with `hmac.Equal` (constant-time, mirrors upstream's `timingSafeEqual`), reject any header `alg` ≠ `HS256` before touching the payload, base64url raw encoding, claim set per Global Constraints. Stdlib only; no `golang-jwt`.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Commit** — `feat: HS256 demo-token sign/verify core`.

### Task 3: Token issuer — HTTP server and subject-token issuance

**Files:**
- Create: `token-issuer/main.go`, `token-issuer/server.go`, `token-issuer/server_test.go`

**Interfaces:**
- Consumes: `internal/config`, `internal/tokens`.
- Produces: `NewServer(cfg *config.Config, jwks JWKSVerifier) *http.Server` with routes:
  - `GET /healthz` → 200 "ok"
  - `GET /demo-subject-token?user=alice` → `{"access_token", "token_type": "Bearer", "expires_in": 1800}`; subject token claims: `iss`, `sub`=alice, `aud: ["openshell-gateway","account"]`, `scope: "openid profile email"`, `departments: ["engineering","finance"]`, `demo_token_use: user_subject`, TTL 1800s.
  - `POST /token` (Tasks 4/5 — 501 stub for now).

```go
type JWKSVerifier interface {
    VerifySVID(jwt string, subjectPrefix string) (tokens.Claims, error)
}
```

- [ ] **Step 1: Write failing tests** (httptest): unknown user → 404; alice → 200 with parseable token whose `departments` = [engineering finance] and `demo_token_use` = user_subject.
- [ ] **Step 2: Run tests to verify they fail.**
- [ ] **Step 3: Implement** — `net/http` handlers, `log/slog` logging, user lookup from `cfg.Users`.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Commit** — `feat: token-issuer subject-token endpoint`.

### Task 4: Token issuer — JWKS/SVID verification and intermediate exchange

**Files:**
- Create: `token-issuer/jwks.go`, `token-issuer/jwks_test.go`
- Modify: `token-issuer/server.go` (replace `/token` stub)

**Interfaces:**
- Consumes: `JWKSVerifier` from Task 3; `tokens.Verify`.
- Produces: `NewJWKSVerifier(jwksURI, spireIssuer, svidAudience string) JWKSVerifier` — fetches JWKS (60s cache), verifies ES256 and RS256 signatures against `kid`, checks `iss`, `aud`, `exp`/`nbf`, and `sub` prefix (Review Focus 6).
- Produces: `/token` request handling — **single signature verification, then explicit dispatch** (deliberate deviation from upstream's try-user-subject-then-fall-through, which conflates "wrong token type" with "invalid token" and 500s on malformed input):
  1. Validate `grant_type` = token-exchange and `client_assertion_type` = jwt-spiffe (400 errors: `unsupported_grant_type`, `unsupported_client_assertion_type`, `missing_client_assertion`, `missing_subject_token`).
  2. `tokens.Verify` the subject token once → 401 `invalid_subject_token` on failure (Review Focus 1).
  3. Switch on `demo_token_use`: `user_subject` → gateway branch (this task); `intermediate` → supervisor branch (Task 5); anything else → 401 `unsupported_token_use` (Review Focus 3).
  4. Gateway branch: `VerifySVID(assertion, cfg.GatewayPrefix)` → 401 `invalid_client_assertion`; `audience` must start with supervisor prefix → 400 `unsupported_intermediate_audience`; mint intermediate per schema → 200.

- [ ] **Step 1: Write failing tests for JWKS verifier** — `httptest.Server` serving a JWKS with generated ES256 + RSA keys (stdlib); `VerifySVID` accepts a self-made SVID with correct `sub` prefix/`iss`/`aud`; rejects: wrong prefix (`spiffe://evil.local/...` — Review Focus 6), wrong issuer, expired, bad signature, unknown `kid`.
- [ ] **Step 2: Run tests to verify they fail.**
- [ ] **Step 3: Implement `jwks.go`** — stdlib `crypto/ecdsa`/`crypto/rsa` + `encoding/json` JWK parsing. Non-obvious algorithm: SPIRE JWT-SVIDs use **P-1363 raw signatures** (64-byte r‖s), not ASN.1 DER — split into two 32-byte halves and call `ecdsa.Verify` with the reconstructed `r`/`s` big.Ints (upstream Node does this via `dsaEncoding: "ieee-p1363"`; Go has no flag).
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Write failing tests for the gateway branch** (httptest with a fake `JWKSVerifier` — no real SPIRE needed): happy path mints intermediate with `azp` = gateway SVID `sub`; expired/garbage subject token → 401 `invalid_subject_token`; intermediate token presented where subject expected → 401 `unsupported_token_use`; bad audience → 400 `unsupported_intermediate_audience`.
- [ ] **Step 6: Implement the dispatch + gateway branch; run tests; commit** — `feat: intermediate token exchange with SVID verification`.

### Task 5: Token issuer — final exchange with permission intersection

**Files:**
- Modify: `token-issuer/server.go`, `token-issuer/server_test.go`

**Interfaces:**
- Consumes: dispatch from Task 4; user department lookup from `cfg.Users` by `sub`.
- Produces: supervisor branch — supervisor-prefixed `client_assertion` + intermediate subject token + `audience` ∈ {engineering, finance, admin, hr} + `scope`. Check order:
  1. `VerifySVID(assertion, cfg.SupervisorPrefix)` → 401.
  2. Intermediate `aud` must contain the supervisor SPIFFE ID → 403 `intermediate_token_audience_mismatch`.
  3. Audience in the supported set → 400 `unsupported_audience`.
  4. **Intersection**: `user.departments ∩ requested scope` must be non-empty → else 403 `insufficient_department_permissions` (this *replaces* upstream's `missing_matching_scope`/`requestedScopes.includes(audience)` check — with audience = target and scope = capability, the intersection is the capability enforcement).
  5. Mint final token with **`scope` = the intersection members** (never the requested list), `azp` = supervisor SVID, `aud` = [audience, "account"], TTL 300s.

- [ ] **Step 1: Write failing tests** covering: alice + scope engineering + audience engineering → 200, final `scope` ⊆ {engineering} and excludes anything not intersected; **scenario 2 shape: alice + scope hr + audience engineering → 403 `insufficient_department_permissions`** (audience from the engineering host, capability hr — the exact live request); bob + finance → 200; carol + hr → 200 (scenario 4); intermediate `aud` for a different supervisor → 403; empty scope → 403 `insufficient_department_permissions` (Review Focus 2); requested scope ⊄ user departments but overlapping → 200 with only the overlapping members in `scope`.
- [ ] **Step 2: Run tests to verify they fail.**
- [ ] **Step 3: Implement the supervisor branch** — set intersection over lowercase department strings; the department list comes from `cfg.Users` lookup by the intermediate's `sub`, never from request parameters.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Commit** — `feat: final exchange enforcing department/capability intersection`.

### Task 6: Document service

**Files:**
- Create: `document-service/main.go`, `document-service/server.go`, `document-service/server_test.go`, `document-service/documents.go`

**Interfaces:**
- Consumes: `internal/tokens.Verify` (shared secret via env), document data ported from v1 `documents.go` (all 7 documents verbatim).
- Produces: `NewServer(secret, issuer, department string, docs []*Document) *http.Server` — one instance per department, plus one public instance:
  - **Topology (explicit):** `document-engineering` (DOC-001, DOC-005), `document-finance` (DOC-002, DOC-005), `document-admin` (DOC-003, DOC-006), `document-hr` (DOC-004), `document-public` (DOC-007). Multi-department docs (DOC-005, DOC-006) appear under each of their departments; DOC-007 is served by the public instance, which still requires a valid final token (audience holds) but no department scope.
  - `GET /healthz`; `GET /documents`; `GET /documents/{id}` (Go 1.22 pattern routing).
  - Auth: final token with `aud` containing this service's department (or `public`) and `scope` containing it; document access requires the token's scope to include one of the document's `RequiredDepartments`. Error JSON mirrors the issuer's `{ "error": "..." }`: `missing_token` 401, `invalid_token` 401 (includes wrong `demo_token_use`), `insufficient_scope` 403; unknown ID → 404.

- [ ] **Step 1: Write failing tests** (httptest, mint final tokens directly with `tokens.Sign`): valid token+audience+scope → 200 with the department's doc list; token scoped engineering against finance service → 403 `insufficient_scope` (Review Focus 4); intermediate token presented → 401 `invalid_token`; missing Authorization → 401 `missing_token`; DOC-005 accessible from engineering with engineering scope; DOC-007 from public service with valid token but no department scope → 200.
- [ ] **Step 2: Run tests to verify they fail.**
- [ ] **Step 3: Implement** — copy document structs/data from v1 (drop `S3URL`), handlers per above.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Commit** — `feat: document-service with final-token audience/scope validation`.

### Task 7: Podman deployment (SPIRE + services)

**Files:**
- Create: `deploy/podman/spire/` — `server.conf`, `agent.conf`, `oidc-discovery-provider.conf` copied from upstream `~/work/repos/OpenShell/examples/spiffe-token-exchange-demo/podman/spire/` (keep `jwt_issuer = "http://spire-oidc:8080"` and `domains = ["spire-oidc", "127.0.0.1", "localhost"]` exactly — see Global Constraints)
- Create: `deploy/podman/scripts/` — `start-spire.sh`, `register-gateway.sh` (adapted upstream), `build-images.sh`, `start-services.sh`
- Create: `deploy/podman/Containerfile.token-issuer`, `deploy/podman/Containerfile.document-service`
- Create: `deploy/podman/profiles/` — per user × capability variants (e.g. `alice-engineering.yaml`, `alice-hr.yaml`, `carol-hr.yaml`, plus a `nodelegation` variant, see Task 8)
- Create: `deploy/podman/compose.yaml` (or plain `podman run` scripts — implementer's choice, one command to start)

**Interfaces:**
- Consumes: both Go binaries; SPIRE images (`ghcr.io/spiffe/spire-server`, `spire-agent`, `oidc-discovery-provider`).

- [ ] **Step 1: Adapt SPIRE configs** — copy upstream files verbatim where possible; trust domain `openshell.local`; network alias `spire-oidc` must resolve from issuer and gateway containers (shared podman network).
- [ ] **Step 2: Write the two Containerfiles** — `CGO_ENABLED=0` static binaries on `distroless/static` or `scratch`, non-root user, port 8080.
- [ ] **Step 3: Write provider profiles** — derive from upstream podman `provider-profile.yaml`; `token_endpoint: http://token-issuer.zt-demo.svc/token`, `jwt_svid_audience: http://token-issuer.zt-demo.svc`. Capability model per Global Constraints: `audience` = target department, `scopes` = the sandbox's capability, e.g. `alice-hr.yaml` declares `host: document-engineering, audience: engineering, scopes: [hr]`.
- [ ] **Step 4: Secret handling** — `start-services.sh` generates `ACCESS_TOKEN_SECRET=$(openssl rand -hex 32)` once and passes it to issuer and every document-service container.
- [ ] **Step 5: Verify manually** — `start-spire.sh` then `podman ps` shows server+agent+oidc healthy; `curl http://localhost:<oidc-port>/keys` returns a JWKS. Environment work: verification is the command output.

### Task 7b: Gateway + sandbox lifecycle

The riskiest integration work — everything between SPIRE and the scenarios — owned by its own task, verified by one working request before any scenario script exists.

**Files:**
- Create: `deploy/podman/scripts/start-gateway.sh`, `deploy/podman/scripts/register-sandbox.sh`, `deploy/podman/scripts/sandbox-request.sh`
- Modify: `register-gateway.sh` if the upstream default selector is wrong for this layout

**macOS specifics (verified against upstream `demo.sh`):**
- The gateway must run as a **container** (`START_GATEWAY=1` path): a macOS-native gateway cannot reach the SPIRE agent's Unix socket, which lives inside the podman machine VM.
- Therefore the gateway's SPIRE selector is `docker:label:openshell.spiffe-demo:gateway` (container label), **not** `unix:uid:$(id -u)` — the upstream default would compute the macOS uid (501) against a container running as root.
- The SPIRE agent runs `--pid=host --security-opt label=disable` with the podman socket mounted; `SPIRE_AGENT_SOCKET_HOST_PATH` must be the same path inside the gateway container as outside.
- `register-sandbox.sh <id>` can only run **after** the sandbox exists (selector is `docker:label:openshell.ai/sandbox-id:${SANDBOX_ID}`), and SVID propagation is not instant — wrap the first request in a retry loop (upstream `demo.sh` uses 18×2s).

- [ ] **Step 1: Write `start-gateway.sh`** — run the OpenShell gateway container with the shared network, SPIRE agent socket mount, and state dir; register the gateway SPIFFE entry (`spiffe://openshell.local/openshell/gateway/demo`, parent `spiffe://openshell.local/openshell/spire-agent/demo`).
- [ ] **Step 2: Write `register-sandbox.sh` + `sandbox-request.sh`** — register a sandbox's SPIFFE entry by its container label; `sandbox-request.sh` performs a curl from inside a sandbox with the retry loop.
- [ ] **Step 3: Verify end-to-end with one request** — create a provider (profile lint must pass — this is where the `.svc` host-name rule bites if wrong), store alice's subject token via `provider create --credential subject_token=...`, create a sandbox, register it, and fetch an engineering doc. This working request is the task's acceptance test; commit — `feat: podman deployment with gateway and sandbox lifecycle`.

### Task 8: Demo scripts and end-to-end scenario run

**Files:**
- Create: `scripts/setup.sh` (build images, start everything, print URLs, smoke test), `scripts/scenario<N>.sh` for N=1..6, `scripts/teardown.sh`
- Create: `docs/DEMO_SCENARIOS.md`, `docs/ARCHITECTURE.md`, `docs/LEARNING_GUIDE.md`
- Modify: `README.md` (full quick start + scenario matrix)

**Interfaces:**
- Consumes: Task 7/7b deployment; OpenShell CLI on the macOS host driving sandboxes.

Scenarios (from the spec, exact), with live mechanics settled up front:
1. Alice's sandbox (engineering capability) fetches engineering doc → ✅ — `alice-engineering.yaml` profile.
2. Alice's sandbox (hr capability) fetches engineering doc → ❌ `insufficient_department_permissions` — `alice-hr.yaml` profile curling `document-engineering` (audience=engineering, scope=hr → empty intersection).
3. Sandbox without user delegation → ❌ no token minted — ship a `nodelegation.yaml` profile variant with `subject_token` `required: false` (the normal profiles declare it required, so it can't just be omitted); expect a clean 401/400 at the issuer, not a 500 (this is the path that motivated Task 4's dispatch rework).
4. Carol's sandbox (hr) fetches hr doc → ✅ — `carol-hr.yaml`.
5. Rogue sandbox → ❌ at SVID prefix check — **SPIRE won't issue outside its trust domain without federation**, so use a non-registered path *inside* it: register `spiffe://openshell.local/rogue/workload/1` against a dedicated container's label, fetch the SVID with `spire-agent api fetch jwt -audience http://token-issuer.zt-demo.svc` from inside the agent container, then POST it directly to `/token`. Expect 401 `invalid_client_assertion`.
6. Audience/replay → ❌ — **cannot be driven from inside the sandbox** (the supervisor injects the token; the sandbox never sees it). Stage out-of-band: mint a final token via a direct `/token` call using a registered supervisor SVID, then curl the wrong document service from the host. Expect 403 `insufficient_scope`.

- [ ] **Step 1: Write `setup.sh`** — idempotent; ends by curling `/healthz` on issuer + one document service and minting one subject token as a smoke test.
- [ ] **Step 2: Write scenario scripts** — each prints the scenario title, the command it runs, and ✅/❌ expected vs actual; exit non-zero on mismatch.
- [ ] **Step 3: Run all six scenarios for real** — the plan's acceptance test; document any environment drift (podman machine version, OpenShell CLI version) encountered.
- [ ] **Step 4: Write the docs** — `DEMO_SCENARIOS.md` (v1-style ✅/❌ permission matrix, curl commands a reader can run); `ARCHITECTURE.md` (port the spec's token-flow diagram; explain the capability model: audience = target, scope = capability); `LEARNING_GUIDE.md` (include two teaching notes: (a) the issuer/document-service shared HS256 secret means the resource server could mint its own tokens — fine for a demo, and a deliberate contrast with the asymmetric SVID path running beside it; (b) upstream's try-and-fall-through grant sniffing vs our explicit `demo_token_use` dispatch — the same fix OAuth made with explicit `grant_type`). README under 200 lines; other docs under 500.
- [ ] **Step 5: Commit** — `feat: scenario scripts and demo docs`.

### Task 9: Final verification and PR

- [ ] **Step 1:** `make lint && make test` — both green.
- [ ] **Step 2:** Re-run `scripts/setup.sh` from a clean state (containers removed) and all six scenario scripts pass.
- [ ] **Step 3:** Push branch, open draft PR (`gh pr create --draft`), run `code-review:code-review` skill on the diff, fix findings, `gh pr ready`, merge with `gh pr merge --squash --delete-branch`.

---

## Self-review notes

- Spec coverage: all spec components map to tasks (issuer → 3–5, document-service → 6, deploy/podman → 7+7b, scripts/docs → 8, scenarios 1–6 → 8 with mechanics settled). `spiffe-token-grant-demo` (client_credentials) is noted in the spec as optional/early module — deferred to a follow-up; not blocking.
- Stage 2 (OpenShift) deliberately excluded: separate plan once Stage 1 is green, per the spec's stage ordering and the version-drift caveat (OpenShell 0.1.3 on the cluster vs 0.1.6 locally).
- Incorporated external review (Opus, verified against upstream): podman gateway prefix, `.svc` token-endpoint host for profile lint, scenario-2 capability/audience model + check order, final-token scope = intersection, alg pinning + `hmac.Equal`, explicit `demo_token_use` dispatch, upstream SPIRE issuer URLs kept, Task 7b gateway/sandbox lifecycle with macOS specifics, rogue-sandbox in-trust-domain path, scenario 3 `required: false` variant, scenario 6 out-of-band staging, config shape and Go version pinning, document topology, shared-secret handling, docs tasked.
