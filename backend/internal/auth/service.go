// Package auth implements accounts and sign-in: email and password
// registration with a verification code or link, Google Sign-In with
// account linking, sessions with rotating refresh tokens, password reset
// and change, and the email-change flow.
//
// Design rules that hold everywhere in this package:
//   - Responses do not reveal whether an email is registered (register and
//     forgot-password answer identically; login failures are generic).
//   - Every secret is stored as a keyed hash or not at all.
//   - Concurrency is settled by the database (row locks, unique
//     constraints), never by check-then-act in Go.
//   - Anything a caller can repeat is rate limited per IP and per target.
package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/audit"
	"github.com/HPTarkk/Tark/backend/internal/google"
	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/password"
	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

// Settings are the tunable numbers of the auth flows.
type Settings struct {
	AccessTTL          time.Duration
	RefreshTTL         time.Duration
	SessionMaxLifetime time.Duration
	LinkBaseURL        string
	GoogleRequireNonce bool
}

// Verification code shape. The app shows a numeric keypad with this many
// boxes; the values are also returned with every flow so the app never
// hard-codes them.
const (
	CodeLength   = 6
	CodeAlphabet = "digits"

	flowTTL          = 15 * time.Minute
	maxCodeAttempts  = 5
	maxSendsPerFlow  = 5
	resendCooldown   = 60 * time.Second
	resetTicketTTL   = 10 * time.Minute
	googleTicketTTL  = 10 * time.Minute
	googleNonceTTL   = 10 * time.Minute
	maxTicketTries   = 5
	refreshRetryGap  = 60 * time.Second
	maxLiveSessions  = 20
	lastSeenInterval = 10 * time.Minute
	completedReplay  = 10 * time.Minute
)

// Rate limits. Per-IP limits stop one source hammering; per-target limits
// stop a distributed attack on one account or address.
var (
	limitRegisterIP    = ratelimit.Rule{Name: "register_ip", Max: 10, Window: time.Hour}
	limitRegisterEmail = ratelimit.Rule{Name: "register_email", Max: 5, Window: time.Hour}
	limitForgotIP      = ratelimit.Rule{Name: "forgot_ip", Max: 10, Window: time.Hour}
	limitForgotEmail   = ratelimit.Rule{Name: "forgot_email", Max: 5, Window: time.Hour}
	limitVerifyIP      = ratelimit.Rule{Name: "verify_ip", Max: 60, Window: 15 * time.Minute}
	limitLoginIP       = ratelimit.Rule{Name: "login_ip", Max: 30, Window: 15 * time.Minute}
	limitLoginEmailIP  = ratelimit.Rule{Name: "login_fail_email_ip", Max: 5, Window: 15 * time.Minute}
	limitLoginEmail    = ratelimit.Rule{Name: "login_fail_email", Max: 20, Window: time.Hour}
	limitGoogleIP      = ratelimit.Rule{Name: "google_ip", Max: 30, Window: 15 * time.Minute}
	limitRefreshIP     = ratelimit.Rule{Name: "refresh_ip", Max: 120, Window: 15 * time.Minute}
	limitUserSensitive = ratelimit.Rule{Name: "user_sensitive", Max: 10, Window: 15 * time.Minute}
	// Wrong verification codes for one address, across all of its flows.
	limitCodeFailEmail = ratelimit.Rule{Name: "code_fail_email", Max: 20, Window: 24 * time.Hour}
)

// Client describes who is calling, as far as the server can tell.
type Client struct {
	IP         string
	Platform   string // android | ios | ""
	InstallKey string // optional; stored on the session
	Locale     string // en | fa
}

// Tokens are what a successful sign-in hands the app.
type Tokens struct {
	AccessToken      string
	AccessExpiresAt  time.Time
	RefreshToken     string
	RefreshExpiresAt time.Time
}

// SignedIn is the result of every flow that ends signed in.
type SignedIn struct {
	Tokens
	UserID     string
	NewAccount bool
}

// Principal is an authenticated caller.
type Principal struct {
	UserID    string
	SessionID string
}

type Service struct {
	pool   *pgxpool.Pool
	lookup *secure.Hasher
	pw     *password.Hasher
	limits ratelimit.Limiter
	audit  *audit.Logger
	outbox *mail.Outbox
	google *google.Verifier
	signer tokenSigner
	cfg    Settings
	log    *slog.Logger
	now    func() time.Time
}

func NewService(pool *pgxpool.Pool, lookup *secure.Hasher, pw *password.Hasher, limits ratelimit.Limiter,
	aud *audit.Logger, outbox *mail.Outbox, gv *google.Verifier, tokenKey []byte, cfg Settings, log *slog.Logger) *Service {
	return &Service{
		pool: pool, lookup: lookup, pw: pw, limits: limits, audit: aud, outbox: outbox, google: gv,
		signer: tokenSigner{key: tokenKey, now: time.Now},
		cfg:    cfg, log: log, now: time.Now,
	}
}

