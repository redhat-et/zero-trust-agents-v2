// Package tokens implements the demo's short-lived access tokens: ES256
// JWTs signed by the issuer with a key only it holds, and verified by
// anyone who can fetch the issuer's published JWKS. Hand-rolled on
// purpose — this demo teaches what a verifier must check.
package tokens

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	UseUserSubject  = "user_subject"
	UseIntermediate = "intermediate"
	UseFinal        = "final"
)

// Claims is a JWT payload.
type Claims map[string]any

func (c Claims) String(key string) string {
	s, _ := c[key].(string)
	return s
}

func (c Claims) Int64(key string) int64 {
	switch v := c[key].(type) {
	case float64:
		return int64(v)
	case int64:
		return v
	case json.Number:
		n, _ := v.Int64()
		return n
	}
	return 0
}

func (c Claims) StringSlice(key string) []string {
	raw, ok := c[key].([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, v := range raw {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// HasAudience reports whether the aud claim (string or list) contains want.
func (c Claims) HasAudience(want string) bool {
	switch v := c["aud"].(type) {
	case string:
		return v == want
	case []any:
		for _, a := range v {
			if s, ok := a.(string); ok && s == want {
				return true
			}
		}
	}
	return false
}

type header struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
	Kid string `json:"kid"`
}

const (
	algES256 = "ES256"
	keySize  = 32 // P-256 coordinate and signature half width
)

var b64 = base64.RawURLEncoding

type jwk struct {
	Kty string `json:"kty"`
	Crv string `json:"crv"`
	Kid string `json:"kid"`
	X   string `json:"x"`
	Y   string `json:"y"`
	Alg string `json:"alg,omitempty"`
	Use string `json:"use,omitempty"`
}

type jwksDoc struct {
	Keys []jwk `json:"keys"`
}

// Signer mints ES256 tokens. Only the issuer holds one.
type Signer struct {
	key *ecdsa.PrivateKey
	kid string
}

// NewSigner wraps a P-256 key and derives its RFC 7638 thumbprint as the
// JWS kid.
func NewSigner(key *ecdsa.PrivateKey) (*Signer, error) {
	if key == nil || key.Curve != elliptic.P256() {
		return nil, errors.New("signing key must be an ECDSA P-256 key")
	}
	x, y, err := jwkCoords(&key.PublicKey)
	if err != nil {
		return nil, err
	}
	kid, err := thumbprint(x, y)
	if err != nil {
		return nil, err
	}
	return &Signer{key: key, kid: kid}, nil
}

// NewSignerFromFile loads a PEM key in PKCS#8 or SEC1 form.
func NewSignerFromFile(path string) (*Signer, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read signing key: %w", err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("parse signing key %s: no PEM block", path)
	}
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		ec, ok := key.(*ecdsa.PrivateKey)
		if !ok {
			return nil, fmt.Errorf("signing key %s is not an EC private key", path)
		}
		return NewSigner(ec)
	}
	ec, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse signing key %s: %w", path, err)
	}
	return NewSigner(ec)
}

// Kid is the key identifier carried in every token header and the JWKS.
func (s *Signer) Kid() string { return s.kid }

// Sign produces an ES256 JWS over the claims.
func (s *Signer) Sign(claims Claims) (string, error) {
	hdr, err := json.Marshal(header{Alg: algES256, Typ: "JWT", Kid: s.kid})
	if err != nil {
		return "", err
	}
	body, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	input := b64.EncodeToString(hdr) + "." + b64.EncodeToString(body)
	digest := sha256.Sum256([]byte(input))
	r, v, err := ecdsa.Sign(rand.Reader, s.key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 2*keySize)
	r.FillBytes(sig[:keySize])
	v.FillBytes(sig[keySize:])
	return input + "." + b64.EncodeToString(sig), nil
}

// Verify checks a token against the signer's own public key. The issuer
// uses this for its subject tokens so it never calls its own JWKS.
func (s *Signer) Verify(token string) (Claims, error) {
	_, claims, sig, input, err := parseChecked(token)
	if err != nil {
		return nil, err
	}
	return finishVerify(&s.key.PublicKey, claims, sig, input)
}

// PublicJWKS returns the published key set: public members only.
func (s *Signer) PublicJWKS() ([]byte, error) {
	x, y, err := jwkCoords(&s.key.PublicKey)
	if err != nil {
		return nil, err
	}
	return json.Marshal(jwksDoc{Keys: []jwk{{
		Kty: "EC", Crv: "P-256", Kid: s.kid, X: x, Y: y, Alg: algES256, Use: "sig",
	}}})
}

