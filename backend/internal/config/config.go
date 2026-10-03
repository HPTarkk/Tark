// Package config reads the service configuration from the environment.
//
// Every secret can be given either directly (TARK_X) or as a path to a file
// holding it (TARK_X_FILE), which suits secret mounts on a container
// platform. Configuration is validated up front: the service refuses to
// start rather than run with a missing or weak secret.
package config

import (
	"errors"
	"fmt"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/HPTarkk/Tark/backend/internal/secure"
)

type Config struct {
	Env         string // "production" or "development"
	HTTPAddr    string
	DatabaseURL string
	DBMaxConns  int32
	// DBAuxConns sizes a second, small pool used only for single-statement side
	// writes (audit events, rate-limit counters). They are issued while a
	// request already holds a transaction connection; if they shared its pool,
	// enough concurrent requests would each hold a connection while waiting
	// for a second one, and nothing could ever proceed.
	DBAuxConns int32
	// DBAllowPlaintext lets production talk to a database over an unencrypted
	// connection even when its address looks public. Only for a private network
	// whose names look public (an FQDN pointing at a private address).
	DBAllowPlaintext bool
	// DocsEnabled serves the interactive API docs at /docs and the contract at
	// /openapi.yaml. On by default in development only.
	DocsEnabled bool
	RunWorkers  bool
	// AdminAddr serves the admin panel on its own listener. Empty: no panel.
	AdminAddr string

	// Where email links point, e.g. https://tarkk.ir. Links are
	// <base>/v/<purpose>#<token>; the fragment never reaches a web server.
	LinkBaseURL string

	// Client IP detection behind a CDN or load balancer. Header is only
	// honoured when the direct peer is inside TrustedProxies.
	ClientIPHeader string
	TrustedProxies []netip.Prefix

	Keys Keys

	Monitor MonitorConfig
	Backup  BackupConfig
	Log     LogConfig
	// MetricsAddr serves /metrics (Prometheus text format) on its own
	// listener. Empty: not served; the admin panel still shows them.
	MetricsAddr string

	Google GoogleConfig
	Bazaar BazaarConfig
	Mail   MailConfig
	Policy EntitlementPolicy

	AccessTokenTTL     time.Duration
	RefreshTokenTTL    time.Duration // idle lifetime; each refresh extends it
	SessionMaxLifetime time.Duration
	PasswordHashSlots  int
}

type Keys struct {
	TokenKey  []byte // HMAC key for access tokens
	LookupKey []byte // HMAC key for stored lookup hashes
	DataKey   []byte // AES-256-GCM key for recoverable secrets
	Pepper    []byte // password pepper

	// Entitlement signing keys by key id (Ed25519 seeds) and the one used
	// for new tokens.
	EntitlementSeeds map[string][]byte
	EntitlementKID   string
}

type GoogleConfig struct {
	// OAuth client ids whose ID tokens are accepted (the `aud` claim).
	ClientIDs    []string
	RequireNonce bool
	JWKSURL      string
}

type BazaarConfig struct {
	// Fake answers every token as a one-month active subscription. Only
	// allowed in development.
	Fake         bool
	BaseURL      string
	PackageName  string
	ClientID     string
	ClientSecret string
	RefreshToken string
	SKUs         []string
}

type MailConfig struct {
	Driver   string // "smtp" or "log" (development only)
	FromName string
	// Servers are tried in order. The first is TARK_SMTP_*, the optional
	// backup is TARK_SMTP2_* (meant for a provider inside Iran, for when
	// the first one is unreachable from there).
	Servers []SMTPServer
}

type SMTPServer struct {
	Name     string
	Host     string
	Port     int
	Username string
	Password string
	From     string
	// "starttls" or "tls". There is no plaintext option.
	Security string
}

type MonitorConfig struct {
	// Who gets alert emails. Empty: alerts only go to the log.
	AlertEmails []string
	// Names this server in alert subjects; defaults to TARK_DOMAIN.
	ServerName string
	// TLSAddr is where the HTTPS front end answers (caddy:443); empty skips
	// the certificate check. TLSNames are the host names to check there,
	// TARK_DOMAIN and TARK_ADMIN_DOMAIN by default.
	TLSAddr  string
	TLSNames []string
}

