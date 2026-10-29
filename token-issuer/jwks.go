package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/redhat-et/zero-trust-agents-v2/internal/tokens"
)

const jwksCacheTTL = 60 * time.Second

type jwk struct {
	Kty string `json:"kty"`
	Crv string `json:"crv"`
	Kid string `json:"kid"`
	X   string `json:"x"`
	Y   string `json:"y"`
	N   string `json:"n"`
	E   string `json:"e"`
}

type jwksDoc struct {
	Keys []jwk `json:"keys"`
}

type jwksVerifier struct {
	uri         string
	spireIssuer string
	svidAud     string

	mu       sync.Mutex
	cached   *jwksDoc
	fetched  time.Time
	client   *http.Client
}

// NewJWKSVerifier returns a JWKSVerifier that fetches keys from uri
// (cached for 60s) and verifies SPIRE-issued JWT-SVIDs.
func NewJWKSVerifier(uri, spireIssuer, svidAudience string) JWKSVerifier {
	return &jwksVerifier{
		uri:         uri,
		spireIssuer: spireIssuer,
		svidAud:     svidAudience,
		client:      &http.Client{Timeout: 10 * time.Second},
	}
}

func (v *jwksVerifier) fetch() (*jwksDoc, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.cached != nil && time.Since(v.fetched) < jwksCacheTTL {
		return v.cached, nil
	}
	resp, err := v.client.Get(v.uri)
	if err != nil {
		return nil, fmt.Errorf("jwks fetch: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jwks fetch: HTTP %d", resp.StatusCode)
	}
	var doc jwksDoc
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return nil, fmt.Errorf("jwks parse: %w", err)
	}
	v.cached, v.fetched = &doc, time.Now()
	return &doc, nil
}

// VerifySVID checks the JWT-SVID signature against the JWKS, then its
// iss/aud/exp claims and the sub prefix (registration check: a validly
// signed SVID from an unregistered identity is still rejected).
func (v *jwksVerifier) VerifySVID(jwt string, subjectPrefix string) (tokens.Claims, error) {
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("svid must have three segments")
	}
	var hdr struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	hdrJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("decode svid header: %w", err)
	}
	if err := json.Unmarshal(hdrJSON, &hdr); err != nil {
		return nil, fmt.Errorf("parse svid header: %w", err)
	}

	doc, err := v.fetch()
	if err != nil {
		return nil, err
	}
	var key *jwk
	for i := range doc.Keys {
		if doc.Keys[i].Kid == hdr.Kid {
			key = &doc.Keys[i]
			break
		}
	}
	if key == nil {
		return nil, fmt.Errorf("no jwks key for kid %q", hdr.Kid)
	}

	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, fmt.Errorf("decode svid signature: %w", err)
	}

	switch hdr.Alg {
	case "ES256":
		if key.Kty != "EC" || key.Crv != "P-256" {
			return nil, fmt.Errorf("jwks key %q is not EC P-256", hdr.Kid)
		}
		// JWT signatures are IEEE P-1363 (fixed-width r||s), not ASN.1 DER.
		if len(sig) != 64 {
			return nil, fmt.Errorf("ES256 signature must be 64 bytes, got %d", len(sig))
		}
		x, err := b64ToBytes(key.X)
		if err != nil {
			return nil, err
		}
		y, err := b64ToBytes(key.Y)
		if err != nil {
			return nil, err
		}
		point := make([]byte, 0, 1+len(x)+len(y))
		point = append(point, 4)
		point = append(point, x...)
		point = append(point, y...)
		pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), point)
		if err != nil {
			return nil, fmt.Errorf("parse EC public key: %w", err)
		}
		r := new(big.Int).SetBytes(sig[:32])
		s := new(big.Int).SetBytes(sig[32:])
		if !ecdsa.Verify(pub, digest[:], r, s) {
			return nil, fmt.Errorf("svid signature validation failed")
		}
	case "RS256":
		if key.Kty != "RSA" {
			return nil, fmt.Errorf("jwks key %q is not RSA", hdr.Kid)
		}
		nBytes, err := b64ToBytes(key.N)
		if err != nil {
			return nil, err
		}
		eBytes, err := base64.RawURLEncoding.DecodeString(key.E)
		if err != nil {
			return nil, fmt.Errorf("decode rsa exponent: %w", err)
		}
		pub := &rsa.PublicKey{N: new(big.Int).SetBytes(nBytes), E: int(new(big.Int).SetBytes(eBytes).Int64())}
		if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, digest[:], sig); err != nil {
			return nil, fmt.Errorf("svid signature validation failed")
		}
	default:
		return nil, fmt.Errorf("unsupported svid alg %q", hdr.Alg)
	}

	claims, err := tokens.Parse(jwt)
	if err != nil {
		return nil, err
	}
	now := time.Now().Unix()
	exp := claims.Int64("exp")
	if exp == 0 {
		return nil, fmt.Errorf("svid has no exp claim")
	}
	if exp <= now {
		return nil, fmt.Errorf("svid expired")
	}
	if nbf := claims.Int64("nbf"); nbf > 0 && nbf > now+30 {
		return nil, fmt.Errorf("svid not active yet")
	}
	if iss := claims.String("iss"); iss != v.spireIssuer {
		return nil, fmt.Errorf("unexpected svid issuer %q", iss)
	}
	if !claims.HasAudience(v.svidAud) {
		return nil, fmt.Errorf("svid audience did not include %q", v.svidAud)
	}
	if sub := claims.String("sub"); !strings.HasPrefix(sub, subjectPrefix) {
		return nil, fmt.Errorf("svid subject %q did not start with %q", sub, subjectPrefix)
	}
	return claims, nil
}

func b64ToBytes(b64 string) ([]byte, error) {
	raw, err := base64.RawURLEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("decode jwk coordinate: %w", err)
	}
	return raw, nil
}
