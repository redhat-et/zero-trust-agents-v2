package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/redhat-et/zero-trust-agents-v2/internal/config"
	"github.com/redhat-et/zero-trust-agents-v2/internal/tokens"
)

const secret = "test-secret"

func newTestConfig(t *testing.T) *config.Config {
	t.Setenv("ACCESS_TOKEN_SECRET", secret)
	cfg, err := config.Load("../config/users.yaml")
	if err != nil {
		t.Fatal(err)
	}
	cfg.TokenIssuer = "http://token-issuer.zt-demo.svc"
	return cfg
}

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := NewServer(newTestConfig(t), nil)
	ts := httptest.NewServer(srv.Handler)
	t.Cleanup(ts.Close)
	return ts
}

func newDemoTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := NewDemoServer(newTestConfig(t), nil)
	ts := httptest.NewServer(srv.Handler)
	t.Cleanup(ts.Close)
	return ts
}

func TestHealthz(t *testing.T) {
	ts := newTestServer(t)
	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
}

func TestSubjectTokenUnknownUser(t *testing.T) {
	ts := newDemoTestServer(t)
	resp, err := http.Get(ts.URL + "/demo-subject-token?user=mallory")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("want 404, got %d", resp.StatusCode)
	}
}

func TestSubjectTokenForAlice(t *testing.T) {
	ts := newDemoTestServer(t)
	resp, err := http.Get(ts.URL + "/demo-subject-token?user=alice")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	var body struct {
		AccessToken string `json:"access_token"`
		TokenType   string `json:"token_type"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.TokenType != "Bearer" || body.ExpiresIn != 1800 {
		t.Fatalf("unexpected envelope: %+v", body)
	}
	claims, err := tokens.Verify(secret, body.AccessToken)
	if err != nil {
		t.Fatalf("minted token does not verify: %v", err)
	}
	if claims.String("sub") != "alice" {
		t.Errorf("sub: %v", claims["sub"])
	}
	if claims.String("demo_token_use") != tokens.UseUserSubject {
		t.Errorf("demo_token_use: %v", claims["demo_token_use"])
	}
	depts := claims.StringSlice("departments")
	if len(depts) != 2 || depts[0] != "engineering" || depts[1] != "finance" {
		t.Errorf("departments: %v", depts)
	}
	if !claims.HasAudience("openshell-gateway") || !claims.HasAudience("account") {
		t.Errorf("aud: %v", claims["aud"])
	}
}

func TestSubjectTokenMissingUserParam(t *testing.T) {
	ts := newDemoTestServer(t)
	resp, err := http.Get(ts.URL + "/demo-subject-token")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", resp.StatusCode)
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body["error"] != "missing_user" {
		t.Errorf("error: %v", body["error"])
	}
}

// The demo-subject-token endpoint mints bearer tokens with no
// authentication, so it must live only on the demo (loopback-published)
// listener — never on the main mux, which the deployment publishes
// beyond loopback for the gateway's authenticated /token calls.
func TestSubjectTokenOnlyOnDemoListener(t *testing.T) {
	mainHandler := NewServer(newTestConfig(t), nil).Handler
	req := httptest.NewRequest(http.MethodGet, "/demo-subject-token?user=alice", nil)
	rec := httptest.NewRecorder()
	mainHandler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("want 404 on the main listener, got %d", rec.Code)
	}

	demoHandler := NewDemoServer(newTestConfig(t), nil).Handler
	req = httptest.NewRequest(http.MethodGet, "/demo-subject-token?user=alice", nil)
	rec = httptest.NewRecorder()
	demoHandler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200 on the demo listener, got %d", rec.Code)
	}
}
