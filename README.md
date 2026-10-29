# Zero Trust Agents v2

An educational demo showing zero-trust identity for AI agent systems
where **the agent is an OpenShell sandbox**: SPIFFE workload identity on
sandboxes, RFC 8693 token exchange through the OpenShell gateway, and
permission intersection enforced cryptographically at token-mint time.

Successor to [zero-trust-agent-demo](https://github.com/redhat-et/zero-trust-agent-demo)
(v1), which enforced the same property with OPA at request time.

## Scenario matrix

| # | User  | Capability | Target          | Result |
|---|-------|------------|-----------------|--------|
| 1 | Alice | engineering | engineering doc | ✅ |
| 2 | Alice | hr          | engineering doc | ❌ no intersection |
| 3 | —     | engineering | engineering doc | ❌ no delegation |
| 4 | Carol | hr          | hr doc          | ✅ |
| 5 | rogue | —           | any             | ❌ unregistered SPIFFE ID |
| 6 | Alice | engineering | finance doc     | ❌ audience mismatch |

## Quick start (macOS, podman machine)

Requirements: podman (machine running), `openshell` CLI 0.1.6, Go 1.22+,
curl, python3.

```console
$ make build          # Go services
$ scripts/setup.sh    # SPIRE + gateway + services + profiles
$ scripts/scenario1.sh
  ...
$ scripts/teardown.sh
```

The setup script adds one line to the podman VM's `/etc/hosts`
(`token-issuer.zt-demo.svc`); teardown explains how to remove it.

## Quick start (Fedora/RHEL, rootless podman)

Requirements: podman 5.x (rootless, `systemctl --user enable --now
podman.socket`), `openshell` CLI 0.1.6 (rpm from upstream releases), Go
1.22+, curl, python3, and sudo for one `/etc/hosts` edit.

```console
$ make build          # Go services
$ scripts/setup.sh    # SPIRE + gateway + services + profiles
$ scripts/scenario1.sh
  ...
$ scripts/teardown.sh
```

The host OS is detected automatically (`ZT2_HOST_OS` overrides). The
gateway is advertised at its loopback publish and the issuer's `.svc`
alias is a host `/etc/hosts` entry rather than a podman-VM one; the
document-service layout is structurally the same as macOS (published
ports + nip.io + `allowed_ips`, with the host's real IP detected at
setup). See the networking notes in `docs/ARCHITECTURE.md`.

## Documentation

- `docs/ARCHITECTURE.md` — components, token flow, claim schema
- `docs/DEMO_SCENARIOS.md` — the six scenarios and what each proves
- `docs/LEARNING_GUIDE.md` — guided tour of the security ideas

## Repository layout

| Path | Contents |
|---|---|
| `token-issuer/` | Go token issuer (subject tokens, RFC 8693 exchanges, SVID verification) |
| `document-service/` | Go protected resource server, one instance per department |
| `deploy/podman/` | SPIRE configs, gateway/services scripts, provider profiles |
| `scripts/` | setup, teardown, and one script per scenario |
| `config/users.yaml` | demo users and departments |

Derived from NVIDIA's OpenShell `spiffe-token-exchange-demo` (Apache-2.0)
and the v1 demo's document/user data. License: Apache-2.0.
