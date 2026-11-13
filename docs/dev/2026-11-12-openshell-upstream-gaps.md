# OpenShell gaps blocking in-cluster A2A

**Date:** 2026-11-12 (updated after the 0.1.8 upgrade)
**Demo:** 2026-11-13 (OpenShift north–south, Podman east–west)

Scenarios 11 and 15 do not run on the OpenShift driver. Both blockers
turned out to be **fixed upstream already**, in releases we were not
using. This document records what the gaps were, what fixes them, and
what genuinely remains open.

## Version matrix

| Item | Version |
| ---- | ------- |
| Deployed demo before 2026-11-12 | OpenShell 0.1.6, `helm-chart-0.1.6` |
| Deployed demo after 2026-11-12 | OpenShell 0.1.8, `helm-chart-0.1.8` |
| Local clone `~/work/repos/OpenShell` | `v0.1.9-pre.2` |
| Local CLI | 0.1.8 (Homebrew tap still publishes 0.1.6) |
| First release with the supervisor app listener | v0.1.7 (`#4936`) |
| First release with additional destination CAs | v0.1.7 (`#3292`) |

The lesson: two gaps were reported as "upstream is missing this", and
both had shipped one minor release earlier.

## Gap 1 — trust for a private upstream CA (fixed in 0.1.7+)

### Symptom seen on 0.1.6

The supervisor terminates TLS on egress and re-originates it upstream.
Against the gateway's chart certificate it logged `ALLOWED … engine:opa`
followed by `NET:FAIL`, and the client saw `SSL_ERROR_SYSCALL`.

### Cause on 0.1.6

`crates/openshell-supervisor-network/src/l7/tls.rs` built the upstream
trust store from `webpki_roots` plus `read_system_ca_bundle()`, which
reads a hardcoded path list. `NetworkTlsMode` accepted only `skip`,
`terminate`, `passthrough`. There was no way to add a CA.

### Fix

`#3292 feat(network): support additional destination CAs` (merged, in
v0.1.7 and later). The chart exposes:

```yaml
supervisor:
  network:
    additionalCaConfigMapName: <name of an operator-owned ConfigMap>
```

The chart mounts that ConfigMap's `ca.crt` into the gateway at
`/etc/openshell-tls/additional-ca-source/ca.crt` and renders
`[openshell.supervisor.network] additional_ca_bundle = "…"`, which the
gateway passes to supervisors (`openshell-supervisor/src/lib.rs`,
`additional_ca_bundle`). Empty value disables it.

This is cluster-wide, not per-endpoint. For our demo that is the right
granularity: every supervisor should trust the deployment's own CA.

### Remaining refinement (optional, possibly not worth an issue)

A per-endpoint `ca_cert_pem` on `NetworkEndpoint.tls` would be more
precise than a cluster-wide bundle, and `SupervisorMiddlewareService`
already carries `tls_ca_cert_pem`, so the plumbing exists. Only raise
this if the cluster-wide bundle proves insufficient.

## Gap 2 — ingress for sandbox apps (being rebuilt upstream)

### What we tried, and why it failed

`spec.service: true` publishes a controller-owned headless Service, but
it is the **boundary** endpoint: `sandbox-control`, port 5500,
selecting the workload pod. The app port is bound inside the sandbox's
isolated network namespace, so the pod's own IP refuses `:8000` even
from inside the pod. A NetworkPolicy cannot help.

`supervisor.sandboxRuntime.boundaryPort: 5500` is a chart value, so this
is by design, not a defect.

### What upstream provides

- **Issue #4310 "Sandbox Service Exposure"** — working group, lead
  `@TaylorMutch`.
- **RFC 0017** (`rfc/0017-sandbox-service-exposure`), state: draft,
  authors `@drew`, `@TaylorMutch`.
- The **supervisor app listener** (`#4936`, `#4940`, v0.1.7+) is opt-in
  application ingress "separate from the gateway control transport". It
  resolves service hostnames and forwards HTTP/WebSocket traffic to the
  right sandbox.
- Chart configuration: `openshell.supervisor.app_listener` and
  `openshell.drivers.kubernetes.sandbox_runtime.app_listener`
  (`{enabled, port, domain, tls_secret_name}`). It requires TLS.
- External routes are owned by ingress integrations, not the compute
  driver. Reference implementation: `openshell-sandbox-proxy`; Gateway
  API evaluation: `#5075`.

The native headless Service is therefore the wrong mechanism, and no
issue should be filed about it.

## What actually remains open

**Routing and peer identity, not TLS trust.** With gap 1 fixed, trust is
solved; what remains is how one sandbox addresses another:

- The provider profile schema has no Host-header override, so a sandbox
  client cannot send the gateway's exposed authority
  (`*.openshell.localhost`) to the gateway's Service IP.
- `.openshell.localhost` authorities do not resolve from inside a
  sandbox; the supervisor forwards them upstream and gets NXDOMAIN.

The app listener plus an operator-controlled domain (Gateway API or a
Route) addresses exactly this: the peer gets a resolvable hostname, its
own TLS certificate, and a listener that routes by host.

## Existing issues, and what they cover

| Issue | State | Relation |
| ----- | ----- | -------- |
| #3292 additional destination CAs | merged | **fixes gap 1** (v0.1.7+) |
| #4310 Sandbox Service Exposure | roadmap, accepted | gap 2 umbrella |
| #4936/#4940 app listener | merged | **fixes gap 2 mechanism** (v0.1.7+) |
| #4953, #4667, #4669, #4670, #4722, #4954 | accepted | service-exposure work items |
| #5075 Gateway API config for the app listener | accepted | the ingress integration we need |
| #2455 Cloudflare upstreams have no working TLS mode | open | adjacent; fingerprint under termination, not trust |
| #2788 sandbox-to-upstream mTLS | stale | client certificates, not server CA |

