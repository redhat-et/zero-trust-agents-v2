# Stage 2: OpenShift deployment — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run all six zero-trust demo scenarios on a ROSA 4.22 cluster, driven from the laptop, with `deploy/openshift/` added and the Podman path unchanged.

**Architecture:** Four layers on ROSA — SPIFFE hardened-chart SPIRE with `ClusterSPIFFEID`-minted identities, the official OpenShell Helm chart with its Kubernetes compute driver behind an `openshiftRoute`, the v2 issuer/document services as plain Deployments in `zt-demo`, and sandbox pods in a dedicated `zt2-sandboxes` namespace so the gateway's identity policy cannot match them. The scenario harness (`scripts/lib.sh`) gains a `ZT2_DRIVER` seam so the same scenario scripts drive both backends.

**Tech Stack:** bash, Helm 3, `oc`, `podman --remote`, SPIFFE helm-charts-hardened (spire v0.29.0, spire-crds v0.5.0), OpenShell chart (ghcr.io/nvidia/openshell/helm-chart).

**Spec:** `docs/dev/2026-10-29-openshift-stage2-design.md` (revised 2026-10-30 after plan review: trust-tier namespace separation, gateway-SVID fetch mechanism, env-contract pins)

## Global constraints

- Trust domain is `openshell.local` (unchanged from Stage 1).
- Namespaces: `spire`, `openshell` (gateway + Agent Sandbox controller only), `zt2-sandboxes` (sandbox pods), `zt-demo` (v2 services). Sandboxes and gateway MUST NOT share a namespace — the gateway `ClusterSPIFFEID` is namespace-scoped and the issuer's gateway check is a prefix match (see Review focus).
- The issuer Service MUST be `token-issuer` in `zt-demo` on port 8080 (profiles hardcode `http://token-issuer.zt-demo.svc:8080`). No Service for the `:8090` demo listener — `oc port-forward deploy/token-issuer` targets the pod.
- Document services: one Deployment + Service per department in `DOC_DEPTS=("engineering" "finance" "admin" "hr" "public")`, named `document-<dept>`, port 8080.
- Issuer env (all set explicitly — code defaults at `internal/config/config.go:62-67` carry Podman aliases): `JWT_SVID_AUDIENCE=http://token-issuer.zt-demo.svc:8080`, `SPIRE_ISSUER=http://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local` (confirm exact Service name from the rendered chart; the issuer rejects SVIDs whose `iss` differs), `ACCESS_TOKEN_ISSUER=http://token-issuer.zt-demo.svc:8080`, `GATEWAY_TRUST_DOMAIN_PREFIX=spiffe://openshell.local/ns/openshell/sa/`, `SPIRE_JWKS_URI=$SPIRE_ISSUER/keys`. Document-service env: `ACCESS_TOKEN_SECRET` (same Secret as issuer), `ACCESS_TOKEN_ISSUER=http://token-issuer.zt-demo.svc:8080`, `DEPARTMENT=<dept>`, `PORT=:8080`. `config/users.yaml` is baked into the image — no ConfigMap.
- Images: linux/amd64, built from the existing `deploy/podman/Containerfile.*`, pushed to `quay.io/panni/zt2-token-issuer` and `quay.io/panni/zt2-document-service` (quay.io supports two-segment paths only; namespace overridable via `ZT2_QUAY_NS`).
- The Podman driver path stays byte-identical in behavior; `ZT2_DRIVER` defaults to `podman`.
- The `/demo-subject-token` listener is reached only via `oc port-forward`, never a Route or Service.
- Every shell script passes `shellcheck`; secrets are Kubernetes Secrets, never chart values or ConfigMaps.
- Commits: `git commit -s` with `Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>`.
- Steps marked **[cluster]** require the ROSA cluster (available from 2026-10-30 morning); all other steps are verifiable offline.

## Review focus

Pinned tests for the failure modes the spec implies but no happy-path test exercises:

- **Gateway identity over-match**: a sandbox pod holding a user subject token must NOT be able to perform the gateway's first exchange. Pinned by the namespace separation itself (gateway `ClusterSPIFFEID` scoped to `openshell`, sandboxes in `zt2-sandboxes`) — Task 4 applies the two ClusterSPIFFEIDs with those exact selectors, and Task 10 Step 3 verifies a sandbox SVID is NOT under the gateway prefix.
- **JWT-SVID audience / issuer mismatch 401s every exchange**: setup.sh sets `JWT_SVID_AUDIENCE` and `SPIRE_ISSUER` explicitly (Task 8, Task 6 manifests); scenario 1 e2e is the pin (Task 10).
- **`@ALLOWED_IPS@` blanked instead of line-deleted silently keeps a whitespace-only line — valid YAML, wrong profile**: Task 3's test asserts the parsed profile's `endpoints` block has exactly one entry with the expected `host` (parse success alone would not catch it).
- **Missing quay pull secret leaves pods in `ImagePullBackOff`**: setup.sh prechecks and fails fast (Task 8); **[cluster]**.
- **setup.sh re-run on a fresh ≤8-hour cluster must converge, not fail on stale profiles**: profiles are immutable per ID (Stage 1's `scripts/setup.sh:50-72` fixed this once already); Task 8 ports the sandbox → provider → profile teardown chain, and Task 10 Step 2 runs setup twice.

---

### Task 1: `ZT2_DRIVER` seam in the scenario harness

**Files:**
- Modify: `scripts/lib.sh`
- Create: `scripts/drivers/lib-podman.sh`

**Interfaces:**
- Produces: `scripts/lib.sh` selects the driver first (`ZT2_DRIVER="${ZT2_DRIVER:-podman}"`), then sources `scripts/drivers/lib-${ZT2_DRIVER}.sh` (clear error if missing). Each driver file defines, with identical signatures:
  - `OS` — array passed to the `openshell` CLI
  - `ENGINEERING_URL`, `HR_URL` — URLs valid **inside sandbox pods** (in-cluster DNS on OpenShift)
  - `ENGINEERING_LOCAL`, `FINANCE_LOCAL` — URLs valid **on the laptop** (host ports on Podman; `oc port-forward` on OpenShift) for scenario 3's healthz and scenario 6's host-side replay
  - `ISSUER_LOCAL`, `DEMO_SUBJECT_URL` — host-side issuer URLs
  - `pre_create_cleanup NAME` — remove a leftover sandbox before `sandbox create`
  - `register_sandbox ID` — make SPIRE attribute identity `ID` AND wait until the SVID is actually obtainable (Stage 1's `sleep 3` exists because the supervisor caches a failed token grant); prints the SPIFFE ID line
  - `supervisor_logs ID` — print the supervisor container's logs for sandbox `ID` (scenario 3 greps them for "Token grant failed")
  - `fetch_gateway_svid`, `fetch_supervisor_svid ID`, `fetch_rogue_svid` — print the respective JWT-SVID or return non-zero
  - per-driver state sourcing: the Podman driver sources `$STATE_DIR/spire.env` (and `deploy/podman/spire/common.sh`, which does host-OS detection and must not run under the OpenShift driver); the OpenShift driver sources `$STATE_DIR/openshift.env`. `lib.sh` itself sources neither.
- `lib.sh` keeps, driver-neutral: `sandbox_id`, `create_sandbox` (calling `pre_create_cleanup`), `sandbox_curl`, `pass`, `fail`, `scenario_header`, `sandbox_spiffe_id ID`.

- [ ] **Step 1: Extract the Podman driver**

Move from `lib.sh` into `scripts/drivers/lib-podman.sh`, unchanged: the `spire.env` sourcing block and `deploy/podman/spire/common.sh` source, the `OS` array, the URL/variable definitions (`ENGINEERING_URL`/`HR_URL`/`ISSUER_LOCAL`/`DEMO_SUBJECT_URL` plus new `ENGINEERING_LOCAL`/`FINANCE_LOCAL` mapped to the same `doc_endpoint_host`/`doc_endpoint_port` values Podman already publishes), the `podman ps … | xargs podman rm -f` cleanup from `create_sandbox` (as `pre_create_cleanup`), `register_sandbox`, `fetch_svid` (stays driver-private), and the three wrappers: `fetch_gateway_svid` → `fetch_svid "spiffe://openshell.local/openshell/gateway/demo" "openshell.spiffe-demo=gateway"`, `fetch_supervisor_svid ID` → `fetch_svid "spiffe://openshell.local/openshell/sandbox/$ID" "openshell.ai/sandbox-id=$ID" "openshell.managed=true"`, `fetch_rogue_svid` → current scenario-5 behavior (register rogue entry, fetch with `zt2.rogue=true` label). `supervisor_logs ID` → the `podman ps --filter label=… | grep supervisor` + `podman logs` sequence currently inline in scenario3.

- [ ] **Step 2: Dispatch in `lib.sh`**

Keep `ROOT`/`STATE_DIR`; add `sandbox_spiffe_id() { echo "spiffe://openshell.local/openshell/sandbox/$1"; }`; select and source the driver; everything else stays.

- [ ] **Step 3: Verify offline**

Run: `shellcheck scripts/lib.sh scripts/drivers/lib-podman.sh`
Expected: clean.

- [ ] **Step 4: Verify Podman behavior unchanged**

Run: `scripts/setup.sh && scripts/scenario1.sh && scripts/scenario3.sh` (scenario 3 exercises `supervisor_logs` and `ENGINEERING_LOCAL`).
Expected: both pass exactly as before (regression pin for the whole refactor). Teardown with `scripts/teardown.sh` afterwards.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh scripts/drivers/lib-podman.sh
git commit -s -m "refactor: introduce ZT2_DRIVER seam in scenario harness"
```

### Task 2: Scenario scripts use driver-neutral helpers

**Files:**
- Modify: `scripts/scenario2.sh:37-38`, `scripts/scenario3.sh:20,38-40`, `scripts/scenario5.sh:17-31`, `scripts/scenario6.sh:24,27-28,57-71`

**Interfaces:**
- Consumes: the Task 1 driver contract.

- [ ] **Step 1: Replace Podman-only calls**

Scenario 2 and 6: `GW_SVID="$(fetch_gateway_svid)"`, `SUP_SVID="$(fetch_supervisor_svid "$ID")"`; scenario 6's `SANDBOX_SPIFFE_ID` → `"$(sandbox_spiffe_id "$ID")"`. Scenario 3: `http://127.0.0.1:18101/healthz` → `"$ENGINEERING_LOCAL/healthz"`; the inline `podman ps`/`podman logs` block → `supervisor_logs "$ID" | grep -q "Token grant failed"`. Scenario 6: the two hardcoded host-side curls (`127.0.0.1:18101/…DOC-001`, `127.0.0.1:18102/…DOC-005`) → `"$ENGINEERING_LOCAL/documents/DOC-001"` and `"$FINANCE_LOCAL/documents/DOC-005"`.

- [ ] **Step 2: Make scenario 5 accept both rogue outcomes**

On OpenShift, SPIRE refuses to mint the rogue SVID at attestation time (no matching `ClusterSPIFFEID`) instead of the issuer rejecting it with 401. Restructure scenario5: if `fetch_rogue_svid` fails, `pass "SPIRE refused to issue an identity outside the attestation policy — nothing to present"` and exit 0; otherwise keep the existing issuer-401 path.

- [ ] **Step 3: Verify**

Run: `scripts/scenario1.sh && scripts/scenario2.sh && scripts/scenario3.sh && scripts/scenario5.sh && scripts/scenario6.sh` (Podman).
Expected: all pass; scenario 3 and 6 through the new variables; scenario 5 via the issuer-401 path.

- [ ] **Step 4: Commit**

```bash
git add scripts/scenario2.sh scripts/scenario3.sh scripts/scenario5.sh scripts/scenario6.sh
git commit -s -m "refactor: scenario scripts use driver-neutral helpers"
```

### Task 3: OpenShift provider profiles

**Files:**
- Create: `deploy/openshift/profiles/` — four `.yaml.in` files mirroring `deploy/podman/profiles/`

**Interfaces:**
- Consumes: `deploy/podman/profiles/*.yaml.in` as the source (copy, do not modify).
- Produces: profiles whose `@DOC_HOST@`/`@DOC_PORT@`/`@ALLOWED_IPS@` placeholders are substituted by `deploy/openshift/setup.sh` (Task 8).

- [ ] **Step 1: Create the templates**

Copy each Podman profile; change only the comment header. The OpenShift substitution contract (implemented in Task 8): `@DOC_HOST@` → `document-<dept>.zt-demo.svc`, `@DOC_PORT@` → `8080`, and the entire line containing `@ALLOWED_IPS@` is **deleted** (`awk`-based; a `sed` blanking leaves a whitespace-only line that is valid YAML but a silently-wrong profile).

- [ ] **Step 2: Write the substitution self-test**

`deploy/openshift/profiles/test-substitution.sh`: substitutes the three placeholders exactly as setup will, then asserts each result parses as YAML **and** each `endpoints` block has exactly one entry whose `host` is `document-<dept>.zt-demo.svc` (the parse alone does not catch the whitespace-line failure mode). Use `yq` if available, else `python3 -c "import yaml,sys; yaml.safe_load(sys.stdin)"`.

- [ ] **Step 3: Verify**

Run: `bash deploy/openshift/profiles/test-substitution.sh`
Expected: all four substituted profiles pass both assertions.

- [ ] **Step 4: Commit**

```bash
git add deploy/openshift/profiles/
git commit -s -m "feat: OpenShift provider profile templates"
```

### Task 4: SPIRE Helm values and ClusterSPIFFEIDs

**Files:**
- Create: `deploy/openshift/spire/values.yaml`, `deploy/openshift/spire/clusterspiffeids.yaml`

**Interfaces:**
- Produces: SPIRE in namespace `spire` with two identities:
  - `openshell-sandboxes` ClusterSPIFFEID — `spiffeIDTemplate: spiffe://{{ .TrustDomain }}/openshell/sandbox/{{ index .PodMeta.Annotations "openshell.ai/sandbox-id" }}`, **namespaceSelector `zt2-sandboxes`**, podSelector `openshell.ai/managed-by: openshell`
  - `zt2-gateway` ClusterSPIFFEID — `spiffeIDTemplate: spiffe://{{ .TrustDomain }}/ns/{{ .Namespace }}/sa/{{ .ServiceAccount }}`, **namespaceSelector `openshell`** (which contains no sandboxes — this is the trust-tier separation; see Review focus)
  - OIDC discovery provider reachable from `zt-demo`.

- [ ] **Step 1: Write values.yaml**

Base on upstream `deploy/helm/openshell/ci/values-spire-stack.yaml`: `global.spire.trustDomain: openshell.local`, `clusterName: zt2-rosa`, single server replica, controller-manager enabled, `jwtIssuer` pointing at the discovery provider Service, PSAT agents, CSI driver enabled. Do not set `fsGroup`/`runAsUser` — OpenShift SCC admission assigns them. Confirm the discovery-provider Service name from rendered output; it feeds `SPIRE_ISSUER` (Global constraints).

- [ ] **Step 2: Write clusterspiffeids.yaml**

Two `ClusterSPIFFEID` resources exactly as in the Interfaces block, selector spelling from upstream CI values (`namespaceSelector.matchLabels.kubernetes.io/metadata.name`, `podSelector.matchLabels`).

- [ ] **Step 3: Verify offline**

Run: `helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/ && helm template spire spiffe/spire --version 0.29.0 -f deploy/openshift/spire/values.yaml > /dev/null && python3 -c "import yaml; [list(yaml.safe_load_all(open('deploy/openshift/spire/clusterspiffeids.yaml')))]"`
Expected: chart renders; ClusterSPIFFEID YAML parses and contains both namespace selectors.

- [ ] **Step 4: Commit**

```bash
git add deploy/openshift/spire/
git commit -s -m "feat: SPIRE hardened-chart values with trust-tier-separated identities"
```

### Task 5: OpenShell chart values

**Files:**
- Create: `deploy/openshift/openshell/values.yaml`

**Interfaces:**
- Produces: OpenShell gateway in namespace `openshell`, Kubernetes compute driver, sandboxes in `zt2-sandboxes`, Route host written to the state file by setup.sh (Task 8).

- [ ] **Step 1: Write values.yaml**

From the OpenShell OpenShift docs and upstream `ci/values-spire.yaml`: enable `openshiftRoute`; `gatewayConfig` sets `openshell.drivers.kubernetes` with `provider_spiffe_workload_api_socket_path: /spiffe-workload-api/spire-agent.sock` and `server.sandboxNamespace: zt2-sandboxes`; null out `podSecurityContext.fsGroup` and `securityContext.runAsUser`; JWT signing on with secrets as Kubernetes Secrets. Record the Agent Sandbox controller install command (release manifest URL from the OpenShell Kubernetes setup docs) as a comment at the top — setup.sh (Task 8) runs it.

- [ ] **Step 2: Verify offline**

Run: `helm template openshell oci://ghcr.io/nvidia/openshell/helm-chart -f deploy/openshift/openshell/values.yaml | grep -A2 -e provider_spiffe -e sandboxNamespace`
Expected: renders; output shows the socket path and `zt2-sandboxes`.

- [ ] **Step 3: Commit**

```bash
git add deploy/openshift/openshell/values.yaml
git commit -s -m "feat: OpenShell chart values for OpenShift"
```

### Task 6: zt-demo namespace manifests

**Files:**
- Create: `deploy/openshift/zt-demo/` — `namespace.yaml`, `token-issuer.yaml` (Deployment + Service `token-issuer` :8080 only — no `:8090` Service), `document-services.yaml` (five written-out Deployment+Service pairs, `document-<dept>` :8080), `networkpolicy.yaml`, `secrets.example.yaml`

**Interfaces:**
- Consumes: images `quay.io/panni/zt2-token-issuer` and `quay.io/panni/zt2-document-service` (Task 7); the env contract in Global constraints (issuer and document-service vars, verbatim).
- Produces: workloads whose env comes from Secrets; `config/users.yaml` stays baked into the image (no ConfigMap).

- [ ] **Step 1: Write the manifests**

Plain written-out YAML (five explicit pairs — no generation loop, so `oc apply -f` works on the directory). Security: every container `allowPrivilegeEscalation: false`, drop all capabilities, `RuntimeDefault` seccomp, no `runAsUser`/`fsGroup`. NetworkPolicy: default-deny ingress in `zt-demo` + allow from namespace `zt2-sandboxes`. Both issuer listeners (`:8080`, `:8090`) are container ports on the same Deployment; `:8090` gets no Service.

- [ ] **Step 2: Verify offline**

Run: `for f in deploy/openshift/zt-demo/*.yaml; do oc apply --dry-run=client --validate=false -f "$f" || exit 1; done`
Expected: every manifest passes client-side validation; the loop's `|| exit 1` makes failure actually fail.

- [ ] **Step 3: Commit**

```bash
git add deploy/openshift/zt-demo/
git commit -s -m "feat: zt-demo namespace manifests for OpenShift"
```

### Task 7: Image build script

**Files:**
- Create: `deploy/openshift/build-images.sh`

**Interfaces:**
- Produces: `quay.io/panni/zt2-token-issuer:v2` and `quay.io/panni/zt2-document-service:v2` (tag overridable via `ZT2_IMAGE_TAG`, namespace via `ZT2_QUAY_NS`), built from `deploy/podman/Containerfile.token-issuer` and `Containerfile.document-service` unchanged.

- [ ] **Step 1: Write the script**

`set -euo pipefail`; require `podman`; precheck that the remote connection can push (a clear message to run `podman --remote --connection rhel login quay.io` if not); for each Containerfile: `podman --remote --connection "${ZT2_PODMAN_CONNECTION:-rhel}" build --platform linux/amd64 -t quay.io/$NS/$name:$TAG -f <containerfile> .` then `podman push` (also via the remote connection, where the quay credentials live).

- [ ] **Step 2: Verify** (requires homelab reachable)

Run: `bash deploy/openshift/build-images.sh && skopeo inspect docker://quay.io/panni/zt2-token-issuer:v2 | grep amd64`
Expected: push succeeds; `skopeo inspect` shows `linux/amd64` (plain single-arch images — `podman manifest inspect` is for manifest lists only).

- [ ] **Step 3: Commit**

```bash
git add deploy/openshift/build-images.sh
git commit -s -m "feat: quay.io image build script for the RHEL homelab"
```

### Task 8: setup.sh / teardown.sh

**Files:**
- Create: `deploy/openshift/setup.sh`, `deploy/openshift/teardown.sh`, `deploy/openshift/lib.sh`

**Interfaces:**
- Consumes: Tasks 3–7 outputs.
- Produces: state file `$ROOT/.zt2-state/openshift.env` exporting `ZT2_DRIVER=openshift`, `ZT2_GATEWAY_ROUTE`, `TOKEN_ISSUER_DEMO_HOST_PORT` (local port forwarded to the issuer pod's `:8090`), `ZT2_STATE_DIR` — sourced by the OpenShift driver (Task 9).

- [ ] **Step 1: Write `deploy/openshift/lib.sh`**

Shared helpers mirroring `deploy/podman/spire/common.sh` conventions: `require_oc`, `wait_rollout NS RESOURCE`, `state_set VAR VALUE` (appends to `openshift.env`).

- [ ] **Step 2: Write setup.sh**

Order: require `oc`, `helm`, `openshell`; verify `oc whoami` and OpenShift ≥ 4.19 (`oc get clusterversion`); precheck quay pull secret exists in `openshell` and `zt-demo` (fail fast with the fix command if the repos are private); install `spire-crds` then `spire` (Task 4 values, `helm repo add spiffe` first); `oc apply` the ClusterSPIFFEIDs; install the Agent Sandbox controller (command from Task 5); install the OpenShell chart (Task 5 values); create `zt2-sandboxes` namespace; apply `zt-demo` manifests with generated `ACCESS_TOKEN_SECRET` and the Global-constraints env; mint subject tokens through the port-forwarded demo listener; **stale-state clearing before profile import** — port Stage 1's chain (`scripts/setup.sh:50-72`): delete existing `zt2-*` sandboxes, then provider records, then profiles (profiles are immutable per ID; a second run without this fails); substitute and import the four profiles (Task 3 contract); start background `oc port-forward deploy/token-issuer` for `:8090`, record port and PID; print the Route host and the `openshell gateway add` command. Idempotent: every step re-runnable (`helm upgrade --install`, `oc apply`).

- [ ] **Step 3: Write teardown.sh**

Kill recorded port-forwards (by PID file); `helm uninstall` the three releases; delete `zt-demo`, `zt2-sandboxes` namespaces and the ClusterSPIFFEIDs; delete sandboxes/providers/profiles via the CLI. Leave `spire` CRDs unless `--all` given (CRD deletion is cluster-wide and slow).

- [ ] **Step 4: Verify offline**

Run: `shellcheck deploy/openshift/*.sh deploy/openshift/lib.sh`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add deploy/openshift/setup.sh deploy/openshift/teardown.sh deploy/openshift/lib.sh
git commit -s -m "feat: OpenShift setup and teardown scripts"
```

### Task 9: OpenShift harness driver

**Files:**
- Create: `scripts/drivers/lib-openshift.sh`, `deploy/openshift/svid-helper.yaml`

**Interfaces:**
- Consumes: `openshift.env` from Task 8; the Task 1 driver contract (identical function names).
- Produces: a complete second driver; scenarios run with `ZT2_DRIVER=openshell`.

- [ ] **Step 1: Write the driver**

- Source `openshift.env`; `OS=(openshell --gateway zt2 --gateway-endpoint "https://$ZT2_GATEWAY_ROUTE")`.
- `ENGINEERING_URL="http://document-engineering.zt-demo.svc:8080"`, `HR_URL` likewise (curl runs inside sandbox pods — in-cluster DNS). `ENGINEERING_LOCAL`/`FINANCE_LOCAL`/`ISSUER_LOCAL`/`DEMO_SUBJECT_URL` via lazily-started background `oc port-forward`s (record PIDs in `$STATE_DIR` for teardown).
- `pre_create_cleanup`: `oc -n zt2-sandboxes delete sandbox "$NAME" --ignore-not-found` (Agent Sandbox CR) plus the `openshell sandbox delete` already in `create_sandbox`.
- `register_sandbox ID`: no-op that echoes the SPIFFE ID line **after** polling until `fetch_supervisor_svid ID` succeeds once (Stage 1 learned the supervisor caches a failed token grant — polling pod Running is not enough).
- `fetch_supervisor_svid ID` / `fetch_rogue_svid`: apply `svid-helper.yaml` as a pod in `zt2-sandboxes` — image `ghcr.io/spiffe/spire-agent:1.12.4`, the CSI `spiffe-socket` volume, annotations parameterized by `oc apply -f -` with `sed` (supervisor helper carries `openshell.ai/sandbox-id=$ID`; rogue helper carries none and requests `spiffe://openshell.local/rogue/workload/1`, which no ClusterSPIFFEID matches) — then `oc exec` `spire-agent api fetch jwt -socketPath /spiffe-workload-api/spire-agent.sock -audience http://token-issuer.zt-demo.svc:8080 -spiffeID <id>`, parse the token as the Podman driver does, delete the helper pod.
- `fetch_gateway_svid`: **no helper pod** — a selector-matched helper is the impersonation the namespace separation exists to prevent. Use `oc debug -n openshell deploy/openshell --image=ghcr.io/spiffe/spire-agent:1.12.4 -- spire-agent api fetch jwt -socketPath /spiffe-workload-api/spire-agent.sock -audience http://token-issuer.zt-demo.svc:8080 -spiffeID spiffe://openshell.local/ns/openshell/sa/<gateway-sa>` — the ephemeral container attaches to the real gateway pod and shares its CSI-mounted socket (gateway SA name confirmed from the rendered chart in Task 5; if the gateway pod lacks the socket mount, stop and record it as a finding — do not fall back to a helper pod).
- `supervisor_logs ID`: `oc -n zt2-sandboxes logs -l "openshell.ai/sandbox-id=$ID" -c supervisor`.

- [ ] **Step 2: Write svid-helper.yaml**

The supervisor/rogue helper pod manifest (annotations are substituted at apply time, so the file carries `@SANDBOX_ID@` placeholders consumed only by the driver functions).

- [ ] **Step 3: Verify offline**

Run: `shellcheck scripts/drivers/lib-openshift.sh`
Expected: clean. Full behavior verification is Task 10.

- [ ] **Step 4: Commit**

```bash
git add scripts/drivers/lib-openshift.sh deploy/openshift/svid-helper.yaml
git commit -s -m "feat: OpenShift scenario harness driver"
```

### Task 10: End-to-end on the cluster **[cluster]**

**Files:**
- Create: `docs/dev/openshift-stage2-findings.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: First run**

Run: `bash deploy/openshift/build-images.sh && bash deploy/openshift/setup.sh`
Expected: green; record wall-clock from empty cluster (target < 15 min, spec's risk item) and the SPIRE chart's actual SCC behavior (spec verification item).

- [ ] **Step 2: Verify the trust-tier separation**

Run: `oc -n zt2-sandboxes exec deploy/<any-sandbox-supervisor> -- ls /spiffe-workload-api` and attempt `fetch_supervisor_svid` for an SVID under `spiffe://openshell.local/ns/openshell/sa/` from a sandbox-namespace helper pod.
Expected: sandbox pods receive only `openshell/sandbox/…` SVIDs; the gateway-prefix request is refused. This is the Review-focus pin for the over-match.

- [ ] **Step 3: Idempotency**

Run: `bash deploy/openshift/setup.sh` a second time.
Expected: converges without errors (stale-profile chain works).

- [ ] **Step 4: All six scenarios**

Run: `ZT2_DRIVER=openshell scripts/scenario{1..6}.sh` in order.
Expected: all six pass. Scenario 5 should pass via the attestation-refusal path. If scenario 1 401s, check `JWT_SVID_AUDIENCE` and `SPIRE_ISSUER` first (Review focus). Record Route TLS passthrough behavior (spec verification item) and whether the issuer's JWKS fetch from `zt-demo` → `spire` crosses any chart-shipped NetworkPolicy in `spire` (if so, add the allow rule to Task 6's policy and record it).

- [ ] **Step 5: Record findings**

Write `docs/dev/openshift-stage2-findings.md`: timings, SCC results, Route/TLS result, JWKS cross-namespace result, whether the gateway pod exposes the Workload API socket to `oc debug`, and any deviation from upstream defaults — these feed Task 11's production note.

- [ ] **Step 6: Commit**

```bash
git add docs/dev/openshift-stage2-findings.md
git commit -s -m "docs: Stage 2 on-cluster verification findings"
```

### Task 11: Documentation

**Files:**
- Modify: `docs/ARCHITECTURE.md`, `docs/DEMO_SCENARIOS.md`, `README.md`
- Create: `docs/PRODUCTION_RECOMMENDATIONS.md`

- [ ] **Step 1: Write the OpenShift sections**

ARCHITECTURE.md: OpenShift deployment section (four-namespace layout with the trust-tier rationale, component table additions). DEMO_SCENARIOS.md: "Running on OpenShift" — prerequisites (`oc`, ROSA 4.19+, pull secret), the four running-order steps from the spec. README: one-line pointer to both paths. PRODUCTION_RECOMMENDATIONS.md (<300 lines): trust domain choice, secret handling, IdP swap point, SCC exceptions actually required (from Task 10 findings), NetworkPolicy narrowing from namespace-wide to supervisor pods, and the namespace-per-trust-tier rule for `ClusterSPIFFEID` scoping.

- [ ] **Step 2: Verify**

Use this repo's `markdown-lint` skill on the four files.
Expected: clean (tables exempt from MD013 per user style guide).

- [ ] **Step 3: Commit**

```bash
git add docs/
git commit -s -m "docs: OpenShift deployment documentation"
```
