// Package config loads demo configuration: users with departments, and
// the SPIFFE/token-issuer wiring. Values are tuned for the Stage 1
// Podman deployment; every field can be overridden by environment
// variable inside Load.
package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type User struct {
	ID          string   `yaml:"id"`
	Name        string   `yaml:"name"`
	Departments []string `yaml:"departments"`
}

type usersFile struct {
	Users []User `yaml:"users"`
}

type Config struct {
	Users            []User
	GatewayPrefix    string
	SupervisorPrefix string
	SPIREIssuer      string
	JWKSURI          string
	SVIDAudience     string
	TokenIssuer      string
	ListenAddr       string
	SigningKeyFile   string
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Load reads users from the YAML file at path and applies environment
// overrides. The signing key's presence is validated by the issuer when
// it loads the file, not here: verifiers of this package never hold it.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read users file: %w", err)
	}
	var uf usersFile
	if err := yaml.Unmarshal(data, &uf); err != nil {
		return nil, fmt.Errorf("parse users file: %w", err)
	}
	spireIssuer := envOr("SPIRE_ISSUER", "http://spire-oidc:8080")
	return &Config{
		Users:            uf.Users,
		GatewayPrefix:    envOr("GATEWAY_TRUST_DOMAIN_PREFIX", "spiffe://openshell.local/openshell/gateway/"),
		SupervisorPrefix: envOr("SUPERVISOR_TRUST_DOMAIN_PREFIX", "spiffe://openshell.local/openshell/sandbox/"),
		SPIREIssuer:      spireIssuer,
		JWKSURI:          envOr("SPIRE_JWKS_URI", spireIssuer+"/keys"),
		SVIDAudience:     envOr("JWT_SVID_AUDIENCE", "http://token-issuer.zt-demo.svc"),
		TokenIssuer:      envOr("ACCESS_TOKEN_ISSUER", "http://token-issuer.zt-demo.svc"),
		ListenAddr:       envOr("PORT", ":8080"),
		SigningKeyFile:   envOr("ACCESS_TOKEN_SIGNING_KEY_FILE", "/etc/zt2/access-token-signing-key.pem"),
	}, nil
}
