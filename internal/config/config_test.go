package config

import (
	"os"
	"path/filepath"
	"testing"
)

const testYAML = `
users:
  - id: alice
    name: Alice
    departments: [engineering, finance]
`

const testAgentsYAML = `
agents:
  - audience: engineering-analyst
    scopes: [engineering]
`

// writeFile writes content to name under a fresh temp dir and returns
// the path.
func writeFile(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// writeTemp writes a users fixture and returns its path.
func writeTemp(t *testing.T, content string) string {
	t.Helper()
	return writeFile(t, "users.yaml", content)
}

// writeAgents writes an agents fixture and returns its path.
func writeAgents(t *testing.T, content string) string {
	t.Helper()
	return writeFile(t, "agents.yaml", content)
}

// loadTest loads the default fixture with an agents file in place.
func loadTest(t *testing.T) *Config {
	t.Helper()
	t.Setenv("AGENTS_FILE", writeAgents(t, testAgentsYAML))
	cfg, err := Load(writeTemp(t, testYAML))
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

// TestLoadReturnsUsers parses the users file and their departments.
func TestLoadReturnsUsers(t *testing.T) {
	cfg := loadTest(t)
	if len(cfg.Users) != 1 {
		t.Fatalf("want 1 user, got %d", len(cfg.Users))
	}
	u := cfg.Users[0]
	if u.ID != "alice" || u.Name != "Alice" {
		t.Fatalf("unexpected user: %+v", u)
	}
	if len(u.Departments) != 2 || u.Departments[0] != "engineering" || u.Departments[1] != "finance" {
		t.Fatalf("unexpected departments: %v", u.Departments)
	}
}

// TestLoadAgents parses agent audiences and their required scopes.
func TestLoadAgents(t *testing.T) {
	cfg := loadTest(t)
	if len(cfg.Agents) != 1 {
		t.Fatalf("want 1 agent, got %d", len(cfg.Agents))
	}
	a := cfg.Agents[0]
	if a.Audience != "engineering-analyst" {
		t.Errorf("audience: %q", a.Audience)
	}
	if len(a.Scopes) != 1 || a.Scopes[0] != "engineering" {
		t.Errorf("scopes: %v", a.Scopes)
	}
}

// TestLoadAgentsMissingFile fails closed when AGENTS_FILE points nowhere:
// an absent file must not mean "no agent audiences".
func TestLoadAgentsMissingFile(t *testing.T) {
	t.Setenv("AGENTS_FILE", filepath.Join(t.TempDir(), "absent.yaml"))
	if _, err := Load(writeTemp(t, testYAML)); err == nil {
		t.Fatal("want error for a missing agents file")
	}
}

// TestLoadAgentsDuplicateAudience rejects two agents claiming the same
// audience, since the later entry would silently shadow the earlier one.
func TestLoadAgentsDuplicateAudience(t *testing.T) {
	t.Setenv("AGENTS_FILE", writeAgents(t, `
agents:
  - audience: engineering-analyst
    scopes: [engineering]
  - audience: engineering-analyst
    scopes: [hr]
`))
	if _, err := Load(writeTemp(t, testYAML)); err == nil {
		t.Fatal("want error for a duplicate agent audience")
	}
}

// TestLoadAgentsRejectsDepartmentCollision refuses agent names that
// shadow a department (including public): the looser department rule
// would win, leaving the agent's scope list dead config.
func TestLoadAgentsRejectsDepartmentCollision(t *testing.T) {
	for _, audience := range []string{"engineering", "public"} {
		t.Run(audience, func(t *testing.T) {
			t.Setenv("AGENTS_FILE", writeAgents(t, `
agents:
  - audience: `+audience+`
    scopes: [engineering]
`))
			if _, err := Load(writeTemp(t, testYAML)); err == nil {
				t.Fatalf("want error for agent audience %q colliding with a department", audience)
			}
		})
	}
}

// TestLoadAgentsMissingScopes rejects an agent that declares no scopes:
// it could never admit anyone and is almost certainly a typo.
func TestLoadAgentsMissingScopes(t *testing.T) {
	t.Setenv("AGENTS_FILE", writeAgents(t, `
agents:
  - audience: engineering-analyst
    scopes: []
`))
	if _, err := Load(writeTemp(t, testYAML)); err == nil {
		t.Fatal("want error for an agent audience with no scopes")
	}
}

// TestLoadDefaults pins every unset field to its deployed default.
func TestLoadDefaults(t *testing.T) {
	cfg := loadTest(t)
	want := map[string]string{
		"GatewayPrefix":    "spiffe://openshell.local/openshell/gateway/",
		"SupervisorPrefix": "spiffe://openshell.local/openshell/sandbox/",
		"SPIREIssuer":      "http://spire-oidc:8080",
		"JWKSURI":          "http://spire-oidc:8080/keys",
		"SVIDAudience":     "http://token-issuer.zt-demo.svc",
		"TokenIssuer":      "http://token-issuer.zt-demo.svc",
		"ListenAddr":       ":8080",
		"SigningKeyFile":   "/etc/zt2/access-token-signing-key.pem",
	}
	got := map[string]string{
		"GatewayPrefix":    cfg.GatewayPrefix,
		"SupervisorPrefix": cfg.SupervisorPrefix,
		"SPIREIssuer":      cfg.SPIREIssuer,
		"JWKSURI":          cfg.JWKSURI,
		"SVIDAudience":     cfg.SVIDAudience,
		"TokenIssuer":      cfg.TokenIssuer,
		"ListenAddr":       cfg.ListenAddr,
		"SigningKeyFile":   cfg.SigningKeyFile,
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s: want %q, got %q", k, w, got[k])
		}
	}
}

// TestLoadEnvOverrides checks each environment override, including the
// JWKS URI deriving from SPIRE_ISSUER.
func TestLoadEnvOverrides(t *testing.T) {
	t.Setenv("AGENTS_FILE", writeAgents(t, testAgentsYAML))
	t.Setenv("GATEWAY_TRUST_DOMAIN_PREFIX", "spiffe://other/gateway/")
	t.Setenv("SUPERVISOR_TRUST_DOMAIN_PREFIX", "spiffe://other/sandbox/")
	t.Setenv("SPIRE_ISSUER", "http://other:9999")
	t.Setenv("JWT_SVID_AUDIENCE", "http://other-aud")
	t.Setenv("ACCESS_TOKEN_ISSUER", "http://other-iss")
	t.Setenv("PORT", ":9999")
	cfg, err := Load(writeTemp(t, testYAML))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.GatewayPrefix != "spiffe://other/gateway/" {
		t.Errorf("gateway prefix: %q", cfg.GatewayPrefix)
	}
	if cfg.SupervisorPrefix != "spiffe://other/sandbox/" {
		t.Errorf("supervisor prefix: %q", cfg.SupervisorPrefix)
	}
	if cfg.SPIREIssuer != "http://other:9999" {
		t.Errorf("spire issuer: %q", cfg.SPIREIssuer)
	}
	if cfg.JWKSURI != "http://other:9999/keys" {
		t.Errorf("jwks uri should derive from SPIRE_ISSUER, got %q", cfg.JWKSURI)
	}
	if cfg.SVIDAudience != "http://other-aud" {
		t.Errorf("svid audience: %q", cfg.SVIDAudience)
	}
	if cfg.TokenIssuer != "http://other-iss" {
		t.Errorf("token issuer: %q", cfg.TokenIssuer)
	}
	if cfg.ListenAddr != ":9999" {
		t.Errorf("listen addr: %q", cfg.ListenAddr)
	}
}

// TestLoadJWKSURIOverride lets SPIRE_JWKS_URI win over the derived URI.
func TestLoadJWKSURIOverride(t *testing.T) {
	t.Setenv("AGENTS_FILE", writeAgents(t, testAgentsYAML))
	t.Setenv("SPIRE_JWKS_URI", "http://explicit/keys")
	cfg, err := Load(writeTemp(t, testYAML))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.JWKSURI != "http://explicit/keys" {
		t.Errorf("jwks uri: %q", cfg.JWKSURI)
	}
}

// TestLoadSigningKeyDefault pins the mounted signing-key path.
func TestLoadSigningKeyDefault(t *testing.T) {
	cfg := loadTest(t)
	if cfg.SigningKeyFile != "/etc/zt2/access-token-signing-key.pem" {
		t.Errorf("signing key path: %q", cfg.SigningKeyFile)
	}
}

// TestLoadSigningKeyOverride honours ACCESS_TOKEN_SIGNING_KEY_FILE.
func TestLoadSigningKeyOverride(t *testing.T) {
	t.Setenv("AGENTS_FILE", writeAgents(t, testAgentsYAML))
	t.Setenv("ACCESS_TOKEN_SIGNING_KEY_FILE", "/tmp/other.pem")
	cfg, err := Load(writeTemp(t, testYAML))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SigningKeyFile != "/tmp/other.pem" {
		t.Errorf("signing key path: %q", cfg.SigningKeyFile)
	}
}