var (
	jwksCacheTTL      = 60 * time.Second
	jwksRetryInterval = 5 * time.Second
)

// JWKSVerifier verifies tokens against a published key set. It holds no
// signing material.
type JWKSVerifier struct {
	url    string
	client *http.Client

	mu          sync.Mutex
	keys        map[string]*ecdsa.PublicKey
	fetched     time.Time
	fetching    bool
	lastFailure time.Time
}

// NewJWKSVerifier fetches keys from url, cached for 60 seconds.
func NewJWKSVerifier(url string) *JWKSVerifier {
	return &JWKSVerifier{
		url:    url,
		client: &http.Client{Timeout: 10 * time.Second},
		keys:   make(map[string]*ecdsa.PublicKey),
	}
}

// Verify checks the token's signature against the key named by its kid.
func (v *JWKSVerifier) Verify(token string) (Claims, error) {
	h, claims, sig, input, err := parseChecked(token)
	if err != nil {
		return nil, err
	}
	pub, err := v.key(h.Kid)
	if err != nil {
		return nil, err
	}
	return finishVerify(pub, claims, sig, input)
}

// key returns the public key for kid. At most one fetch is in flight,
// it happens outside the lock, and a cached key keeps verifying while
// it runs or while the endpoint is down. A failed fetch is retried no
// more often than jwksRetryInterval.
func (v *JWKSVerifier) key(kid string) (*ecdsa.PublicKey, error) {
	v.mu.Lock()
	pub := v.keys[kid]
	if pub != nil && time.Since(v.fetched) < jwksCacheTTL {
		v.mu.Unlock()
		return pub, nil
	}
	// An unknown kid shortly after a successful fetch must not trigger a
	// refetch: kid is attacker-controlled, so every random value would
	// otherwise become one JWKS request. A rotated-in key is still
	// discovered once the interval expires.
	recentMiss := pub == nil && !v.fetched.IsZero() && time.Since(v.fetched) < jwksRetryInterval
	if v.fetching || recentMiss || time.Since(v.lastFailure) < jwksRetryInterval {
		fetching := v.fetching
		v.mu.Unlock()
		if pub != nil {
			return pub, nil
		}
		switch {
		case fetching:
			return nil, fmt.Errorf("jwks: fetch in progress for kid %q", kid)
		case recentMiss:
			return nil, fmt.Errorf("unknown kid %q", kid)
		default:
			return nil, fmt.Errorf("jwks: no key for kid %q after a failed fetch", kid)
		}
	}
	v.fetching = true
	v.mu.Unlock()

	err := v.refresh() // network I/O must not hold the lock

	v.mu.Lock()
	defer v.mu.Unlock()
	v.fetching = false
	if err != nil {
		v.lastFailure = time.Now()
		if cached := v.keys[kid]; cached != nil {
			return cached, nil
		}
		return nil, err
	}
	pub = v.keys[kid]
	if pub == nil {
		return nil, fmt.Errorf("unknown kid %q", kid)
	}
	return pub, nil
}

func (v *JWKSVerifier) refresh() error {
	resp, err := v.client.Get(v.url)
	if err != nil {
		return fmt.Errorf("fetch JWKS: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("fetch JWKS: %s", resp.Status)
	}
	var doc jwksDoc
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return fmt.Errorf("parse JWKS: %w", err)
	}
	keys := make(map[string]*ecdsa.PublicKey, len(doc.Keys))
	for _, k := range doc.Keys {
		if k.Kty != "EC" || k.Crv != "P-256" || k.Kid == "" {
			continue
		}
		pub, err := publicKey(k)
		if err != nil {
			continue
		}
		keys[k.Kid] = pub
	}
	v.mu.Lock()
	v.keys = keys
	v.fetched = time.Now()
	v.mu.Unlock()
	return nil
}

// parseChecked parses a token once and enforces the algorithm and kid
// guards shared by both verifiers.
func parseChecked(token string) (header, Claims, []byte, string, error) {
	h, claims, sig, input, err := parseSigned(token)
	if err != nil {
		return header{}, nil, nil, "", err
	}
	if h.Alg != algES256 {
		return header{}, nil, nil, "", fmt.Errorf("unsupported alg %q", h.Alg)
	}
	if h.Kid == "" {
		return header{}, nil, nil, "", errors.New("token has no kid")
	}
	return h, claims, sig, input, nil
}

