// The document-service: a protected resource server. One instance runs
// per department; access requires a final token (from the token-issuer's
// supervisor exchange) whose audience names this service's department and
// whose scope covers the document's required department.
package main

import (
	"log/slog"
	"net/http"
	"os"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	secret := os.Getenv("ACCESS_TOKEN_SECRET")
	if secret == "" {
		logger.Error("ACCESS_TOKEN_SECRET is required")
		os.Exit(1)
	}
	issuer := os.Getenv("ACCESS_TOKEN_ISSUER")
	if issuer == "" {
		issuer = "http://token-issuer.zt-demo.svc"
	}
	department := os.Getenv("DEPARTMENT")
	if department == "" {
		logger.Error("DEPARTMENT is required (engineering|finance|admin|hr|public)")
		os.Exit(1)
	}
	addr := os.Getenv("PORT")
	if addr == "" {
		addr = ":8080"
	}
	srv := NewServer(secret, issuer, department, Documents(department))
	logger.Info("document service listening", "addr", addr, "department", department)
	if err := http.ListenAndServe(addr, srv.Handler()); err != nil {
		logger.Error("serve", "err", err)
		os.Exit(1)
	}
}
