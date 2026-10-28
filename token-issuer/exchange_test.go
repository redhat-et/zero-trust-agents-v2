package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/redhat-et/zero-trust-agents-v2/internal/tokens"
)

// fakeJWKS accepts any assertion whose sub starts with the wanted prefix.
type fakeJWKS struct {
	subByPrefix map[string]string // prefix -> sub to report
	failPrefix  string            // if set, requests with this prefix fail
}

func (f *fakeJWKS) VerifySVID(jwt string, subjectPrefix string) (tokens.Claims, error) {
	if f.failPrefix != "" && subjectPrefix == f.failPrefix {
		return nil, errFakeVerify
	}
	sub, ok := f.subByPrefix[subjectPrefix]
	if !ok {
		return nil, errFakeVerify
	}
	return tokens.Claims{"sub": sub}, nil
}

var errFakeVerify = &verifyError{}

type verifyError struct{}

func (*verifyError) Error() string { return "fake verify failed" }

const (
	gatewaySVIDSub   = gatewayPrefix + "demo"
	supervisorSVIDID = supervisorPref + "abc123"
)

func newExchangeServer(t *testing.T, jwks JWKSVerifier) *httptest.Server {
	t.Helper()
	cfg := newTestConfig(t)
	s := NewServer(cfg, jwks)
	ts := httptest.NewServer(s.Handler)
	t.Cleanup(ts.Close)
	return ts
}

