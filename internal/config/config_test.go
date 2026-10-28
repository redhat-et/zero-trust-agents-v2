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

func writeTemp(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "users.yaml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadReturnsUsers(t *testing.T) {
	t.Setenv("ACCESS_TOKEN_SECRET", "s3cret")
	cfg, err := Load(writeTemp(t, testYAML))
	if err != nil {
		t.Fatal(err)
	}
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

func TestLoadDefaults(t *testing.T) {
	t.Setenv("ACCESS_TOKEN_SECRET", "s3cret")
	cfg, err := Load(writeTemp(t, testYAML))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"GatewayPrefix":    "spiffe://openshell.local/openshell/gateway/",
		"SupervisorPrefix": "spiffe://openshell.local/openshell/sandbox/",
		"SPIREIssuer":      "http://spire-oidc:8080",
		"JWKSURI":          "http://spire-oidc:8080/keys",
		"SVIDAudience":     "http://token-issuer.zt-demo.svc",
		"TokenIssuer":      "http://token-issuer.zt-demo.svc",
		"ListenAddr":       ":8080",
	}
	got := map[string]string{
		"GatewayPrefix":    cfg.GatewayPrefix,
		"SupervisorPrefix": cfg.SupervisorPrefix,
		"SPIREIssuer":      cfg.SPIREIssuer,
		"JWKSURI":          cfg.JWKSURI,
		"SVIDAudience":     cfg.SVIDAudience,
		"TokenIssuer":      cfg.TokenIssuer,
		"ListenAddr":       cfg.ListenAddr,
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s: want %q, got %q", k, w, got[k])
		}
	}
}

func TestLoadEnvOverrides(t *testing.T) {
	t.Setenv("ACCESS_TOKEN_SECRET", "s3cret")
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

func TestLoadJWKSURIOverride(t *testing.T) {
	t.Setenv("ACCESS_TOKEN_SECRET", "s3cret")
	t.Setenv("SPIRE_JWKS_URI", "http://explicit/keys")
	cfg, err := Load(writeTemp(t, testYAML))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.JWKSURI != "http://explicit/keys" {
		t.Errorf("jwks uri: %q", cfg.JWKSURI)
	}
}

func TestLoadMissingSecret(t *testing.T) {
	t.Setenv("ACCESS_TOKEN_SECRET", "")
	if _, err := Load(writeTemp(t, testYAML)); err == nil {
		t.Fatal("want error for missing ACCESS_TOKEN_SECRET")
	}
}
