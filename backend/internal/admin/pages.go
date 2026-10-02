package admin

import (
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
)

var uuidRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	st, err := loadStats(r.Context(), s.Pool)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.render(w, r, http.StatusOK, "dashboard", map[string]any{"S": st})
}

// users finds one account by exact email address or account id. There is
// deliberately no list or partial search: support looks up the person who
// wrote in, it does not browse.
func (s *Server) users(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		s.render(w, r, http.StatusOK, "users", nil)
		return
	}
	a := adminFrom(ctx)
	var id string
	var err error
	if uuidRE.MatchString(q) {
		err = s.Pool.QueryRow(ctx, `SELECT id FROM users WHERE id = $1`, q).Scan(&id)
	} else {
		err = s.Pool.QueryRow(ctx, `SELECT user_id FROM user_emails WHERE email = $1 AND removed_at IS NULL`,
			strings.ToLower(q)).Scan(&id)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		s.record(ctx, a.ID, "user.search", "", ipFrom(ctx), map[string]any{"found": false})
		s.render(w, r, http.StatusOK, "users", map[string]any{"Q": q, "NotFound": true})
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/users/"+id, http.StatusSeeOther)
}

type userView struct {
	ID, Name, Status string
	Avatar           *string
	Created          time.Time
	Emails           []emailView
	Providers        []string
	Sessions         []sessionView
	Purchases        []purchaseView
	Suspicious       *time.Time
	SubEvents        []eventView
	Audit            []eventView
	AdminEvents      []eventView
	RevealedEmail    string
	RevealedEmailID  string
}

type emailView struct {
	ID, Masked string
	Primary    bool
	Verified   time.Time
	Removed    *time.Time
}

type sessionView struct {
	Platform *string
	Created  time.Time
	LastSeen time.Time
	Revoked  *time.Time
	Reason   *string
}

type purchaseView struct {
	SKU, State    string
	ValidUntil    *time.Time
	AutoRenew     bool
	Refunded      *time.Time
	LastVerified  *time.Time
	CheckFailures int
	Created       time.Time
}

type eventView struct {
	At      time.Time
	Kind    string
	Details string
	Who     string
}

func (s *Server) user(w http.ResponseWriter, r *http.Request) {
	s.showUser(w, r, "", "")
}

