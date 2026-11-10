# Stage B work packages: A2A between DocsClaw sandboxes

This directory splits the remaining Stage B work into three PR-sized
packages. The authoritative scope stays in the
[integration plan](../2026-11-06-zt2-docsclaw-integration-plan.md)
(§B.1–B.7); each file here records only the decisions that plan leaves
open, the files each package touches, and the evidence a run must
produce. The DocsClaw contract itself is evidenced in the sibling
`docsclaw` checkout, `docs/dev/zero-trust/release-test-plan.md` (T4a).

## Packages

<!-- markdownlint-disable MD013 -->

| WP | Title | Plan refs | Branch | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| B1 | Asymmetric signing and JWKS | §B.1 | `feature/stage-b1-es256-jwks` | — | merged (#10) |
| B2 | Agent audiences in the issuer | §B.2 | `feature/stage-b2-agent-audiences` | B1 (merged) | merged (#12) |
| B3 | Exposure and profile wiring, scenarios 11–15 | §B.3–B.7 | `feature/stage-b3-a2a-wiring` | B1, B2 | merged (#14) |

<!-- markdownlint-enable MD013 -->

Order: **B1 → B2 → B3**. B1 and B2 touch different code and can land in
parallel, but B3 needs both before it can prove anything end to end.

## Contract pinned across the packages

These values are fixed here so the three packages agree. Each WP file
may add detail but must not change a value without updating this table.

<!-- markdownlint-disable MD013 -->

| Item | Value |
| --- | --- |
| Access-token algorithm | ES256 (P-256); `kid` = RFC 7638 SHA-256 JWK thumbprint |
| Issuer signing key | PKCS#8 PEM at `/etc/zt2/access-token-signing-key.pem` (`ACCESS_TOKEN_SIGNING_KEY_FILE`) |
| JWKS endpoint | `GET http://<issuer>:8080/.well-known/jwks.json`, no auth, `Cache-Control: public, max-age=60` |
| Verifier JWKS URL | `ACCESS_TOKEN_JWKS_URL=http://token-issuer.zt-demo.svc:8080/.well-known/jwks.json` |
| Issuer URL / `iss` | `http://token-issuer.zt-demo.svc:8080` — exact match including `:8080` |
| Agent audience config | `config/agents.yaml`, baked into the issuer image at `/config/agents.yaml` (`AGENTS_FILE`) |
| Agent binary path | `/usr/local/bin/docsclaw` (profile `binaries`) |
| A2A method | POST, so the peer endpoint needs `access: read-write` |
| Caller allowlist | the exact caller SVID, `spiffe://openshell.local/openshell/sandbox/<A's sandbox id>` |
| Removed secret | `ACCESS_TOKEN_SECRET` — no code, config, or deploy reference remains |

<!-- markdownlint-enable MD013 -->

## Working agreements

- One WP per PR. Branch from `main` with the name in the table above;
  conventional commits; `git commit -s`; no push or PR without asking.
- Keep scenarios 1–6 green after every change and re-run the affected
  harness checks. A scenario is "green" only when a run in this session
  produced its PASS lines.
- `make lint test` and `shellcheck` before every commit; `markdownlint`
  for docs.
- Append real commands and observed output to the run log at the end of
  each WP file. Never record an expected result as an observed one.
- If an OpenShell behavior blocks a step, record the gap and stop. Do
  not build a silent workaround.

## Review questions for this split

1. **B2 scope narrowing.** The plan says the minted scope stays
   `user.departments ∩ requested scope`. B2 therefore treats an agent
   audience's `scopes` as the minimum capability it requires and does
   not remove extra scopes from the token. The alternative — also
   intersect with the agent's `scopes` — is narrower but departs from
   the department behavior. Recommendation: keep parity now.
1. **B3 scenario 15 caller.** The plan's example is "Bob's assistant",
   but Bob's departments are finance and admin, so the issuer refuses
   an engineering-scoped final token before B is ever reached; that
   would test the issuer, not `caller_not_allowed`. Recommendation: use
   a second Alice sandbox that is not in `allowed_callers`.
1. **B3 prerequisite.** The Stage A artifacts (§A.3–A.6: agent image
   and config, `create_sandbox` image parameter, `sandbox_ask`) are not
   in this repository's history. B3 assumes they exist; if they do not,
   B3 delivers only the minimum helper surface it needs and says so in
   its PR. Confirm which is intended.
1. **Agent config delivery.** `config/agents.yaml` is static, so B2
   bakes it into the issuer image like `config/users.yaml`, rather than
   adding a ConfigMap on OpenShift. Confirm this is acceptable for the
   demo.

## Run logs

Each WP file ends with a run log. A row is added only after the command
was actually executed in this session, with its real output summarized.