func (s *Service) hash(domain string, parts ...string) []byte { return s.lookup.Sum(domain, parts...) }

// Authenticate resolves an access token to a live session.
func (s *Service) Authenticate(ctx context.Context, token string) (Principal, error) {
	claims, err := s.signer.parse(token)
	if err != nil {
		return Principal{}, apperr.Unauthorized("access token invalid or expired")
	}
	var lastSeen time.Time
	err = s.pool.QueryRow(ctx, `
		SELECT s.last_seen_at FROM sessions s JOIN users u ON u.id = s.user_id
		WHERE s.id = $1 AND s.user_id = $2 AND s.revoked_at IS NULL AND s.expires_at > now() AND u.status = 'active'`,
		claims.SID, claims.UID).Scan(&lastSeen)
	if errors.Is(err, pgx.ErrNoRows) {
		return Principal{}, apperr.Unauthorized("session ended")
	}
	if err != nil {
		return Principal{}, err
	}
	// Writing on every request would turn reads into writes; once every few
	// minutes is enough to show when a device was last active.
	if s.now().Sub(lastSeen) > lastSeenInterval {
		if _, err := s.pool.Exec(ctx, `UPDATE sessions SET last_seen_at = now() WHERE id = $1`, claims.SID); err != nil {
			s.log.WarnContext(ctx, "last_seen update failed", "err", err)
		}
	}
	return Principal{UserID: claims.UID, SessionID: claims.SID}, nil
}

// startSession creates a session and its first refresh token inside tx.
func (s *Service) startSession(ctx context.Context, tx pgx.Tx, userID string, c Client) (Tokens, error) {
	now := s.now()
	var sessionID string
	var platform, installKey *string
	if c.Platform != "" {
		platform = &c.Platform
	}
	if c.InstallKey != "" {
		installKey = &c.InstallKey
	}
	sessionEnd := now.Add(s.cfg.SessionMaxLifetime)
	if err := tx.QueryRow(ctx, `
		INSERT INTO sessions (user_id, expires_at, platform, install_key) VALUES ($1, $2, $3, $4) RETURNING id`,
		userID, sessionEnd, platform, installKey).Scan(&sessionID); err != nil {
		return Tokens{}, err
	}
	// Keep the number of live sessions bounded; the oldest ones go first.
	if _, err := tx.Exec(ctx, `
		UPDATE sessions SET revoked_at = now(), revoke_reason = 'session_limit'
		WHERE id IN (
			SELECT id FROM sessions WHERE user_id = $1 AND revoked_at IS NULL
			ORDER BY last_seen_at DESC OFFSET $2)`, userID, maxLiveSessions); err != nil {
		return Tokens{}, err
	}
	refresh := newRefreshToken()
	refreshEnd := minTime(now.Add(s.cfg.RefreshTTL), sessionEnd)
	if _, err := tx.Exec(ctx, `INSERT INTO refresh_tokens (session_id, token_hash, expires_at) VALUES ($1, $2, $3)`,
		sessionID, s.hash("refresh", refresh), refreshEnd); err != nil {
		return Tokens{}, err
	}
	access, accessEnd := s.signer.issue(sessionID, userID, s.cfg.AccessTTL)
	return Tokens{AccessToken: access, AccessExpiresAt: accessEnd, RefreshToken: refresh, RefreshExpiresAt: refreshEnd}, nil
}