type LogConfig struct {
	// Dir keeps the log on disk, one file per day. Empty: stdout only.
	Dir      string
	KeepDays int
}

type BackupConfig struct {
	// Dir enables daily backups into it. Empty: no backups.
	Dir string
	// Key encrypts backups (32 bytes). Required with Dir.
	Key      []byte
	HourUTC  int
	KeepDays int
}

type EntitlementPolicy struct {
	GraceHours           int
	RefreshDays          int
	SuspiciousOfflineHrs int
}

func Load() (*Config, error) {
	var errs []error
	get := func(name, def string) string {
		if v, ok := os.LookupEnv(name); ok && v != "" {
			return v
		}
		return def
	}
	secret := func(name string, required bool) string {
		if path := os.Getenv(name + "_FILE"); path != "" {
			b, err := os.ReadFile(path)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s_FILE: %w", name, err))
				return ""
			}
			return strings.TrimSpace(string(b))
		}
		v := os.Getenv(name)
		if v == "" && required {
			errs = append(errs, fmt.Errorf("%s is required", name))
		}
		return v
	}
	key := func(name string) []byte {
		v := secret(name, true)
		if v == "" {
			return nil
		}
		b, err := secure.DecodeKey(name, v)
		if err != nil {
			errs = append(errs, err)
		}
		return b
	}
	integer := func(name string, def int) int {
		v := get(name, "")
		if v == "" {
			return def
		}
		n, err := strconv.Atoi(v)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", name, err))
		}
		return n
	}
	boolean := func(name string, def bool) bool {
		v := get(name, "")
		if v == "" {
			return def
		}
		b, err := strconv.ParseBool(v)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", name, err))
		}
		return b
	}
	duration := func(name string, def time.Duration) time.Duration {
		v := get(name, "")
		if v == "" {
			return def
		}
		d, err := time.ParseDuration(v)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", name, err))
		}
		return d
	}

	env := get("TARK_ENV", "production")
	c := &Config{
		Env:              env,
		DocsEnabled:      boolean("TARK_DOCS_ENABLED", env == "development"),
		HTTPAddr:         get("TARK_HTTP_ADDR", ":8080"),
		DatabaseURL:      secret("TARK_DATABASE_URL", true),
		DBMaxConns:       int32(integer("TARK_DB_MAX_CONNS", 20)),
		DBAuxConns:       int32(integer("TARK_DB_AUX_CONNS", 5)),
		DBAllowPlaintext: boolean("TARK_DATABASE_ALLOW_PLAINTEXT", false),
		RunWorkers:       boolean("TARK_RUN_WORKERS", true),
		AdminAddr:        get("TARK_ADMIN_ADDR", ""),
		LinkBaseURL:      strings.TrimRight(get("TARK_LINK_BASE_URL", "https://tarkk.ir"), "/"),
		ClientIPHeader:   get("TARK_CLIENT_IP_HEADER", ""),

		AccessTokenTTL:     duration("TARK_ACCESS_TOKEN_TTL", 15*time.Minute),
		RefreshTokenTTL:    duration("TARK_REFRESH_TOKEN_TTL", 180*24*time.Hour),
		SessionMaxLifetime: duration("TARK_SESSION_MAX_LIFETIME", 2*365*24*time.Hour),
		PasswordHashSlots:  integer("TARK_PASSWORD_HASH_SLOTS", 4),
	}

	for _, p := range splitList(get("TARK_TRUSTED_PROXIES", "")) {
		prefix, err := netip.ParsePrefix(p)
		if err != nil {
			errs = append(errs, fmt.Errorf("TARK_TRUSTED_PROXIES: %w", err))
			continue
		}
		c.TrustedProxies = append(c.TrustedProxies, prefix)
	}

	c.Keys = Keys{
		TokenKey:  key("TARK_TOKEN_KEY"),
		LookupKey: key("TARK_LOOKUP_KEY"),
		DataKey:   key("TARK_DATA_KEY"),
		Pepper:    key("TARK_PASSWORD_PEPPER"),
	}
	c.Keys.EntitlementSeeds, c.Keys.EntitlementKID = parseEntitlementKeys(
		secret("TARK_ENTITLEMENT_KEYS", true), get("TARK_ENTITLEMENT_ACTIVE_KID", ""), &errs)

	c.Monitor = MonitorConfig{
		AlertEmails: splitList(get("TARK_ALERT_EMAILS", "")),
		ServerName:  get("TARK_ALERT_SERVER_NAME", get("TARK_DOMAIN", "")),
		TLSAddr:     get("TARK_ALERT_TLS_ADDR", ""),
		TLSNames:    splitList(get("TARK_ALERT_TLS_NAMES", strings.Join(splitList(get("TARK_DOMAIN", "")+","+get("TARK_ADMIN_DOMAIN", "")), ","))),
	}
	c.Log = LogConfig{
		Dir:      get("TARK_LOG_DIR", ""),
		KeepDays: integer("TARK_LOG_KEEP_DAYS", 30),
	}
	c.MetricsAddr = get("TARK_METRICS_ADDR", "")
	c.Backup = BackupConfig{
		Dir:      get("TARK_BACKUP_DIR", ""),
		HourUTC:  integer("TARK_BACKUP_HOUR_UTC", 23),
		KeepDays: integer("TARK_BACKUP_KEEP_DAYS", 14),
	}
	if c.Backup.Dir != "" {
		c.Backup.Key = key("TARK_BACKUP_KEY")
	}

	c.Google = GoogleConfig{
		ClientIDs:    splitList(get("TARK_GOOGLE_CLIENT_IDS", "")),
		RequireNonce: boolean("TARK_GOOGLE_REQUIRE_NONCE", true),
		JWKSURL:      get("TARK_GOOGLE_JWKS_URL", "https://www.googleapis.com/oauth2/v3/certs"),
	}

	c.Bazaar = BazaarConfig{
		Fake:         boolean("TARK_BAZAAR_FAKE", false),
		BaseURL:      strings.TrimRight(get("TARK_BAZAAR_BASE_URL", "https://pardakht.cafebazaar.ir/devapi/v2"), "/"),
		PackageName:  get("TARK_BAZAAR_PACKAGE", "com.b1101.tark"),
		ClientID:     secret("TARK_BAZAAR_CLIENT_ID", false),
		ClientSecret: secret("TARK_BAZAAR_CLIENT_SECRET", false),
		RefreshToken: secret("TARK_BAZAAR_REFRESH_TOKEN", false),
		SKUs:         splitList(get("TARK_BAZAAR_SKUS", "tark_premium_1m,tark_premium_3m,tark_premium_6m,tark_premium_12m")),
	}

	smtpServer := func(name, prefix, fromVar string) SMTPServer {
		return SMTPServer{
			Name:     name,
			Host:     get(prefix+"_HOST", ""),
			Port:     integer(prefix+"_PORT", 587),
			Username: secret(prefix+"_USERNAME", false),
			Password: secret(prefix+"_PASSWORD", false),
			From:     get(fromVar, ""),
			Security: get(prefix+"_SECURITY", "starttls"),
		}
	}
	c.Mail = MailConfig{
		Driver:   get("TARK_MAIL_DRIVER", "smtp"),
		FromName: get("TARK_MAIL_FROM_NAME", "Tark"),
		Servers:  []SMTPServer{smtpServer("primary", "TARK_SMTP", "TARK_MAIL_FROM")},
	}
	if backup := smtpServer("backup", "TARK_SMTP2", "TARK_SMTP2_FROM"); backup.Host != "" {
		c.Mail.Servers = append(c.Mail.Servers, backup)
	}

	c.Policy = EntitlementPolicy{
		GraceHours:           integer("TARK_POLICY_GRACE_HOURS", 72),
		RefreshDays:          integer("TARK_POLICY_REFRESH_DAYS", 5),
		SuspiciousOfflineHrs: integer("TARK_POLICY_SUSPICIOUS_OFFLINE_HOURS", 72),
	}

	errs = append(errs, c.validate()...)
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	return c, nil
}

