package tokens

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// testClaims returns a fresh map per call: tests mutate the claims
// (delete/set exp), and a shared map would leak state between tests.
func testClaims() Claims {
	return Claims{
		"iss":            "http://token-issuer.zt-demo.svc",
		"sub":            "alice",
		"demo_token_use": UseUserSubject,
		"iat":            time.Now().Unix(),
		"exp":            time.Now().Add(time.Minute).Unix(),
	}
}

func newTestSigner(t *testing.T) *Signer {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	s, err := NewSigner(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func signOrFail(t *testing.T, s *Signer, c Claims) string {
	t.Helper()
	tok, err := s.Sign(c)
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func TestSignVerifyRoundTrip(t *testing.T) {
	s := newTestSigner(t)
	got, err := s.Verify(signOrFail(t, s, testClaims()))
	if err != nil {
		t.Fatal(err)
	}
	if got["sub"] != "alice" || got["demo_token_use"] != UseUserSubject {
		t.Fatalf("unexpected claims: %v", got)
	}
}

func TestSignUsesES256AndKid(t *testing.T) {
	s := newTestSigner(t)
	parts := strings.Split(signOrFail(t, s, testClaims()), ".")
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatal(err)
	}
	var h header
	if err := json.Unmarshal(raw, &h); err != nil {
		t.Fatal(err)
	}
	if h.Alg != "ES256" {
		t.Errorf("alg: %q", h.Alg)
	}
	if h.Typ != "JWT" {
		t.Errorf("typ: %q", h.Typ)
	}
	if h.Kid == "" || h.Kid != s.Kid() {
		t.Errorf("kid %q must equal signer kid %q", h.Kid, s.Kid())
	}
}

func TestVerifyTamperedPayload(t *testing.T) {
	s := newTestSigner(t)
	parts := strings.Split(signOrFail(t, s, testClaims()), ".")
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
	if _, err := s.Verify(strings.Join(parts, ".")); err == nil {
		t.Fatal("want error for tampered payload")
	}
}

func TestVerifyExpired(t *testing.T) {
	s := newTestSigner(t)
	c := testClaims()
	c["exp"] = time.Now().Add(-time.Minute).Unix()
	if _, err := s.Verify(signOrFail(t, s, c)); err == nil {
		t.Fatal("want error for expired token")
	}
}

func TestVerifyMissingExp(t *testing.T) {
	// A demo whose thesis is short-lived tokens must not accept one that
	// never expires.
	s := newTestSigner(t)
	c := testClaims()
	delete(c, "exp")
	if _, err := s.Verify(signOrFail(t, s, c)); err == nil {
		t.Fatal("want error for token without exp")
	}
}

func TestVerifyWrongKey(t *testing.T) {
	signer := newTestSigner(t)
	other := newTestSigner(t)
	if _, err := signer.Verify(signOrFail(t, other, testClaims())); err == nil {
		t.Fatal("want error for token signed by another key")
	}
}

func TestVerifyAlgNone(t *testing.T) {
	payload, _ := json.Marshal(testClaims())
	tok := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0." +
		base64.RawURLEncoding.EncodeToString(payload) + "."
	if _, err := newTestSigner(t).Verify(tok); err == nil {
		t.Fatal("want error for alg: none")
	}
}

func TestVerifyAlgHS256(t *testing.T) {
	// A header that claims HS256 must never be accepted on the
	// asymmetric path, even with a syntactically valid signature.
	payload, _ := json.Marshal(testClaims())
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT","kid":"es-1"}`))
	input := hdr + "." + base64.RawURLEncoding.EncodeToString(payload)
	digest := sha256.Sum256([]byte(input))
	sig := base64.RawURLEncoding.EncodeToString(digest[:])
	if _, err := newTestSigner(t).Verify(input + "." + sig); err == nil {
		t.Fatal("want error for alg: HS256")
	}
}

func TestVerifyMissingKid(t *testing.T) {
	payload, _ := json.Marshal(testClaims())
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"ES256","typ":"JWT"}`))
	sig := base64.RawURLEncoding.EncodeToString(make([]byte, 64))
	if _, err := newTestSigner(t).Verify(hdr + "." + base64.RawURLEncoding.EncodeToString(payload) + "." + sig); err == nil {
		t.Fatal("want error for token without kid")
	}
}

func TestPublicJWKSShape(t *testing.T) {
	s := newTestSigner(t)
	raw, err := s.PublicJWKS()
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Keys []map[string]any `json:"keys"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Keys) != 1 {
		t.Fatalf("want one key, got %d", len(doc.Keys))
	}
	k := doc.Keys[0]
	for field, want := range map[string]string{
		"kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": s.Kid(),
	} {
		if k[field] != want {
			t.Errorf("%s: want %q, got %v", field, want, k[field])
		}
	}
	for _, private := range []string{"d", "p", "q", "dp", "dq", "qi"} {
		if _, ok := k[private]; ok {
			t.Errorf("JWKS must not contain private member %q", private)
		}
	}
}

