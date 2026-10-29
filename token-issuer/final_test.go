package main

import (
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/redhat-et/zero-trust-agents-v2/internal/tokens"
)

func supervisorJWKS() *fakeJWKS {
	return &fakeJWKS{assertions: map[string]string{"supervisor-svid": supervisorSVIDID}}
}

func supervisorForm(intermediate, audience string, scopes ...string) url.Values {
	return url.Values{
		"grant_type":            {tokenExchangeGrant},
		"client_assertion_type": {jwtSpiffeAssertion},
		"client_assertion":      {"supervisor-svid"},
		"subject_token":         {intermediate},
		"audience":              {audience},
		"scope":                 {joinScopes(scopes)},
	}
}

func joinScopes(scopes []string) string {
	out := ""
	for i, s := range scopes {
		if i > 0 {
			out += " "
		}
		out += s
	}
	return out
}

func finalForm(t *testing.T, user, audience string, scopes ...string) url.Values {
	t.Helper()
	return supervisorForm(intermediateToken(t, user, supervisorSVIDID), audience, scopes...)
}

func decodeFinal(t *testing.T, body map[string]any) tokens.Claims {
	t.Helper()
	tok, _ := body["access_token"].(string)
	if tok == "" {
		t.Fatalf("no access_token in %v", body)
	}
	claims, err := tokens.Verify(secret, tok)
	if err != nil {
		t.Fatalf("final token does not verify: %v", err)
	}
	return claims
}

func TestFinalExchangeAliceEngineering(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	status, body := postToken(t, ts, finalForm(t, "alice", "engineering", "engineering"))
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
	claims := decodeFinal(t, body)
	if claims.String("demo_token_use") != tokens.UseFinal {
		t.Errorf("demo_token_use: %v", claims["demo_token_use"])
	}
	if claims.String("sub") != "alice" {
		t.Errorf("sub: %v", claims["sub"])
	}
	if claims.String("azp") != supervisorSVIDID || claims.String("client_id") != supervisorSVIDID {
		t.Errorf("azp/client_id: %v/%v", claims["azp"], claims["client_id"])
	}
	if !claims.HasAudience("engineering") || !claims.HasAudience("account") {
		t.Errorf("aud: %v", claims["aud"])
	}
	if claims.String("scope") != "engineering" {
		t.Errorf("scope must be exactly the intersection, got %q", claims.String("scope"))
	}
}

// Scenario 2, live shape: audience comes from the target host
// (engineering), scope is the sandbox's capability (hr). Alice is not in
// hr, so the intersection is empty.
func TestFinalExchangeScenario2NoIntersection(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	status, body := postToken(t, ts, finalForm(t, "alice", "engineering", "hr"))
	if status != http.StatusForbidden {
		t.Fatalf("want 403, got %d: %v", status, body)
	}
	if body["error"] != "insufficient_department_permissions" {
		t.Errorf("error: %v", body["error"])
	}
}

func TestFinalExchangeBobFinance(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	status, body := postToken(t, ts, finalForm(t, "bob", "finance", "finance"))
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
	if claims := decodeFinal(t, body); claims.String("scope") != "finance" {
		t.Errorf("scope: %q", claims.String("scope"))
	}
}

func TestFinalExchangeCarolHr(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	status, body := postToken(t, ts, finalForm(t, "carol", "hr", "hr"))
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
}

func TestFinalExchangeIntersectionIsSubset(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	// Alice: engineering+finance. Request both engineering and hr:
	// the token must carry only engineering.
	status, body := postToken(t, ts, finalForm(t, "alice", "engineering", "engineering", "hr"))
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
	if claims := decodeFinal(t, body); claims.String("scope") != "engineering" {
		t.Errorf("scope must be intersection only, got %q", claims.String("scope"))
	}
}

func TestFinalExchangeEmptyScope(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	status, body := postToken(t, ts, finalForm(t, "alice", "engineering"))
	if status != http.StatusForbidden || body["error"] != "insufficient_department_permissions" {
		t.Fatalf("want 403 insufficient_department_permissions, got %d %v", status, body)
	}
}

func TestFinalExchangeAudienceMismatch(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	// Intermediate bound to a different supervisor.
	tok := intermediateToken(t, "alice", supervisorPref+"other-sandbox")
	status, body := postToken(t, ts, supervisorForm(tok, "engineering", "engineering"))
	if status != http.StatusForbidden || body["error"] != "intermediate_token_audience_mismatch" {
		t.Fatalf("want 403 intermediate_token_audience_mismatch, got %d %v", status, body)
	}
}

func TestFinalExchangeUnsupportedAudience(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	status, body := postToken(t, ts, finalForm(t, "alice", "legal", "engineering"))
	if status != http.StatusBadRequest || body["error"] != "unsupported_audience" {
		t.Fatalf("want 400 unsupported_audience, got %d %v", status, body)
	}
}

func TestFinalExchangeUnknownUser(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	// A validly signed intermediate for a user not in users.yaml.
	tok, err := tokens.Sign(secret, tokens.Claims{
		"iss": "http://token-issuer.zt-demo.svc", "sub": "mallory",
		"aud": supervisorSVIDID, "demo_token_use": tokens.UseIntermediate,
		"iat": time.Now().Unix(), "exp": time.Now().Add(5 * time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	status, body := postToken(t, ts, supervisorForm(tok, "engineering", "engineering"))
	if status != http.StatusForbidden || body["error"] != "insufficient_department_permissions" {
		t.Fatalf("want 403 for unknown user (no departments), got %d %v", status, body)
	}
}

func TestFinalExchangePublicAudience(t *testing.T) {
	// The public document service is reachable through the token path:
	// a final token with audience=public carries no department scope.
	ts := newExchangeServer(t, supervisorJWKS())
	status, body := postToken(t, ts, finalForm(t, "alice", "public"))
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
	claims := decodeFinal(t, body)
	if !claims.HasAudience("public") {
		t.Errorf("aud: %v", claims["aud"])
	}
	if claims.String("scope") != "" {
		t.Errorf("scope must be empty (no department intersection), got %q", claims.String("scope"))
	}
}

func TestFinalExchangeWrongTokenType(t *testing.T) {
	ts := newExchangeServer(t, supervisorJWKS())
	// Subject token presented where an intermediate is expected.
	status, body := postToken(t, ts, supervisorForm(subjectToken(t, "alice"), "engineering", "engineering"))
	if status != http.StatusUnauthorized || body["error"] != "unsupported_token_use" {
		t.Fatalf("want 401 unsupported_token_use, got %d %v", status, body)
	}
}
