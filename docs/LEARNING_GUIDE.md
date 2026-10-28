# Learning Guide

A guided tour of the security ideas in this demo, ordered so each builds
on the last. Skim `docs/ARCHITECTURE.md` first for the component map.

## 1. The agent is a workload, not a user

An OpenShell sandbox has no credentials of its own. Its identity is a
SPIFFE ID (`spiffe://openshell.local/openshell/sandbox/<uuid>`) issued by
SPIRE to *the container itself*, attested by container labels — not by
anything the sandbox process could copy or steal. Scenario 5 is the
payoff: a rogue workload with a perfectly valid SVID gets nothing,
because its SPIFFE ID is not under the registered supervisor prefix.

**Where to look:** `deploy/podman/spire/register-sandbox.sh` (the
label-based selector), and the issuer's prefix check in
`token-issuer/jwks.go` (`VerifySVID`).

## 2. Delegation is a stored token, exchange is the mechanism

"Alice's sandbox" means the gateway holds Alice's subject token (minted
by `GET /demo-subject-token?user=alice`, carrying her `departments`
claim) and exchanges it via RFC 8693 when the sandbox needs access. The
sandbox never sees Alice's token — see step 3.

**Where to look:** `deploy/podman/profiles/*.yaml` (the
`subject_token` credential and `token_grant` block).

## 3. Capabilities are configured, never requested

The audience names the target service; the scopes name the sandbox's
capability — both come from the provider profile, matched on the
endpoint's host:port. A sandbox cannot ask for a scope its profile does
not declare, because it never constructs the exchange request at all;
its supervisor does.

**Where to look:** the `audience_overrides` in the profiles, and
`docs/DEMO_SCENARIOS.md`'s permission matrix.

## 4. The intersection is enforced at mint time

This is v2's headline difference from v1. At the final exchange
(`token-issuer/server.go`, `handleSupervisorExchange`), the issuer looks
up the user's departments **server-side** by the intermediate token's
`sub` and computes `departments ∩ requested scope`. Empty → `403
insufficient_department_permissions`, nothing minted. Non-empty → the
token's scope *is* the intersection — never the requested list, so an
over-broad request cannot smuggle scope. v1 enforced the same property
with OPA at request time; here the token itself is born narrow.

Two teaching notes hidden in the implementation:

- **The shared HS256 secret is deliberately a demo shortcut.** The
  issuer and document services share `ACCESS_TOKEN_SECRET`, which means
  the resource server *could* mint its own tokens — fine here, and a
  useful contrast with the asymmetric (SPIRE-signed) SVID path running
  right beside it. A production design would use asymmetric signing so
  verifiers hold only public keys.
- **`GET /demo-subject-token` is the simulated login, not a real one.**
  It mints any known user's subject token with no authentication — in a
  real system this endpoint is your IdP. The blast radius is contained
  (exchanging the token still requires a valid gateway SVID, and the
  final scope is intersected server-side with that user's real
  departments), but do not copy this endpoint into anything real.
- **The JWKS trust anchor rides plain HTTP on the podman network.**
  `http://spire-oidc:8080/keys` is standard SPIRE OIDC-discovery
  practice and matches the upstream demo — the podman network is the
  trust boundary — but note the tension with the zero-trust thesis: a
  workload that could win the `spire-oidc` DNS race could serve its own
  JWKS. Production deployments use HTTPS with a pinned CA
  (`SPIRE_JWKS_CA_FILE` upstream) or, better, the SPIRE Workload API
  socket for same-host verification.
- **Grant sniffing vs. explicit token types.** The upstream Node issuer
  *tries* to parse the subject token as a user token and falls through
  to the supervisor branch on any error — so a malformed token surfaces
  as a 500, and "wrong token type" is indistinguishable from "invalid
  token". Our Go port verifies the signature once and dispatches on the
  `demo_token_use` claim with a specific error for each mismatch. This
  is the same fix OAuth made when it introduced explicit `grant_type`:
  infer the protocol branch from an explicit declaration, not from
  which credential happens to parse.

## 5. Audience binding stops replay

The intermediate token's audience is the supervisor's SPIFFE ID — it is
useless to any other sandbox. The final token's audience is the target
department, so scenario 6's replay of an engineering token against the
finance service fails at `403 insufficient_scope`. Short TTLs (300s)
bound the blast radius of any leaked token.

## 6. The sandbox's network is not its own

The sandbox container runs with no network; its resolv.conf points at a
local broker inside the sandbox binary, and every connection is staged
through the supervisor, which enforces endpoint policy (declared hosts
and ports only), resolves DNS through its own trusted resolver, and
injects credentials. That is why scenario 2's deny happens *before* any
HTTP request leaves the supervisor: the token grant fails, so there is
nothing to send. The `docs/ARCHITECTURE.md` networking notes describe
the podman-machine specifics this demo had to accommodate.

## Suggested reading order in the code

1. `internal/tokens/tokens.go` — what a verifier must check (alg
   pinning, constant-time compare; watch `TestVerifyAlgNone` and
   `TestVerifyAlgRS256` fail in `tokens_test.go`).
2. `token-issuer/jwks.go` — P-1363 signature handling and the SPIFFE
   prefix check.
3. `token-issuer/server.go` — the three-token dispatch and the
   intersection.
4. `document-service/server.go` — the minimal resource-server check.