func writeKeyFile(t *testing.T, blockType string, der []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "key.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: blockType, Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestNewSignerFromFilePKCS8(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	s, err := NewSignerFromFile(writeKeyFile(t, "PRIVATE KEY", der))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Verify(signOrFail(t, s, testClaims())); err != nil {
		t.Fatal(err)
	}
}

func TestNewSignerFromFileSEC1(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewSignerFromFile(writeKeyFile(t, "EC PRIVATE KEY", der)); err != nil {
		t.Fatal(err)
	}
}

func TestNewSignerFromFileMissing(t *testing.T) {
	if _, err := NewSignerFromFile(filepath.Join(t.TempDir(), "absent.pem")); err == nil {
		t.Fatal("want error for a missing key file")
	}
}

// withJWKSTimings narrows the cache and retry windows for tests. The
// verifier is not used concurrently with this helper.
func withJWKSTimings(ttl, retry time.Duration) func() {
	oldTTL, oldRetry := jwksCacheTTL, jwksRetryInterval
	jwksCacheTTL, jwksRetryInterval = ttl, retry
	return func() { jwksCacheTTL, jwksRetryInterval = oldTTL, oldRetry }
}

func jwksServer(t *testing.T, s *Signer, hits *int64) *httptest.Server {
	t.Helper()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if hits != nil {
			atomic.AddInt64(hits, 1)
		}
		raw, err := s.PublicJWKS()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw)
	}))
	t.Cleanup(ts.Close)
	return ts
}

func TestJWKSVerifierFetchesPublishedKey(t *testing.T) {
	s := newTestSigner(t)
	v := NewJWKSVerifier(jwksServer(t, s, nil).URL)
	if _, err := v.Verify(signOrFail(t, s, testClaims())); err != nil {
		t.Fatal(err)
	}
}

func TestJWKSVerifierRejectsOtherKey(t *testing.T) {
	signer := newTestSigner(t)
	other := newTestSigner(t)
	v := NewJWKSVerifier(jwksServer(t, other, nil).URL)
	if _, err := v.Verify(signOrFail(t, signer, testClaims())); err == nil {
		t.Fatal("want error when the token key is not in the JWKS")
	}
}

func TestJWKSVerifierCaches(t *testing.T) {
	s := newTestSigner(t)
	var hits int64
	v := NewJWKSVerifier(jwksServer(t, s, &hits).URL)
	tok := signOrFail(t, s, testClaims())
	for i := 0; i < 3; i++ {
		if _, err := v.Verify(tok); err != nil {
			t.Fatal(err)
		}
	}
	if hits != 1 {
		t.Errorf("want one JWKS fetch inside the cache window, got %d", hits)
	}
}

func TestJWKSVerifierUnavailable(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	defer ts.Close()
	s := newTestSigner(t)
	v := NewJWKSVerifier(ts.URL)
	if _, err := v.Verify(signOrFail(t, s, testClaims())); err == nil {
		t.Fatal("want error when the JWKS cannot be fetched")
	}
}

func TestParseWithoutVerification(t *testing.T) {
	s := newTestSigner(t)
	got, err := Parse(signOrFail(t, s, testClaims()))
	if err != nil {
		t.Fatal(err)
	}
	if got["sub"] != "alice" {
		t.Fatalf("unexpected sub: %v", got["sub"])
	}
}

