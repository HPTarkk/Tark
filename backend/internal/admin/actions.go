package admin

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
)

// Accounts is what the panel needs from the auth service.
type Accounts interface {
	DeleteByAdmin(ctx context.Context, userID, locale string) error
}

// Billing is what the panel needs from the billing service.
type Billing interface {
	RecheckNow(ctx context.Context, purchaseID string) (bool, error)
}

// Every action names a reason, and the reason is recorded with it.
func reasonOf(r *http.Request) (string, bool) {
	reason := strings.TrimSpace(r.PostFormValue("reason"))
	return reason, len([]rune(reason)) >= 3 && len([]rune(reason)) <= 500
}

// act runs an action on one account and goes back to its page with a
// message. fn returns the message to show, or an error.
func (s *Server) act(kind string, needsReason bool, fn func(ctx context.Context, r *http.Request, userID, reason string) (string, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		a, userID := adminFrom(ctx), chi.URLParam(r, "id")
		if !uuidRE.MatchString(userID) {
			http.NotFound(w, r)
			return
		}
		reason, ok := reasonOf(r)
		if needsReason && !ok {
			s.showUserMessage(w, r, http.StatusBadRequest, "", T(ctx, "act.reason"))
			return
		}
		msg, err := fn(ctx, r, userID, reason)
		var notice actionError
		if errors.As(err, &notice) {
			s.showUserMessage(w, r, http.StatusBadRequest, "", notice.msg)
			return
		}
		if errors.Is(err, pgx.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		if err != nil {
			s.fail(w, r, err)
			return
		}
		details := map[string]any{}
		if reason != "" {
			details["reason"] = reason
		}
		target := userID
		if kind == "user.deleted" {
			target = "" // the account is gone; keep no link to it
		}
		s.record(ctx, a.ID, kind, target, ipFrom(ctx), details)
		if kind == "user.deleted" {
			s.render(w, r, http.StatusOK, "message", map[string]any{"Title": T(ctx, "act.deletedT"), "Text": msg})
			return
		}
		s.showUserMessage(w, r, http.StatusOK, msg, "")
	}
}

// actionError is a refusal to show on the page rather than a failure.
type actionError struct{ msg string }

func (e actionError) Error() string { return e.msg }

func (s *Server) showUserMessage(w http.ResponseWriter, r *http.Request, status int, done, problem string) {
	ctx := r.Context()
	id := chi.URLParam(r, "id")
	u := userView{ID: id}
	err := s.Pool.QueryRow(ctx, `SELECT name, status, avatar_id, created_at FROM users WHERE id = $1`, id).
		Scan(&u.Name, &u.Status, &u.Avatar, &u.Created)
	if errors.Is(err, pgx.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err == nil {
		err = s.loadUserDetails(r, &u)
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.render(w, r, status, "user", map[string]any{"U": u, "Done": done, "Problem": problem})
}

func (s *Server) disableUser(ctx context.Context, _ *http.Request, userID, _ string) (string, error) {
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE users SET status = 'disabled', updated_at = now() WHERE id = $1`, userID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return pgx.ErrNoRows
		}
		_, err = tx.Exec(ctx, `UPDATE sessions SET revoked_at = now(), revoke_reason = 'admin_disabled'
			WHERE user_id = $1 AND revoked_at IS NULL`, userID)
		return err
	})
	return T(ctx, "act.disabled"), err
}

func (s *Server) enableUser(ctx context.Context, _ *http.Request, userID, _ string) (string, error) {
	tag, err := s.Pool.Exec(ctx, `UPDATE users SET status = 'active', updated_at = now() WHERE id = $1`, userID)
	if err == nil && tag.RowsAffected() == 0 {
		err = pgx.ErrNoRows
	}
	return T(ctx, "act.enabled"), err
}

func (s *Server) signOutUser(ctx context.Context, _ *http.Request, userID, _ string) (string, error) {
	tag, err := s.Pool.Exec(ctx, `UPDATE sessions SET revoked_at = now(), revoke_reason = 'admin_signout'
		WHERE user_id = $1 AND revoked_at IS NULL`, userID)
	if err != nil {
		return "", err
	}
	return T(ctx, "act.signedOut", tag.RowsAffected()), nil
}

func (s *Server) recheckPurchase(ctx context.Context, r *http.Request, userID, _ string) (string, error) {
	pid := r.PostFormValue("purchase")
	if !uuidRE.MatchString(pid) {
		return "", pgx.ErrNoRows
	}
	var owner string
	if err := s.Pool.QueryRow(ctx, `SELECT user_id FROM bazaar_purchases WHERE id = $1`, pid).Scan(&owner); err != nil {
		return "", err
	}
	if owner != userID {
		return "", pgx.ErrNoRows
	}
	if s.Billing == nil {
		return "", errors.New("billing is not wired")
	}
	answered, err := s.Billing.RecheckNow(ctx, pid)
	if err != nil {
		return "", err
	}
	if !answered {
		return "", actionError{T(ctx, "act.noAnswer")}
	}
	return T(ctx, "act.rechecked"), nil
}

func (s *Server) clearSuspicious(ctx context.Context, _ *http.Request, userID, _ string) (string, error) {
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE subscription_accounts SET suspicious_since = NULL, updated_at = now()
			WHERE user_id = $1 AND suspicious_since IS NOT NULL`, userID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return actionError{T(ctx, "act.notFlagged")}
		}
		_, err = tx.Exec(ctx, `INSERT INTO subscription_events (user_id, kind, details) VALUES ($1, 'suspicious_cleared_by_admin', '{}')`, userID)
		return err
	})
	return T(ctx, "act.cleared"), err
}

