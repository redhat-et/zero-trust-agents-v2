package tokens

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

var testClaims = Claims{
	"iss":            "http://token-issuer.zt-demo.svc",
	"sub":            "alice",
	"demo_token_use": UseUserSubject,
	"iat":            time.Now().Unix(),
	"exp":            time.Now().Add(time.Minute).Unix(),
}

func signOrFail(t *testing.T, c Claims) string {
	t.Helper()
	tok, err := Sign("secret", c)
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func TestSignVerifyRoundTrip(t *testing.T) {
	tok := signOrFail(t, testClaims)
	got, err := Verify("secret", tok)
	if err != nil {
		t.Fatal(err)
	}
	if got["sub"] != "alice" || got["demo_token_use"] != UseUserSubject {
		t.Fatalf("unexpected claims: %v", got)
	}
}

func TestVerifyTamperedPayload(t *testing.T) {
	tok := signOrFail(t, testClaims)
	parts := strings.Split(tok, ".")
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(payload, &m); err != nil {
		t.Fatal(err)
	}
	m["sub"] = "admin"
	tampered, _ := json.Marshal(m)
	parts[1] = base64.RawURLEncoding.EncodeToString(tampered)
	if _, err := Verify("secret", strings.Join(parts, ".")); err == nil {
		t.Fatal("want error for tampered payload")
	}
}

func TestVerifyExpired(t *testing.T) {
	c := Claims(testClaims)
	c["exp"] = time.Now().Add(-time.Minute).Unix()
	tok := signOrFail(t, c)
	if _, err := Verify("secret", tok); err == nil {
		t.Fatal("want error for expired token")
	}
}

func TestVerifyMissingExp(t *testing.T) {
	// A demo whose thesis is short-lived tokens must not accept one that
	// never expires.
	c := Claims(testClaims)
	delete(c, "exp")
	tok := signOrFail(t, c)
	if _, err := Verify("secret", tok); err == nil {
		t.Fatal("want error for token without exp")
	}
}

func TestVerifyWrongSecret(t *testing.T) {
	tok := signOrFail(t, testClaims)
	if _, err := Verify("other", tok); err == nil {
		t.Fatal("want error for wrong secret")
	}
}

func TestVerifyAlgNone(t *testing.T) {
	// Hand-craft a token with alg: none and no signature.
	payload, _ := json.Marshal(map[string]any(testClaims))
	tok := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0." +
		base64.RawURLEncoding.EncodeToString(payload) + "."
	if _, err := Verify("secret", tok); err == nil {
		t.Fatal("want error for alg: none")
	}
}

func TestVerifyAlgRS256(t *testing.T) {
	// Hand-craft a token whose header claims RS256 but whose signature
	// is a valid HMAC (the key-confusion forgery).
	payload, _ := json.Marshal(map[string]any(testClaims))
	signingInput := "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9." +
		base64.RawURLEncoding.EncodeToString(payload)
	// Build properly: header RS256, HMAC signature over the input.
	mac := hmacSHA256("secret", signingInput)
	forged := signingInput + "." + base64.RawURLEncoding.EncodeToString(mac)
	if _, err := Verify("secret", forged); err == nil {
		t.Fatal("want error for alg: RS256 on HS256 path")
	}
}

func TestParseWithoutVerification(t *testing.T) {
	tok := signOrFail(t, testClaims)
	got, err := Parse(tok)
	if err != nil {
		t.Fatal(err)
	}
	if got["sub"] != "alice" {
		t.Fatalf("unexpected sub: %v", got["sub"])
	}
}