func TestJWKSVerifierBacksOffAfterFailure(t *testing.T) {
	var hits int64
	s := newTestSigner(t)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt64(&hits, 1)
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	defer ts.Close()

	defer withJWKSTimings(0, time.Hour)()
	v := NewJWKSVerifier(ts.URL)
	tok := signOrFail(t, s, testClaims())
	if _, err := v.Verify(tok); err == nil {
		t.Fatal("want an error while the JWKS is down and no key is cached")
	}
	for i := 0; i < 3; i++ {
		_, _ = v.Verify(tok)
	}
	if got := atomic.LoadInt64(&hits); got != 1 {
		t.Errorf("want one fetch inside the retry window, got %d", got)
	}
}

func TestJWKSVerifierServesCachedKeyDuringSlowRefresh(t *testing.T) {
	s := newTestSigner(t)
	var hits int64
	var startedOnce, releaseOnce sync.Once
	started := make(chan struct{})
	release := make(chan struct{})
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if atomic.AddInt64(&hits, 1) > 1 {
			startedOnce.Do(func() { close(started) })
			<-release
		}
		raw, err := s.PublicJWKS()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_, _ = w.Write(raw)
	}))
	defer ts.Close()
	defer unblock()

	defer withJWKSTimings(0, time.Hour)()
	v := NewJWKSVerifier(ts.URL)
	tok := signOrFail(t, s, testClaims())
	if _, err := v.Verify(tok); err != nil {
		t.Fatal(err)
	}

	slowDone := make(chan struct{})
	go func() {
		_, _ = v.Verify(tok) // triggers the refresh, blocks in the handler
		close(slowDone)
	}()
	<-started

	result := make(chan error, 1)
	go func() {
		_, err := v.Verify(tok)
		result <- err
	}()
	blocked := false
	select {
	case err := <-result:
		if err != nil {
			t.Errorf("a cached key must verify without waiting: %v", err)
		}
	case <-time.After(2 * time.Second):
		blocked = true
	}
	unblock()
	<-slowDone
	if blocked {
		if err := <-result; err != nil {
			t.Logf("blocked verify returned: %v", err)
		}
		t.Fatal("second verify blocked behind the in-flight refresh")
	}
}

func TestPublicKeyRejectsOversizedCoordinate(t *testing.T) {
	x := make([]byte, keySize+1)
	x[0] = 1 // numerically larger than a P-256 coordinate
	_, err := publicKey(jwk{
		Kty: "EC", Crv: "P-256", Kid: "k",
		X: b64.EncodeToString(x),
		Y: b64.EncodeToString(make([]byte, keySize)),
	})
	if err == nil {
		t.Fatal("want an error for a coordinate longer than 32 bytes")
	}
}

func TestJWKSVerifierThrottlesUnknownKid(t *testing.T) {
	var hits int64
	s := newTestSigner(t)
	other := newTestSigner(t)
	defer withJWKSTimings(time.Minute, time.Hour)()
	v := NewJWKSVerifier(jwksServer(t, s, &hits).URL)

	if _, err := v.Verify(signOrFail(t, s, testClaims())); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if _, err := v.Verify(signOrFail(t, other, testClaims())); err == nil {
			t.Fatal("want an error for an unknown kid")
		}
	}
	if got := atomic.LoadInt64(&hits); got != 1 {
		t.Errorf("unknown-kid tokens must not refetch inside the retry window, got %d fetches", got)
	}
}

// RS256 support: Keycloak signs user tokens with an RSA key. The
// verifier must accept that key type without weakening the algorithm
// guard.

func signRS256(t *testing.T, key *rsa.PrivateKey, kid string, c Claims) string {
	t.Helper()
	hdr, err := json.Marshal(header{Alg: algRS256, Typ: "JWT", Kid: kid})
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	input := b64.EncodeToString(hdr) + "." + b64.EncodeToString(payload)
	digest := sha256.Sum256([]byte(input))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return input + "." + b64.EncodeToString(sig)
}

func rsaJWKS(t *testing.T, key *rsa.PublicKey, kid string) *httptest.Server {
	t.Helper()
	doc := jwksDoc{Keys: []jwk{{
		Kty: "RSA",
		Kid: kid,
		Alg: algRS256,
		Use: "sig",
		N:   b64.EncodeToString(key.N.Bytes()),
		E:   b64.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
	}}}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw)
	}))
	t.Cleanup(ts.Close)
	return ts
}