func subjectToken(t *testing.T, user string) string {
	t.Helper()
	tok, err := tokens.Sign(secret, tokens.Claims{
		"iss":            "http://token-issuer.zt-demo.svc",
		"sub":            user,
		"aud":            []string{"openshell-gateway", "account"},
		"scope":          "openid profile email",
		"departments":    []string{"engineering", "finance"},
		"demo_token_use": tokens.UseUserSubject,
		"iat":            time.Now().Unix(),
		"exp":            time.Now().Add(30 * time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func intermediateToken(t *testing.T, user string, aud string) string {
	t.Helper()
	tok, err := tokens.Sign(secret, tokens.Claims{
		"iss":            "http://token-issuer.zt-demo.svc",
		"sub":            user,
		"aud":            aud,
		"scope":          "openid profile email",
		"azp":            gatewaySVIDSub,
		"client_id":      gatewaySVIDSub,
		"demo_token_use": tokens.UseIntermediate,
		"iat":            time.Now().Unix(),
		"exp":            time.Now().Add(5 * time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func postToken(t *testing.T, ts *httptest.Server, form url.Values) (int, map[string]any) {
	t.Helper()
	resp, err := http.Post(ts.URL+"/token", "application/x-www-form-urlencoded", strings.NewReader(form.Encode()))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return resp.StatusCode, body
}

const (
	tokenExchangeGrant = "urn:ietf:params:oauth:grant-type:token-exchange"
	jwtSpiffeAssertion = "urn:ietf:params:oauth:client-assertion-type:jwt-spiffe"
)

func gatewayForm(subjectTok, audience string) url.Values {
	return url.Values{
		"grant_type":            {tokenExchangeGrant},
		"client_assertion_type": {jwtSpiffeAssertion},
		"client_assertion":      {"svid"},
		"subject_token":         {subjectTok},
		"audience":              {audience},
	}
}

func TestIntermediateExchangeHappyPath(t *testing.T) {
	jwks := &fakeJWKS{subByPrefix: map[string]string{gatewayPrefix: gatewaySVIDSub}}
	ts := newExchangeServer(t, jwks)
	status, body := postToken(t, ts, gatewayForm(subjectToken(t, "alice"), supervisorSVIDID))
	if status != http.StatusOK {
		t.Fatalf("want 200, got %d: %v", status, body)
	}
	tok, _ := body["access_token"].(string)
	if tok == "" {
		t.Fatal("no access_token")
	}
	claims, err := tokens.Verify(secret, tok)
	if err != nil {
		t.Fatalf("intermediate does not verify: %v", err)
	}
	if claims.String("sub") != "alice" {
		t.Errorf("sub: %v", claims["sub"])
	}
	if claims.String("demo_token_use") != tokens.UseIntermediate {
		t.Errorf("demo_token_use: %v", claims["demo_token_use"])
	}
	if claims.String("azp") != gatewaySVIDSub || claims.String("client_id") != gatewaySVIDSub {
		t.Errorf("azp/client_id: %v/%v", claims["azp"], claims["client_id"])
	}
	if !claims.HasAudience(supervisorSVIDID) {
		t.Errorf("aud: %v", claims["aud"])
	}
}

func TestIntermediateExchangeInvalidSubjectToken(t *testing.T) {
	jwks := &fakeJWKS{subByPrefix: map[string]string{gatewayPrefix: gatewaySVIDSub}}
	ts := newExchangeServer(t, jwks)
	status, body := postToken(t, ts, gatewayForm("garbage.token.here", supervisorSVIDID))
	if status != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d: %v", status, body)
	}
	if body["error"] != "invalid_subject_token" {
		t.Errorf("error: %v", body["error"])
	}
}

func TestIntermediateExchangeExpiredSubjectToken(t *testing.T) {
	jwks := &fakeJWKS{subByPrefix: map[string]string{gatewayPrefix: gatewaySVIDSub}}
	ts := newExchangeServer(t, jwks)
	tok, err := tokens.Sign(secret, tokens.Claims{
		"iss": "http://token-issuer.zt-demo.svc", "sub": "alice",
		"demo_token_use": tokens.UseUserSubject,
		"iat":            time.Now().Add(-time.Hour).Unix(),
		"exp":            time.Now().Add(-time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	status, body := postToken(t, ts, gatewayForm(tok, supervisorSVIDID))
	if status != http.StatusUnauthorized || body["error"] != "invalid_subject_token" {
		t.Fatalf("want 401 invalid_subject_token, got %d %v", status, body)
	}
}

func TestIntermediateExchangeWrongTokenType(t *testing.T) {
	jwks := &fakeJWKS{subByPrefix: map[string]string{gatewayPrefix: gatewaySVIDSub}}
	ts := newExchangeServer(t, jwks)
	// An intermediate presented where a subject token is expected.
	status, body := postToken(t, ts, gatewayForm(intermediateToken(t, "alice", supervisorSVIDID), supervisorSVIDID))
	if status != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d: %v", status, body)
	}
	if body["error"] != "unsupported_token_use" {
		t.Errorf("error: %v", body["error"])
	}
}

func TestIntermediateExchangeUnknownTokenUse(t *testing.T) {
	jwks := &fakeJWKS{subByPrefix: map[string]string{gatewayPrefix: gatewaySVIDSub}}
	ts := newExchangeServer(t, jwks)
	tok, err := tokens.Sign(secret, tokens.Claims{
		"iss": "http://token-issuer.zt-demo.svc", "sub": "alice",
		"demo_token_use": "banana",
		"exp":            time.Now().Add(time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	status, body := postToken(t, ts, gatewayForm(tok, supervisorSVIDID))
	if status != http.StatusUnauthorized || body["error"] != "unsupported_token_use" {
		t.Fatalf("want 401 unsupported_token_use, got %d %v", status, body)
	}
}

func TestIntermediateExchangeInvalidClientAssertion(t *testing.T) {
	jwks := &fakeJWKS{subByPrefix: map[string]string{gatewayPrefix: gatewaySVIDSub}, failPrefix: gatewayPrefix}
	ts := newExchangeServer(t, jwks)
	status, body := postToken(t, ts, gatewayForm(subjectToken(t, "alice"), supervisorSVIDID))
	if status != http.StatusUnauthorized || body["error"] != "invalid_client_assertion" {
		t.Fatalf("want 401 invalid_client_assertion, got %d %v", status, body)
	}
}

func TestIntermediateExchangeUnsupportedAudience(t *testing.T) {
	jwks := &fakeJWKS{subByPrefix: map[string]string{gatewayPrefix: gatewaySVIDSub}}
	ts := newExchangeServer(t, jwks)
	status, body := postToken(t, ts, gatewayForm(subjectToken(t, "alice"), "http://not-a-supervisor"))
	if status != http.StatusBadRequest || body["error"] != "unsupported_intermediate_audience" {
		t.Fatalf("want 400 unsupported_intermediate_audience, got %d %v", status, body)
	}
}

func TestTokenEndpointValidation(t *testing.T) {
	jwks := &fakeJWKS{subByPrefix: map[string]string{gatewayPrefix: gatewaySVIDSub}}
	ts := newExchangeServer(t, jwks)

	cases := []struct {
		name   string
		form   url.Values
		status int
		errMsg string
	}{
		{"wrong grant_type", url.Values{"grant_type": {"password"}}, 400, "unsupported_grant_type"},
		{"wrong assertion type", url.Values{
			"grant_type": {tokenExchangeGrant}, "client_assertion_type": {"other"},
		}, 400, "unsupported_client_assertion_type"},
		{"missing assertion", url.Values{
			"grant_type": {tokenExchangeGrant}, "client_assertion_type": {jwtSpiffeAssertion},
		}, 400, "missing_client_assertion"},
		{"missing subject token", url.Values{
			"grant_type": {tokenExchangeGrant}, "client_assertion_type": {jwtSpiffeAssertion},
			"client_assertion": {"svid"},
		}, 400, "missing_subject_token"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, body := postToken(t, ts, tc.form)
			if status != tc.status || body["error"] != tc.errMsg {
				t.Fatalf("want %d %s, got %d %v", tc.status, tc.errMsg, status, body)
			}
		})
	}
}