// Refresh rotates a refresh token. A token that was already used means
// either a retry whose answer got lost, or theft. A retry arrives within
// seconds and its replacement has not been used yet; anything else ends
// the session for everyone holding it.
func (s *Service) Refresh(ctx context.Context, refresh string, c Client) (Tokens, error) {
	if err := s.limits.Hit(ctx, limitRefreshIP, c.IP); err != nil {
		return Tokens{}, err
	}
	if len(refresh) > 128 || len(refresh) < len(refreshPrefix)+10 {
		return Tokens{}, apperr.Unauthorized("refresh token invalid")
	}
	var out Tokens
	var reuse bool
	var reuseUser string
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		var (
			tokenID, sessionID, userID, status string
			usedAt, burnedAt, revokedAt        *time.Time
			tokenEnd, sessionEnd               time.Time
		)
		err := tx.QueryRow(ctx, `
			SELECT rt.id, rt.session_id, rt.used_at, rt.burned_at, rt.expires_at, s.revoked_at, s.expires_at, s.user_id, u.status
			FROM refresh_tokens rt
			JOIN sessions s ON s.id = rt.session_id
			JOIN users u ON u.id = s.user_id
			WHERE rt.token_hash = $1
			FOR UPDATE OF rt, s`, s.hash("refresh", refresh)).
			Scan(&tokenID, &sessionID, &usedAt, &burnedAt, &tokenEnd, &revokedAt, &sessionEnd, &userID, &status)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Unauthorized("refresh token invalid")
		}
		if err != nil {
			return err
		}
		now := s.now()
		if revokedAt != nil || !now.Before(sessionEnd) || !now.Before(tokenEnd) || status != "active" {
			return apperr.New(http.StatusUnauthorized, "session_ended", "sign in again")
		}

		if usedAt != nil {
			retry := false
			if burnedAt == nil && now.Sub(*usedAt) <= refreshRetryGap {
				// Burn any child the caller never received; if a child was
				// already used, the old token is in someone else's hands.
				var usedChildren int
				if err := tx.QueryRow(ctx, `SELECT count(*) FROM refresh_tokens WHERE parent_id = $1 AND used_at IS NOT NULL AND burned_at IS NULL`, tokenID).
					Scan(&usedChildren); err != nil {
					return err
				}
				retry = usedChildren == 0
			}
			if !retry {
				if _, err := tx.Exec(ctx, `UPDATE sessions SET revoked_at = now(), revoke_reason = 'refresh_reuse' WHERE id = $1`, sessionID); err != nil {
					return err
				}
				reuse, reuseUser = true, userID
				return nil
			}
			if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET used_at = now(), burned_at = now() WHERE parent_id = $1 AND used_at IS NULL`, tokenID); err != nil {
				return err
			}
		} else if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET used_at = now() WHERE id = $1`, tokenID); err != nil {
			return err
		}

		next := newRefreshToken()
		nextEnd := minTime(now.Add(s.cfg.RefreshTTL), sessionEnd)
		if _, err := tx.Exec(ctx, `INSERT INTO refresh_tokens (session_id, token_hash, parent_id, expires_at) VALUES ($1, $2, $3, $4)`,
			sessionID, s.hash("refresh", next), tokenID, nextEnd); err != nil {
			return err
		}
		access, accessEnd := s.signer.issue(sessionID, userID, s.cfg.AccessTTL)
		out = Tokens{AccessToken: access, AccessExpiresAt: accessEnd, RefreshToken: next, RefreshExpiresAt: nextEnd}
		return nil
	})
	if err != nil {
		return Tokens{}, err
	}
	if reuse {
		s.audit.Record(ctx, audit.RefreshReuse, reuseUser, c.IP, nil)
		return Tokens{}, apperr.New(http.StatusUnauthorized, "session_ended", "sign in again")
	}
	return out, nil
}

// Logout ends the caller's session.
func (s *Service) Logout(ctx context.Context, p Principal, ip string) error {
	if _, err := s.pool.Exec(ctx, `UPDATE sessions SET revoked_at = now(), revoke_reason = 'logout' WHERE id = $1 AND revoked_at IS NULL`, p.SessionID); err != nil {
		return err
	}
	s.audit.Record(ctx, audit.LoggedOut, p.UserID, ip, nil)
	return nil
}

// LogoutAll ends every session of the caller's account, this one included.
func (s *Service) LogoutAll(ctx context.Context, p Principal, ip string) error {
	if _, err := s.pool.Exec(ctx, `UPDATE sessions SET revoked_at = now(), revoke_reason = 'logout_all' WHERE user_id = $1 AND revoked_at IS NULL`, p.UserID); err != nil {
		return err
	}
	s.audit.Record(ctx, audit.LoggedOutAll, p.UserID, ip, nil)
	return nil
}

// revokeOthers ends every session of userID except keep (may be "").
func revokeOthers(ctx context.Context, tx pgx.Tx, userID, keep, reason string) error {
	_, err := tx.Exec(ctx, `
		UPDATE sessions SET revoked_at = now(), revoke_reason = $3
		WHERE user_id = $1 AND revoked_at IS NULL AND ($2 = '' OR id::text <> $2)`, userID, keep, reason)
	return err
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

// Sweep deletes expired auth rows. Run periodically by the worker.
//
// Rows go in batches and a failing table does not stop the others (see
// store.Sweep), because every statement runs under the pool's statement
// timeout.
func Sweep(ctx context.Context, pool *pgxpool.Pool) error {
	return store.Sweep(ctx, pool,
		store.SweepRule{Table: "auth_flows", Where: `expires_at < now() - interval '1 day'`},
		store.SweepRule{Table: "google_tickets", Where: `expires_at < now() - interval '1 day'`},
		store.SweepRule{Table: "google_nonces", Where: `expires_at < now()`},
		store.SweepRule{Table: "google_seen_tokens", Where: `expires_at < now()`},
		store.SweepRule{Table: "refresh_tokens", Where: `expires_at < now() - interval '1 day'`},
		store.SweepRule{Table: "sessions", Where: `(revoked_at IS NOT NULL AND revoked_at < now() - interval '30 days') OR expires_at < now() - interval '30 days'`},
		store.SweepRule{Table: "idempotency_keys", Where: `expires_at < now()`},
	)
}
