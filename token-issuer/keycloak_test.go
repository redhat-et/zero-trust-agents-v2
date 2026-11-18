package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/redhat-et/zero-trust-agents-v2/internal/tokens"
)

// keycloakToken mints an RS256 token shaped like a Keycloak access
// token: realm issuer, groups claim, human-readable sub.
func keycloakToken(t *testing.T, key *rsa.PrivateKey, kid, iss, sub string, groups []string) string {
	t.Helper()
	hdr, err := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT", "kid": kid})
	if err != nil {
		t.Fatal(err)
	}
	claims := map[string]any{
		"iss":    iss,
		"sub":    sub,
		"groups": groups,
		"scope":  "openid engineering finance",
		"iat":    time.Now().Unix(),
		"exp":    time.Now().Add(30 * time.Minute).Unix(),
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	b64 := base64.RawURLEncoding
	input := b64.EncodeToString(hdr) + "." + b64.EncodeToString(payload)
	digest := sha256.Sum256([]byte(input))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return input + "." + b64.EncodeToString(sig)
}

// keycloakJWKS serves the public half of the signing key.
func keycloakJWKS(t *testing.T, key *rsa.PublicKey, kid string) string {
	t.Helper()
	b64 := base64.RawURLEncoding
	doc := map[string]any{"keys": []map[string]string{{
		"kty": "RSA",
		"kid": kid,
		"alg": "RS256",
		"use": "sig",
		"n":   b64.EncodeToString(key.N.Bytes()),
		"e":   b64.EncodeToString([]byte{1, 0, 1}),
	}}}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(raw)
	}))
	t.Cleanup(ts.Close)
	return ts.URL
}

func keycloakTestServer(t *testing.T, issuer, jwksURL string) *server {
	t.Helper()
	cfg := newTestConfig(t)
	cfg.SubjectTokenIssuer = issuer
	cfg.SubjectTokenJWKSURL = jwksURL
	return newServer(cfg, nil, testIssuerSigner)
}

func TestVerifySubjectAcceptsConfiguredIssuer(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	const iss = "http://keycloak.zt-demo.svc:8080/realms/zt"
	s := keycloakTestServer(t, iss, keycloakJWKS(t, &key.PublicKey, "kc-1"))
	tok := keycloakToken(t, key, "kc-1", iss, "alice", []string{"engineering"})
	claims, err := s.verifySubject(tok)
	if err != nil {
		t.Fatal(err)
	}
	if claims.String("sub") != "alice" {
		t.Fatalf("sub: %v", claims["sub"])
	}
	if got := claims.StringSlice("groups"); len(got) != 1 || got[0] != "engineering" {
		t.Fatalf("groups: %v", got)
	}
}

func TestVerifySubjectRejectsForeignIssuer(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	const iss = "http://keycloak.zt-demo.svc:8080/realms/zt"
	s := keycloakTestServer(t, iss, keycloakJWKS(t, &key.PublicKey, "kc-1"))
	tok := keycloakToken(t, key, "kc-1", "http://evil.example/realms/zt", "alice", []string{"engineering"})
	if _, err := s.verifySubject(tok); err == nil {
		t.Fatal("want error for a token from another issuer")
	}
}

func TestVerifySubjectFallsBackToLocalSigner(t *testing.T) {
	cfg := newTestConfig(t)
	s := newServer(cfg, nil, testIssuerSigner)
	tok, err := testIssuerSigner.Sign(tokens.Claims{
		"iss":            "http://token-issuer.zt-demo.svc",
		"sub":            "alice",
		"demo_token_use": tokens.UseUserSubject,
		"scope":          "openid profile email",
		"exp":            time.Now().Add(time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	claims, err := s.verifySubject(tok)
	if err != nil {
		t.Fatal(err)
	}
	if claims.String("sub") != "alice" {
		t.Fatalf("sub: %v", claims["sub"])
	}
}

func TestFinalTokenUsesGroupsClaim(t *testing.T) {
	cfg := newTestConfig(t)
	s := newServer(cfg, nil, testIssuerSigner)
	claims := tokens.Claims{
		"sub":    "stranger", // deliberately absent from users.yaml
		"aud":    []any{"supervisor-svid"},
		"scope":  "openid engineering",
		"groups": []any{"engineering"},
	}
	req := httptest.NewRequest(http.MethodPost, "/token", nil)
	req.Form = url.Values{"audience": {"engineering"}, "scope": {"engineering"}}
	rec := httptest.NewRecorder()
	s.handleSupervisorExchange(rec, req, claims, tokens.Claims{"sub": "supervisor-svid"})
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	tok, _ := body["access_token"].(string)
	final, err := testIssuerSigner.Verify(tok)
	if err != nil {
		t.Fatal(err)
	}
	if final.String("scope") != "engineering" {
		t.Fatalf("scope must be the groups intersection, got %q", final.String("scope"))
	}
	if final.String("sub") != "stranger" {
		t.Fatalf("sub: %v", final["sub"])
	}
}

func TestGroupsClaimCannotExceedItself(t *testing.T) {
	cfg := newTestConfig(t)
	s := newServer(cfg, nil, testIssuerSigner)
	claims := tokens.Claims{
		"sub":    "stranger",
		"aud":    []any{"supervisor-svid"},
		"scope":  "openid engineering",
		"groups": []any{"engineering"},
	}
	req := httptest.NewRequest(http.MethodPost, "/token", nil)
	req.Form = url.Values{"audience": {"hr"}, "scope": {"hr"}}
	rec := httptest.NewRecorder()
	s.handleSupervisorExchange(rec, req, claims, tokens.Claims{"sub": "supervisor-svid"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestIsUserSubject(t *testing.T) {
	const iss = "http://keycloak.zt-demo.svc:8080/realms/zt"
	cfg := newTestConfig(t)
	cfg.SubjectTokenIssuer = iss
	s := newServer(cfg, nil, testIssuerSigner)
	cases := []struct {
		name   string
		claims tokens.Claims
		want   bool
	}{
		{"keycloak token", tokens.Claims{"iss": iss}, true},
		{"local user token", tokens.Claims{"demo_token_use": tokens.UseUserSubject}, true},
		{"local intermediate", tokens.Claims{"demo_token_use": tokens.UseIntermediate}, false},
		{"foreign issuer", tokens.Claims{"iss": "http://evil.example"}, false},
	}
	for _, tc := range cases {
		if got := s.isUserSubject(tc.claims); got != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}