// Premium can be given for 1 to 12 months at a time.
const maxGrantMonths = 12

func (s *Server) grantPremium(ctx context.Context, r *http.Request, userID, reason string) (string, error) {
	months, err := strconv.Atoi(r.PostFormValue("months"))
	if err != nil || months < 1 || months > maxGrantMonths {
		return "", actionError{T(ctx, "act.months")}
	}
	a := adminFrom(ctx)
	now := s.now()
	end := now.AddDate(0, months, 0)
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var gid string
		if err := tx.QueryRow(ctx, `
			INSERT INTO premium_grants (user_id, granted_by, reason, starts_at, ends_at) VALUES ($1, $2, $3, $4, $5) RETURNING id`,
			userID, a.ID, reason, now, end).Scan(&gid); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO subscription_events (user_id, kind, details) VALUES ($1, 'premium_granted', $2)`,
			userID, map[string]any{"grant": gid, "months": months, "until": end.UTC().Format(time.RFC3339), "by": a.Name, "reason": reason})
		return err
	})
	return T(ctx, "act.granted", formatDate(langFrom(ctx), end)), err
}

func (s *Server) revokeGrant(ctx context.Context, r *http.Request, userID, reason string) (string, error) {
	gid := r.PostFormValue("grant")
	if !uuidRE.MatchString(gid) {
		return "", pgx.ErrNoRows
	}
	a := adminFrom(ctx)
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE premium_grants SET revoked_at = now(), revoked_by = $3
			WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`, gid, userID, a.ID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return actionError{T(ctx, "act.alreadyRevoked")}
		}
		_, err = tx.Exec(ctx, `INSERT INTO subscription_events (user_id, kind, details) VALUES ($1, 'premium_revoked', $2)`,
			userID, map[string]any{"grant": gid, "by": a.Name, "reason": reason})
		return err
	})
	return T(ctx, "act.revoked"), err
}

func (s *Server) deleteUser(ctx context.Context, r *http.Request, userID, _ string) (string, error) {
	var email string
	err := s.Pool.QueryRow(ctx, `SELECT email FROM user_emails WHERE user_id = $1 AND is_primary AND removed_at IS NULL`, userID).Scan(&email)
	if err != nil {
		return "", err
	}
	if strings.ToLower(strings.TrimSpace(r.PostFormValue("confirm"))) != email {
		return "", actionError{T(ctx, "act.confirmEmail")}
	}
	locale := r.PostFormValue("locale")
	if locale != "fa" {
		locale = "en"
	}
	if s.Accounts == nil {
		return "", errors.New("accounts are not wired")
	}
	if err := s.Accounts.DeleteByAdmin(ctx, userID, locale); err != nil {
		return "", err
	}
	return T(ctx, "act.deleted"), nil
}

// retryMail makes every waiting email due now (after fixing SMTP, say).
func (s *Server) retryMail(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tag, err := s.Pool.Exec(ctx, `UPDATE mail_outbox SET next_try_at = now()
		WHERE sent_at IS NULL AND failed_at IS NULL AND next_try_at > now()`)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.Mailer.Nudge()
	s.record(ctx, adminFrom(ctx).ID, "mail.retry", "", ipFrom(ctx), map[string]any{"emails": tag.RowsAffected()})
	http.Redirect(w, r, "/mail", http.StatusSeeOther)
}
