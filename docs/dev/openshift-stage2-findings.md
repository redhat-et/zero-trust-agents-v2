# Stage 2 on-cluster verification findings

Date: 2026-10-30, cluster: ROSA 4.22.20 (temporary, ≤ 8 h)

## Result

**All six scenarios pass on OpenShift** (`ZT2_DRIVER=openshift
scripts/scenario{1..6}.sh`), and the trust-tier separation is verified:
a pod in `zt2-sandboxes` requesting a gateway-prefix SPIFFE ID
(`spiffe://openshell.local/ns/openshell/sa/openshell`) is refused
("no identity issued") — the over-match the namespace split exists to
prevent is closed. Scenario 5 passes via the stronger path: SPIRE's
attestation policy refuses to mint the rogue identity at all, so
nothing is even presented to the issuer.

Setup wall-clock once images are cached and charts installed: ~1-4 min
per idempotent re-run. A from-empty-cluster run was not cleanly timed
(the working state was reached iteratively); measure it on the next
fresh cluster.

**Correction (2026-10-30, PR review):** the `default` fallback
identity was NOT actually disabled during the run above — its values
override sat one level too high in
`deploy/openshift/spire/values.yaml` (next to `clusterSPIFFEIDs`,
not inside it), so chart 0.29.0 silently ignored it and
`spire-spire-default` (fallback) still covered `openshell`. The
zt2-sandboxes refusal recorded above holds either way (it tests the
wrong-namespace direction, not the fallback), but the openshell-ns
claim ("an arbitrary openshell-ns pod gets no identity") was untested.
The override now sits inside `clusterSPIFFEIDs`
(`helm template … | grep -c 'fallback: true'` returns 0). Re-verified
on a fresh cluster 2026-10-30 (setup wall-clock 4:03 from empty):
`oc get clusterspiffeid` does not list `spire-spire-default`, and a
throwaway SVID-fetch pod in `openshell` (default SA, no gateway
labels) is refused with "no identity issued".

## What was verified

- SPIFFE hardened charts (spire v0.29.0, spire-crds v0.5.0) install
  cleanly on ROSA **once the namespaces carry the OpenShift pod-security
  labels**: the CSI driver DaemonSet needs `privileged`, and the OIDC
  discovery provider (CSI socket mount) does too on the server
  namespace. `setup.sh` pre-creates `spire`/`spire-system` with
  `pod-security.kubernetes.io/enforce=privileged` and
  `security.openshift.io/scc.podSecurityLabelSync=false`; the chart is
  configured with `namespaces.create=false` so Helm never fights over
  namespace ownership. No SCC exceptions beyond the CSI driver
  DaemonSet's privileged requirement (chart-managed).
- The chart's `global.openshift: true` + `recommendations.enabled:
  true` are the intended OpenShift path; `caSubject` is then required.
- OpenShell chart v0.1.6: `server.providerTokenGrants.spiffe.enabled`
  is the correct values path for the Workload API socket (NOT
  `gatewayConfig.providerTokenGrants` — that renders an invalid
  top-level TOML table and crash-loops the gateway).
- The gateway's cert (pkiInitJob) includes the Route host in its SAN
  when `pkiInitJob.serverDnsNames[0]` is set at install time; TLS
  passthrough through the OpenShift Route works.
- CLI registration of a remote mTLS gateway:
  `openshell gateway add https://<route> --name zt2 --local` selects
  the mTLS registration type (a plain https add assumes browser edge
  auth, unusable from scripts), then the `openshell-client-tls` secret
  must be extracted into
  `~/.config/openshell/gateways/zt2/mtls/{ca.crt,tls.crt,tls.key}` —
  `gateway add --local` generates throwaway local certs that must be
  overwritten.
- **Supervisor pods mount the `openshell-client-tls` secret**: with
  sandboxes in their own namespace, that secret must be copied from
  `openshell` to `zt2-sandboxes` (setup.sh does this). Without it,
  supervisors stay in `ContainerCreating` and sandboxes hang in
  `ConfigurationPending` until the 300 s admission timeout.
- Private quay.io images pull once the `zt2-quay` pull secret is
  linked to the default service account (`oc secrets link default
  zt2-quay --for=pull`); the secret alone is not enough.
- Endpoint hosts in profiles must be **full FQDNs**
  (`document-<dept>.zt-demo.svc.cluster.local`): the sandbox's DNS
  proxy returns NXDOMAIN for the short `.svc` form (no search domains
  in the sandbox resolver), while the gateway and supervisors resolve
  short forms fine — which is why the token-issuer URLs can stay
  short.
- The `zt-demo` NetworkPolicy must allow ingress from **both**
  `zt2-sandboxes` (supervisors → document services) and `openshell`
  (the gateway's token-grant path calls the issuer).
- The issuer's `spiffe-helper` sidecar writes the trust bundle a few
  seconds after pod start; the issuer retries `SPIRE_JWKS_CA_FILE` for
  30 s (TDD: `TestJWKSCACertFileAppearsLate`) instead of disabling
  TLS verification at startup.

## SVID helper mechanics (scenarios 2, 5, 6)

The spire-controller-manager mints **per-pod-UID** entries for
ClusterSPIFFEIDs:

- Supervisor SVIDs: a helper pod in `zt2-sandboxes` carrying the
  sandbox-id annotation AND the `openshell.ai/managed-by: openshell`
  label gets its own entry — after the controller's reconciliation
  interval. The helper therefore runs a busybox `sleep 15` init
  container before the (distroless) spire-agent fetch, which IS the
  container command; the driver reads the token from `oc logs`.
- Gateway SVID: an `oc debug` ephemeral container on the gateway pod
  does NOT work — the agent's container locator cannot reliably
  attribute ephemeral containers (flaky DeadlineExceeded /
  no-identity errors). Instead a helper pod in `openshell` running AS
  the gateway's ServiceAccount gets the SA-based identity. This needs
  the RBAC to create pods in `openshell` and use its service account —
  the same trust an ephemeral debug container needs, and nothing a
  sandbox holds.

## Operational notes

- Port-forwards die when their target deployment rolls (issuer
  restarts kill the minter forward). The driver restarts a dead
  minter forward; `ensure_forward` owns the issuer/doc-service
  forwards with PID files.
- `state_set` had a shell-precedence bug (`grep … || true > tmp`
  redirected the fallback, wiping the state file on every call) —
  fixed with a grouped redirect.
- An earlier "environment anomaly" diagnosis in this file was wrong:
  the intermittent `[[ -f … ]]` failures were a typo
  (`ZT2_DRIVER=openshell` vs `openshift`) in my own commands and docs,
  since fixed everywhere.
