// Package config loads demo configuration: users with departments, and
// the SPIFFE/token-issuer wiring. Values are tuned for the Stage 1
// Podman deployment; every field can be overridden by environment
// variable inside Load.
package config

import (
	"errors"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type User struct {
	ID          string   `yaml:"id"`
	Name        string   `yaml:"name"`
	Departments []string `yaml:"departments"`
}

// Agent is an A2A audience: the scope it requires is the minimum the
// caller must hold for the exchange to succeed.
type Agent struct {
	Audience string   `yaml:"audience"`
	Scopes   []string `yaml:"scopes"`
}

type usersFile struct {
	Users []User `yaml:"users"`
}

type agentsFile struct {
	Agents []Agent `yaml:"agents"`
}

// DepartmentAudiences are the built-in department audiences. Agent
// audiences must not reuse these names: the department rule is looser,
// so a collision would silently make the agent's scope list dead config.
var DepartmentAudiences = map[string]bool{
	"engineering": true, "finance": true, "admin": true, "hr": true, "public": true,
}

type Config struct {
	Users            []User
	Agents           []Agent
	GatewayPrefix    string
	SupervisorPrefix string
	SPIREIssuer      string
	JWKSURI          string
	SVIDAudience     string
	TokenIssuer      string
	ListenAddr       string
	SigningKeyFile   string
}

// envOr returns the environment value for key, or def when it is unset
// or empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Load reads users from the YAML file at path and agents from
// AGENTS_FILE, then applies environment overrides. The signing key's
// presence is validated by the issuer when it loads the file, not here:
// verifiers of this package never hold it.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read users file: %w", err)
	}
	var uf usersFile
	if err := yaml.Unmarshal(data, &uf); err != nil {
		return nil, fmt.Errorf("parse users file: %w", err)
	}
	agents, err := loadAgents(envOr("AGENTS_FILE", "config/agents.yaml"))
	if err != nil {
		return nil, err
	}
	spireIssuer := envOr("SPIRE_ISSUER", "http://spire-oidc:8080")
	return &Config{
		Users:            uf.Users,
		Agents:           agents,
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

// loadAgents reads agent audiences from path and rejects the configs
// that would otherwise misroute silently: empty or duplicate audiences,
// names that collide with departments, and agents with no scopes.
func loadAgents(path string) ([]Agent, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read agents file: %w", err)
	}
	var af agentsFile
	if err := yaml.Unmarshal(data, &af); err != nil {
		return nil, fmt.Errorf("parse agents file: %w", err)
	}
	seen := make(map[string]bool, len(af.Agents))
	for _, a := range af.Agents {
		if a.Audience == "" {
			return nil, errors.New("agents file: audience is required")
		}
		if DepartmentAudiences[a.Audience] {
			return nil, fmt.Errorf("agents file: audience %q collides with a department audience", a.Audience)
		}
		if len(a.Scopes) == 0 {
			return nil, fmt.Errorf("agents file: %s declares no scopes", a.Audience)
		}
		if seen[a.Audience] {
			return nil, fmt.Errorf("agents file: duplicate audience %q", a.Audience)
		}
		seen[a.Audience] = true
	}
	return af.Agents, nil
}
