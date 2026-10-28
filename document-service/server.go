package main

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/redhat-et/zero-trust-agents-v2/internal/tokens"
)

type docServer struct {
	secret     string
	issuer     string
	department string
	docs       []*Document
	byID       map[string]*Document
	mux        *http.ServeMux
}

// NewServer builds the document service for one department. The token's
// aud must name the department (audience = target service) and its scope
// must cover each document's required department (scope = capability).
func NewServer(secret, issuer, department string, docs []*Document) *docServer {
	s := &docServer{
		secret:     secret,
		issuer:     issuer,
		department: department,
		docs:       docs,
		byID:       make(map[string]*Document, len(docs)),
		mux:        http.NewServeMux(),
	}
	for _, d := range docs {
		s.byID[d.ID] = d
	}
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	s.mux.HandleFunc("GET /documents", s.handleList)
	s.mux.HandleFunc("GET /documents/{id}", s.handleGet)
	return s
}

func (s *docServer) Handler() http.Handler { return s.mux }

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func (s *docServer) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write([]byte("ok\n"))
}

// authenticate verifies the bearer token is a final token issued for
// this department.
func (s *docServer) authenticate(r *http.Request) (tokens.Claims, string) {
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return nil, "missing_token"
	}
	claims, err := tokens.Verify(s.secret, strings.TrimPrefix(auth, "Bearer "))
	if err != nil || claims.String("demo_token_use") != tokens.UseFinal {
		return nil, "invalid_token"
	}
	if claims.String("iss") != s.issuer {
		return nil, "invalid_token"
	}
	if !claims.HasAudience(s.department) {
		return nil, "insufficient_scope"
	}
	return claims, ""
}

func (s *docServer) hasScope(claims tokens.Claims, depts []string) bool {
	if len(depts) == 0 {
		return true
	}
	scopes := strings.Fields(claims.String("scope"))
	for _, d := range depts {
		for _, sc := range scopes {
			if sc == d {
				return true
			}
		}
	}
	return false
}

func (s *docServer) handleList(w http.ResponseWriter, r *http.Request) {
	claims, errCode := s.authenticate(r)
	if errCode != "" {
		writeJSON(w, statusFor(errCode), map[string]string{"error": errCode})
		return
	}
	out := make([]map[string]any, 0, len(s.docs))
	for _, d := range s.docs {
		if s.hasScope(claims, requiredDepartments(d)) {
			out = append(out, map[string]any{
				"id": d.ID, "title": d.Title, "sensitivity": d.Sensitivity,
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"documents": out})
}

func (s *docServer) handleGet(w http.ResponseWriter, r *http.Request) {
	claims, errCode := s.authenticate(r)
	if errCode != "" {
		writeJSON(w, statusFor(errCode), map[string]string{"error": errCode})
		return
	}
	id := r.PathValue("id")
	d, ok := s.byID[id]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if !s.hasScope(claims, requiredDepartments(d)) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "insufficient_scope"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id": d.ID, "title": d.Title, "sensitivity": d.Sensitivity, "content": d.Content,
	})
}

func statusFor(errCode string) int {
	switch errCode {
	case "missing_token", "invalid_token":
		return http.StatusUnauthorized
	default:
		return http.StatusForbidden
	}
}