func (s *Server) showUser(w http.ResponseWriter, r *http.Request, revealedID, revealed string) {
	ctx := r.Context()
	id := chi.URLParam(r, "id")
	if !uuidRE.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	u := userView{ID: id, RevealedEmailID: revealedID, RevealedEmail: revealed}
	err := s.Pool.QueryRow(ctx, `SELECT name, status, avatar_id, created_at FROM users WHERE id = $1`, id).
		Scan(&u.Name, &u.Status, &u.Avatar, &u.Created)
	if errors.Is(err, pgx.ErrNoRows) {
		s.render(w, r, http.StatusNotFound, "message", map[string]any{"Title": "No such account", "Text": "It may have been deleted."})
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if err := s.loadUserDetails(r, &u); err != nil {
		s.fail(w, r, err)
		return
	}
	if revealed == "" {
		s.record(ctx, adminFrom(ctx).ID, "user.viewed", id, ipFrom(ctx), nil)
	}
	s.render(w, r, http.StatusOK, "user", map[string]any{"U": u})
}

func (s *Server) loadUserDetails(r *http.Request, u *userView) error {
	ctx := r.Context()
	rows, err := s.Pool.Query(ctx, `
		SELECT id, email, is_primary, verified_at, removed_at FROM user_emails WHERE user_id = $1
		ORDER BY removed_at NULLS FIRST, is_primary DESC, created_at`, u.ID)
	if err != nil {
		return err
	}
	u.Emails, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (emailView, error) {
		var e emailView
		var addr string
		err := row.Scan(&e.ID, &addr, &e.Primary, &e.Verified, &e.Removed)
		e.Masked = maskEmail(addr)
		return e, err
	})
	if err != nil {
		return err
	}
	rows, err = s.Pool.Query(ctx, `SELECT provider FROM auth_identities WHERE user_id = $1 ORDER BY provider`, u.ID)
	if err != nil {
		return err
	}
	if u.Providers, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
		return err
	}
	rows, err = s.Pool.Query(ctx, `
		SELECT platform, created_at, last_seen_at, revoked_at, revoke_reason FROM sessions
		WHERE user_id = $1 ORDER BY revoked_at NULLS FIRST, last_seen_at DESC LIMIT 20`, u.ID)
	if err != nil {
		return err
	}
	u.Sessions, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (sessionView, error) {
		var v sessionView
		return v, row.Scan(&v.Platform, &v.Created, &v.LastSeen, &v.Revoked, &v.Reason)
	})
	if err != nil {
		return err
	}
	rows, err = s.Pool.Query(ctx, `
		SELECT sku, state, valid_until, auto_renewing, refunded_at, last_verified_at, check_failures, created_at
		FROM bazaar_purchases WHERE user_id = $1 ORDER BY created_at DESC`, u.ID)
	if err != nil {
		return err
	}
	u.Purchases, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (purchaseView, error) {
		var p purchaseView
		return p, row.Scan(&p.SKU, &p.State, &p.ValidUntil, &p.AutoRenew, &p.Refunded, &p.LastVerified, &p.CheckFailures, &p.Created)
	})
	if err != nil {
		return err
	}
	if err := s.Pool.QueryRow(ctx, `SELECT suspicious_since FROM subscription_accounts WHERE user_id = $1`, u.ID).
		Scan(&u.Suspicious); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	events := func(sql string) ([]eventView, error) {
		rows, err := s.Pool.Query(ctx, sql, u.ID)
		if err != nil {
			return nil, err
		}
		return pgx.CollectRows(rows, func(row pgx.CollectableRow) (eventView, error) {
			var e eventView
			return e, row.Scan(&e.At, &e.Kind, &e.Details, &e.Who)
		})
	}
	if u.SubEvents, err = events(`SELECT at, kind, details::text, '' FROM subscription_events WHERE user_id = $1 ORDER BY at DESC LIMIT 30`); err != nil {
		return err
	}
	if u.Audit, err = events(`SELECT at, kind, details::text, '' FROM audit_events WHERE user_id = $1 ORDER BY at DESC LIMIT 50`); err != nil {
		return err
	}
	u.AdminEvents, err = events(`
		SELECT e.at, e.kind, e.details::text, COALESCE(a.name, '(removed admin)') FROM admin_events e
		LEFT JOIN admin_users a ON a.id = e.admin_id WHERE e.target_user = $1 ORDER BY e.at DESC LIMIT 30`)
	return err
}

