# Stage 2 on-cluster verification findings

Date: 2026-10-30, cluster: ROSA 4.22.20 (temporary, ≤ 8 h)

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
  top-level TOML table and crash-loops the gateway). Verified rendered
  config: `provider_spiffe_workload_api_socket_path`, sandboxes in
  `zt2-sandboxes`, CSI volume on the gateway pod.
- The gateway's cert (pkiInitJob) correctly includes the Route host in
  its SAN when `pkiInitJob.serverDnsNames[0]` is set at install time;
  TLS passthrough through the OpenShift Route works (verified with
  openssl through the Route).
- CLI registration of a remote mTLS gateway:
  `openshell gateway add https://<route> --name zt2 --local` selects
  the mTLS registration type (a plain https add assumes browser edge
  auth, unusable from scripts), then the `openshell-client-tls` secret
  must be extracted into
  `~/.config/openshell/gateways/zt2/mtls/{ca.crt,tls.crt,tls.key}` —
  `gateway add --local` generates throwaway local certs that must be
  overwritten. Result: `Authentication: Authenticated (mTLS
  transport)`.
- zt-demo services: all six pods Running (issuer 2/2 with the
  spiffe-helper sidecar). Private quay.io images pull correctly once
  the `zt2-quay` pull secret is linked to the default service account
  (`oc secrets link default zt2-quay --for=pull`) — the secret alone
  is not enough; pods do not carry `imagePullSecrets`.
- Profiles import and the subject-token smoke test pass through the
  port-forwarded `:8090` listener.
- setup.sh is idempotent: it was re-run ~6 times against the live
  cluster (chart upgrades converge, stale-profile chain clears
  previous runs).

## Route health check

The gateway serves gRPC on 8080 and health on 8081; the Route forwards
to the gRPC port. A health check through the Route therefore uses
`curl -ksS` (chart CA is self-signed) and treats any HTTP response
(the gRPC 404) as reachable.

## Not yet verified (blocked, see below)

- The six scenarios end-to-end on OpenShift.
- The trust-tier separation check (a sandbox-namespace helper pod must
  NOT obtain a gateway-prefix SVID).
- Wall-clock timing from a truly empty cluster (the successful path
  was reached iteratively; a fresh `spire`-clean cluster run should be
  measured).

## Environment anomaly (local, not cluster)

Scenario execution from the Claude Code Bash tool fails at
`scripts/lib.sh`'s driver-file existence check: `[[ -f
…/lib-openshift.sh ]]` intermittently returns false for bash processes
spawned by the tool, while `ls`, `git`, python, and `/usr/bin/stat` see
the file; a literal path in the command text works while the identical
string built at runtime fails, byte-for-byte equal. Reproduces on a
fresh `git archive` copy in /tmp, so it is not repo corruption; it is
an artifact of the tool's command-execution layer on this machine.
Running the scripts from a real terminal is unaffected as far as can
be determined without one. If the scenarios fail the same way from a
user terminal, that would falsify this diagnosis — treat it as a
code bug then.
