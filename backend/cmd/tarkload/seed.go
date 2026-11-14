package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/password"
	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

// Everything about a made-up account follows from its number, so `run` can
// sign in as account 137 without a file listing what `seed` wrote.
const (
	seedPassword = "Load-test-passphrase-1"
	emailDomain  = "loadtest.invalid" // .invalid never resolves (RFC 2606)
)

func digest(kind string, i int) [32]byte {
	return sha256.Sum256(fmt.Appendf(nil, "tarkload:%s:%d", kind, i))
}

func seedUUID(kind string, i int) string {
	d := digest(kind, i)
	d[6] = d[6]&0x0f | 0x40
	d[8] = d[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", d[0:4], d[4:6], d[6:8], d[8:10], d[10:16])
}

func seedEmail(i int) string { return fmt.Sprintf("user%07d@%s", i, emailDomain) }

// seedInstallKey has the shape of the app's install key (32 bytes, base64url).
func seedInstallKey(i int) string {
	d := digest("install", i)
	return base64.RawURLEncoding.EncodeToString(d[:])
}

func seedRefreshToken(i int) string {
	d := digest("refresh", i)
	return "trt1_" + base64.RawURLEncoding.EncodeToString(d[:])
}

// hasPassword: seven accounts in ten can sign in with the password; the rest
// are Google-only, as a share of real accounts are.
func hasPassword(i int) bool { return i%10 < 7 }

func seedCmd(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("seed", flag.ContinueOnError)
	users := fs.Int("users", 200000, "accounts to create")
	history := fs.Int("history", 3, "used refresh tokens kept per session, as months of real use leave behind")
	subscribers := fs.Int("subscribers", 5, "percent of accounts with a running subscription")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	pool, err := store.Open(ctx, cfg.DatabaseURL, 4)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := store.Migrate(ctx, pool); err != nil {
		return err
	}
	var existing int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&existing); err != nil {
		return err
	}
	if existing > 0 {
		return errors.New("the database already has accounts; seed only an empty one")
	}

	lookup, err := secure.NewHasher(cfg.Keys.LookupKey)
	if err != nil {
		return err
	}
	sealer, err := secure.NewSealer(cfg.Keys.DataKey)
	if err != nil {
		return err
	}
	pw, err := password.New(cfg.Keys.Pepper, password.DefaultParams, 1)
	if err != nil {
		return err
	}
	// One hash for everyone: hashing 200,000 passwords would take most of an
	// hour and the server checks each one at full cost either way.
	hash, err := pw.Hash(ctx, seedPassword)
	if err != nil {
		return err
	}

	n := *users
	now := time.Now().UTC()
	start := time.Now()
	copyRows := func(table string, cols []string, count int, row func(i int) []any) error {
		_, err := pool.CopyFrom(ctx, pgx.Identifier{table}, cols, pgx.CopyFromSlice(count, func(i int) ([]any, error) {
			return row(i), nil
		}))
		if err != nil {
			return fmt.Errorf("seed %s: %w", table, err)
		}
		fmt.Printf("  %-22s %9d rows  (%s)\n", table, count, time.Since(start).Round(time.Millisecond))
		return nil
	}
	// Accounts opened evenly over the last year.
	created := func(i int) time.Time {
		return now.Add(-time.Duration(float64(n-i) / float64(n) * float64(365*24*time.Hour)))
	}

	if err := copyRows("users", []string{"id", "name", "created_at", "updated_at"}, n, func(i int) []any {
		return []any{seedUUID("user", i), fmt.Sprintf("Load user %d", i), created(i), created(i)}
	}); err != nil {
		return err
	}
	if err := copyRows("user_emails", []string{"user_id", "email", "is_primary", "verified_at", "created_at"}, n, func(i int) []any {
		return []any{seedUUID("user", i), seedEmail(i), true, created(i), created(i)}
	}); err != nil {
		return err
	}
	// Password identities for seven in ten; Google for the other three and
	// for two of the seven (accounts that linked both).
	var identities [][]any
	for i := range n {
		if hasPassword(i) {
			identities = append(identities, []any{seedUUID("user", i), "password", nil, hash})
		}
		if !hasPassword(i) || i%10 < 2 {
			identities = append(identities, []any{seedUUID("user", i), "google", fmt.Sprintf("loadtest-google-%d", i), nil})
		}
	}
	if err := copyRows("auth_identities", []string{"user_id", "provider", "provider_subject", "password_hash"}, len(identities),
		func(i int) []any { return identities[i] }); err != nil {
		return err
	}

	// One live session per account, last used some time in the past month,
	// and for a third of them an older session that was signed out.
	sessionEnd := now.Add(cfg.SessionMaxLifetime)
	if err := copyRows("sessions", []string{"id", "user_id", "created_at", "last_seen_at", "expires_at", "platform", "install_key"}, n, func(i int) []any {
		seen := now.Add(-time.Duration(i%720) * time.Hour)
		return []any{seedUUID("session", i), seedUUID("user", i), created(i), seen, sessionEnd, "android", seedInstallKey(i)}
	}); err != nil {
		return err
	}
	if err := copyRows("sessions", []string{"id", "user_id", "created_at", "last_seen_at", "expires_at", "revoked_at", "revoke_reason", "platform"}, n/3, func(j int) []any {
		i := j * 3
		return []any{seedUUID("old-session", i), seedUUID("user", i), created(i), created(i), sessionEnd, now.Add(-time.Duration(i%600) * time.Hour), "logout", "android"}
	}); err != nil {
		return err
	}

	// The live refresh token of each session, and behind it the chain of
	// used ones.
	refreshEnd := now.Add(cfg.RefreshTokenTTL)
	if err := copyRows("refresh_tokens", []string{"id", "session_id", "token_hash", "expires_at"}, n, func(i int) []any {
		return []any{seedUUID("rt", i), seedUUID("session", i), lookup.Sum("refresh", seedRefreshToken(i)), refreshEnd}
	}); err != nil {
		return err
	}
	if *history > 0 {
		h := *history
		if err := copyRows("refresh_tokens", []string{"session_id", "token_hash", "created_at", "expires_at", "used_at"}, n*h, func(k int) []any {
			i, g := k/h, k%h
			d := digest("old-rt", k)
			used := now.Add(-time.Duration(g+1) * 24 * time.Hour)
			return []any{seedUUID("session", i), d[:], used.Add(-24 * time.Hour), used.Add(cfg.RefreshTokenTTL), used}
		}); err != nil {
			return err
		}
	}

	// Subscribers: a verified purchase with time left, next checked by the
	// worker some time in the coming three days.
	if *subscribers > 0 {
		every := 100 / *subscribers
		count := n / every
		if err := copyRows("bazaar_purchases", []string{"id", "user_id", "token_hash", "token_enc", "sku", "state", "initiated_at",
			"valid_until", "auto_renewing", "last_checked_at", "last_verified_at", "next_check_at"}, count, func(j int) []any {
			i := j * every
			id := seedUUID("purchase", i)
			token := fmt.Sprintf("loadtest-purchase-%d", i)
			checked := now.Add(-time.Duration(j%300) * time.Minute)
			return []any{id, seedUUID("user", i), lookup.Sum("bazaar-token", token), sealer.Seal([]byte(token), []byte("bazaar:"+id)),
				"tark_premium_1m", "active", now.Add(-10 * 24 * time.Hour), now.Add(20 * 24 * time.Hour), true,
				checked, checked, now.Add(time.Duration(1+j%72) * time.Hour)}
		}); err != nil {
			return err
		}
		if err := copyRows("subscription_accounts", []string{"user_id", "last_verified_at"}, count, func(j int) []any {
			return []any{seedUUID("user", j*every), now}
		}); err != nil {
			return err
		}
	}

	// A year of security events: about five per account.
	kinds := []string{"login.succeeded", "google.signed_in", "session.logged_out", "login.failed", "register.completed"}
	if err := copyRows("audit_events", []string{"at", "kind", "user_id", "ip_hash", "details"}, n*5, func(k int) []any {
		i := k / 5
		at := created(i).Add(time.Duration(k%5) * time.Duration(float64(now.Sub(created(i)))/5))
		return []any{at, kinds[k%5], seedUUID("user", i), "seeded", []byte(`{}`)}
	}); err != nil {
		return err
	}

	if _, err := pool.Exec(ctx, `ANALYZE`); err != nil {
		return err
	}
	fmt.Printf("seeded %d accounts in %s; password for all: %s\n", n, time.Since(start).Round(time.Millisecond), seedPassword)
	return nil
}