// reveal shows one full email address, once, and records who looked.
func (s *Server) reveal(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	a, ip := adminFrom(ctx), ipFrom(ctx)
	userID, emailID := chi.URLParam(r, "id"), r.PostFormValue("email")
	if !uuidRE.MatchString(userID) || !uuidRE.MatchString(emailID) {
		http.NotFound(w, r)
		return
	}
	if err := s.Limits.Hit(ctx, ruleReveal, a.ID); err != nil {
		http.Error(w, "Too many addresses revealed in the last hour.", http.StatusTooManyRequests)
		return
	}
	var addr string
	err := s.Pool.QueryRow(ctx, `SELECT email FROM user_emails WHERE id = $1 AND user_id = $2`, emailID, userID).Scan(&addr)
	if errors.Is(err, pgx.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.record(ctx, a.ID, "user.email_revealed", userID, ip, nil)
	s.showUser(w, r, emailID, addr)
}

// maskEmail keeps enough to recognise an address without exposing it:
// pe***@gmail.com.
func maskEmail(e string) string {
	local, domain, ok := strings.Cut(e, "@")
	if !ok {
		return "***"
	}
	r := []rune(local)
	keep := min(2, len(r))
	if len(r) <= 2 {
		keep = 1
	}
	return string(r[:keep]) + "***@" + domain
}

func (s *Server) security(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	rows, err := s.Pool.Query(ctx, `
		SELECT kind, count(*) FROM audit_events WHERE at > now() - interval '24 hours'
		GROUP BY kind ORDER BY count(*) DESC, kind`)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	type kc struct {
		Kind  string
		Count int
	}
	counts, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (kc, error) {
		var k kc
		return k, row.Scan(&k.Kind, &k.Count)
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	type ev struct {
		At     time.Time
		Kind   string
		UserID *string
		IP     string
		Detail string
	}
	rows, err = s.Pool.Query(ctx, `
		SELECT at, kind, user_id::text, COALESCE(left(ip_hash, 8), ''), details::text FROM audit_events
		WHERE kind NOT IN ('login.succeeded', 'google.signed_in', 'session.logged_out')
		ORDER BY at DESC LIMIT 100`)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	recent, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (ev, error) {
		var e ev
		return e, row.Scan(&e.At, &e.Kind, &e.UserID, &e.IP, &e.Detail)
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.render(w, r, http.StatusOK, "security", map[string]any{"Counts": counts, "Recent": recent})
}

func (s *Server) mailPage(w http.ResponseWriter, r *http.Request) {
	type row struct {
		Kind                         string
		Sent, Failed, Pending, Tries int
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT kind,
		       count(*) FILTER (WHERE sent_at IS NOT NULL),
		       count(*) FILTER (WHERE failed_at IS NOT NULL),
		       count(*) FILTER (WHERE sent_at IS NULL AND failed_at IS NULL),
		       COALESCE(max(attempts) FILTER (WHERE sent_at IS NULL AND failed_at IS NULL), 0)
		FROM mail_outbox WHERE created_at > now() - interval '7 days'
		GROUP BY kind ORDER BY kind`)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	list, err := pgx.CollectRows(rows, func(rr pgx.CollectableRow) (row, error) {
		var x row
		return x, rr.Scan(&x.Kind, &x.Sent, &x.Failed, &x.Pending, &x.Tries)
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.render(w, r, http.StatusOK, "mail", map[string]any{"Rows": list})
}

func (s *Server) backups(w http.ResponseWriter, r *http.Request) {
	type run struct {
		Started  time.Time
		Finished *time.Time
		OK       bool
		File     *string
		Bytes    *int64
		Rows     *int64
		Error    *string
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT started_at, finished_at, ok, file, bytes, row_count, error FROM backup_runs ORDER BY id DESC LIMIT 30`)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	list, err := pgx.CollectRows(rows, func(rr pgx.CollectableRow) (run, error) {
		var x run
		return x, rr.Scan(&x.Started, &x.Finished, &x.OK, &x.File, &x.Bytes, &x.Rows, &x.Error)
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.render(w, r, http.StatusOK, "backups", map[string]any{"Runs": list})
}

func (s *Server) activity(w http.ResponseWriter, r *http.Request) {
	type ev struct {
		At     time.Time
		Who    string
		Kind   string
		Target *string
		Detail string
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT e.at, COALESCE(a.name, '-'), e.kind, e.target_user::text, e.details::text
		FROM admin_events e LEFT JOIN admin_users a ON a.id = e.admin_id
		ORDER BY e.at DESC LIMIT 200`)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	list, err := pgx.CollectRows(rows, func(rr pgx.CollectableRow) (ev, error) {
		var x ev
		return x, rr.Scan(&x.At, &x.Who, &x.Kind, &x.Target, &x.Detail)
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.render(w, r, http.StatusOK, "activity", map[string]any{"Events": list})
}

// ---- admins (owner only) ------------------------------------------------------

type adminRow struct {
	ID, Email, Name, Role string
	TOTP, MustChange      bool
	Disabled, LastLogin   *time.Time
	Created               time.Time
}

func (s *Server) admins(w http.ResponseWriter, r *http.Request) {
	s.showAdmins(w, r, http.StatusOK, nil)
}

func (s *Server) showAdmins(w http.ResponseWriter, r *http.Request, status int, data map[string]any) {
	rows, err := s.Pool.Query(r.Context(), `
		SELECT id, email, name, role, totp_secret IS NOT NULL, must_change_password, disabled_at, last_login_at, created_at
		FROM admin_users ORDER BY disabled_at NULLS FIRST, created_at`)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	list, err := pgx.CollectRows(rows, func(rr pgx.CollectableRow) (adminRow, error) {
		var x adminRow
		return x, rr.Scan(&x.ID, &x.Email, &x.Name, &x.Role, &x.TOTP, &x.MustChange, &x.Disabled, &x.LastLogin, &x.Created)
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if data == nil {
		data = map[string]any{}
	}
	data["Admins"] = list
	s.render(w, r, status, "admins", data)
}

func (s *Server) createAdmin(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	a := adminFrom(ctx)
	email, name, role := r.PostFormValue("email"), r.PostFormValue("name"), Role(r.PostFormValue("role"))
	temp, err := CreateAdmin(ctx, s.Deps, email, name, role, a.ID)
	if err != nil {
		s.showAdmins(w, r, http.StatusBadRequest, map[string]any{"Error": err.Error()})
		return
	}
	s.record(ctx, a.ID, "admin.created", "", ipFrom(ctx), map[string]any{"email": normalizeEmail(email), "role": string(role)})
	s.showAdmins(w, r, http.StatusOK, map[string]any{"Temp": temp, "TempFor": normalizeEmail(email)})
}

func (s *Server) setAdminDisabled(disable bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		a, id := adminFrom(ctx), chi.URLParam(r, "id")
		if !uuidRE.MatchString(id) {
			http.NotFound(w, r)
			return
		}
		if id == a.ID {
			s.showAdmins(w, r, http.StatusBadRequest, map[string]any{"Error": "You cannot disable yourself."})
			return
		}
		err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
			if disable {
				if _, err := tx.Exec(ctx, `UPDATE admin_users SET disabled_at = now() WHERE id = $1 AND disabled_at IS NULL`, id); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, `DELETE FROM admin_sessions WHERE admin_id = $1`, id)
				return err
			}
			_, err := tx.Exec(ctx, `UPDATE admin_users SET disabled_at = NULL WHERE id = $1`, id)
			return err
		})
		if err != nil {
			s.fail(w, r, err)
			return
		}
		kind := "admin.enabled"
		if disable {
			kind = "admin.disabled"
		}
		s.record(ctx, a.ID, kind, "", ipFrom(ctx), map[string]any{"admin": id})
		http.Redirect(w, r, "/admins", http.StatusSeeOther)
	}
}

// resetAdmin gives an admin who lost their password or phone a new one-time
// password and makes them enrol TOTP again.
func (s *Server) resetAdmin(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	a, id := adminFrom(ctx), chi.URLParam(r, "id")
	if !uuidRE.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	if id == a.ID {
		s.showAdmins(w, r, http.StatusBadRequest, map[string]any{"Error": "Change your own password on the Account page."})
		return
	}
	temp := randomToken()[:16]
	hash, err := s.Passwords.Hash(ctx, temp)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	var email string
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `
			UPDATE admin_users SET password_hash = $2, must_change_password = true, totp_secret = NULL, totp_last_step = 0
			WHERE id = $1 RETURNING email`, id, hash).Scan(&email); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `DELETE FROM admin_sessions WHERE admin_id = $1`, id)
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.record(ctx, a.ID, "admin.reset", "", ipFrom(ctx), map[string]any{"admin": id})
	s.showAdmins(w, r, http.StatusOK, map[string]any{"Temp": temp, "TempFor": email})
}
