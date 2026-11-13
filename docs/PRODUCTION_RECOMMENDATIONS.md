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
2. Give each user (or team) their own sandbox namespace and reflect
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

Access tokens are ES256-signed. The issuer holds the private key — a
Kubernetes Secret on OpenShift, a `0600` file under the state directory
on Podman — and the document services verify through
`/.well-known/jwks.json` without ever holding signing material. The
demo fetches that JWKS over plain HTTP; production must serve it over
TLS and pin the CA, because the key set is the only trust anchor for
access tokens. The demo does not rotate the key: a production design
would use a KMS and publish overlapping keys during rotation. The
gateway's JWT signing keys and SPIRE's CA should be persisted and
rotated — on a throwaway cluster they are ephemeral, which is fine for
a demo and wrong for production.

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

## Replacing the token issuer

The issuer is a demo implementation of a small, standard contract. The
provider profile's `token_grant` block names the token endpoint, the SVID
audience, the assertion type, and the subject token source, so repointing
that block moves the exchange to a different STS. Repointing it is not the
whole change: resource servers verify access tokens against the issuer's
`/.well-known/jwks.json` (see "Secrets" above), so a replacement STS must
publish its signing keys there, and every service must be pointed at that
JWKS before it will accept the new tokens. Plan both halves together.

### What a replacement must preserve

- `POST /token` accepting the RFC 8693 grant type
  `urn:ietf:params:oauth:grant-type:token-exchange`.
- Client authentication from `client_assertion` with type
  `urn:ietf:params:oauth:client-assertion-type:jwt-spiffe` (RFC 7523 private
  key JWT), verified against SPIRE's JWKS over TLS: signature, `alg`, `exp`
  and `nbf`, `iss` equal to SPIRE's OIDC issuer, `aud` containing the
  profile's `jwt_svid_audience`, and a `sub` this deployment trusts.
- The two-step exchange: the gateway trades the user subject token for an
  intermediate token bound to one supervisor's SPIFFE ID, and the supervisor
  trades that for the final scoped token.
- A final `scope` equal to the intersection of the user's real entitlements
  and the requested scope, never the requested scope on its own.
- `azp` and `client_id` set to the caller's SPIFFE ID, so every minted token
  is attributable to the workload that requested it.
- `/.well-known/jwks.json`, so resource servers verify access tokens without
  holding signing material.
- The same `iss` value, or an update to every service that pins it. The
  engineering-analyst agent compares its configured `issuer` against the
  token's `iss` and rejects any mismatch as `invalid_issuer`
  (`agents/engineering-analyst/agent-config.yaml.in`), so a replacement STS
  with a different issuer value needs those values updated in the same
  migration as the JWKS change. Trusting the new keys does not make a pinned
  issuer accept them.
- Distinct error codes: `invalid_client_assertion`,
  `insufficient_department_permissions`, `invalid_subject_token`,
  `unsupported_grant_type`. Monitoring depends on telling these causes apart.

### Demo-only pieces to replace

- The `demo_token_use` claim, a branch flag that exists only because one
  issuer plays both the gateway and supervisor roles. Use two endpoints or
  two client registrations.
- The `/demo-subject-token` endpoint, a stand-in for the customer's IdP.
- The user-to-department map in `internal/config/config.go`. Use IdP group
  claims or a policy engine.
- Prefix matching on SPIFFE IDs. Use the exact gateway identity or an
  allowlist, as described above.
- Plain-HTTP JWKS and a static signing key. Use TLS with CA pinning, and a
  KMS-backed key with overlapping rotation.

### Implementation options

1. Extend this issuer. It is Go with minimal dependencies, and its tests are
   the executable form of the contract in this section.
2. Use Keycloak token exchange with a custom `ClientAuthenticator` SPI. The
   `jwt-spiffe` assertion type is not native, so SVID verification is code to
   write rather than configuration to enable. Validate this path before
   committing to it.
3. Put a thin STS in front of the customer's IdP. It verifies workload
   identity and delegates attribute lookup to the identity system that
   already governs entitlements.

The two-hop exchange is a design choice, not a requirement. A single
exchange from the user token plus the supervisor SVID to the final token
would also work, but then the gateway handles the user token on every
request path. The two-hop shape is what confines that token to one hop.

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

## Agent-to-agent delegation (roadmap)

Today an agent that calls another agent authenticates as **itself**: the
calling sandbox's supervisor mints a final token with an agent audience,
and the receiving agent fetches its own downstream documents with **its
own** provider profile. The caller's token never travels further than
the first hop.

The target design is request-bound delegation. B's supervisor would use
the incoming token as `subject_token` and its own SVID as the actor,
producing a nested `act` claim chain where scope can only narrow at each
hop — the model the v1 demo used with OPA. That needs an OpenShell
feature (a supervisor that can exchange an inbound token rather than
only its own), and is a candidate upstream proposal.

A second roadmap item: wrapping mainstream agents (Codex, Pi, OpenClaw)
with an A2A adapter that reuses DocsClaw's `pkg/inboundauth`. The point
of the demo is that the security model does not depend on the agent —
verification sits at the network boundary, not in the agent's prompt.

## What to monitor

- SPIRE agent health and SVID issuance rates (identity is the root of
  trust here — an agent outage is a token outage).
- The issuer's 401/403 rates by cause (`invalid_client_assertion`,
  `insufficient_department_permissions`, `invalid_audience`): each is
  an attack or a misconfiguration being correctly refused.
- Gateway token-grant failures (`Token grant failed` in supervisor
  logs) — scenario 3 shows what a healthy deny looks like.
