// Package tokens implements the demo's HS256 JWTs: subject, intermediate,
// and final access tokens share one signing secret (mirroring the upstream
// OpenShell spiffe-token-exchange-demo). Hand-rolled on purpose — this demo
// teaches what a verifier must check.
package tokens

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
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
}

const (
	algHS256 = "HS256"
)

var b64 = base64.RawURLEncoding

// Sign produces an HS256 JWS over the claims.
func Sign(secret string, claims Claims) (string, error) {
	hdr, err := json.Marshal(header{Alg: algHS256, Typ: "JWT"})
	if err != nil {
		return "", err
	}
	body, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	signingInput := b64.EncodeToString(hdr) + "." + b64.EncodeToString(body)
	return signingInput + "." + b64.EncodeToString(hmacSHA256(secret, signingInput)), nil
}

func hmacSHA256(secret, input string) []byte {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(input))
	return m.Sum(nil)
}

// Verify checks the HS256 signature (constant-time, with the header alg
// pinned — alg:none / RS256 forgeries are rejected before any payload
// trust) and token expiry. Issuer and claim semantics are the caller's.
func Verify(secret, token string) (Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("token must have three segments")
	}
	var h header
	hdrJSON, err := b64.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("decode header: %w", err)
	}
	if err := json.Unmarshal(hdrJSON, &h); err != nil {
		return nil, fmt.Errorf("parse header: %w", err)
	}
	if h.Alg != algHS256 {
		return nil, fmt.Errorf("unsupported alg %q", h.Alg)
	}
	want := hmacSHA256(secret, parts[0]+"."+parts[1])
	got, err := b64.DecodeString(parts[2])
	if err != nil || !hmac.Equal(want, got) {
		return nil, errors.New("signature validation failed")
	}
	claims, err := Parse(token)
	if err != nil {
		return nil, err
	}
	if exp := claims.Int64("exp"); exp > 0 && exp <= time.Now().Unix() {
		return nil, errors.New("token expired")
	}
	return claims, nil
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
