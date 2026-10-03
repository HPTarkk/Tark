package admin

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/secure"
)

// Session lifetimes. A password-stage session only lives long enough to
// type a TOTP code. A full session ends after 12 hours however busy, and
// after 30 idle minutes.
const (
	passwordStageTTL = 10 * time.Minute
	sessionMaxTTL    = 12 * time.Hour
	sessionIdle      = 30 * time.Minute
)

type Role string

const (
	RoleOwner   Role = "owner"
	RoleSupport Role = "support"
	RoleViewer  Role = "viewer"
)

func (r Role) Valid() bool { return r == RoleOwner || r == RoleSupport || r == RoleViewer }

// atLeast orders roles: owner > support > viewer.
func (r Role) atLeast(min Role) bool {
	rank := map[Role]int{RoleViewer: 1, RoleSupport: 2, RoleOwner: 3}
	return rank[r] >= rank[min]
}

// Admin is the signed-in admin of a request.
type Admin struct {
	ID                 string
	Email              string
	Name               string
	Role               Role
	MustChangePassword bool
	HasTOTP            bool
}

type session struct {
	id          string
	adminID     string
	stage       string
	csrf        string
	pendingTOTP []byte
	createdAt   time.Time
	lastSeen    time.Time
	expiresAt   time.Time
}

func randomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func (s *Server) cookieName() string {
	if s.Secure {
		// __Host- cookies must be Secure, path /, and carry no Domain: no
		// other host (not even a sibling subdomain) can set or read them.
		return "__Host-tark_admin"
	}
	return "tark_admin"
}

func (s *Server) setCookie(w http.ResponseWriter, name, value string, maxAge time.Duration) {
	http.SetCookie(w, &http.Cookie{
		Name: name, Value: value, Path: "/", MaxAge: int(maxAge.Seconds()),
		HttpOnly: true, Secure: s.Secure, SameSite: http.SameSiteStrictMode,
	})
}

func (s *Server) clearCookie(w http.ResponseWriter, name string) {
	http.SetCookie(w, &http.Cookie{
		Name: name, Value: "", Path: "/", MaxAge: -1,
		HttpOnly: true, Secure: s.Secure, SameSite: http.SameSiteStrictMode,
	})
}

func (s *Server) tokenHash(token string) []byte { return s.Lookup.Sum("admin-session", token) }

