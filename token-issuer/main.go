// The token-issuer: mints demo user subject tokens and (in later tasks)
// performs RFC 8693 gateway/supervisor token exchange with SPIFFE JWT-SVID
// client authentication.
package main

import (
	"log/slog"
	"os"
	"time"

	"github.com/redhat-et/zero-trust-agents-v2/internal/config"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	usersFile := os.Getenv("USERS_FILE")
	if usersFile == "" {
		usersFile = "config/users.yaml"
	}
	cfg, err := config.Load(usersFile)
	if err != nil {
		logger.Error("load config", "err", err)
		os.Exit(1)
	}
	srv := NewServer(cfg, nil)
	logger.Info("token issuer listening", "addr", cfg.ListenAddr)
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("serve", "err", err)
		os.Exit(1)
	}
}

func now() int64 { return time.Now().Unix() }
