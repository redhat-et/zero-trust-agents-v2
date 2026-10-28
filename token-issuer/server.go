package main

import (
	"encoding/json"
	"net/http"
	"os"

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

func (s *server) handleToken(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "not_implemented"})
}