func TestJWKSVerifierAcceptsRS256(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	v := NewJWKSVerifier(rsaJWKS(t, &key.PublicKey, "rsa-1").URL)
	got, err := v.Verify(signRS256(t, key, "rsa-1", testClaims()))
	if err != nil {
		t.Fatal(err)
	}
	if got["sub"] != "alice" {
		t.Fatalf("unexpected claims: %v", got)
	}
}

func TestJWKSVerifierRejectsAlgNoneOnRSAKey(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	v := NewJWKSVerifier(rsaJWKS(t, &key.PublicKey, "rsa-1").URL)
	payload, _ := json.Marshal(testClaims())
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT","kid":"rsa-1"}`))
	tok := hdr + "." + base64.RawURLEncoding.EncodeToString(payload) + "."
	if _, err := v.Verify(tok); err == nil {
		t.Fatal("want error for alg: none even with an RSA key")
	}
}

func TestJWKSVerifierRejectsAlgHS256OnRSAKey(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	v := NewJWKSVerifier(rsaJWKS(t, &key.PublicKey, "rsa-1").URL)
	payload, _ := json.Marshal(testClaims())
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT","kid":"rsa-1"}`))
	input := hdr + "." + base64.RawURLEncoding.EncodeToString(payload)
	digest := sha256.Sum256([]byte(input))
	tok := input + "." + base64.RawURLEncoding.EncodeToString(digest[:])
	if _, err := v.Verify(tok); err == nil {
		t.Fatal("want error for alg: HS256")
	}
}

func TestJWKSVerifierRejectsRS256AgainstECKey(t *testing.T) {
	// The token names a kid that resolves to an EC key; the algorithm
	// must not be downgraded or reinterpreted.
	ec := newTestSigner(t)
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		raw, _ := ec.PublicJWKS()
		_, _ = w.Write(raw)
	}))
	defer ts.Close()
	v := NewJWKSVerifier(ts.URL)
	tok := signRS256(t, key, ec.Kid(), testClaims())
	if _, err := v.Verify(tok); err == nil {
		t.Fatal("want error when an RS256 token names an EC key")
	}
}

func TestJWKSVerifierSkipsEncryptionKeys(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	doc := jwksDoc{Keys: []jwk{
		{Kty: "RSA", Kid: "sig-1", Alg: algRS256, Use: "sig",
			N: b64.EncodeToString(key.N.Bytes()), E: b64.EncodeToString(big.NewInt(int64(key.E)).Bytes())},
		{Kty: "RSA", Kid: "enc-1", Alg: "RSA-OAEP", Use: "enc",
			N: b64.EncodeToString(key.N.Bytes()), E: b64.EncodeToString(big.NewInt(int64(key.E)).Bytes())},
	}}
	raw, _ := json.Marshal(doc)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(raw)
	}))
	defer ts.Close()
	v := NewJWKSVerifier(ts.URL)
	if _, err := v.Verify(signRS256(t, key, "sig-1", testClaims())); err != nil {
		t.Fatalf("signing key must verify: %v", err)
	}
	if _, err := v.Verify(signRS256(t, key, "enc-1", testClaims())); err == nil {
		t.Fatal("an encryption key must not verify a signature")
	}
}

func TestSignerRejectsRS256Header(t *testing.T) {
	s := newTestSigner(t)
	hdr, _ := json.Marshal(header{Alg: algRS256, Typ: "JWT", Kid: s.Kid()})
	payload, _ := json.Marshal(testClaims())
	input := b64.EncodeToString(hdr) + "." + b64.EncodeToString(payload)
	digest := sha256.Sum256([]byte(input))
	r, v, err := ecdsa.Sign(rand.Reader, s.key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 2*keySize)
	r.FillBytes(sig[:keySize])
	v.FillBytes(sig[keySize:])
	tok := input + "." + b64.EncodeToString(sig)
	if _, err := s.Verify(tok); err == nil {
		t.Fatal("the local signer must reject a non-ES256 header")
	}
}
