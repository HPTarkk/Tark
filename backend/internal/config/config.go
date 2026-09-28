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

	"github.com/HPTarkk/Tark/backend/internal/secure"
)

type Config struct {
	Env         string // "production" or "development"
	HTTPAddr    string
	DatabaseURL string
	DBMaxConns  int32
	RunWorkers  bool

	// Where email links point, e.g. https://tarkk.ir. Links are
	// <base>/v/<purpose>#<token>; the fragment never reaches a web server.
	LinkBaseURL string

	// Client IP detection behind a CDN or load balancer. Header is only
	// honoured when the direct peer is inside TrustedProxies.
	ClientIPHeader string
	TrustedProxies []netip.Prefix

	Keys Keys

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
	Host     string
	Port     int
	Username string
	Password string
	From     string
	FromName string
	// "starttls" or "tls". There is no plaintext option.
	Security string
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

	c := &Config{
		Env:            get("TARK_ENV", "production"),
		HTTPAddr:       get("TARK_HTTP_ADDR", ":8080"),
		DatabaseURL:    secret("TARK_DATABASE_URL", true),
		DBMaxConns:     int32(integer("TARK_DB_MAX_CONNS", 20)),
		RunWorkers:     boolean("TARK_RUN_WORKERS", true),
		LinkBaseURL:    strings.TrimRight(get("TARK_LINK_BASE_URL", "https://tarkk.ir"), "/"),
		ClientIPHeader: get("TARK_CLIENT_IP_HEADER", ""),

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
		SKUs:         splitList(get("TARK_BAZAAR_SKUS", "tark_premium_1m,tark_premium_6m,tark_premium_12m")),
	}

	c.Mail = MailConfig{
		Driver:   get("TARK_MAIL_DRIVER", "smtp"),
		Host:     get("TARK_SMTP_HOST", ""),
		Port:     integer("TARK_SMTP_PORT", 587),
		Username: secret("TARK_SMTP_USERNAME", false),
		Password: secret("TARK_SMTP_PASSWORD", false),
		From:     get("TARK_MAIL_FROM", ""),
		FromName: get("TARK_MAIL_FROM_NAME", "Tark"),
		Security: get("TARK_SMTP_SECURITY", "starttls"),
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
		if c.Mail.Host == "" || c.Mail.From == "" {
			errs = append(errs, errors.New("TARK_SMTP_HOST and TARK_MAIL_FROM are required for the smtp mail driver"))
		}
		if c.Mail.Security != "starttls" && c.Mail.Security != "tls" {
			errs = append(errs, errors.New("TARK_SMTP_SECURITY must be starttls or tls"))
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
	if c.ClientIPHeader != "" && len(c.TrustedProxies) == 0 {
		errs = append(errs, errors.New("TARK_CLIENT_IP_HEADER needs TARK_TRUSTED_PROXIES, otherwise anyone can forge their IP"))
	}
	return errs
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
