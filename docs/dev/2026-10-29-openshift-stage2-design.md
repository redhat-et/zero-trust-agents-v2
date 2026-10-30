# Stage 2: OpenShift deployment — design

Date: 2026-10-29
Status: draft
Target environment: ROSA, OpenShift 4.22

## Intent

Prove that the v2 zero-trust token flow (cryptographic permission
intersection at token-mint time, SPIFFE-bound agent identity) runs
unchanged on OpenShift — the environment Red Hat customers actually
run in production. Stage 1 (Podman) remains the zero-preparation path
customers can try themselves; Stage 2 is the production-representative
reference. The deployment must be a real-world recommendation, not a
demo shortcut: every mechanism used must be a documented, supported
feature of OpenShell, SPIFFE/SPIRE, or OpenShift.

## Goals

- All six demo scenarios pass on a ROSA 4.22 cluster, driven from the
  author's laptop via the `openshell` CLI.
- Agent identity is per-sandbox SPIFFE SVID, minted via Kubernetes
  workload attestation — no manual SPIRE registration entries.
- The deployment uses official Helm charts and documented extension
  points only; nothing is invented or guessed.
- Side-by-side with Stage 1: `deploy/podman/` is untouched;
  `deploy/openshift/` is added.

## Non-goals

- Reproducible cluster provisioning (temporary-cluster tooling). A
  separate task; this design assumes a running ROSA 4.22 cluster and
  an `oc` context.
