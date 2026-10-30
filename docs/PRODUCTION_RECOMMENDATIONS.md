# Production recommendations

What the OpenShift demo deployment (`deploy/openshift/`) would change
for a real deployment. The demo is a reference architecture; these are
the deltas between it and production, and the reasoning.

## Trust domain

The demo uses `openshell.local`, inherited from Stage 1 to keep the
two deployments comparable. Production should use a domain the
organization controls (`spiffe://<company>.example`), planned once for
all clusters — cross-cluster federation and bundle rotation both get
harder to retrofit than to plan.

## One namespace per trust tier

The issuer authorizes the gateway by a *prefix* match on
`spiffe://…/ns/openshell/sa/`. That is only safe if the
`ClusterSPIFFEID` that mints identities under the prefix matches
exactly the pods that should hold it. The deployment therefore keeps:

- `zt2-sandboxes` — sandbox pods only (annotation-keyed SVIDs),
- `openshell` — the gateway (SA-based SVID, pod-selector-tightened to
  the gateway's own labels),
- `zt-demo` — the protected services.

Two hardening steps for production:

1. Replace the prefix check with the exact gateway SPIFFE ID
   (`spiffe://…/ns/openshell/sa/openshell`) or a small allowlist.
1. Give each user (or team) their own sandbox namespace and reflect
   that in the policy, rather than one shared `zt2-sandboxes`. The
   `ClusterSPIFFEID` namespaceSelector makes this a label change.

The generic `/ns/<ns>/sa/<sa>` chart default (the `fallback` identity)
is safe only in namespaces with a single trust tier; the deployment
excludes the `openshell` namespace from it and covers `zt-demo` with
an explicit identity instead. The real boundary is namespace
membership: whoever can create pods in `openshell`, or use its service
accounts, can obtain a gateway-prefix SVID — treat that namespace as
cluster-admin territory and gate it with RBAC accordingly.

## Secrets

The demo mints HS256 tokens with a shared `ACCESS_TOKEN_SECRET` (the
upstream demo pattern). Production should use asymmetric signing
(RS256/ES256): the document services then verify with the issuer's
public key and never hold signing material. The gateway's JWT signing
keys and SPIRE's CA should be persisted and rotated — on a
throwaway cluster they are ephemeral, which is fine for a demo and
wrong for production.

## Human identity: any IdP

No IdP is deployed. The issuer's `/demo-subject-token` endpoint is a
stand-in for yours: the subject token is an OAuth2 access token
presented at the RFC 8693 exchange (`subject_token_type:
urn:ietf:params:oauth:token-type:access_token`), so Keycloak, Entra
ID, Okta, or anything else that issues such a token plugs in at that
boundary. A real integration verifies subject tokens against the
customer's OIDC discovery endpoint (RS256/ES256 via their JWKS). The
agent-identity side already demonstrates exactly this pattern — the
issuer verifies SPIFFE JWT-SVIDs against SPIRE's JWKS over TLS — so
the extension is symmetric, not novel.

## NetworkPolicy

The demo's `zt-demo` policy allows ingress from the whole
`zt2-sandboxes` namespace. Production should narrow the `from` block
to supervisor pods (pod selector on the sandbox labels), and add the
same default-deny stance to the issuer. Egress policies for sandbox
namespaces (allow only the gateway and approved upstreams) are the
OpenShell NetworkPolicy's job; verify the CNI enforces both
directions — OVN-Kubernetes does.

## SPIRE on OpenShift

The SPIFFE hardened charts run without SCC exceptions apart from the
CSI driver's DaemonSet, which needs `privileged` (standard for node
CSI drivers; the chart labels its namespaces accordingly). See
`docs/dev/openshift-stage2-findings.md` for what was observed
on-cluster.

## What to monitor

- SPIRE agent health and SVID issuance rates (identity is the root of
  trust here — an agent outage is a token outage).
- The issuer's 401/403 rates by cause (`invalid_client_assertion`,
  `insufficient_department_permissions`, `invalid_audience`): each is
  an attack or a misconfiguration being correctly refused.
- Gateway token-grant failures (`Token grant failed` in supervisor
  logs) — scenario 3 shows what a healthy deny looks like.
