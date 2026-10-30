# OpenShift runbook: fresh cluster to six passing scenarios

Step-by-step re-creation of the Stage 2 deployment on a new ROSA
cluster (written for the ≤ 8 h temporary clusters; also applies to any
OpenShift 4.19+). Everything here is what
`docs/dev/openshift-stage2-findings.md` verified on ROSA 4.22.20.

## One-time prerequisites (laptop + homelab)

- `oc` logged in to the cluster with cluster-admin.
- Helm 3, `openshell` CLI 0.1.6, `podman` with the `rhel` remote
  connection, `yq`, `python3`, `curl` on PATH.
- `podman --remote --connection rhel login quay.io` (push credentials
  live on the remote host).
- Local podman credentials for quay.io (`~/.config/containers/auth.json`)
  — `setup.sh` builds the in-cluster pull secret from them, so the
  `quay.io/panni/zt2-*` repositories can stay private. If the repos
  are public instead, run `ZT2_PUBLIC_IMAGES=1 setup.sh` to skip the
  pull-secret precheck.

## 1. Build and push the images (only once per code change)

```bash
deploy/openshift/build-images.sh
```

Builds `quay.io/panni/zt2-token-issuer:v2` and
`quay.io/panni/zt2-document-service:v2` for linux/amd64 on the RHEL
homelab and pushes them. Skip if the images are already current.

## 2. Set up the cluster

```bash
deploy/openshift/setup.sh
```

Installs SPIRE (hardened charts, OpenShift pod-security labels on
pre-created namespaces), the Agent Sandbox controller, the OpenShell
gateway behind an OpenShift Route (TLS passthrough, cert SAN from the
cluster's apps domain), the zt-demo services with a generated secret,
copies the chart's client TLS secret into `zt2-sandboxes` (supervisor
pods mount it), registers the gateway with the CLI (mTLS; a stale
`zt2` registration from an earlier cluster is removed first), imports
the four provider profiles, and starts the loopback port-forward for
the subject-token minter.

Expected wall-clock from an empty cluster: measure it (the original
bring-up was iterative); chart installs plus image pulls plus
rollouts are roughly 5-10 minutes. The script is idempotent — re-run
it after any partial failure.

## 3. Run the scenarios

```bash
ZT2_DRIVER=openshift scripts/scenario1.sh
# ... through scenario6.sh
```

Run from the repo root on the laptop. The OpenShift driver
(`scripts/drivers/lib-openshift.sh`) starts the host-side
`oc port-forward`s it needs and restarts the minter forward if it
died (e.g. after an issuer rollout). Each scenario prints what it
does and exits non-zero on any unexpected result.

What each proves: see `docs/DEMO_SCENARIOS.md`. On OpenShift,
scenario 5 passes via SPIRE's attestation policy refusing to mint the
rogue identity at all (stronger than Podman's issuer-side 401).

## 4. Teardown

```bash
deploy/openshift/teardown.sh          # releases, namespaces, CLI state
deploy/openshift/teardown.sh --all    # also CRDs and agent-sandbox-system
```

For a ≤ 8 h cluster, teardown is optional — expiry does it for you.

## Troubleshooting

- **Sandbox stuck in `ConfigurationPending`**: check
  `oc -n zt2-sandboxes get pods` — if the supervisor pod is in
  `ContainerCreating` with `secret "openshell-client-tls" not found`,
  re-run setup (step 2 copies it).
- **Scenario 1 401s at every exchange**: check the issuer logs
  (`oc -n zt-demo logs deploy/token-issuer -c token-issuer`) for
  `SPIRE_JWKS_CA_FILE` messages — the sidecar writes the bundle a few
  seconds after pod start and the issuer retries for 30 s.
- **`Empty reply from server` on 127.0.0.1:18090**: the minter
  port-forward died (issuer rollout); the driver restarts it, but a
  scenario started mid-rollout may fail once — just re-run it.
- **CLI `edge credentials are missing`**: the gateway registration
  lost its mTLS bundle; re-run setup (it re-extracts
  `openshell-client-tls` into `~/.config/openshell/gateways/zt2/mtls/`).
- **`no identity issued` for the gateway SVID** (scenarios 2/6):
  check `oc get clusterspiffeid` — `spire-spire-zt2-gateway` must show
  `podEntryRenderFailures: 0`; a non-zero count means the
  spiffeIDTemplate is invalid.
