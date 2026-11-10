# WP-B3: exposure and profile wiring, scenarios 11–15

**Plan reference:** §B.3–B.7 of the
[integration plan](../2026-11-06-zt2-docsclaw-integration-plan.md).
This is the only package that runs DocsClaw inside the v2 stack.
**Status:** merged (#14). Scenarios 11–15 pass on the Podman driver.
The OpenShift pass (B3-A9) ran on 2026-11-10 and is **still open**: the
cluster is reachable and scenarios 1–6 pass under `ZT2_DRIVER=openshift`,
but no cluster-reachable DocsClaw image exists (the `-openshell-*` tag was
removed from ghcr), so the A2A spike could not run past creating B. The
run log records the exposure-URL findings and the exact failure; the gap is
recorded rather than worked around.
**Branch:** `feature/stage-b3-a2a-wiring`.

## Scope

Deliver the wiring in §B.3–B.5 and the scenarios in §B.6:

- the sandbox-to-sandbox exposure spike, Podman and OpenShift;
- B's profile egress (document service + issuer JWKS) and inbound config;
- A's profile (peer endpoint with `access: read-write` and an
  `audience_overrides` entry) and peer config;
- Carol's hr analyst service for the negative path;
- `create_agent_service`, service-URL and config-upload helpers;
- scenarios 11–15 and their documentation.

Non-goals: request-bound delegation (§B.7 roadmap), AgentCard signature
verification, streaming/push, mainstream-agent adapters.

## Prerequisites

- B1 merged: the issuer publishes an ES256 JWKS.
- B2 merged: `engineering-analyst` and `hr-analyst` are accepted
  audiences.
- Stage A artifacts: the derived image with DocsClaw at
  `/usr/local/bin/docsclaw`, `agents/doc-assistant/`, the
  `create_sandbox` image parameter and `sandbox_ask` (§A.3–A.6). B3 does
  not re-implement Stage A; if an artifact is missing, add only the
  minimum helper surface listed under "Files to change" and say so in
  the PR.
- `docsclaw:dev-openshell` built from `~/work/docsclaw` with
  `make image-openshell` (arm64). The gateway resolves it from the same
  Podman engine.
- A running zt2 stack: `zt2-gateway`, `zt2-token-issuer`, the five
  document services, the SPIRE trio.

## Decisions pinned

1. **Profiles are new files, not edits to the scenario 1–6 profiles.**
   The existing four stay untouched so their scenarios keep their exact
   behavior. Three templates are added in each driver:
   - `engineering-analyst` (B): Alice × engineering grant; endpoints =
     engineering document service plus the issuer JWKS host; binaries =
     `docsclaw` and curl.
   - `alice-a2a` (A): Alice × engineering grant; endpoints = engineering
     document service plus B's exposed host; override for B's host with
     `audience: engineering-analyst`, `scopes: [engineering]`.
   - `carol-hr-analyst`: Carol × hr grant; endpoints = hr document
     service plus the issuer JWKS host.
1. **The JWKS endpoint is part of B's own egress.** Without it every
   verification on B is `503 jwks_unavailable`. Podman host:
   `192.168.127.254.nip.io:8080` with `allowed_ips` for
   `192.168.127.254`; OpenShift host: `token-issuer.zt-demo.svc:8080`.
   `access: read-only` and `binaries: [/usr/local/bin/docsclaw]`.
1. **A's peer endpoint is `access: read-write`.** A2A uses POST;
   `read-only` fails at A's supervisor with `403 policy_denied` before
   the request leaves the sandbox (T4a gotcha 1).
1. **The caller allowlist is the exact sandbox SVID.** B's
   `inbound_auth.allowed_callers` gets
   `spiffe://openshell.local/openshell/sandbox/<A's sandbox id>`,
   substituted at run time. The `…/sandbox/` prefix would admit every
   sandbox and scenario 15 could not distinguish a caller.
