package main

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"

	"github.com/redhat-et/zero-trust-agents-v2/internal/config"
	"github.com/redhat-et/zero-trust-agents-v2/internal/tokens"
)

// JWKSVerifier verifies SPIFFE JWT-SVIDs against the SPIRE OIDC JWKS.
type JWKSVerifier interface {
	VerifySVID(jwt string, subjectPrefix string) (tokens.Claims, error)
}

type server struct {
	cfg    *config.Config
	secret string
	jwks   JWKSVerifier
	mux    *http.ServeMux
	byUser map[string]config.User
}

// NewServer builds the token issuer. jwks may be nil while only the
// subject-token endpoint is used; /token returns 501 until Task 4 wires it.
func NewServer(cfg *config.Config, jwks JWKSVerifier) *http.Server {
	s := &server{
		cfg:    cfg,
		secret: os.Getenv("ACCESS_TOKEN_SECRET"),
		jwks:   jwks,
		mux:    http.NewServeMux(),
		byUser: make(map[string]config.User),
	}
	for _, u := range cfg.Users {
		s.byUser[u.ID] = u
	}
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	s.mux.HandleFunc("GET /demo-subject-token", s.handleSubjectToken)
	s.mux.HandleFunc("POST /token", s.handleToken)
	return &http.Server{Addr: cfg.ListenAddr, Handler: s.mux}
}

// Handler exposes the routing for tests.
func (s *server) Handler() http.Handler { return s.mux }

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func (s *server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write([]byte("ok\n"))
}

func (s *server) handleSubjectToken(w http.ResponseWriter, r *http.Request) {
	userID := r.URL.Query().Get("user")
	if userID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing_user"})
		return
	}
	user, ok := s.byUser[userID]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown_user"})
		return
	}
	tok, err := tokens.Sign(s.secret, tokens.Claims{
		"iss":            s.cfg.TokenIssuer,
		"sub":            user.ID,
		"aud":            []string{"openshell-gateway", "account"},
		"scope":          "openid profile email",
		"departments":    user.Departments,
		"demo_token_use": tokens.UseUserSubject,
		"iat":            now(),
		"exp":            now() + 1800,
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"access_token": tok,
		"token_type":   "Bearer",
		"expires_in":   1800,
	})
}

const (
	tokenExchangeGrantType = "urn:ietf:params:oauth:grant-type:token-exchange"
	jwtSpiffeAssertType    = "urn:ietf:params:oauth:client-assertion-type:jwt-spiffe"
	intermediateTTL        = 300
)

// handleToken implements POST /token. The subject token's signature is
// verified once, then the demo_token_use claim decides which exchange
// branch runs — user_subject for the gateway (intermediate exchange),
// intermediate for the supervisor (final exchange). Unlike the upstream
// Node demo, an unrecognized or invalid token gets a specific error
// instead of falling through to a 500.
func (s *server) handleToken(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if r.Form.Get("grant_type") != tokenExchangeGrantType {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported_grant_type"})
		return
	}
	if r.Form.Get("client_assertion_type") != jwtSpiffeAssertType {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported_client_assertion_type"})
		return
	}
	assertion := r.Form.Get("client_assertion")
	if assertion == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing_client_assertion"})
		return
	}
	subjectToken := r.Form.Get("subject_token")
	if subjectToken == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing_subject_token"})
		return
	}
	if s.jwks == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error", "message": "jwks verifier not configured"})
		return
	}

	claims, err := tokens.Verify(s.secret, subjectToken)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid_subject_token"})
		return
	}
	// The client_assertion (a SPIFFE JWT-SVID) identifies the caller:
	// gateway or supervisor. Each branch then demands its own subject
	// token type, so a wrong-type token gets a specific error instead of
	// upstream's fall-through 500.
	gatewaySVID, gwErr := s.jwks.VerifySVID(assertion, s.cfg.GatewayPrefix)
	supervisorSVID, supErr := s.jwks.VerifySVID(assertion, s.cfg.SupervisorPrefix)
	switch {
	case gwErr == nil:
		if claims.String("demo_token_use") != tokens.UseUserSubject {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unsupported_token_use"})
			return
		}
		s.gatewayExchange(w, r, claims, gatewaySVID)
	case supErr == nil:
		if claims.String("demo_token_use") != tokens.UseIntermediate {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unsupported_token_use"})
			return
		}
		s.handleSupervisorExchange(w, r, claims, supervisorSVID)
	default:
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid_client_assertion"})
	}
}

// gatewayExchange: the gateway presents its own SVID plus a user
// subject token, and receives an intermediate token bound to one
// supervisor's SPIFFE ID.
func (s *server) gatewayExchange(w http.ResponseWriter, r *http.Request, userClaims tokens.Claims, gatewaySVID tokens.Claims) {
	audience := r.Form.Get("audience")
	if !strings.HasPrefix(audience, s.cfg.SupervisorPrefix) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported_intermediate_audience", "audience": audience})
		return
	}
	tok, err := tokens.Sign(s.secret, tokens.Claims{
		"iss":            s.cfg.TokenIssuer,
		"sub":            userClaims.String("sub"),
		"aud":            []string{audience},
		"scope":          userClaims.String("scope"),
		"azp":            gatewaySVID.String("sub"),
		"client_id":      gatewaySVID.String("sub"),
		"demo_token_use": tokens.UseIntermediate,
		"iat":            now(),
		"exp":            now() + intermediateTTL,
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"access_token": tok,
		"token_type":   "Bearer",
		"expires_in":   intermediateTTL,
	})
}

// handleSupervisorExchange lands in Task 5.
func (s *server) handleSupervisorExchange(w http.ResponseWriter, r *http.Request, claims tokens.Claims, supervisorSVID tokens.Claims) {
	writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "not_implemented"})
}
