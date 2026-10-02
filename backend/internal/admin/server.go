// Package admin is the admin panel: a small server-rendered website, served
// on its own listener (TARK_ADMIN_ADDR) and its own host name, never on the
// public API.
//
// Security model: separate admin accounts (never app accounts), password
// plus TOTP for everyone, three roles, short sessions in a __Host- cookie
// with SameSite=Strict and a CSRF token on every form, per-IP and
// per-account limits on sign-in, no JavaScript and a CSP that forbids it,
// and every sign-in and every look at a user recorded in admin_events.
// Full email addresses are masked unless an admin reveals one, which is
// recorded too.
package admin

import (
	"context"
	"crypto/subtle"
	"embed"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/metrics"
	"github.com/HPTarkk/Tark/backend/internal/password"
	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

//go:embed templates/*.html static/*
var assets embed.FS

// Mailer is the part of the mail outbox the panel uses.
type Mailer interface {
	Enqueue(ctx context.Context, tx store.Querier, kind string, m mail.Message, discardAfter time.Time) error
	Nudge()
}

type Deps struct {
	Pool      *pgxpool.Pool
	Passwords *password.Hasher
	Lookup    *secure.Hasher
	Sealer    *secure.Sealer
	Limits    ratelimit.Limiter
	Mailer    Mailer
	Accounts  Accounts
	Billing   Billing
	// Metrics feed the System page; nil hides those numbers.
	Metrics *metrics.Registry
	// LogDir is TARK_LOG_DIR, searched by the Logs page; empty turns it off.
	LogDir string
	// Notified of every admin sign-in, and receive the weekly summary.
	AlertEmails []string
	// ServerName labels emails, e.g. api.tarkk.ir.
	ServerName string
	ClientIP   func(*http.Request) string
	Log        *slog.Logger
	// Secure marks cookies Secure (always in production).
	Secure bool
}

type Server struct {
	Deps
	pages map[string]*template.Template
	now   func() time.Time
}

var (
	ruleLoginIP    = ratelimit.Rule{Name: "admin_login_ip", Max: 10, Window: 15 * time.Minute}
	ruleLoginEmail = ratelimit.Rule{Name: "admin_login_email", Max: 5, Window: 15 * time.Minute}
	ruleTOTP       = ratelimit.Rule{Name: "admin_totp", Max: 5, Window: 15 * time.Minute}
	ruleReveal     = ratelimit.Rule{Name: "admin_reveal", Max: 30, Window: time.Hour}
)

func New(d Deps) (*Server, error) {
	s := &Server{Deps: d, now: time.Now, pages: map[string]*template.Template{}}
	names, err := fs.Glob(assets, "templates/*.html")
	if err != nil {
		return nil, err
	}
	for _, n := range names {
		if strings.HasSuffix(n, "/layout.html") {
			continue
		}
		t, err := template.New("layout.html").Funcs(funcs).ParseFS(assets, "templates/layout.html", n)
		if err != nil {
			return nil, fmt.Errorf("admin: template %s: %w", n, err)
		}
		s.pages[strings.TrimSuffix(strings.TrimPrefix(n, "templates/"), ".html")] = t
	}
	return s, nil
}

type ctxKey int

const (
	keyAdmin ctxKey = iota
	keySession
	keyIP
)

func adminFrom(ctx context.Context) *Admin { a, _ := ctx.Value(keyAdmin).(*Admin); return a }
func sessionFrom(ctx context.Context) *session {
	s, _ := ctx.Value(keySession).(*session)
	return s
}
func ipFrom(ctx context.Context) string { ip, _ := ctx.Value(keyIP).(string); return ip }

// Handler is the whole panel.
func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.Use(s.recoverer, headers, s.withIP)
	static, _ := fs.Sub(assets, "static")
	r.Handle("/static/*", http.StripPrefix("/static/", http.FileServer(http.FS(static))))
	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })

	r.Get("/login", s.loginPage)
	r.Post("/login", s.login)
	r.Group(func(r chi.Router) {
		r.Use(s.requireStage("password"))
		r.Get("/login/totp", s.totpPage)
		r.Post("/login/totp", s.totp)
	})
	r.Post("/logout", s.logout)

	r.Group(func(r chi.Router) {
		r.Use(s.requireStage("full"))
		r.Get("/account/password", s.passwordPage)
		r.Post("/account/password", s.changePassword)
		r.Group(func(r chi.Router) {
			r.Use(s.requirePasswordChanged)
			r.Get("/", s.dashboard)
			r.Get("/system", s.system)
			r.Group(func(r chi.Router) {
				r.Use(requireRole(RoleSupport))
				r.Get("/users", s.users)
				r.Get("/users/{id}", s.user)
				r.Post("/users/{id}/reveal", s.reveal)
				r.Get("/security", s.security)
				r.Get("/mail", s.mailPage)
				r.Post("/mail/retry", s.retryMail)
				r.Post("/users/{id}/disable", s.act("user.disabled", true, s.disableUser))
				r.Post("/users/{id}/enable", s.act("user.enabled", true, s.enableUser))
				r.Post("/users/{id}/signout", s.act("user.signed_out", false, s.signOutUser))
				r.Post("/users/{id}/recheck", s.act("purchase.rechecked", false, s.recheckPurchase))
			})
			r.Group(func(r chi.Router) {
				r.Use(requireRole(RoleOwner))
				r.Get("/admins", s.admins)
				r.Post("/admins", s.createAdmin)
				r.Post("/admins/{id}/disable", s.setAdminDisabled(true))
				r.Post("/admins/{id}/enable", s.setAdminDisabled(false))
				r.Post("/admins/{id}/reset", s.resetAdmin)
				r.Post("/users/{id}/clear-suspicious", s.act("subscription.suspicious_cleared", true, s.clearSuspicious))
				r.Post("/users/{id}/grant", s.act("premium.granted", true, s.grantPremium))
				r.Post("/users/{id}/revoke-grant", s.act("premium.revoked", true, s.revokeGrant))
				r.Post("/users/{id}/delete", s.act("user.deleted", true, s.deleteUser))
				r.Get("/backups", s.backups)
				r.Get("/activity", s.activity)
				r.Get("/logs", s.logs)
			})
		})
	})
	r.NotFound(func(w http.ResponseWriter, r *http.Request) {
		s.render(w, r, http.StatusNotFound, "message", map[string]any{"Title": "Not found", "Text": "There is no such page."})
	})
	return r
}