func (c *Config) Development() bool { return c.Env == "development" }

func (c *Config) validate() []error {
	var errs []error
	if c.Env != "production" && c.Env != "development" {
		errs = append(errs, errors.New("TARK_ENV must be production or development"))
	}
	if !strings.HasPrefix(c.LinkBaseURL, "https://") && !c.Development() {
		errs = append(errs, errors.New("TARK_LINK_BASE_URL must be https"))
	}
	if len(c.Google.ClientIDs) == 0 {
		errs = append(errs, errors.New("TARK_GOOGLE_CLIENT_IDS is required"))
	}
	if c.AccessTokenTTL < time.Minute || c.AccessTokenTTL > time.Hour {
		errs = append(errs, errors.New("TARK_ACCESS_TOKEN_TTL must be between 1m and 1h"))
	}
	if c.RefreshTokenTTL < time.Hour || c.RefreshTokenTTL > c.SessionMaxLifetime {
		errs = append(errs, errors.New("TARK_REFRESH_TOKEN_TTL must be at least 1h and at most TARK_SESSION_MAX_LIFETIME"))
	}
	switch c.Mail.Driver {
	case "smtp":
		for i, srv := range c.Mail.Servers {
			prefix, from := "TARK_SMTP", "TARK_MAIL_FROM"
			if i > 0 {
				prefix, from = "TARK_SMTP2", "TARK_SMTP2_FROM"
			}
			if srv.Host == "" || srv.From == "" {
				errs = append(errs, fmt.Errorf("%s_HOST and %s are required for the smtp mail driver", prefix, from))
			}
			if srv.Security != "starttls" && srv.Security != "tls" {
				errs = append(errs, fmt.Errorf("%s_SECURITY must be starttls or tls", prefix))
			}
		}
	case "log":
		if !c.Development() {
			errs = append(errs, errors.New("TARK_MAIL_DRIVER=log is only allowed with TARK_ENV=development"))
		}
	default:
		errs = append(errs, errors.New("TARK_MAIL_DRIVER must be smtp or log"))
	}
	if c.Bazaar.Fake {
		if !c.Development() {
			errs = append(errs, errors.New("TARK_BAZAAR_FAKE is only allowed with TARK_ENV=development"))
		}
	} else if c.Bazaar.ClientID == "" || c.Bazaar.ClientSecret == "" || c.Bazaar.RefreshToken == "" {
		errs = append(errs, errors.New("TARK_BAZAAR_CLIENT_ID, TARK_BAZAAR_CLIENT_SECRET and TARK_BAZAAR_REFRESH_TOKEN are required"))
	}
	p := c.Policy
	// Same bounds as the app's verifier; a token outside them is refused.
	if p.GraceHours < 0 || p.GraceHours > 336 || p.RefreshDays < 0 || p.RefreshDays > 30 ||
		p.SuspiciousOfflineHrs < 1 || p.SuspiciousOfflineHrs > 720 {
		errs = append(errs, errors.New("entitlement policy numbers are outside the bounds the app accepts"))
	}
	if c.DBMaxConns < 2 {
		errs = append(errs, errors.New("TARK_DB_MAX_CONNS must be at least 2"))
	}
	if c.DBAuxConns < 1 {
		errs = append(errs, errors.New("TARK_DB_AUX_CONNS must be at least 1"))
	}
	if !c.Development() && !c.DBAllowPlaintext {
		if host := plaintextDatabaseHost(c.DatabaseURL); host != "" {
			errs = append(errs, fmt.Errorf("TARK_DATABASE_URL reaches %q without TLS; use sslmode=require (or verify-full), "+
				"or set TARK_DATABASE_ALLOW_PLAINTEXT=true if that address is on a private network", host))
		}
	}
	for _, e := range c.Monitor.AlertEmails {
		if strings.Count(e, "@") != 1 || strings.ContainsAny(e, " <>\r\n") || strings.Contains(e, "CHANGE_ME") {
			errs = append(errs, fmt.Errorf("TARK_ALERT_EMAILS: %q is not an email address", e))
		}
	}
	if c.AdminAddr != "" && c.AdminAddr == c.HTTPAddr {
		errs = append(errs, errors.New("TARK_ADMIN_ADDR must differ from TARK_HTTP_ADDR: the panel never shares the public API's listener"))
	}
	if c.MetricsAddr != "" && (c.MetricsAddr == c.HTTPAddr || c.MetricsAddr == c.AdminAddr) {
		errs = append(errs, errors.New("TARK_METRICS_ADDR must differ from TARK_HTTP_ADDR and TARK_ADMIN_ADDR: metrics are never served to the public"))
	}
	if c.Monitor.TLSAddr != "" && len(c.Monitor.TLSNames) == 0 {
		errs = append(errs, errors.New("TARK_ALERT_TLS_ADDR needs host names: set TARK_DOMAIN or TARK_ALERT_TLS_NAMES"))
	}
	if c.Log.KeepDays < 1 {
		errs = append(errs, errors.New("TARK_LOG_KEEP_DAYS must be at least 1"))
	}
	if c.Backup.HourUTC < 0 || c.Backup.HourUTC > 23 {
		errs = append(errs, errors.New("TARK_BACKUP_HOUR_UTC must be 0 to 23"))
	}
	if c.Backup.KeepDays < 1 {
		errs = append(errs, errors.New("TARK_BACKUP_KEEP_DAYS must be at least 1"))
	}
	if c.ClientIPHeader != "" && len(c.TrustedProxies) == 0 {
		errs = append(errs, errors.New("TARK_CLIENT_IP_HEADER needs TARK_TRUSTED_PROXIES, otherwise anyone can forge their IP"))
	}
	return errs
}

