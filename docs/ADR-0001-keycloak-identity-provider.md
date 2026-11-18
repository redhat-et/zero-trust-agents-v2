# ADR-0001: Keycloak as the identity provider for the OpenShift demo

- Status: accepted
- Date: 2026-11-18
- Supersedes: the "Keycloak does the exchange" part of the
  `2026-11-13` Keycloak integration design

## Context

The 2026-11-13 customer delivery made Keycloak the headline follow-up.
The demo asked the customer to accept a custom token issuer as a key
element of the security story, and the honest answer to "will you
support it?" was no. v1 had already proved a Keycloak integration.

The original design chose approach C: Keycloak performs both RFC 8693
hops natively, with a SPIFFE identity provider and `federated-jwt`
client authentication from the per-sandbox SVIDs. On 2026-11-18 the
implementation and a live Phase 0 run found that this flow cannot work
as designed.

### Why the native exchange was rejected

Keycloak does not let the `audience` parameter add an audience.
Audiences are produced by the **requesting client's role-mapped client
scopes**, and audience filtering removes client-role mappings that do
not belong to a requested audience. The first hop issues the
intermediate token for the sandbox, so the department role mapping is
filtered out of it; the second hop cannot resolve the document-service
audience and returns `Requested audience not available`.

Requesting both audiences at the first hop would carry the role
through, but the harness (OpenShell's provider profile) expresses a
single `audience`. That is a flow redesign, not a configuration fix.

Evidence: `docs/dev/2026-11-18-keycloak-phase0-findings.md`.

## Decision

Keycloak is the **identity provider**; the existing token issuer remains
the **exchange engine**.

- Keycloak issues the user subject token by password grant against a
  per-user login client (`login-alice`, `login-bob`, `login-carol`).
  The token carries a fixed human-readable `sub`, the verified `groups`
  claim, and the user's department scopes.
- The token issuer verifies that token against the realm JWKS (RS256),
  re-checks its `iss`, and derives the department intersection from the
  verified `groups` claim, which it carries into the intermediate token.
  Only access tokens issued to a `login-*` client are accepted, so
  service-account and ID tokens cannot start a user flow. Its SVID
  verification, two-hop exchange, scope intersection, and access-token
  JWKS are unchanged.
- Podman keeps `/demo-subject-token`; only the user-attribute rename
  (`departments` → `groups`) crosses both drivers.

## Consequences

- The demo answers "does it integrate with Keycloak?" with Keycloak as
  the IdP and a reproducible realm. Goals 1 and 3 of the original design
  are met; goal 4 (no custom component in the exchange path) is not.
  The exchange remains a small, standard-contract STS.
- The issuer gains a second verification path. It accepts ES256 from the
  demo minter and RS256 from Keycloak, routed by the unverified `iss` and
  re-checked after signature verification.
- The realm export, the pinned image, and `setup-keycloak.sh` make the
  identity plane reproducible on a temporary cluster.
- The optional SPIFFE identity provider and SVID client authentication
  remain in the Keycloak realm as a demonstrated capability; they are
  not on the demo path.

### CVE-2026-114938 (Java4Shell)

Every Keycloak image currently available bundles an affected OpenJDK.
The deployment sets `JAVA_OPTS_APPEND=-XX:-UseBASE64Intrinsics`, and
`verify-keycloak.sh` fails setup unless the running JVM reports
`UseBASE64Intrinsics = false`. The test cluster exposes `avx512vbmi`, so
the condition is live. Revisit when a fixed image ships; the image is
pinned by amd64 digest, not by a bare tag.

## Alternatives considered

1. **Native Keycloak exchange with requester-side resolver scopes.**
   First hop works; the role-filtering rule blocks the second hop.
   Rejected after live testing.
2. **Static per-profile audiences.** Loses the per-sandbox SVID binding:
   one client per profile cannot authenticate many sandbox SVIDs.
   Rejected.
3. **Parameterized scopes.** Preview feature; does not address the
   filtering rule. Future research.
4. **Keep the stand-in IdP.** No longer acceptable after the customer
   asked for Keycloak.

## Operations

```bash
deploy/openshift/keycloak/setup-keycloak.sh           # idempotent
deploy/openshift/keycloak/setup-keycloak.sh --reset   # re-import realm
deploy/openshift/keycloak/verify-keycloak.sh          # CVE + login checks
```

Realm import is one-shot: a changed export needs `--reset` on a
temporary cluster. `verify-spiffe-auth.sh` exercises the optional SPIFFE
client-authentication path.

## Follow-ups

- Time-boxed spike: can OpenShell's token grant request the sandbox and
  the service audience together? If yes, the native exchange is back on
  the table.
- Run the A2A scenarios 11–15 and the Podman suite with the hybrid
  (blocked in the 2026-11-18 session by missing model credentials and no
  Podman stack).