func headers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Cache-Control", "no-store")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy",
			"default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		h.Set("Strict-Transport-Security", "max-age=31536000")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		h.Set("X-Robots-Tag", "noindex, nofollow")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) withIP(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := ""
		if s.ClientIP != nil {
			ip = s.ClientIP(r)
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), keyIP, ip)))
	})
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				if v == http.ErrAbortHandler {
					panic(v)
				}
				s.Log.ErrorContext(r.Context(), "admin panic", "value", v, "stack", string(debug.Stack()))
				http.Error(w, "internal error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// requireStage lets through only a session at exactly that stage, and checks
// the CSRF token on every POST.
func (s *Server) requireStage(stage string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			sess, a, err := s.loadSession(r.Context(), r)
			if err != nil {
				s.fail(w, r, err)
				return
			}
			if sess == nil {
				http.Redirect(w, r, "/login", http.StatusSeeOther)
				return
			}
			if sess.stage != stage {
				if sess.stage == "full" {
					http.Redirect(w, r, "/", http.StatusSeeOther)
				} else {
					http.Redirect(w, r, "/login/totp", http.StatusSeeOther)
				}
				return
			}
			if r.Method == http.MethodPost && !s.csrfOK(r, sess.csrf) {
				s.render(w, r, http.StatusForbidden, "message", map[string]any{
					"Title": "Form expired", "Text": "That form was too old or came from somewhere else. Go back, reload and try again."})
				return
			}
			ctx := context.WithValue(context.WithValue(r.Context(), keySession, sess), keyAdmin, a)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func (s *Server) csrfOK(r *http.Request, want string) bool {
	got := r.PostFormValue("csrf")
	return got != "" && subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func (s *Server) requirePasswordChanged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if adminFrom(r.Context()).MustChangePassword {
			http.Redirect(w, r, "/account/password", http.StatusSeeOther)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func requireRole(min Role) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !adminFrom(r.Context()).Role.atLeast(min) {
				http.Error(w, "Your role cannot open this page.", http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func (s *Server) render(w http.ResponseWriter, r *http.Request, status int, page string, data map[string]any) {
	t, ok := s.pages[page]
	if !ok {
		s.fail(w, r, fmt.Errorf("admin: no page %q", page))
		return
	}
	if data == nil {
		data = map[string]any{}
	}
	data["Admin"] = adminFrom(r.Context())
	if sess := sessionFrom(r.Context()); sess != nil {
		data["CSRF"] = sess.csrf
	}
	var b strings.Builder
	if err := t.Execute(&b, data); err != nil {
		s.fail(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(b.String()))
}

func (s *Server) fail(w http.ResponseWriter, r *http.Request, err error) {
	s.Log.ErrorContext(r.Context(), "admin request failed", "path", r.URL.Path, "err", err)
	http.Error(w, "Something went wrong. It has been logged.", http.StatusInternalServerError)
}

// ---- sign-in ----------------------------------------------------------------

const preCookie = "tark_admin_pre"

func (s *Server) loginPage(w http.ResponseWriter, r *http.Request) {
	if sess, _, err := s.loadSession(r.Context(), r); err == nil && sess != nil {
		target := "/"
		if sess.stage == "password" {
			target = "/login/totp"
		}
		http.Redirect(w, r, target, http.StatusSeeOther)
		return
	}
	s.showLogin(w, r, http.StatusOK, "")
}

// showLogin renders the form with a fresh double-submit token: there is no
// session yet to hold a CSRF token, so the form and a cookie carry the same
// random value.
func (s *Server) showLogin(w http.ResponseWriter, r *http.Request, status int, msg string) {
	token := randomToken()
	s.setCookie(w, preCookie, token, 30*time.Minute)
	s.render(w, r, status, "login", map[string]any{"Pre": token, "Error": msg})
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	c, err := r.Cookie(preCookie)
	if err != nil || c.Value == "" || subtle.ConstantTimeCompare([]byte(c.Value), []byte(r.PostFormValue("pre"))) != 1 {
		s.showLogin(w, r, http.StatusForbidden, "The form expired. Try again.")
		return
	}
	ip := ipFrom(ctx)
	email := normalizeEmail(r.PostFormValue("email"))
	pw := r.PostFormValue("password")
	if len(email) > 254 || len(pw) > 1024 {
		s.showLogin(w, r, http.StatusBadRequest, "Wrong email or password.")
		return
	}
	if err := s.Limits.Hit(ctx, ruleLoginIP, ip); err != nil {
		s.record(ctx, "", "admin.login_throttled", "", ip, nil)
		s.showLogin(w, r, http.StatusTooManyRequests, "Too many attempts. Wait 15 minutes.")
		return
	}
	if err := s.Limits.Hit(ctx, ruleLoginEmail, email); err != nil {
		s.record(ctx, "", "admin.login_throttled", "", ip, nil)
		s.showLogin(w, r, http.StatusTooManyRequests, "Too many attempts. Wait 15 minutes.")
		return
	}
	var id, hash string
	err = s.Pool.QueryRow(ctx, `SELECT id, password_hash FROM admin_users WHERE email = $1 AND disabled_at IS NULL`, email).Scan(&id, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		s.Passwords.VerifyDummy(ctx, pw) // same time as a real check
		s.record(ctx, "", "admin.login_failed", "", ip, nil)
		s.showLogin(w, r, http.StatusUnauthorized, "Wrong email or password.")
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if _, err := s.Passwords.Verify(ctx, pw, hash); err != nil {
		s.record(ctx, id, "admin.login_failed", "", ip, nil)
		s.showLogin(w, r, http.StatusUnauthorized, "Wrong email or password.")
		return
	}
	if err := s.Limits.Reset(ctx, ruleLoginEmail, email); err != nil {
		s.Log.ErrorContext(ctx, "admin limit reset failed", "err", err)
	}
	s.clearCookie(w, preCookie)
	if err := s.startSession(ctx, w, id, "password", ip); err != nil {
		s.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/login/totp", http.StatusSeeOther)
}

// totpPage asks for a code, or, for an admin without TOTP yet, enrols it.
func (s *Server) totpPage(w http.ResponseWriter, r *http.Request) {
	s.showTOTP(w, r, http.StatusOK, "")
}

func (s *Server) showTOTP(w http.ResponseWriter, r *http.Request, status int, msg string) {
	ctx := r.Context()
	a, sess := adminFrom(ctx), sessionFrom(ctx)
	data := map[string]any{"Error": msg}
	if !a.HasTOTP {
		secret, err := s.pendingSecret(ctx, sess)
		if err != nil {
			s.fail(w, r, err)
			return
		}
		data["Enroll"] = true
		data["Key"] = groupKey(secret)
		data["URL"] = template.URL(otpauthURL(secret, a.Email))
	}
	s.render(w, r, status, "totp", data)
}

// pendingSecret returns the secret being enrolled in this session, making
// one the first time.
func (s *Server) pendingSecret(ctx context.Context, sess *session) ([]byte, error) {
	if len(sess.pendingTOTP) > 0 {
		return s.openTOTP(sess.adminID, sess.pendingTOTP)
	}
	secret := newTOTPSecret()
	sealed := s.sealTOTP(sess.adminID, secret)
	if _, err := s.Pool.Exec(ctx, `UPDATE admin_sessions SET pending_totp = $2 WHERE id = $1`, sess.id, sealed); err != nil {
		return nil, err
	}
	sess.pendingTOTP = sealed
	return secret, nil
}

func (s *Server) totp(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	a, sess, ip := adminFrom(ctx), sessionFrom(ctx), ipFrom(ctx)
	if err := s.Limits.Hit(ctx, ruleTOTP, a.ID); err != nil {
		s.record(ctx, a.ID, "admin.totp_throttled", "", ip, nil)
		s.endSession(ctx, w, sess)
		s.showLogin(w, r, http.StatusTooManyRequests, "Too many wrong codes. Wait 15 minutes, then sign in again.")
		return
	}
	code := strings.ReplaceAll(strings.TrimSpace(r.PostFormValue("code")), " ", "")
	enrolling := !a.HasTOTP
	var secret []byte
	var lastStep int64
	var err error
	if enrolling {
		secret, err = s.pendingSecret(ctx, sess)
	} else {
		var sealed []byte
		if err = s.Pool.QueryRow(ctx, `SELECT totp_secret, totp_last_step FROM admin_users WHERE id = $1`, a.ID).
			Scan(&sealed, &lastStep); err == nil {
			secret, err = s.openTOTP(a.ID, sealed)
		}
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	step := verifyTOTP(secret, code, s.now(), lastStep)
	if step == 0 {
		s.record(ctx, a.ID, "admin.totp_failed", "", ip, nil)
		s.showTOTP(w, r, http.StatusUnauthorized, "That code is not right. Check the time on your phone and try the newest code.")
		return
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		// The step only moves forward, so two tabs racing with one code
		// cannot both succeed.
		q := `UPDATE admin_users SET totp_last_step = $2, last_login_at = now() WHERE id = $1 AND totp_last_step < $2`
		args := []any{a.ID, step}
		if enrolling {
			q = `UPDATE admin_users SET totp_secret = $3, totp_last_step = $2, last_login_at = now() WHERE id = $1 AND totp_secret IS NULL`
			args = append(args, s.sealTOTP(a.ID, secret))
		}
		tag, err := tx.Exec(ctx, q, args...)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return errReplay
		}
		// The password-stage session ends; a new token starts the full one.
		_, err = tx.Exec(ctx, `DELETE FROM admin_sessions WHERE id = $1`, sess.id)
		return err
	})
	if errors.Is(err, errReplay) {
		s.showTOTP(w, r, http.StatusUnauthorized, "That code was already used. Wait for the next one.")
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if err := s.Limits.Reset(ctx, ruleTOTP, a.ID); err != nil {
		s.Log.ErrorContext(ctx, "admin limit reset failed", "err", err)
	}
	if err := s.startSession(ctx, w, a.ID, "full", ip); err != nil {
		s.fail(w, r, err)
		return
	}
	kind := "admin.login"
	if enrolling {
		kind = "admin.totp_enrolled"
	}
	s.record(ctx, a.ID, kind, "", ip, nil)
	s.notifySignIn(ctx, a, ip)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

var errReplay = errors.New("totp step already used")

// notifySignIn emails the alert recipients about every admin sign-in, so a
// sign-in nobody expected is noticed.
func (s *Server) notifySignIn(ctx context.Context, a *Admin, ip string) {
	if len(s.AlertEmails) == 0 {
		return
	}
	prefix := "[Tarkk] "
	if s.ServerName != "" {
		prefix = "[Tarkk " + s.ServerName + "] "
	}
	msg := mail.Message{
		Subject: prefix + "Admin sign-in: " + a.Name,
		Text: fmt.Sprintf("%s (%s, %s) signed in to the admin panel at %s from %s.\n\n"+
			"If that was not expected, disable the admin on the Admins page and change your own password.\n",
			a.Name, a.Email, a.Role, s.now().UTC().Format("2006-01-02 15:04 UTC"), ip),
	}
	for _, to := range s.AlertEmails {
		msg.To = to
		if err := s.Mailer.Enqueue(ctx, s.Pool, "admin_signin", msg, s.now().Add(24*time.Hour)); err != nil {
			s.Log.ErrorContext(ctx, "admin sign-in notice failed", "err", err)
			return
		}
	}
	s.Mailer.Nudge()
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	sess, a, err := s.loadSession(ctx, r)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if sess != nil {
		if !s.csrfOK(r, sess.csrf) {
			http.Error(w, "Form expired.", http.StatusForbidden)
			return
		}
		s.record(ctx, a.ID, "admin.logout", "", ipFrom(ctx), nil)
	}
	s.endSession(ctx, w, sess)
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (s *Server) passwordPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, r, http.StatusOK, "password", nil)
}

const adminMinPassword = 12

func (s *Server) changePassword(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	a, sess, ip := adminFrom(ctx), sessionFrom(ctx), ipFrom(ctx)
	current, next, again := r.PostFormValue("current"), r.PostFormValue("new"), r.PostFormValue("again")
	show := func(status int, msg string) {
		s.render(w, r, status, "password", map[string]any{"Error": msg})
	}
	var hash string
	if err := s.Pool.QueryRow(ctx, `SELECT password_hash FROM admin_users WHERE id = $1`, a.ID).Scan(&hash); err != nil {
		s.fail(w, r, err)
		return
	}
	if _, err := s.Passwords.Verify(ctx, current, hash); err != nil {
		s.record(ctx, a.ID, "admin.password_change_failed", "", ip, nil)
		show(http.StatusUnauthorized, "Your current password is not right.")
		return
	}
	if next != again {
		show(http.StatusBadRequest, "The two new passwords are different.")
		return
	}
	if len([]rune(password.Normalize(next))) < adminMinPassword || password.Problem(next, a.Email) != "" || next == current {
		show(http.StatusBadRequest, fmt.Sprintf("Choose a new password of at least %d characters that is not common and not your email.", adminMinPassword))
		return
	}
	newHash, err := s.Passwords.Hash(ctx, next)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE admin_users SET password_hash = $2, must_change_password = false WHERE id = $1`, a.ID, newHash); err != nil {
			return err
		}
		// Every other browser signed in as this admin is signed out.
		_, err := tx.Exec(ctx, `DELETE FROM admin_sessions WHERE admin_id = $1 AND id <> $2`, a.ID, sess.id)
		return err
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.record(ctx, a.ID, "admin.password_changed", "", ip, nil)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}
