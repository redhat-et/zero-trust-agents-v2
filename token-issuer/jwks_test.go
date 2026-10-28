package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/redhat-et/zero-trust-agents-v2/internal/tokens"
)

const (
	testSPIREIssuer = "http://spire-oidc:8080"
	testSVIDAud     = "http://token-issuer.zt-demo.svc"
	gatewayPrefix   = "spiffe://openshell.local/openshell/gateway/"
	supervisorPref  = "spiffe://openshell.local/openshell/sandbox/"
)

type jwksKey struct {
	Kty string `json:"kty"`
	Crv string `json:"crv"`
	Kid string `json:"kid"`
	X   string `json:"x"`
	Y   string `json:"y"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// jwksServer spins an httptest server serving a JWKS with one ES256 and
// one RS256 key, returning the server and key material.
func jwksServer(t *testing.T) (*httptest.Server, *ecdsa.PrivateKey, *rsa.PrivateKey) {
	t.Helper()
	ecKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	b64 := base64.RawURLEncoding
	point, err := ecKey.PublicKey.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	// Uncompressed point: 0x04 || X || Y, 32-byte coordinates on P-256.
	x, y := point[1:33], point[33:65]
	keys := map[string]any{
		"keys": []jwksKey{
			{
				Kty: "EC", Crv: "P-256", Kid: "ec-1",
				X: b64.EncodeToString(x),
				Y: b64.EncodeToString(y),
			},
			{
				Kty: "RSA", Kid: "rsa-1",
				N: b64.EncodeToString(rsaKey.N.Bytes()),
				E: b64.EncodeToString([]byte{1, 0, 1}),
			},
		},
	}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(keys)
	}))
	t.Cleanup(ts.Close)
	return ts, ecKey, rsaKey
}

func newVerifier(t *testing.T, uri string) JWKSVerifier {
	t.Helper()
	return NewJWKSVerifier(uri, testSPIREIssuer, testSVIDAud)
}

// signES256SVID crafts a JWT-SVID with a P-1363 (r||s) signature.
func signES256SVID(t *testing.T, key *ecdsa.PrivateKey, kid string, claims tokens.Claims) string {
	t.Helper()
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "typ": "JWT", "kid": kid})
	payload, _ := json.Marshal(claims)
	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(payload)
	r, s, err := ecdsa.Sign(rand.Reader, key, sha256Sum(signingInput))
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func validSVIDClaims(sub string) tokens.Claims {
	return tokens.Claims{
		"iss": testSPIREIssuer,
		"sub": sub,
		"aud": testSVIDAud,
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(5 * time.Minute).Unix(),
	}
}

func TestVerifySVIDAcceptsES256(t *testing.T) {
	ts, ecKey, _ := jwksServer(t)
	v := newVerifier(t, ts.URL)
	svid := signES256SVID(t, ecKey, "ec-1", validSVIDClaims(gatewayPrefix+"demo"))
	claims, err := v.VerifySVID(svid, gatewayPrefix)
	if err != nil {
		t.Fatal(err)
	}
	if claims.String("sub") != gatewayPrefix+"demo" {
		t.Errorf("sub: %v", claims["sub"])
	}
}

func TestVerifySVIDAcceptsRS256(t *testing.T) {
	ts, _, rsaKey := jwksServer(t)
	v := newVerifier(t, ts.URL)
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT", "kid": "rsa-1"})
	payload, _ := json.Marshal(validSVIDClaims(gatewayPrefix+"demo"))
	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(payload)
	sig, err := rsaSignPKCS1v15(rsaKey, sha256Sum(signingInput))
	if err != nil {
		t.Fatal(err)
	}
	svid := signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
	if _, err := v.VerifySVID(svid, gatewayPrefix); err != nil {
		t.Fatalf("RS256 SVID should verify: %v", err)
	}
}

func TestVerifySVIDRejectsWrongPrefix(t *testing.T) {
	ts, ecKey, _ := jwksServer(t)
	v := newVerifier(t, ts.URL)
	// Validly signed, but a rogue trust domain (review focus: the
	// rogue-sandbox scenario 5 unit test).
	svid := signES256SVID(t, ecKey, "ec-1", validSVIDClaims("spiffe://evil.local/rogue/1"))
	if _, err := v.VerifySVID(svid, gatewayPrefix); err == nil {
		t.Fatal("want error for wrong subject prefix")
	}
}

func TestVerifySVIDRejectsWrongIssuer(t *testing.T) {
	ts, ecKey, _ := jwksServer(t)
	v := newVerifier(t, ts.URL)
	c := validSVIDClaims(gatewayPrefix+"demo")
	c["iss"] = "http://attacker"
	if _, err := v.VerifySVID(signES256SVID(t, ecKey, "ec-1", c), gatewayPrefix); err == nil {
		t.Fatal("want error for wrong issuer")
	}
}

func TestVerifySVIDRejectsExpired(t *testing.T) {
	ts, ecKey, _ := jwksServer(t)
	v := newVerifier(t, ts.URL)
	c := validSVIDClaims(gatewayPrefix+"demo")
	c["exp"] = time.Now().Add(-time.Minute).Unix()
	if _, err := v.VerifySVID(signES256SVID(t, ecKey, "ec-1", c), gatewayPrefix); err == nil {
		t.Fatal("want error for expired SVID")
	}
}

func TestVerifySVIDRejectsWrongAudience(t *testing.T) {
	ts, ecKey, _ := jwksServer(t)
	v := newVerifier(t, ts.URL)
	c := validSVIDClaims(gatewayPrefix+"demo")
	c["aud"] = "http://someone-else"
	if _, err := v.VerifySVID(signES256SVID(t, ecKey, "ec-1", c), gatewayPrefix); err == nil {
		t.Fatal("want error for wrong audience")
	}
}

func TestVerifySVIDRejectsBadSignature(t *testing.T) {
	ts, _, _ := jwksServer(t)
	otherKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	v := newVerifier(t, ts.URL)
	// Signed by a key not in the JWKS, kid points at the real one.
	svid := signES256SVID(t, otherKey, "ec-1", validSVIDClaims(gatewayPrefix+"demo"))
	if _, err := v.VerifySVID(svid, gatewayPrefix); err == nil {
		t.Fatal("want error for bad signature")
	}
}

func TestVerifySVIDRejectsUnknownKid(t *testing.T) {
	ts, ecKey, _ := jwksServer(t)
	v := newVerifier(t, ts.URL)
	svid := signES256SVID(t, ecKey, "ec-unknown", validSVIDClaims(gatewayPrefix+"demo"))
	if _, err := v.VerifySVID(svid, gatewayPrefix); err == nil {
		t.Fatal("want error for unknown kid")
	}
	_ = ecKey
}

func TestVerifySVIDRejectsGarbage(t *testing.T) {
	ts, _, _ := jwksServer(t)
	v := newVerifier(t, ts.URL)
	if _, err := v.VerifySVID("not-a-jwt", gatewayPrefix); err == nil {
		t.Fatal("want error for garbage input")
	}
	if _, err := v.VerifySVID(strings.Repeat("a.b.c", 1), gatewayPrefix); err == nil {
		t.Fatal("want error for malformed input")
	}
}

func sha256Sum(input string) []byte {
	sum := sha256.Sum256([]byte(input))
	return sum[:]
}

func rsaSignPKCS1v15(key *rsa.PrivateKey, digest []byte) ([]byte, error) {
	return rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest)
}
