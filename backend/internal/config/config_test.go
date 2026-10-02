package config

import (
	"os"
	"strings"
	"testing"
)

func TestPlaintextDatabaseHost(t *testing.T) {
	for _, c := range []struct {
		url  string
		want string // "" = acceptable
	}{
		{"postgres://u:p@db.example.com:5432/tark?sslmode=disable", "db.example.com"},
		{"postgres://u:p@db.example.com/tark", "db.example.com"},                          // pgx default is "prefer": can fall back to plaintext
		{"postgres://u:p@db.example.com/tark?sslmode=allow", "db.example.com"},            // plaintext first
		{"postgres://u:p@db.example.com/tark?sslmode=prefer", "db.example.com"},           // can fall back
		{"postgres://u:p@db.example.com/tark?sslmode=require", ""},                        // encrypted
		{"postgres://u:p@db.example.com/tark?sslmode=verify-full", ""},                    // encrypted and verified
		{"postgres://u:p@185.143.232.10/tark?sslmode=disable", "185.143.232.10"},          // public address
		{"postgres://u:p@10.0.0.5/tark?sslmode=disable", ""},                              // private address
		{"postgres://u:p@127.0.0.1/tark?sslmode=disable", ""},                             // loopback
		{"postgres://u:p@[::1]/tark?sslmode=disable", ""},                                 // loopback v6
		{"postgres://u:p@db/tark?sslmode=disable", ""},                                    // compose service name
		{"postgres://u:p@localhost/tark?sslmode=disable", ""},                             // local
		{"host=/var/run/postgresql dbname=tark user=u", ""},                               // unix socket
		{"postgres://u:p@db.example.com,10.0.0.5/tark?sslmode=require", ""},               // every host encrypted
		{"postgres://u:p@10.0.0.5,db.example.com/tark?sslmode=disable", "db.example.com"}, // a public fallback host
	} {
		if got := plaintextDatabaseHost(c.url); got != c.want {
			t.Errorf("%s: got %q, want %q", c.url, got, c.want)
		}
	}
}

// Load reads the real environment; this sets the minimum a valid
// configuration needs and then varies one thing.
func loadWith(t *testing.T, env map[string]string) (*Config, error) {
	t.Helper()
	base := map[string]string{
		"TARK_DATABASE_URL":      "postgres://u:p@db/tark?sslmode=disable",
		"TARK_TOKEN_KEY":         "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE",
		"TARK_LOOKUP_KEY":        "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI",
		"TARK_DATA_KEY":          "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM",
		"TARK_PASSWORD_PEPPER":   "BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ",
		"TARK_ENTITLEMENT_KEYS":  "k1:BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU",
		"TARK_GOOGLE_CLIENT_IDS": "x.apps.googleusercontent.com",
		"TARK_MAIL_DRIVER":       "log",
		"TARK_BAZAAR_FAKE":       "true",
		"TARK_ENV":               "development",
	}
	// Hermetic: a developer who has sourced .env.development (as the README
	// says to) has TARK_* variables set; none of them may leak into the test.
	for _, kv := range os.Environ() {
		if k, _, _ := strings.Cut(kv, "="); strings.HasPrefix(k, "TARK_") {
			t.Setenv(k, "")
		}
	}
	for k, v := range base {
		t.Setenv(k, v)
	}
	for k, v := range env {
		t.Setenv(k, v)
	}
	return Load()
}

func TestDocsDefaultToDevelopmentOnly(t *testing.T) {
	c, err := loadWith(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !c.DocsEnabled {
		t.Error("docs should be on by default in development")
	}

	// Production needs real mail and Bazaar settings to be valid at all.
	prod := map[string]string{
		"TARK_ENV": "production", "TARK_MAIL_DRIVER": "smtp", "TARK_BAZAAR_FAKE": "false",
		"TARK_SMTP_HOST": "smtp.example.com", "TARK_MAIL_FROM": "a@example.com",
		"TARK_BAZAAR_CLIENT_ID": "i", "TARK_BAZAAR_CLIENT_SECRET": "s", "TARK_BAZAAR_REFRESH_TOKEN": "r",
	}
	c, err = loadWith(t, prod)
	if err != nil {
		t.Fatal(err)
	}
	if c.DocsEnabled {
		t.Error("docs must be off by default in production")
	}
	prod["TARK_DOCS_ENABLED"] = "true"
	if c, err = loadWith(t, prod); err != nil || !c.DocsEnabled {
		t.Errorf("TARK_DOCS_ENABLED=true must turn them on: %v", err)
	}
}

func TestProductionRefusesPlaintextDatabaseOnPublicHost(t *testing.T) {
	prod := map[string]string{
		"TARK_ENV": "production", "TARK_MAIL_DRIVER": "smtp", "TARK_BAZAAR_FAKE": "false",
		"TARK_SMTP_HOST": "smtp.example.com", "TARK_MAIL_FROM": "a@example.com",
		"TARK_BAZAAR_CLIENT_ID": "i", "TARK_BAZAAR_CLIENT_SECRET": "s", "TARK_BAZAAR_REFRESH_TOKEN": "r",
		"TARK_DATABASE_URL": "postgres://u:p@db.example.com/tark?sslmode=disable",
	}
	if _, err := loadWith(t, prod); err == nil {
		t.Fatal("plaintext to a public host must be refused in production")
	}
	prod["TARK_DATABASE_ALLOW_PLAINTEXT"] = "true"
	if _, err := loadWith(t, prod); err != nil {
		t.Fatalf("the explicit escape hatch must work: %v", err)
	}
	prod["TARK_DATABASE_ALLOW_PLAINTEXT"] = ""
	prod["TARK_DATABASE_URL"] = "postgres://u:p@db.example.com/tark?sslmode=require"
	if _, err := loadWith(t, prod); err != nil {
		t.Fatalf("TLS must be accepted: %v", err)
	}
}

func TestAlertAndBackupSettings(t *testing.T) {
	c, err := loadWith(t, map[string]string{
		"TARK_ALERT_EMAILS": "a@example.com, b@example.com",
		"TARK_DOMAIN":       "api.tarkk.ir",
		"TARK_BACKUP_DIR":   "/backups",
		"TARK_BACKUP_KEY":   "BgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgY",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Monitor.AlertEmails) != 2 || c.Monitor.ServerName != "api.tarkk.ir" ||
		len(c.Backup.Key) != 32 || c.Backup.HourUTC != 23 || c.Backup.KeepDays != 14 {
		t.Fatalf("got %+v %+v", c.Monitor, c.Backup)
	}

	for name, env := range map[string]map[string]string{
		"placeholder recipient": {"TARK_ALERT_EMAILS": "CHANGE_ME@example.com"},
		"not an address":        {"TARK_ALERT_EMAILS": "pedi"},
		"header injection":      {"TARK_ALERT_EMAILS": "a@example.com\r\nBcc: x@evil.test"},
		"backups without a key": {"TARK_BACKUP_DIR": "/backups"},
		"short key":             {"TARK_BACKUP_DIR": "/backups", "TARK_BACKUP_KEY": "AQID"},
		"hour out of range":     {"TARK_BACKUP_HOUR_UTC": "24"},
		"keep nothing":          {"TARK_BACKUP_KEEP_DAYS": "0"},
	} {
		if _, err := loadWith(t, env); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
