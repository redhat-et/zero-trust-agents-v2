package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/redhat-et/zero-trust-agents-v2/internal/tokens"
)

const docSecret = "doc-test-secret"
const docIssuer = "http://token-issuer.zt-demo.svc"

func finalToken(t *testing.T, user, audience string, scopes ...string) string {
	t.Helper()
	tok, err := tokens.Sign(docSecret, tokens.Claims{
		"iss":            docIssuer,
		"sub":            user,
		"aud":            []string{audience, "account"},
		"scope":          strings.Join(scopes, " "),
		"azp":            "spiffe://openshell.local/openshell/sandbox/abc123",
		"client_id":      "spiffe://openshell.local/openshell/sandbox/abc123",
		"demo_token_use": tokens.UseFinal,
		"iat":            time.Now().Unix(),
		"exp":            time.Now().Add(5 * time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func newDocServer(t *testing.T, department string) *httptest.Server {
	t.Helper()
	srv := NewServer(docSecret, docIssuer, department, Documents(department))
	ts := httptest.NewServer(http.Handler(srv.Handler()))
	t.Cleanup(ts.Close)
	return ts
}

func get(t *testing.T, ts *httptest.Server, path, token string) (int, map[string]any) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, ts.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	var body map[string]any
	// healthz is plain text; JSON endpoints always parse.
	_ = json.NewDecoder(resp.Body).Decode(&body)
	return resp.StatusCode, body
}

func TestHealthz(t *testing.T) {
	ts := newDocServer(t, "engineering")
	status, body := get(t, ts, "/healthz", "")
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
}

func TestListDocumentsHappyPath(t *testing.T) {
	ts := newDocServer(t, "engineering")
	status, body := get(t, ts, "/documents", finalToken(t, "alice", "engineering", "engineering"))
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
	docs, _ := body["documents"].([]any)
	if len(docs) == 0 {
		t.Fatal("want non-empty document list")
	}
	// DOC-001 (engineering) and DOC-005 (finance+engineering) must appear.
	ids := map[string]bool{}
	for _, d := range docs {
		if m, ok := d.(map[string]any); ok {
			ids[m["id"].(string)] = true
		}
	}
	if !ids["DOC-001"] || !ids["DOC-005"] {
		t.Errorf("engineering service must list DOC-001 and DOC-005, got %v", ids)
	}
}

func TestGetDocumentHappyPath(t *testing.T) {
	ts := newDocServer(t, "engineering")
	status, body := get(t, ts, "/documents/DOC-001", finalToken(t, "alice", "engineering", "engineering"))
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
	if body["title"] != "Engineering Roadmap" {
		t.Errorf("title: %v", body["title"])
	}
	if body["content"] == "" {
		t.Error("content must be present")
	}
}

func TestWrongAudience(t *testing.T) {
	// Review focus 4: token scoped for engineering used against the
	// finance service -> 403 with a code distinct from a scope failure,
	// so tests can tell the two controls apart.
	finTS := newDocServer(t, "finance")
	status, body := get(t, finTS, "/documents", finalToken(t, "alice", "engineering", "engineering"))
	if status != http.StatusForbidden {
		t.Fatalf("want 403, got %d: %v", status, body)
	}
	if body["error"] != "invalid_audience" {
		t.Errorf("error: %v", body["error"])
	}
}

func TestInsufficientScope(t *testing.T) {
	// Right audience for finance, wrong scope for DOC-002 (finance-only):
	// the scope control denies, distinct from the audience control.
	finTS := newDocServer(t, "finance")
	status, body := get(t, finTS, "/documents/DOC-002", finalToken(t, "alice", "finance", "engineering"))
	if status != http.StatusForbidden || body["error"] != "insufficient_scope" {
		t.Fatalf("want 403 insufficient_scope, got %d %v", status, body)
	}
}

func TestMultiDepartmentDocEitherScope(t *testing.T) {
	// DOC-005 (finance+engineering): accessible with either scope...
	for _, dept := range []string{"engineering", "finance"} {
		ts := newDocServer(t, dept)
		status, body := get(t, ts, "/documents/DOC-005", finalToken(t, "alice", dept, dept))
		if status != http.StatusOK {
			t.Fatalf("dept %s: want 200, got %d: %v", dept, status, body)
		}
	}
	// ...but an engineering-scoped token against the finance service is
	// an audience failure even though the scope would cover DOC-005.
	finTS := newDocServer(t, "finance")
	status, body := get(t, finTS, "/documents/DOC-005", finalToken(t, "alice", "engineering", "engineering"))
	if status != http.StatusForbidden || body["error"] != "invalid_audience" {
		t.Fatalf("want 403 invalid_audience, got %d %v", status, body)
	}
}

func TestPublicDocumentStillRequiresToken(t *testing.T) {
	pub := newDocServer(t, "public")
	// Missing Authorization header -> 401.
	status, body := get(t, pub, "/documents/DOC-007", "")
	if status != http.StatusUnauthorized || body["error"] != "missing_token" {
		t.Fatalf("want 401 missing_token, got %d %v", status, body)
	}
	// Valid token with no department scope -> 200 for the public doc.
	status, body = get(t, pub, "/documents/DOC-007", finalToken(t, "alice", "public"))
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
	if body["title"] != "All-Hands Summary" {
		t.Errorf("title: %v", body["title"])
	}
}

func TestIntermediateTokenRejected(t *testing.T) {
	ts := newDocServer(t, "engineering")
	tok, err := tokens.Sign(docSecret, tokens.Claims{
		"iss": docIssuer, "sub": "alice", "aud": "engineering",
		"scope": "engineering", "demo_token_use": tokens.UseIntermediate,
		"iat": time.Now().Unix(), "exp": time.Now().Add(time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	status, body := get(t, ts, "/documents", tok)
	if status != http.StatusUnauthorized || body["error"] != "invalid_token" {
		t.Fatalf("want 401 invalid_token, got %d %v", status, body)
	}
}

func TestGarbageTokenRejected(t *testing.T) {
	ts := newDocServer(t, "engineering")
	status, body := get(t, ts, "/documents", "not.a.token")
	if status != http.StatusUnauthorized || body["error"] != "invalid_token" {
		t.Fatalf("want 401 invalid_token, got %d %v", status, body)
	}
}

func TestUnknownDocument(t *testing.T) {
	ts := newDocServer(t, "engineering")
	status, body := get(t, ts, "/documents/DOC-999", finalToken(t, "alice", "engineering", "engineering"))
	if status != http.StatusNotFound {
		t.Fatalf("want 404, got %d: %v", status, body)
	}
}
