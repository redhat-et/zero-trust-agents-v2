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

## Attribution

- SPIRE configs and registration scripts adapted from
  `OpenShell/examples/spiffe-token-exchange-demo/podman/`
  (NVIDIA, Apache-2.0).
- Document data and user definitions ported from
  `zero-trust-agent-demo` (same author, Apache-2.0).