// finishVerify checks the signature and expiry of an already parsed
// token. exp is mandatory: a demo whose thesis is short-lived tokens
// must not accept one that never expires.
func finishVerify(pub *ecdsa.PublicKey, claims Claims, sig []byte, input string) (Claims, error) {
	if err := verifyES256(pub, input, sig); err != nil {
		return nil, err
	}
	exp := claims.Int64("exp")
	if exp == 0 {
		return nil, errors.New("token has no exp claim")
	}
	if exp <= time.Now().Unix() {
		return nil, errors.New("token expired")
	}
	return claims, nil
}

// verifyES256 checks a JWS ECDSA signature, which is the raw
// concatenation r||s — not ASN.1, so ecdsa.VerifyASN1 must not be used.
func verifyES256(pub *ecdsa.PublicKey, input string, sig []byte) error {
	if len(sig) != 2*keySize {
		return errors.New("signature validation failed")
	}
	r := new(big.Int).SetBytes(sig[:keySize])
	s := new(big.Int).SetBytes(sig[keySize:])
	digest := sha256.Sum256([]byte(input))
	if !ecdsa.Verify(pub, digest[:], r, s) {
		return errors.New("signature validation failed")
	}
	return nil
}

func parseSigned(token string) (header, Claims, []byte, string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return header{}, nil, nil, "", errors.New("token must have three segments")
	}
	hdrJSON, err := b64.DecodeString(parts[0])
	if err != nil {
		return header{}, nil, nil, "", fmt.Errorf("decode header: %w", err)
	}
	var h header
	if err := json.Unmarshal(hdrJSON, &h); err != nil {
		return header{}, nil, nil, "", fmt.Errorf("parse header: %w", err)
	}
	sig, err := b64.DecodeString(parts[2])
	if err != nil {
		return header{}, nil, nil, "", fmt.Errorf("decode signature: %w", err)
	}
	claims, err := Parse(token)
	if err != nil {
		return header{}, nil, nil, "", err
	}
	return h, claims, sig, parts[0] + "." + parts[1], nil
}

func jwkCoords(pub *ecdsa.PublicKey) (string, string, error) {
	point, err := pub.Bytes()
	if err != nil {
		return "", "", fmt.Errorf("encode public key: %w", err)
	}
	if len(point) != 1+2*keySize || point[0] != 4 {
		return "", "", fmt.Errorf("unexpected public key encoding (length %d)", len(point))
	}
	return b64.EncodeToString(point[1 : 1+keySize]),
		b64.EncodeToString(point[1+keySize:]), nil
}

// thumbprint is the RFC 7638 SHA-256 JWK thumbprint: the SHA-256 of the
// canonical public members, base64url-encoded.
func thumbprint(x, y string) (string, error) {
	canonical, err := json.Marshal(struct {
		Crv string `json:"crv"`
		Kty string `json:"kty"`
		X   string `json:"x"`
		Y   string `json:"y"`
	}{Crv: "P-256", Kty: "EC", X: x, Y: y})
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return b64.EncodeToString(sum[:]), nil
}

func publicKey(k jwk) (*ecdsa.PublicKey, error) {
	xb, err := b64.DecodeString(k.X)
	if err != nil {
		return nil, fmt.Errorf("decode x: %w", err)
	}
	yb, err := b64.DecodeString(k.Y)
	if err != nil {
		return nil, fmt.Errorf("decode y: %w", err)
	}
	if len(xb) > keySize || len(yb) > keySize {
		return nil, errors.New("public key coordinate is too long for P-256")
	}
	point := make([]byte, 1+2*keySize)
	point[0] = 4
	new(big.Int).SetBytes(xb).FillBytes(point[1 : 1+keySize])
	new(big.Int).SetBytes(yb).FillBytes(point[1+keySize:])
	pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), point)
	if err != nil {
		return nil, fmt.Errorf("public key point is not on P-256: %w", err)
	}
	return pub, nil
}

// Parse decodes the payload without verifying the signature. Test use only.
func Parse(token string) (Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("token must have three segments")
	}
	payload, err := b64.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("decode payload: %w", err)
	}
	var claims Claims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, fmt.Errorf("parse payload: %w", err)
	}
	return claims, nil
}
