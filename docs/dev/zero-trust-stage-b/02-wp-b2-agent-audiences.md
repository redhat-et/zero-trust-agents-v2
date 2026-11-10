# WP-B2: agent audiences in the issuer

**Plan reference:** §B.2 of the
[integration plan](../2026-11-06-zt2-docsclaw-integration-plan.md).
**Status:** implemented on `feature/stage-b2-agent-audiences` (stacked
on B1); Podman evidence recorded below, OpenShift run pending.
**Branch:** `feature/stage-b2-agent-audiences`.

## Scope

Deliver §B.2 as one PR: accept agent audiences in the supervisor
exchange alongside the five department audiences, with the scopes each
agent requires coming from configuration. No claim changes and no
DocsClaw changes.

Non-goals: narrowing the minted scope (see the review question in the
[index](00-index.md#review-questions-for-this-split)), per-agent
authorization policy, agent discovery, profile wiring (B3).

## Decisions pinned

1. **Configuration file.** New `config/agents.yaml`:

   ```yaml
   agents:
     - audience: engineering-analyst
       scopes: [engineering]
     - audience: hr-analyst
       scopes: [hr]
   ```

   `hr-analyst` is included because §B.5 needs it for the negative
   scenarios; leaving it out would make B3 invent a second mechanism.
1. **Delivery.** The file is baked into the issuer image at
   `/config/agents.yaml`, the same way `users.yaml` is baked, and
   `AGENTS_FILE` defaults to `/config/agents.yaml`. There is no
   ConfigMap and no volume.
1. **Departments stay hardcoded.** The five department audiences keep
   their current behavior; configuration adds audiences, it does not
   replace them.
1. **Audience lookup.** Replace the `supportedAudiences` map with a
   method that answers two questions: is this audience supported, and
   which scopes does it require? Department audiences return their own
   name as the required scope; `public` returns none.
1. **Intersection rule unchanged.** The minted scope remains
   `user.departments ∩ requested scope` (§B.2). The agent's configured
   scopes are the minimum capability the audience requires: the
   exchange succeeds only when the intersection contains at least one
   of them. Nothing is removed from the minted scope.
1. **No new claims.** `azp` and `client_id` remain the supervisor SVID;
   `aud` becomes `[<agent audience>, "account"]`, which `HasAudience`
   already handles as a list.
1. **Error codes unchanged.** An unknown audience is still
   `400 unsupported_audience`; an empty or insufficient intersection is
   still `403 insufficient_department_permissions`.

## Interfaces consumed by later packages

- The issuer accepts `audience=engineering-analyst` with
  `scope=engineering` and mints `scope=engineering`,
  `aud=[engineering-analyst, account]`.
- B3's profiles may therefore request the agent audience both as the
  grant `audience` and as an `audience_overrides` entry.

## Files to change

<!-- markdownlint-disable MD013 -->

| Path | Change |
| --- | --- |
| `config/agents.yaml` | New file with the two agent audiences |
| `internal/config/config.go` | Add `Agent` and `Agents`; load `AGENTS_FILE` |
| `internal/config/config_test.go` | Agent parsing and missing-file behavior |
| `token-issuer/server.go` | Audience/scope lookup; supervisor-exchange check |
| `token-issuer/final_test.go` | Accept/deny matrix for agent audiences |
| `deploy/podman/Containerfile.token-issuer` | Copy `config/agents.yaml` and set `AGENTS_FILE` |
| `deploy/podman/scripts/start-services.sh` | Set `AGENTS_FILE` (no mount needed if baked) |
| `deploy/openshift/zt-demo/token-issuer.yaml` | Set `AGENTS_FILE`; the image already carries the file |
| `docs/ARCHITECTURE.md` | Claim schema and capability model mention agent audiences |

<!-- markdownlint-enable MD013 -->

## Tasks

1. Add `config/agents.yaml` and the config loader. Verify:
   `go test ./internal/config/`.
1. Replace the audience map and add the intersection check. Verify:
   `go test ./token-issuer/`.
1. Wire `AGENTS_FILE` into both drivers and the image. Verify:
   `deploy/podman/scripts/build-images.sh` and
   `deploy/podman/scripts/start-services.sh`.
1. Mint an agent-audience token out of band and record the claims.
1. Update `docs/ARCHITECTURE.md` and run `markdownlint`.

## Acceptance tests and evidence

<!-- markdownlint-disable MD013 -->

| ID | Check | Command | Expected |
| --- | --- | --- | --- |
| B2-A1 | Go suite | `make lint test` | exit 0, no findings |
| B2-A2 | Alice × engineering-analyst | direct `/token` calls as in `scripts/scenario6.sh`, with `audience=engineering-analyst`, `scope=engineering` | 200; decoded final token has `scope=engineering` and `aud` containing `engineering-analyst` |
| B2-A3 | Wrong capability | same, with `scope=hr` | 403 `insufficient_department_permissions` |
| B2-A4 | Unknown audience | same, with `audience=marketing` | 400 `unsupported_audience` |
| B2-A5 | Department behavior | `scripts/scenario1.sh` … `scripts/scenario6.sh` | every script prints its PASS line |
| B2-A6 | OpenShift | `[cluster]` re-run B2-A2 with `ZT2_DRIVER=openshift` | same result |

<!-- markdownlint-enable MD013 -->

## Dependencies

- No code dependency. Run after B1 in practice, because the evidence
  commands use the ES256 issuer and its JWKS.
- Blocks B3: A's grant and override need the audience to exist.

## Risks and gotchas

- **Baked config means a rebuild.** `config/agents.yaml` never changes
  at runtime in the demo; if it ever does, baking is the wrong choice
  and a ConfigMap is the follow-up.
- **`public` remains special.** The existing "non-empty intersection"
  rule applies to every audience except `public`; keep that exception
  when the check moves into the new lookup.
- **Excess scopes are not clipped.** A user in engineering and finance
  who requests `scope=engineering finance` for `engineering-analyst`
  still receives both scopes. This matches department behavior; raise
  it in review if narrowing is preferred.

## Run log

<!-- markdownlint-disable MD013 -->

| Date | Command | Observed |
| --- | --- | --- | --- |
| 2026-11-09 | `make lint test`, `go test -race -count=1 ./...` | `0 issues`; all four packages `ok` |
| 2026-11-09 | alice → `engineering-analyst`, `scope=engineering` | `200`; `aud=["engineering-analyst","account"]`, `scope="engineering"`, `azp` = the supervisor SVID |
| 2026-11-09 | alice → `engineering-analyst`, `scope=hr` | `403 insufficient_department_permissions` (empty intersection) |
| 2026-11-09 | carol → `hr-analyst`, `scope=hr` | `200`; `aud=["hr-analyst","account"]`, `scope="hr"` |
| 2026-11-09 | carol → `engineering-analyst`, `scope=engineering` | `403 insufficient_department_permissions` |
| 2026-11-09 | `scripts/scenario1.sh` … `scripts/scenario6.sh` | all six print PASS |
| 2026-11-09 | PR #11 review fixes: `go test -race -count=1 ./...`, `make lint`, `scenario1..6` | collision test RED→green; `0 issues`; mint matrix unchanged (200/403/200/403); all six scenarios PASS; issuer logs `agent audiences loaded count=2` |
| — | OpenShift `B2-A6` | not run: no cluster in this session |

<!-- markdownlint-enable MD013 -->