// startSession creates a session at the given stage and sets its cookie.
func (s *Server) startSession(ctx context.Context, w http.ResponseWriter, adminID, stage, ip string) error {
	token := randomToken()
	ttl := passwordStageTTL
	if stage == "full" {
		ttl = sessionMaxTTL
	}
	if _, err := s.Pool.Exec(ctx, `
		INSERT INTO admin_sessions (token_hash, admin_id, stage, csrf, expires_at, ip_hash)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		s.tokenHash(token), adminID, stage, randomToken(), s.now().Add(ttl), s.ipHash(ip)); err != nil {
		return err
	}
	s.setCookie(w, s.cookieName(), token, ttl)
	return nil
}

func (s *Server) ipHash(ip string) *string {
	if ip == "" {
		return nil
	}
	h := s.Lookup.SumString("audit-ip", ip)
	return &h
}

// loadSession finds the request's live session and its admin. A disabled
// admin, an expired or idle session all count as none.
func (s *Server) loadSession(ctx context.Context, r *http.Request) (*session, *Admin, error) {
	c, err := r.Cookie(s.cookieName())
	if err != nil || c.Value == "" || len(c.Value) > 100 {
		return nil, nil, nil
	}
	var sess session
	var a Admin
	var secret []byte
	err = s.Pool.QueryRow(ctx, `
		SELECT s.id, s.admin_id, s.stage, s.csrf, s.pending_totp, s.created_at, s.last_seen_at, s.expires_at,
		       a.email, a.name, a.role, a.must_change_password, a.totp_secret
		FROM admin_sessions s JOIN admin_users a ON a.id = s.admin_id
		WHERE s.token_hash = $1 AND s.expires_at > now() AND a.disabled_at IS NULL`, s.tokenHash(c.Value)).
		Scan(&sess.id, &sess.adminID, &sess.stage, &sess.csrf, &sess.pendingTOTP, &sess.createdAt, &sess.lastSeen, &sess.expiresAt,
			&a.Email, &a.Name, &a.Role, &a.MustChangePassword, &secret)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	now := s.now()
	if sess.stage == "full" && now.Sub(sess.lastSeen) > sessionIdle {
		_, err := s.Pool.Exec(ctx, `DELETE FROM admin_sessions WHERE id = $1`, sess.id)
		return nil, nil, err
	}
	// Touch at most once a minute.
	if now.Sub(sess.lastSeen) > time.Minute {
		if _, err := s.Pool.Exec(ctx, `UPDATE admin_sessions SET last_seen_at = $2 WHERE id = $1`, sess.id, now); err != nil {
			return nil, nil, err
		}
	}
	a.ID = sess.adminID
	a.HasTOTP = len(secret) > 0
	return &sess, &a, nil
}

func (s *Server) endSession(ctx context.Context, w http.ResponseWriter, sess *session) {
	if sess != nil {
		if _, err := s.Pool.Exec(ctx, `DELETE FROM admin_sessions WHERE id = $1`, sess.id); err != nil {
			s.Log.ErrorContext(ctx, "admin session delete failed", "err", err)
		}
	}
	s.clearCookie(w, s.cookieName())
}

// record writes an admin event. Failures are logged, not returned: the
// record must never be the reason an action fails, but a missing record is
// an error worth seeing.
func (s *Server) record(ctx context.Context, adminID, kind, targetUser, ip string, details map[string]any) {
	if details == nil {
		details = map[string]any{}
	}
	var aid, target *string
	if adminID != "" {
		aid = &adminID
	}
	if targetUser != "" {
		target = &targetUser
	}
	if _, err := s.Pool.Exec(ctx, `
		INSERT INTO admin_events (admin_id, kind, target_user, ip_hash, details) VALUES ($1, $2, $3, $4, $5)`,
		aid, kind, target, s.ipHash(ip), details); err != nil {
		s.Log.ErrorContext(ctx, "admin event write failed", "kind", kind, "err", err)
	}
}

func (s *Server) sealTOTP(adminID string, secret []byte) []byte {
	return s.Sealer.Seal(secret, []byte("admin-totp:"+adminID))
}

func (s *Server) openTOTP(adminID string, sealed []byte) ([]byte, error) {
	return s.Sealer.Open(sealed, []byte("admin-totp:"+adminID))
}

// normalizeEmail is enough for admin addresses, which only owners type.
func normalizeEmail(e string) string { return strings.ToLower(strings.TrimSpace(e)) }

// Reasons CreateAdmin refuses; the panel shows them in the admin's language.
var (
	errBadRole     = errors.New("role must be owner, support or viewer")
	errBadEmail    = errors.New("not an email address")
	errBadName     = errors.New("name must be 1 to 64 characters")
	errAdminExists = errors.New("an admin with that email already exists")
)

// CreateAdmin adds an admin with a one-time password, which is returned and
// must be changed at first sign-in, together with enrolling TOTP.
func CreateAdmin(ctx context.Context, d Deps, email, name string, role Role, createdBy string) (string, error) {
	email = normalizeEmail(email)
	if !role.Valid() {
		return "", errBadRole
	}
	if strings.Count(email, "@") != 1 || len(email) > 254 || strings.ContainsAny(email, " <>\r\n") {
		return "", errBadEmail
	}
	name = strings.TrimSpace(name)
	if name == "" || len([]rune(name)) > 64 {
		return "", errBadName
	}
	temp := secure.RandomToken(12)
	hash, err := d.Passwords.Hash(ctx, temp)
	if err != nil {
		return "", err
	}
	var by *string
	if createdBy != "" {
		by = &createdBy
	}
	if _, err := d.Pool.Exec(ctx, `
		INSERT INTO admin_users (email, name, role, password_hash, created_by) VALUES ($1, $2, $3, $4, $5)`,
		email, name, string(role), hash, by); err != nil {
		if strings.Contains(err.Error(), "admin_users_email_key") {
			return "", errAdminExists
		}
		return "", err
	}
	return temp, nil
}
