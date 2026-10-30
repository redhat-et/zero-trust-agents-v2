# Architecture

An educational demo of zero-trust identity for AI agent systems where
**the agent is an OpenShell sandbox**. Successor to
[zero-trust-agent-demo](https://github.com/redhat-et/zero-trust-agent-demo)
(v1): where v1 enforced permission intersection with OPA at request
time, v2 enforces the same property **cryptographically at
token-mint time**.

## Components

| Component | Directory | Role |
|---|---|---|
| Token issuer | `token-issuer/` | Go port of the upstream Node demo issuer, plus the departments∩capabilities intersection. Mints user subject tokens; performs the gateway (intermediate) and supervisor (final) RFC 8693 exchanges; verifies SPIFFE JWT-SVIDs against SPIRE's JWKS. |
| Document service | `document-service/` | Protected resource server, one instance per department. Validates audience + scope on the final token; serves the v1 sample documents. |
| SPIRE | `deploy/podman/spire/` | Workload identity: server, agent (Workload API socket), OIDC discovery provider (JWKS). Adapted from the upstream OpenShell podman demo. |
| OpenShell gateway | `deploy/podman/scripts/start-gateway.sh` | Runs as a container, holds per-user provider profiles with stored subject tokens, performs the intermediate exchange on behalf of sandboxes. |
| Provider profiles | `deploy/podman/profiles/` | One per user × capability. Capabilities are profile-configured, never sandbox-chosen. |
| Scenario scripts | `scripts/` | One per demo scenario; see `docs/DEMO_SCENARIOS.md`. |

## Token flow

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

1. The sandbox curls a document service. The supervisor intercepts the
   request (the sandbox's network is brokered; it has no direct egress).
1. The supervisor fetches the sandbox's SPIFFE JWT-SVID from the SPIRE
   agent's Workload API socket.
1. The supervisor asks the gateway for a token (dynamic token grant).
1. The gateway verifies its own SVID, then exchanges the stored user
   subject token at the issuer. The intermediate token's audience is the
   sandbox's SPIFFE ID — it is bound to exactly one supervisor.
1. The supervisor exchanges the intermediate for the final scoped
   access token. **This is where v2's permission intersection lives**:
   `user.departments ∩ requested scope` must be non-empty, and the
   minted scope is exactly the intersection. A rogue SPIFFE ID (not
   under the supervisor prefix) is rejected one step earlier, at SVID
   verification.
1. The supervisor injects the final token into the outbound request; the
   document service checks audience and scope.

## Token claim schema

All demo tokens are HS256 with a shared `ACCESS_TOKEN_SECRET`
(upstream demo pattern) and carry a `demo_token_use` discriminator:

| Token | demo_token_use | azp / client_id | aud | TTL |
|---|---|---|---|---|
| Subject | `user_subject` | — | openshell-gateway, account | 1800s |
| Intermediate | `intermediate` | gateway SPIFFE ID | supervisor SPIFFE ID | 300s |
| Final | `final` | supervisor SPIFFE ID | department, account | 300s |

The subject token additionally carries `departments` (from
`config/users.yaml`); the final token's `scope` is the intersection
result — never the requested list.

## Capability model

The provider profile — not the sandbox — decides what a sandbox may do:

- `audience` names the target service (from the endpoint's
  `audience_overrides`, matched on host:port);
- `scopes` names the sandbox's capability;
- the stored `subject_token` credential is the user's delegation.

"Launching a sandbox as Alice with engineering capability" means a
provider profile holding Alice's subject token with
`scopes: [engineering]`.

## Podman-machine networking notes (macOS)

Stage 1 runs on podman machine (libkrun). Three properties of that
environment shaped the deployment, all discovered the hard way:

- Supervisors share the VM's host network, so podman network aliases are
  unresolvable from their netns. The gateway's `grpc_endpoint` must be
  `host.containers.internal:<published port>`.
- Host-gateway names (`host.containers.internal`) are special-cased by
  the supervisor's policy DNS and fail closed for endpoint traffic, and
  RFC 1918 destinations require `allowed_ips`. Document services are
  published on host ports 18101-18105 and declared as
  `192.168.127.254.nip.io` endpoints with
  `allowed_ips: [192.168.127.254]`.
- Plain-HTTP token endpoints pass OpenShell profile lint only for
  loopback or `*.svc`-shaped hosts. The issuer keeps the alias
  `token-issuer.zt-demo.svc` (resolvable by the gateway on the podman
  network) plus a VM `/etc/hosts` entry mapping it to
  `host.containers.internal` — a hosts entry upstream's README
  explicitly sanctions for host-running components.

## Linux host networking notes (Fedora/RHEL)

On a Linux host the same components run without the podman-machine VM,
and the macOS workarounds collapse (`ZT2_HOST_OS` selects the layout):

- The supervisor's host network is the real host network, so the
  gateway is advertised at its loopback publish
  (`http://127.0.0.1:18083`).
- The layout mirrors macOS structurally: supervisors run
  `network=host` and resolve endpoints through the host's resolver, so
  document services stay on published host ports 18101-18105, declared
  as `<host-ip>.nip.io` endpoints with `allowed_ips: [<host-ip>]` (the
  supervisor resolves `host.containers.internal` to the host's LAN
  address, not a link-local one, and denies undeclared RFC 1918
  destinations). The host IP is detected at setup time, and the
  publishes bind all interfaces so the LAN address reaches them.
- The `.svc` lint rule is platform-independent, so the issuer keeps the
  `token-issuer.zt-demo.svc` alias plus a host `/etc/hosts` entry
  mapping it to the host's LAN IP (added with sudo by `setup.sh`). The
  issuer's authenticated `/token` port publishes on loopback and the
  LAN address, but its unauthenticated demo-subject-token minter runs
  on a second listener (`:8090`) published loopback only, so the LAN
  publication cannot be used to mint subject tokens remotely. The hosts entry matters for
  the gateway too: aardvark forwards unknown names to the host's
  resolver, so an entry pointing at 127.0.0.1 would make containers
  resolve the issuer to their own loopback.

Two Linux-only pitfalls found the hard way (both fixed in the scripts):

- `podman run --label k:v` stores the whole string as a label *key*
  with an empty value — label arguments must use `k=v`. The scenario
  scripts' out-of-band SVID fetches pass labels this way.
- The gateway's container watcher treats any container carrying a
  sandbox's labels as that sandbox: a short-lived probe container with
  those labels gets the real sandbox deleted when the probe exits.
  `fetch_svid` therefore only runs after a sandbox's last use.

Provider profiles are templates (`deploy/podman/profiles/*.yaml.in`)
rendered per host OS into the state dir at setup time; the same
services, SPIRE wiring, and scenario scripts run unchanged.

## OpenShift deployment (Stage 2)

The same architecture runs on ROSA/OpenShift 4.19+ via
`deploy/openshift/` — the production-representative reference. The
scenario harness selects the backend with `ZT2_DRIVER=podman|openshift`
(`scripts/drivers/`), so the six scenarios are unchanged.

| Concern | Podman (Stage 1) | OpenShift (Stage 2) |
|---|---|---|
| SPIRE | server/agent/OIDC containers, manual registration entries | SPIFFE hardened charts, `ClusterSPIFFEID` workload attestation |
| Sandbox identity | label-selected SPIRE entries | one SVID per sandbox pod (`openshell.ai/sandbox-id` annotation) |
| Gateway identity | label-selected entry | SA-based SVID, pod-selector-tightened |
| Gateway | Podman container, loopback | OpenShell Helm chart behind an OpenShift Route (TLS passthrough) |
| Sandboxes | containers on a podman network | supervisor + workload pods in `zt2-sandboxes`, NetworkPolicy-brokered egress |
| Egress enforcement | gateway proxy + OPA | same, plus enforced NetworkPolicy (OVN-Kubernetes) |

Namespaces are one trust tier each — this is load-bearing, not style:
the issuer's gateway check is a prefix match on
`spiffe://…/ns/openshell/sa/`, so the gateway's `ClusterSPIFFEID` is
pod-selector-tightened, the chart's fallback identity is excluded
from the `openshell` namespace, and sandboxes live in their own
`zt2-sandboxes` namespace. A sandbox pod must never be able to obtain
an SVID under the gateway prefix; the deployment is verified against
exactly that (see the design doc and
`docs/dev/openshift-stage2-findings.md`).

The token issuer verifies SPIRE's JWKS over TLS against the SPIFFE
trust bundle (a `spiffe-helper` sidecar writes it from the
CSI-mounted Workload API socket). The unauthenticated
`/demo-subject-token` listener is reachable only via
`oc port-forward` — never a Route or Service.

Human identity is a deliberate non-component: the subject token is an
OAuth2 access token presented at the RFC 8693 exchange, so any
customer IdP plugs in at that boundary — see
[production recommendations](PRODUCTION_RECOMMENDATIONS.md).

## Attribution

- SPIRE configs and registration scripts adapted from
  `OpenShell/examples/spiffe-token-exchange-demo/podman/`
  (NVIDIA, Apache-2.0).
- Document data and user definitions ported from
  `zero-trust-agent-demo` (same author, Apache-2.0).