// plaintextDatabaseHost returns the first database host the URL would connect
// to without TLS, unless that host is clearly on a private network (a unix
// socket, loopback, a private address, or a single-label name such as a
// compose service). "" means nothing to report. A URL that does not parse is
// left for store.Open to complain about.
func plaintextDatabaseHost(url string) string {
	pc, err := pgconn.ParseConfig(url)
	if err != nil {
		return ""
	}
	type target struct {
		host string
		tls  bool
	}
	targets := []target{{pc.Host, pc.TLSConfig != nil}}
	for _, f := range pc.Fallbacks {
		targets = append(targets, target{f.Host, f.TLSConfig != nil})
	}
	for _, t := range targets {
		if !t.tls && !privateHost(t.host) {
			return t.host
		}
	}
	return ""
}

func privateHost(host string) bool {
	if strings.HasPrefix(host, "/") || host == "localhost" {
		return true
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
	}
	return !strings.Contains(host, ".")
}

// parseEntitlementKeys reads "k1:<base64 seed>,k2:<base64 seed>".
func parseEntitlementKeys(raw, active string, errs *[]error) (map[string][]byte, string) {
	keys := map[string][]byte{}
	first := ""
	for _, entry := range splitList(raw) {
		kid, value, ok := strings.Cut(entry, ":")
		kid = strings.TrimSpace(kid)
		if !ok || kid == "" || strings.ContainsAny(kid, ".") {
			*errs = append(*errs, errors.New("TARK_ENTITLEMENT_KEYS entries must be kid:<base64 seed> and the kid cannot contain a dot"))
			continue
		}
		seed, err := secure.DecodeKey("TARK_ENTITLEMENT_KEYS["+kid+"]", strings.TrimSpace(value))
		if err != nil {
			*errs = append(*errs, err)
			continue
		}
		keys[kid] = seed
		if first == "" {
			first = kid
		}
	}
	if raw != "" && len(keys) == 0 {
		*errs = append(*errs, errors.New("TARK_ENTITLEMENT_KEYS has no usable key"))
	}
	if active == "" {
		active = first
	}
	if _, ok := keys[active]; raw != "" && !ok {
		*errs = append(*errs, fmt.Errorf("TARK_ENTITLEMENT_ACTIVE_KID %q is not in TARK_ENTITLEMENT_KEYS", active))
	}
	return keys, active
}

func splitList(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}
