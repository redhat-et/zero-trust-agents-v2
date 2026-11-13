# Plan: native-Service A2A for OpenShift scenarios 11 and 15

**Date:** 2026-11-12 (demo is Friday 2026-11-13)
**Goal:** run scenarios 11 (full A2A chain) and 15 (caller allowlist) on a
fresh OpenShift cluster, using B's native headless Service instead of the
gateway's exposed-service authority.
**Status:** designed 2026-11-11; implemented and tested in-cluster
2026-11-12. **The native Service cannot expose the app port** — see
"2026-11-12 in-cluster result". Demo now splits by driver.

## Why this path

The 2026-11-11/12 probe ruled out keeping the gateway in the in-cluster
A2A path (evidence in
`docs/DEMO_WALKTHROUGH_OPENSHIFT.md`, "Why the gateway Route cannot be
A's in-cluster path"):

- The gateway Route + `Host` works from a plain pod, but the Route host
  also resolves to `32.193.255.39`, which blackholes; the supervisor
  picked it and the sandbox call timed out.
- The gateway Service `:8080` + `Host` reaches the gateway from a plain
  pod, but inside a sandbox the supervisor terminates TLS with its own CA
  and cannot verify the gateway's self-signed chart certificate:
  `ALLOWED … engine:opa`, then `NET:FAIL`, client `SSL_ERROR_SYSCALL`.
- A DocsClaw `host_header` option alone cannot fix the upstream TLS leg;
  `tls: passthrough` would disable the L7 inspection that injects the
  token.

The native headless Service is plain HTTP, which the supervisor already
proxies and inspects for the document services. The token flow is
unchanged: A's supervisor mints the engineering-analyst token for the
declared host:port, B validates it and the caller allowlist.

## Prerequisites (fresh ROSA 4.22 cluster, 8 h lifetime)

- `oc` logged in as cluster-admin; `helm`, `openshell`, `python3`, `yq`,
  `skopeo` on PATH.
- quay.io pull access for `quay.io/panni/zt2-*:v2` (public or
  `zt2-quay` secret via podman auth) and the public DocsClaw image
  `quay.io/panni/docsclaw:v2-openshell-amd64-r3`.
- `~/.config/zt2/llm.env` with `LLM_API_KEY`, `LLM_BASE_URL`,
  `LLM_MODEL`; the MaaS base must include `/v1`.
- Start setup early: `ZT2_DRIVER=openshift deploy/openshift/setup.sh`
  (writes `.zt2-state/openshift.env`; several minutes).

## Step 0 — baseline (about 15 min)

```bash
ZT2_DRIVER=openshift deploy/openshift/setup.sh
for s in 1 2 3 4 5 6; do ZT2_DRIVER=openshift scripts/scenario$s.sh; done
```

All six must PASS before changing anything. `scenario12` and 13/14 should
also still pass; run 13/14 model-free now if time allows.

## Step 1 — verify the headless Service mechanism (about 15 min)

Create one sandbox and enable its Service:

```bash
# after scenario13 has left eng-analyst running (or create one):
oc -n zt2-sandboxes get sandbox -o name | sed 's|.*/||'
oc -n zt2-sandboxes patch sandbox/default--eng-analyst --type=merge \
  -p '{"spec":{"service":true}}'
oc -n zt2-sandboxes get svc
```

Confirm:

- a headless Service (`ClusterIP: None`) named after the Sandbox CR
  (`default--eng-analyst`) appears;
- DNS resolves from another sandbox:
  `getent hosts default--eng-analyst.zt2-sandboxes.svc.cluster.local`
  (or curl `:8000/health`);
- the Service disappears when the Sandbox is deleted (ownerReference).

If no Service appears, check the controller version (`v1.0.9` supports
`spec.service`) and the Sandbox Ready condition. If DNS resolves but the
port is not published, remember headless DNS returns pod IPs, so dialing
`:8000` directly is sufficient.

## Step 2 — implementation (about 45–60 min)

### Driver helper

Add `publish_a2a_peer NAME PORT` to both drivers and use it in scenarios
11 and 15 instead of `start_relay` for B.

- `scripts/drivers/lib-podman.sh`: call the existing
  `start_relay "$name" "$port" "$A2A_PORT"`.
- `scripts/drivers/lib-openshift.sh`:
  1. find the Sandbox CR for the name:
     `oc -n zt2-sandboxes get sandbox -o name | sed 's|.*/||' | grep -E -- "--${name}$"`;
  2. `oc patch sandbox/<cr> --type=merge -p '{"spec":{"service":true}}'`;
  3. wait for `svc/<cr>`;
  4. set `A2A_HOST="<cr>.zt2-sandboxes.svc.cluster.local"` and
     `A2A_PORT="$port"`.

`render_alice_a2a_profile` already renders `@A2A_HOST@`/`@A2A_PORT@` into
both the `endpoints` entry and the `audience_overrides` entry, so the
profile follows automatically.

### Scenarios

- `scripts/scenario11.sh`: replace
  `start_relay eng-analyst 8000 "$A2A_PORT"` with
  `publish_a2a_peer eng-analyst 8000`.
- `scripts/scenario15.sh`: same replacement.
- Leave scenario12's `start_relay alice-a2a …` alone; it is the deny
  scenario and does not need B.
- Keep the traps (`stop_relay`) harmless; the Service is owned by the
  Sandbox CR and disappears with it.

### Ordering guard

`render_alice_a2a_profile` deletes providers of that profile type before
re-importing. Always render/import the profile **before** creating A's
provider, as the scenarios already do.

## Step 3 — validation (about 15 min)

```bash
set -a; source ~/.config/zt2/llm.env; set +a
ZT2_DRIVER=openshift scripts/scenario11.sh   # expect PASS
ZT2_DRIVER=openshift scripts/scenario12.sh   # regression, expect PASS
ZT2_DRIVER=openshift scripts/scenario13.sh   # regression, expect PASS
ZT2_DRIVER=openshift scripts/scenario14.sh   # regression, expect PASS
ZT2_DRIVER=openshift scripts/scenario15.sh   # expect PASS
```

Evidence to record in `docs/dev/zero-trust-stage-b/03-wp-b3-exposure-wiring.md`:

- scenario 11: A's trace `→ a2a_call`, `← a2a_call ok`; B logs
  `request authenticated` with `aud=engineering-analyst`, A's SVID,
  `scope=engineering`; no `jwks_unavailable`.
- scenario 15: B returns `403 caller_not_allowed`.
- supervisor log: `ALLOWED … -> default--eng-analyst.zt2-sandboxes.svc.cluster.local:8000`
  and the token grant for the same host:port.

## Risks and fallbacks

| Risk | Check | Fallback |
| --- | --- | --- |
| No headless Service | Sandbox Ready condition, `oc get svc` | Create a ClusterIP Service manually selecting the pod; discover the selector label from the pod |
| CR name differs from `default--<sandbox>` | list CRs and match `--<name>$` | Derive the Service name from the CR, never hard-code |
| Ingress blocked | curl from A to the Service FQDN | Add a NetworkPolicy allowing `zt2-sandboxes` → B:8000 |
| Token not minted | supervisor log shows the audience override | Confirm the profile endpoint and override both use the Service FQDN:8000 |
| Scenario 12 changes | run it | It must stay a deny at `:18810`; do not point it at B |

## 2026-11-12 in-cluster result

Tested on a fresh ROSA 4.22 cluster with the stack up. The mechanism
exists but does not publish the app:

- `spec.service: true` does create a controller-owned headless Service
  (`ClusterIP: None`, `ownerReference` to the Sandbox, so it dies with
  it).
- The Service is named `sandbox-control`, selects the **workload** pod,
  and targets **port 5500**. Nothing listens on 5500 there.
- Decisive: inside B, `curl 127.0.0.1:8000/health` returns `200` while
  `curl 10.128.0.81:8000/health` (B's own pod IP) is **refused**.
  DocsClaw listens inside the sandbox's isolated network namespace; the
  pod IP never serves the app.
- `openshell-sandbox-workloads` admits ingress only from supervisor
  pods, port 5500. A peer pod cannot reach the supervisor pod's 5500
  either (policy drop, not refusal).

A NetworkPolicy was tried and removed: with a pod carrying the exact
`openshell.ai/boundary-role=supervisor` label, `10.128.0.81:8000` still
timed out. Pod-network controls cannot reach a namespace they do not
share.

Consequence: cross-sandbox ingress must go through the supervisor's
inbound relay, which is the gateway path, whose blocker is the
supervisor's TLS trust of the self-signed chart certificate (see
`DEMO_WALKTHROUGH_OPENSHIFT.md`). The native-Service idea solved the
wrong half of the problem.

Baseline: scenarios 1–6 PASS, and scenario 12 still PASSes with the new
code. Scenario 11 fails at the POST with `context deadline exceeded`
after the supervisor correctly publishes the DNS mapping
(`resolved=10.128.0.81 synthetic=198.18.0.3 ports=8000`) — the token
side is not the problem.

## Demo narrative (Friday)

- **OpenShift, north–south**: laptop → gateway Route → exposed agent
  (scenarios 13/14), plus scenario 12's deny. The gateway enforces the
  exposed-service auth.
- **Podman, east–west**: A → host relay → B (scenarios 11/15), supervisor
  egress policy + minted engineering-analyst token + B's inbound
  validation and caller allowlist.
- Why the split: the relay is the only working east-west transport we
  have. On OpenShift the gateway path is blocked by the supervisor's TLS
  trust of a self-signed chart certificate, and the native Service never
  exposes the app port (see "2026-11-12 in-cluster result"). The
  security model is identical on both drivers; only the transport is
  not yet available in-cluster.
- Say the limitation as a finding, not a gap: the sandbox boundary is a
  network namespace, so pod-level controls cannot reach the workload.
  Ingress has to pass the supervisor's relay.

## Out of scope today

- OpenShell per-endpoint upstream CA/skip-verify so the gateway can be
  used for in-cluster A2A. Upstream analysis, existing issues, and
  drafts for the core team: `2026-11-12-openshell-upstream-gaps.md`.
- A Route in front of the headless Service (adds a router hairpin; not
  needed for east-west).
- Reproducible DocsClaw image publishing (issue #18).