- Changes to the Podman deployment or to the token flow itself.
- Real IdP integration (Keycloak or otherwise) — see
  [Human identity](#human-identity).
- Multi-replica HA of any demo component.

## Background

Stage 1 runs everything on one host under Podman: SPIRE
server/agent/OIDC provider with hand-registered entries, the OpenShell
gateway as a container with the Podman compute driver, and the Go
token issuer and per-department document services. The supervisor
fetches the sandbox's JWT-SVID from the local SPIRE Workload API
socket and the gateway performs RFC 8693 exchanges against the issuer.

Key upstream facts verified during design (OpenShell v0.1.6 docs and
the NVIDIA/OpenShell repository):

- OpenShell has a Kubernetes compute driver. Sandboxes are paired
  supervisor + workload pods created via the Agent Sandbox SIG CRD
  (`sandboxes.agents.x-k8s.io`); a NetworkPolicy restricts workload
  ingress to the supervisor, and the supervisor brokers all egress.
- OpenShift support is documented: no privileged SCC, Restricted
  Pod Security Standard, UID ranges from namespace SCC annotations,
  `openshiftRoute` ingress option, requires OpenShift 4.19+ (Landlock).
- NVIDIA maintains `examples/spiffe-token-exchange-demo` — a
  Kubernetes reference for exactly v2's flow — and its CI deploys
  SPIRE via the SPIFFE `helm-charts-hardened` charts
  (`spire` v0.29.0, `spire-crds` v0.5.0).
- Per-sandbox SVIDs come from a `ClusterSPIFFEID` template keyed on
  the pod annotation `openshell.ai/sandbox-id`, producing
  `spiffe://<trust-domain>/openshell/sandbox/<sandbox-id>`.
- The Workload API socket reaches sandbox pods via the SPIFFE CSI
  driver (`csi.spiffe.io`), configured in the OpenShell Kubernetes
  driver by `provider_spiffe_workload_api_socket_path`.
- The issuer verifies JWT-SVIDs against SPIRE JWKS published by the
  in-cluster OIDC discovery provider (upstream uses a `spiffe-helper`
  sidecar to place the trust bundle).

## Architecture

Four layers on ROSA 4.22, in four namespaces:

```text
spire           SPIRE server, agents, controller-manager,
                CSI driver, OIDC discovery provider
openshell       OpenShell gateway (Helm chart, k8s compute driver),
                Agent Sandbox controller — no sandboxes here
zt2-sandboxes   sandbox pods (supervisor + workload), created by the
                Agent Sandbox controller via server.sandboxNamespace
zt-demo         token issuer, per-department document services
```

Sandboxes get their own namespace deliberately: the gateway's
`ClusterSPIFFEID` is namespace-scoped to `openshell`, and the issuer's
gateway check is a prefix match on
`spiffe://openshell.local/ns/openshell/sa/`. If sandbox pods shared the
`openshell` namespace, every one of them would also receive an SVID
under the gateway prefix — any sandbox holding a user subject token
could perform the gateway's first exchange and mint an intermediate
token for an arbitrary supervisor audience, while every scenario still
passed. One namespace per trust tier is what makes the chart's default
SA-based template safe.

### SPIRE

Deploy with the SPIFFE `helm-charts-hardened` charts, following
OpenShell's `ci/values-spire-stack.yaml` as the reference values:

- `spire-crds` v0.5.0, then `spire` v0.29.0, in namespace `spire`.
- Server: single replica (demo). Controller-manager enabled.
- Agents: Kubernetes workload attestor (PSAT), socket exposed via the
  SPIFFE CSI driver.
- A `ClusterSPIFFEID` (`openshell-sandboxes`) with:

  ```yaml
  spiffeIDTemplate: >-
    spiffe://{{ .TrustDomain }}/openshell/sandbox/
    {{ index .PodMeta.Annotations "openshell.ai/sandbox-id" }}
  ```

  namespace selector `zt2-sandboxes`, pod selector
  `openshell.ai/managed-by: openshell` (as in upstream CI values,
  with the namespace changed per the trust-tier separation above).
- Gateway identity: in the upstream Kubernetes example the gateway's
  SVID is ServiceAccount-based,
  `spiffe://<trust-domain>/ns/openshell/sa/<service-account>` — the
  issuer's `GATEWAY_TRUST_DOMAIN_PREFIX` validates exactly that
  prefix. Provide it via the hardened chart's default
  ServiceAccount-scoped `ClusterSPIFFEID` (or an explicit one with
  `spiffeIDTemplate:
  spiffe://{{ .TrustDomain }}/ns/{{ .Namespace }}/sa/{{ .ServiceAccount }}`
  scoped to the `openshell` namespace) and set
  `GATEWAY_TRUST_DOMAIN_PREFIX=spiffe://openshell.local/ns/openshell/sa/`
  on the issuer. No manual registration for either identity.
  The gateway SPIFFE ID is hardcoded in `scripts/scenario2.sh` and
  `scripts/scenario6.sh`; both must read it from the harness instead
  (see [Scenario harness](#scenario-harness-and-execution-model)).

- OIDC discovery provider enabled; the issuer fetches JWKS over
  HTTP from its in-cluster Service (hardened chart default:
  `spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local`,
  exact name/port confirmed from the rendered chart at
  implementation). Stage 1's issuer already fetches JWKS over HTTP
  (`SPIRE_JWKS_URI`), so no `spiffe-helper` sidecar or trust-bundle
  file is needed — the upstream sidecar pattern applies only to
  workloads that cannot do HTTP discovery.
- Trust domain: `openshell.local`, unchanged from Stage 1
  (`deploy/podman/spire/common.sh`). Changing it buys the demo nothing
  and would stack a second simultaneous delta on top of the gateway
  path change above, against SPIFFE IDs that appear as literal strings
  in the scenario scripts.

OpenShift specifics: the hardened chart is expected to run under the
restricted SCC with OpenShift-assigned UIDs; if any SPIRE service
account needs an SCC exception, grant the narrowest one and document
why (v1 needed `anyuid` for the older chart; the hardened chart is
claimed not to — verify on cluster and record the result).

### OpenShell gateway

- Install the Agent Sandbox controller/CRDs first (documented
  prerequisite), then the official OpenShell Helm chart
  (`oci://ghcr.io/nvidia/openshell/helm-chart`) into namespace
  `openshell`.
- `gatewayConfig` renders into `gateway.toml`:

  - compute driver: Kubernetes, sandboxes in the `zt2-sandboxes`
    namespace (`server.sandboxNamespace`).
  - `provider_spiffe_workload_api_socket_path:
    /spiffe-workload-api/spire-agent.sock` (from upstream
    `ci/values-spire.yaml`).
  - JWT signing enabled for the gateway (needed for the extension
    token flow and health probes; secrets in Kubernetes Secrets, not
    chart values).

- Exposure: the chart's `openshiftRoute` option (TLS passthrough
  Route). The laptop CLI registers the gateway with
  `openshell gateway add https://<route-host>`.
- Per the OpenShift docs: null out `podSecurityContext.fsGroup` and
  `securityContext.runAsUser` so SCC admission assigns UID ranges.

### v2 services

- Token issuer: one Deployment + two Services. **Naming is a hard
  constraint, not a preference**: the Service must be `token-issuer`
  in namespace `zt-demo` on port 8080, because the profile templates
  already hardcode `http://token-issuer.zt-demo.svc:8080` as both
  `token_endpoint` and `jwt_svid_audience`. Honour it and those two
  fields need no substitution at all on OpenShift — Stage 1's `.svc`
  alias was chosen to be real in-cluster DNS.
- `JWT_SVID_AUDIENCE` must match the audience the supervisors request.
  The deployment value is `http://token-issuer.zt-demo.svc:8080`, but
  the code default in `internal/config/config.go` is the port-less
  `http://token-issuer.zt-demo.svc`; a mismatch 401s every exchange,
  so the setup script sets it explicitly rather than inheriting it.
- The unauthenticated `/demo-subject-token` minter stays on its own
  listener (`:8090` in the image) with **no Service at all** —
  `oc port-forward deploy/token-issuer` targets the pod directly. A
  ClusterIP Service, combined with the `zt-demo` ingress allow rule,
  would make "mint a token as any user" reachable from every sandbox
  pod; Stage 1 published it loopback-only and Stage 2 must not be
  weaker — see [Scenario harness](#scenario-harness-and-execution-model).
- Document services: one Deployment + Service for **each of the five
  departments** — engineering, finance, admin, hr, public — matching
  `DOC_DEPTS` in `deploy/podman/scripts/start-services.sh`. Two is not
  enough: scenario 6 replays an engineering-scoped token against the
  **finance** service (DOC-005), and scenario 3 health-checks
  engineering directly.
- NetworkPolicy on `zt-demo`: default-deny ingress plus an allow rule
  for the `zt2-sandboxes` namespace (where supervisor pods connect
  from). Leaving `zt-demo` default-allow in a zero-trust demo undercuts
  the thesis, and the policy is a few lines. Production recommendations
  then narrow it from namespace-wide to supervisor pods.
- Images: built from the existing `deploy/podman/Containerfile.*`
  (no new Dockerfiles) for linux/amd64 on the RHEL 10 homelab host
  via `podman --remote --connection rhel`, pushed to quay.io
  (namespace proposed: `panni/zt2` — override at implementation).
  ROSA pulls them with a pull secret if the repos are private.
- Secrets: `ACCESS_TOKEN_SECRET`, per-user subject tokens, and any
  gateway credentials are Kubernetes Secrets created by the setup
  script; never chart values or ConfigMaps.

### Provider profiles and token flow

The flow is identical to Stage 1; only hostnames change:

- The four profiles (`deploy/podman/profiles/*.yaml.in`) are reused
  with `@DOC_HOST@` resolving to in-cluster service DNS (for example
  `document-engineering.zt-demo.svc`) and `@DOC_PORT@` to 8080
  (upstream deliberately omits `allowed_ips` on Kubernetes because
  service CIDRs vary). `@ALLOWED_IPS@` sits on its own line inside the
  `endpoints:` list, so the OpenShift substitution must **delete the
  line**, not replace it with an empty string.
- `token_grant` blocks are unchanged: jwt-spiffe client assertion,
  RFC 8693 token exchange at `http://token-issuer.zt-demo.svc:8080/token`,
  subject token stored gateway-side.
- The intermediate token audience remains the requesting sandbox's
  SPIFFE ID (`spiffe://openshell.local/openshell/sandbox/<id>`), which
  is also unchanged from Stage 1's
  `SUPERVISOR_TRUST_DOMAIN_PREFIX`; the departments ∩ capabilities
  intersection at the issuer is untouched.

### Human identity

Stage 2 deliberately does not deploy an IdP. The issuer's
`/demo-subject-token` endpoint stands in for "your IdP": the subject
token is an OAuth2 access token presented at the RFC 8693 exchange,
so any customer IdP (Keycloak, Entra ID, Okta, ...) plugs in at that
boundary. The docs call this out explicitly with the swap point on
the architecture diagram. What a real integration adds —
customer-JWKS verification of RS256/ES256 subject tokens — is a
documented extension point, not demo scope. The issuer already
demonstrates real JWKS verification on the agent-identity side
(SPIRE), so the demo does not hide the difference.

### Scenario harness and execution model

The scenario scripts are **not** portable as written. `scripts/lib.sh`
is both the scenario harness and, implicitly, the compute-driver
abstraction — and it currently has exactly one driver hardwired into
it. Stage 2's real work is giving it a second one, selected by
`ZT2_DRIVER=podman|openshift` so Stage 1 keeps working byte-identically.

| `lib.sh` concern | Podman driver (today) | OpenShift driver |
| --- | --- | --- |
| Gateway endpoint | `http://127.0.0.1:18083`, hardcoded | `https://<route>` from setup state |
| Sandbox cleanup | `podman ps … \| xargs podman rm -f` | `oc delete`, or leave it to the Sandbox controller |
| `register_sandbox` | `deploy/podman/spire/register-sandbox.sh` | No-op; wait for the `ClusterSPIFFEID`-minted SVID |
| `fetch_svid` | `podman run spire-agent` on the host socket | Supervisor/rogue: helper pod + `oc exec`; gateway: `oc debug` ephemeral container on the gateway pod |
| Doc service URLs | `nip.io` host, ports 18101-18105 | `oc port-forward`, or in-cluster `.svc` names |
| `ISSUER_LOCAL` | `http://127.0.0.1:8080` | `oc port-forward` to the issuer Service |

Two decisions drive the rest:

- **Subject-token minter: `oc port-forward`, never a Route.**
  `start-services.sh` deliberately publishes the `/demo-subject-token`
  listener on loopback only, so the network-reachable port cannot carry
  the token minter. A ROSA Route is internet-facing, so routing `:8090`
  would publish "mint a token as any user" to the public internet for
  the cluster's lifetime. `setup.sh` instead backgrounds a port-forward
  and writes `TOKEN_ISSUER_DEMO_HOST_PORT` into the state file exactly
  as Stage 1 does, leaving `DEMO_SUBJECT_URL` untouched. `teardown.sh`
  kills it.
- **Out-of-band SVIDs: helper pod + `oc exec`, except the gateway.**
  Scenarios 2, 5 and 6 need a JWT-SVID fetched by a process SPIRE will
  attribute to a given identity. On Podman that is a labelled throwaway
  container; on Kubernetes it is a short-lived pod in `zt2-sandboxes`
  carrying the `openshell.ai/sandbox-id` annotation the
  `ClusterSPIFFEID` keys on, with the CSI-mounted Workload API socket,
  driven by `oc exec -- spire-agent api fetch jwt`. The Podman
  version's warning does not apply here: there is no container watcher
  to confuse, so the helper pod cannot delete the real sandbox out from
  under the test. The gateway SVID is different: no selector-based
  helper can be allowed to mint it (that is the impersonation the
  namespace separation exists to prevent), so scenarios 2 and 6 fetch it
  with `oc debug` attaching an ephemeral `spire-agent` container to the
  real gateway pod, sharing its CSI-mounted Workload API socket.

Scenario 5 gets *better* in the port. A rogue identity on Kubernetes is
a pod the `ClusterSPIFFEID` deliberately does not match — a more
convincing demonstration than Podman's `--label zt2.rogue=true`, and
one that shows attestation policy doing the work.

Running order on the laptop:

1. `oc` authenticated to the ROSA cluster.
1. `deploy/openshift/setup.sh` — installs charts, applies manifests,
   substitutes profile hosts, starts port-forwards, writes state.
1. `openshell gateway add https://<route>` (or re-select an existing
   registration).
1. `ZT2_DRIVER=openshift scripts/scenario*.sh`.

## Deliverables

- `deploy/openshift/` (matching the Goals section; `deploy/podman/`
  stays untouched):
  - SPIRE Helm values (hardened charts).
  - OpenShell chart values + any patches.
  - Manifests for the zt-demo namespace: issuer Deployment + its two
    Services, five document-service Deployments + Services, the
    `zt-demo` NetworkPolicy, and Secrets templates.
  - `setup.sh` / `teardown.sh` (`oc` + `helm` based), mirroring the
    Podman scripts' structure and self-healing behavior, including
    port-forward lifecycle.
  - `build-images.sh` using `podman --remote --connection rhel`,
    linux/amd64, push to quay.io.
  - The SVID helper-pod manifest used by the OpenShift `fetch_svid`.
- `scripts/lib.sh` refactored behind `ZT2_DRIVER`, with the Podman
  path unchanged in behavior. This is a Stage 2 deliverable in its own
  right, not a side effect of the manifests — see
  [Scenario harness](#scenario-harness-and-execution-model).
- Profile templates parameterized for the OpenShift hostnames.
- Docs updated in the same PR: `docs/ARCHITECTURE.md` (OpenShift
  section), `docs/DEMO_SCENARIOS.md` (how to run on OpenShift),
  README pointer.
- A short "recommendations for production" note covering: trust
  domain choice, secret handling, IdP swap point, and any SCC
  exceptions actually required.

## Constraints and risks

- Temporary ROSA clusters live ≤ 8 hours: setup must be idempotent
  and re-runnable; images live in quay.io, not the cluster registry.
- The 8-hour TTL means SPIRE's trust bundle and gateway signing keys
  are ephemeral — acceptable for the demo; documented as a difference
  from production (where keys are persisted and rotated).
- OpenShift 4.22 + OVN-Kubernetes enforces NetworkPolicy (a
  documented OpenShell requirement); Landlock requires 4.19+ — both
  satisfied.
- Setup wall-clock is itself a risk against the 8-hour TTL: SPIRE
  charts, Agent Sandbox CRDs, the OpenShell chart and image pulls all
  precede the first scenario. Target: empty cluster to passing
  scenario 1 in under 15 minutes. If the real figure is much worse,
  the demo is not usable and that is a finding worth recording.
- Private quay.io repos need a pull secret in both `openshell` and
  `zt-demo`; `setup.sh` checks for it up front rather than letting
  pods sit in `ImagePullBackOff`.
- Verification items for implementation (do not assume; check on
  cluster): hardened-chart SCC behavior on OpenShift, Route TLS
  passthrough with the gateway's TLS mode, and whether the workload
  pod (not only the supervisor) can be given the SVID role. Any
  deviation from upstream defaults gets recorded in the production
  recommendations note.

## Open items

None blocking design approval. Implementation-time decisions (quay
namespace, exact chart version pins) are flagged in
[Deliverables](#deliverables) and
[Constraints and risks](#constraints-and-risks).

Resolved during review on 2026-10-29:

| Question | Resolution |
| --- | --- |
| Trust domain | Keep `openshell.local`; minimize the Stage 1 → Stage 2 delta |
| Deploy directory | `deploy/openshift/` |
| Document services | All five departments, not two — scenario 6 needs finance |
| `zt-demo` NetworkPolicy | Default-deny + allow `openshell`, in demo scope |
| Subject-token minter | `oc port-forward`, never a Route |
| Out-of-band SVID fetch | Supervisor/rogue: helper pod in `zt2-sandboxes` + `oc exec`; gateway: `oc debug` on the gateway pod |
| Scenario portability | `ZT2_DRIVER` seam in `scripts/lib.sh` |
| Sandbox namespace | `zt2-sandboxes`, separate from the gateway — keeps the gateway `ClusterSPIFFEID` (and its prefix-checked trust) from matching sandbox pods |
| Issuer/document env | `SPIRE_ISSUER` (JWKS `iss` check) and `ACCESS_TOKEN_ISSUER` (document-service `iss` check) set explicitly on both Deployments; code defaults carry Podman aliases |