## Operational notes on 0.1.8

- **Credential propagation is asynchronous.** A supervisor created moments
  before its first inspected request can fail the token grant and return
  `502` with an empty body, then succeed seconds later. The supervisor
  caches the failed grant. `scripts/scenario15.sh` retries on `502`
  (12 attempts, 5 s apart) rather than asserting on the first response;
  a persistent `502` still fails.
- **`scripts/setup.sh` is not idempotent against an existing gateway.**
  Profile import rejects duplicates, and the Podman gateway keeps its
  store in `.zt2-state/gateway/gateway.db`, which `scripts/teardown.sh`
  does not remove. Reset that file (or reinstall) before re-running
  setup, otherwise step 4 fails with `profile 'docsclaw-model' already
  exists`.
- **The CLI name `zt2` is ambiguous.** Stored CLI metadata points at
  whichever gateway registered last, which was the OpenShift Route. All
  scripts pass `--gateway-endpoint` explicitly; ad-hoc `openshell`
  commands must too, or they will act on the other driver's gateway.

## Experiments on OpenShell 0.1.8 (2026-11-12)

### Scenario 11 with the native Service

Captured deliberately as a negative result. A's supervisor resolves and
dials the published address, then times out at the HTTP layer:

```text
peer published as default--eng-analyst.zt2-sandboxes.svc.cluster.local:8000
← a2a_call error: … Post "http://default--eng-analyst.…:8000/": context deadline exceeded
```

The Service advertises port 5500 (the boundary port) and selects the
workload pod, whose app port is not reachable on the pod IP at all. No
policy or token decision is involved — the request has nowhere to land.

### Supervisor app listener

Enabled with our own CA and certificate:

- `supervisor.app_listener{enabled,port:9443,domain:zt2-sandboxes.svc.cluster.local}`
  and `sandbox_runtime.app_listener.tls_secret_name` render correctly and
  reach the supervisor pod as `OPENSHELL_APP_LISTENER_ENABLED=true`.
- The listener starts, presents the operator certificate, and completes a
  TLS handshake.
- It then refuses the request because no route is installed:

```text
OCSF NET:OPEN [MED] DENIED unknown [reason:App listener unknown or expired SNI route]
```

So the data plane exists and TLS trust works end to end. What is missing
is **route discovery**: the listener dispatches on SNI
(`<prefix>[--<service>].<domain>`, parsed in
`openshell-supervisor/src/app_listener.rs`), and nothing advertises a
route for a sandbox in this topology. The chart's own fixture says it
"does not deploy discovery or a proxy" and sets
`supervisor_topology: gateway`.

That is the concrete remaining work: service-route discovery
(`#4667`, `#4953`) plus the ingress and DNS that make a peer addressable
(`#5075`). It is a wiring gap, not a security gap — the allowlist and
token checks were never reached in either experiment.

Both experiments were reverted; the cluster matches what `setup.sh`
produces.

## Recommended actions

1. **Done:** upgrade the OpenShift deployment to 0.1.8 and the CLI to
   0.1.8.
2. Wire the CA: create a ConfigMap in the gateway namespace containing
   the gateway CA as `ca.crt`, then set
   `supervisor.network.additionalCaConfigMapName` and let the chart roll
   the gateway. Prove delivery by checking the rendered `gateway.toml`
   and the supervisor's startup log.
3. Upgrade the Podman driver to 0.1.8 for version parity, then re-run
   scenarios 11 and 15 there.
4. Evaluate the app listener with a Gateway API (or Route) ingress for
   cross-sandbox A2A. This is where the remaining routing work lives.
5. Only then consider an upstream issue — most likely about peer
   addressing/identity, not TLS.

## Draft comment for #4310 / RFC 0017

> We run OpenShell on OpenShift (ROSA 4.22) for agent-to-agent calls
> between sandboxes. Both agents hold SPIFFE identities and the call
> carries a minted, audience-bound token; the receiving agent checks the
> token and a caller allowlist. It works on the Podman driver, where a
> host relay publishes the peer.
>
> We tried `spec.service: true` on Kubernetes and found it publishes the
> boundary port (`sandbox-control:5500`), with the app port unreachable
> from the pod IP. That matched the controller's intent once we read
> `sandbox_runtime.boundary_port`, so we moved on.
>
> For the app listener, two questions:
>
> 1. With `supervisor.network.additionalCaConfigMapName` we can make
>    supervisors trust our own CA. Is that the intended way to reach a
>    peer listener that has no publicly trusted certificate?
> 2. For OpenShift, is the intended integration a Gateway API listener
>    (#5075), a Route, or operator-managed ingress in front of the
>    listener? We are happy to test whichever is furthest along and
>    report back.

## What to tell the customer

East-west A2A runs today on the Podman driver. On Kubernetes the pieces
shipped upstream in v0.1.7 — an app listener and operator-supplied
destination CAs — and we upgraded to 0.1.8 to use them. What remains is
wiring an ingress (Gateway API) so one sandbox has a resolvable,
certificate-bearing address for another. The security model is unchanged
on both drivers: SPIFFE identity, the minted scoped token, the caller
allowlist.