1. **B's config is uploaded, never baked.** Sandbox IDs are per-run
   UUIDs; `agent-config.yaml.in` is rendered and delivered under
   `/workspace` with `sandbox upload` before `docsclaw serve` starts.
1. **Bootstrap ordering is fixed** because of the two dependencies
   above:
   1. create B → 2. expose B's port → 3. render/import A's profile with
   B's host and port → 4. create A and read its ID → 5. render/upload
   B's config with A's SVID → 6. start `docsclaw serve --host 0.0.0.0`
   in B → 7. render/upload A's config with B's URL → 8. run A's
   `docsclaw ask`.
1. **A's config lists two peers.** `engineering-analyst` (bound in A's
   profile) and `hr-analyst` (deliberately unbound). Scenario 12 needs
   the agent to attempt the hr call and the supervisor to refuse it;
   configuration grants the tool, policy decides the reach.
1. **Scenario 15 uses a second Alice sandbox, not Bob.** Bob has no
   engineering department, so the issuer refuses an engineering-scoped
   final token before B is reached. A second sandbox with the
   `alice-a2a` profile has the capability but is not in B's
   `allowed_callers`, which is the condition the scenario must isolate.
   Flagged in the [index](00-index.md#review-questions-for-this-split).
1. **Scenario 14 needs a live hr-analyst service.** Carol's sandbox
   runs `docsclaw serve` with `inbound_auth.audience: hr-analyst` and
   `required_scopes: [hr]`. The replayed token is minted out of band,
   the same way scenario 6 mints one.
1. **URL stability is a spike output, not an assumption.** Whether
   `service expose` yields a stable host/port decides whether A's
   profile can be imported once at setup or must be
   delete-and-reimported per run. Record the answer before writing the
   scenario scripts.

## Files to change

<!-- markdownlint-disable MD013 -->

| Path | Change |
| --- | --- |
| `deploy/podman/profiles/engineering-analyst.yaml.in` | New: B's egress profile (documents + JWKS) |
| `deploy/podman/profiles/alice-a2a.yaml.in` | New: A's egress profile (documents + peer endpoint, override) |
| `deploy/podman/profiles/carol-hr-analyst.yaml.in` | New: hr-analyst peer for scenario 14 |
| `deploy/openshift/profiles/*.yaml.in` | The same three, in-cluster hosts |
| `deploy/podman/scripts/build-images.sh` | Derived `zt2-docsclaw` image if Stage A did not add it |
| `deploy/openshift/build-images.sh` | Same for the OpenShift image |
| `agents/engineering-analyst/{system-prompt.txt,agent-config.yaml.in,agent-card.json}` | New: B's prompt, inbound auth, tools |
| `agents/hr-analyst/{system-prompt.txt,agent-config.yaml.in,agent-card.json}` | New: the negative peer |
| `agents/doc-assistant/agent-config.a2a.yaml.in` | A's config with two peers and substituted URLs |
| `scripts/lib.sh` | `create_agent_service`, `service_url`, `sandbox_upload`, `mint_final_token` |
| `scripts/drivers/lib-podman.sh` | `DOCSCLAW_IMAGE`, issuer egress host/port, A2A allowed IPs |
| `scripts/drivers/lib-openshift.sh` | Same names, in-cluster values |
| `scripts/setup.sh` | Render/import the two static profiles; keep A's per-run |
| `deploy/openshift/setup.sh` | Same |
| `scripts/scenario11.sh` … `scripts/scenario15.sh` | New scenarios |
| `deploy/podman/scripts/start-services.sh` | Only if B1 left a JWKS host substitution to add |
| `docs/DEMO_SCENARIOS.md` | Scenarios 11–15 |
| `docs/ARCHITECTURE.md` | A2A flow diagram |
| `docs/ROADMAP.md` or `docs/PRODUCTION_RECOMMENDATIONS.md` | Request-bound delegation (§B.7) |

<!-- markdownlint-enable MD013 -->

## Tasks

1. **Spike (§B.3).** Run it on OpenShift first when the cluster is
   available, as the plan requires; otherwise run the Podman spike now
   and do the OpenShift pass before the PR is marked ready. Expose a
   `docsclaw serve` sandbox, call it from another sandbox, confirm the
   final-token claims, the no-token path, the JWKS fetch through B's
   own supervisor, and loopback reachability. Also confirm whether the
   exposed URL is reachable from the laptop: scenario 13 calls it
   directly. Record commands and output in the run log and in a short
   findings note if a gap appears.
1. Add the three profile templates in both drivers and helper
   functions. Verify: `profile lint` on every rendered file.
1. Add the agent configs and the derived image. Verify: `docsclaw
   --version` and the binary path inside a sandbox.
1. Wire `setup.sh` (static profiles only) and the per-run ordering in a
   helper or in scenario 11.
1. Write scenarios 11–15, one script each, following the existing
   scenario style.
1. Update the three docs and run `markdownlint`.

## Acceptance tests and evidence

<!-- markdownlint-disable MD013 -->

| ID | Check | Command | Expected |
| --- | --- | --- | --- |
| B3-A1 | A→B full chain | `scripts/scenario11.sh` | A's answer contains B's analysis; B's log shows `sub=alice`, `azp=spiffe://…/sandbox/<A>`, `scope=engineering`, `aud=engineering-analyst` |
| B3-A2 | Unbound peer | `scripts/scenario12.sh` | A's trace shows the hr call attempt; A's supervisor returns `403 policy_denied`; B is never reached |
| B3-A3 | No token | `scripts/scenario13.sh` | direct host call to B returns `401 missing_token` |
| B3-A4 | Replay across peers | `scripts/scenario14.sh` | the engineering-analyst token at the hr analyst returns `403 invalid_audience` |
| B3-A5 | Caller allowlist | `scripts/scenario15.sh` | a second Alice sandbox returns `403 caller_not_allowed` at B |
| B3-A6 | No regression | `scripts/scenario1.sh` … `scripts/scenario6.sh` | every script prints its PASS line |
| B3-A7 | Token isolation | search A/B stdout, supervisor logs, and the session store | no JWT and no `jti` marker |
| B3-A8 | JWKS egress | B's stderr/log while verifying | no `503 jwks_unavailable` |
| B3-A9 | OpenShift | `[cluster]` the spike and scenario 11 with `ZT2_DRIVER=openshift` | same claims; record any hairpin gap |

<!-- markdownlint-enable MD013 -->

## Dependencies

- B1 and B2 merged.
- Stage A artifacts and the `docsclaw:dev-openshell` image.
- A running zt2 stack; scenarios 1–6 green is the entry condition.
- The ROSA cluster for B3-A9; the Podman results stand on their own and
  a gap is recorded rather than worked around.

## Risks and gotchas

- `sandbox create` without `--detach` can look hung after the sandbox is
  Ready. Always detach.
- `register-sandbox.sh` needs
  `SPIRE_SERVER_CONTAINER=zt2-spire-server`.
- Provider credentials are keyed by the profile's env var name:
  `LLM_API_KEY=… provider create … --credential LLM_API_KEY`.
- Profiles are immutable per ID; an existing sandbox does not pick up a
  re-import. Recreate the sandbox after any profile change.
- `docsclaw serve` must bind `--host 0.0.0.0` when reached through a
  container proxy; the default is loopback.
- Subject tokens expire after 30 minutes. Mint a fresh subject token
  and a fresh provider per run; a reused provider ages the sandbox out
  of its capability with a bare `502`.
- `sandbox upload` takes the **parent** directory as the destination, so
  a local `config-b/` lands as `/workspace/config-b/`.
- `setup.sh` deletes every sandbox and provider when any `zt2-*` profile
  exists. Add the new profiles to its import loop, or a rerun removes
  them; use `start-services.sh` for service-only restarts.
- A profile that depends on a runtime URL cannot be imported at setup.
  Delete and re-import it per run, or confirm a stable URL in the spike
  and then import once.

## Run log

<!-- markdownlint-disable MD013 -->

| Date | Command | Observed |
| --- | --- | --- |
| 2026-11-10 | `openshell service expose eng-analyst 8000 agent --authorization-mode bearer-passthrough` | `URL: http://default--eng-analyst--agent.openshell.localhost:18083/`. Stable: derived from workspace, sandbox, service name and gateway port, so a fixed sandbox name yields a fixed URL. `/health` returns 200 from the laptop. |
| 2026-11-10 | from sandbox A: `curl http://default--eng-analyst--agent.openshell.localhost:18083/health` | `curl: (7) Could not connect`. Supervisor log: `Denied staged transparent connection`. `podman machine ssh getent hosts <name>` → `::1` — the VM resolver maps `*.localhost` to loopback (RFC 6761), and loopback is never a permitted upstream destination. |
| 2026-11-10 | from sandbox A: same, with `-H 'Host: default--eng-analyst--agent.openshell.localhost'` against the published gateway IP | `403 request_authority_mismatch`: the gateway requires the request authority to equal the endpoint the tunnel was authorized for. |
| 2026-11-10 | from sandbox A: `curl http://host.openshell.internal:18083/health` with that endpoint declared | `404` from the gateway. The trusted-gateway alias is reachable, but the authority is the alias, not a service name, so it cannot route. Supervisor warns `host.openshell.internal maps to a non-link-local IP; trusted-gateway SSRF exemption disabled`. |
| 2026-11-10 | `openshell forward service eng-analyst --target-port 8000 --local 127.0.0.1:18800`, profile endpoint `192.168.127.254.nip.io:18800` | From sandbox A: `health=200`. The host-published path works; it is what the Podman driver uses for A→B. |
| 2026-11-10 | `STATE_DIR=$PWD/.zt2-state bash scripts/setup.sh` | Seven profiles rendered, `Provider profile lint passed.` and `Imported 1 provider profile.` for each. |
| 2026-11-10 | `scripts/scenario1.sh` … `scenario6.sh` | PASS: full chain, `403 insufficient_department_permissions`, `Token grant failed`, Carol's path, `401 invalid_client_assertion`, `403 invalid_audience`. |
| 2026-11-10 | `scripts/scenario13.sh` | PASS: exposed URL reachable from the laptop (`/health` 200); tokenless POST returns `401 missing_token`. |
| 2026-11-10 | `scripts/scenario14.sh` | PASS: out-of-band token has `aud=engineering-analyst`, `scope=engineering`, `azp=<sandbox SVID>`; the hr analyst returns `403 invalid_audience`. |
| 2026-11-10 | `scripts/scenario15.sh` | PASS: second Alice sandbox obtains a valid token and B returns `403 caller_not_allowed`. |
| 2026-11-10 | `scripts/scenario11.sh` (MaaS `rits/deepseek-ai/DeepSeek-V4.1-Flash-1017`) | PASS. A's trace: `→ a2a_call {"message":"Please review document DOC-001 …","peer":"engineering-analyst"}` then `← a2a_call ok: [completed] …`. B logs `"request authenticated" sub="alice" azp="spiffe://openshell.local/openshell/sandbox/<A's id>" scope="engineering" aud="engineering-analyst account"`. No `jwks_unavailable` in B's log. |
| 2026-11-10 | `scripts/scenario12.sh` | PASS. A's trace shows the attempt then `← a2a_call error: … dial tcp 198.18.0.3:18810: connect: permission denied`. A deny with no declared endpoint reaches DocsClaw as a refused connection rather than the `blocked by sandbox network policy` message a declared-but-denied policy produces. |
| 2026-11-10 | `oc whoami`; `deploy/openshift/setup.sh` (fresh ROSA `cwy7f-af7e-xo9`) | `cluster-admin`; setup exit 0, all `zt-demo` and `openshell` pods `Running`, gateway `zt2` registered and `Authenticated (mTLS)` |
| 2026-11-10 | `ZT2_DRIVER=openshift scripts/scenario1.sh` … `scenario6.sh` (default ports) | 1–5 PASS; **6 FAIL**: `sanity check failed: engineering token got 401 from engineering service` |
| 2026-11-10 | `lsof -nP -iTCP:18101` and `podman ps` | `gvproxy` (the still-running Podman demo) holds IPv4 `127.0.0.1:18101`/`18102`, while `oc port-forward` bound only `[::1]`. `curl 127.0.0.1:18101` therefore reached the **Podman** document service, which rejects a cluster token with `401 invalid_token`. The same token returned `200` from a probe pod against `document-engineering.zt-demo.svc:8080`. Root cause: the OpenShift driver's host ports collide with the Podman driver's. |
| 2026-11-10 | fix: `scripts/drivers/lib-openshift.sh` host ports moved to the `191xx` block (`19180`/`19101`/`19102`) and `oc port-forward --address 127.0.0.1`; re-ran 1–6 with the Podman stack still up | all six print PASS. This is the B3-A6 regression evidence: scenarios 1–6 green on OpenShift, including scenario 6 |
| 2026-11-10 | `openshell service expose eng-analyst 8000 agent --authorization-mode bearer-passthrough` (`service list -o json`) | `URL: https://default--eng-analyst--agent.openshell.localhost/` — a `.openshell.localhost` authority with **no port and no Route host**, unlike Podman's `http://…:18083/` |
| 2026-11-10 | laptop: `curl https://default--eng-analyst--agent.openshell.localhost/health` | `(7) Couldn't connect` — nothing listens on `127.0.0.1:443`; the literal service URL is not laptop-reachable |
| 2026-11-10 | laptop: `curl -H 'Host: default--eng-analyst--agent.openshell.localhost' https://zt2-gateway.apps.rosa.cwy7f-af7e-xo9.4di1.p3.openshiftapps.com/health` | `412` — TLS-passthrough Route selected by SNI, then the gateway routes on the `Host` authority. The authority-routing form reaches the gateway; a live backend was not available to confirm the final hop |
| 2026-11-10 | pod in `zt2-sandboxes`: `curl http://openshell.openshell.svc.cluster.local:8080/`; `curl -k https://…:8080/health` | plain HTTP → `connection reset by peer`; HTTPS → `404`. The gateway Service on 8080 is **TLS-only**, so `A2A_HOST=openshell.openshell.svc.cluster.local` + `A2A_PORT=8080` with an `http://` peer URL is wrong twice: wrong scheme and wrong authority (the gateway routes by service authority, not by the Service DNS name) |
| 2026-11-10 | create sandbox B with `DOCSCLAW_IMAGE` default, `service expose`, `docsclaw serve` | **blocked**: `default--eng-analyst` stuck `Init:ImagePullBackOff`. `ghcr.io/redhat-et/docsclaw:0.16.0-SNAPSHOT-49026ef-openshell-amd64` → `manifest unknown`; the registry now lists only `0.16.0-amd64`/`arm64` (no `-openshell-*` tags). The cached image exists only in the local Podman machine, which the cluster cannot pull from |
| 2026-11-10 | after the failed pull, `openshell sandbox exec` | `connect error: transport error` / empty stdout — the gateway relay degraded; requires a gateway restart before further A2A work |

**B3-A9 status: OPEN — blocked, not passed.** Scenarios 11, 12 and 15 could not run because no cluster-reachable DocsClaw image exists, and the full A2A spike stopped at the first hop because B could not start `docsclaw serve`. Scenarios 13 and 14 (host/laptop paths) were not run for the same reason. The exposure-URL and gateway-listener findings above are the spike's concrete output; the working A→B form is not yet proven.

<!-- markdownlint-enable MD013 -->
