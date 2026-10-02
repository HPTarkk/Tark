package auth

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/audit"
	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/password"
	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

var errInvalidCredentials = apperr.New(http.StatusUnauthorized, "invalid_credentials", "email or password is wrong")

// Login signs in with email and password. Every failure looks the same
// (wrong password, unknown address, Google-only account) and takes the
// same time, so the endpoint cannot be used to learn who has an account.
func (s *Service) Login(ctx context.Context, rawEmail, pw string, c Client) (SignedIn, error) {
	email, err := NormalizeEmail(rawEmail)
	if err != nil {
		return SignedIn{}, err
	}
	if len(pw) == 0 || len(pw) > 4*password.MaxLength {
		return SignedIn{}, errInvalidCredentials
	}
	if err := s.limits.Hit(ctx, limitLoginIP, c.IP); err != nil {
		return SignedIn{}, err
	}
	// The attempt is counted before the password is checked, atomically in the
	// database, and given back if it turns out not to be a failure. Checking
	// first and counting afterwards would let a burst of parallel guesses all
	// pass the check before any of them was counted. A locked-out address
	// costs no hashing at all.
	emailIP := email + "|" + c.IP
	if err := s.reserveLoginAttempt(ctx, email, emailIP); err != nil {
		s.audit.Record(ctx, audit.LoginThrottled, "", c.IP, nil)
		return SignedIn{}, err
	}
	failed := false
	defer func() {
		if !failed {
			s.refundLoginAttempt(ctx, email, emailIP)
		}
	}()

	var userID, status, hash string
	err = s.pool.QueryRow(ctx, `
		SELECT u.id, u.status, i.password_hash
		FROM user_emails e
		JOIN users u ON u.id = e.user_id
		JOIN auth_identities i ON i.user_id = u.id AND i.provider = 'password'
		WHERE e.email = $1 AND e.removed_at IS NULL`, email).Scan(&userID, &status, &hash)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return SignedIn{}, err
	}
	if userID == "" {
		s.pw.VerifyDummy(ctx, pw)
		failed = true
		return SignedIn{}, s.loginFailed(ctx, "", c.IP)
	}
	needsRehash, err := s.pw.Verify(ctx, pw, hash)
	if errors.Is(err, password.ErrMismatch) {
		failed = true
		return SignedIn{}, s.loginFailed(ctx, userID, c.IP)
	}
	if err != nil {
		return SignedIn{}, err
	}
	if status != "active" {
		// Safe to say now: the caller proved the password.
		return SignedIn{}, apperr.New(http.StatusForbidden, "account_disabled", "contact support")
	}

	var out SignedIn
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if needsRehash {
			if newHash, err := s.pw.Hash(ctx, pw); err == nil {
				if _, err := tx.Exec(ctx, `UPDATE auth_identities SET password_hash = $2, updated_at = now() WHERE user_id = $1 AND provider = 'password'`, userID, newHash); err != nil {
					return err
				}
			}
		}
		tokens, err := s.startSession(ctx, tx, userID, c)
		out = SignedIn{Tokens: tokens, UserID: userID}
		return err
	})
	if err != nil {
		return SignedIn{}, err
	}
	// The right password: this person's own failed tries no longer count.
	_ = s.limits.Reset(ctx, limitLoginEmailIP, emailIP)
	s.audit.Record(ctx, audit.LoginSucceeded, userID, c.IP, map[string]any{"method": "password"})
	return out, nil
}

// loginRules are the failure counters shared by password sign-in and the
// Google link step, so the link step is not a side door for guessing.
func loginRules(email, emailIP string) []struct {
	r       ratelimit.Rule
	subject string
} {
	return []struct {
		r       ratelimit.Rule
		subject string
	}{{limitLoginEmailIP, emailIP}, {limitLoginEmail, email}}
}

// reserveLoginAttempt counts one attempt against both failure counters and
// refuses it when either is over its limit.
func (s *Service) reserveLoginAttempt(ctx context.Context, email, emailIP string) error {
	for _, rule := range loginRules(email, emailIP) {
		if err := s.limits.Hit(ctx, rule.r, rule.subject); err != nil {
			return err
		}
	}
	return nil
}

// refundLoginAttempt gives back an attempt that was not a wrong guess (the
// password was right, or the request failed for another reason).
func (s *Service) refundLoginAttempt(ctx context.Context, email, emailIP string) {
	for _, rule := range loginRules(email, emailIP) {
		if err := s.limits.Refund(ctx, rule.r, rule.subject); err != nil {
			s.log.WarnContext(ctx, "login counter refund failed", "err", err)
		}
	}
}

// loginFailed records a wrong password. The attempt was already counted by
// reserveLoginAttempt.
func (s *Service) loginFailed(ctx context.Context, userID, ip string) error {
	s.audit.Record(ctx, audit.LoginFailed, userID, ip, map[string]any{"known": userID != ""})
	return errInvalidCredentials
}

// ChangePassword replaces the password after checking the current one. The
// caller's session stays; every other session ends.
func (s *Service) ChangePassword(ctx context.Context, p Principal, current, next string, c Client) error {
	if err := s.limits.Hit(ctx, limitUserSensitive, p.UserID); err != nil {
		return err
	}
	var hash, email, locale string
	err := s.pool.QueryRow(ctx, `
		SELECT i.password_hash, e.email FROM auth_identities i
		JOIN user_emails e ON e.user_id = i.user_id AND e.is_primary AND e.removed_at IS NULL
		WHERE i.user_id = $1 AND i.provider = 'password'`, p.UserID).Scan(&hash, &email)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Conflict("password_not_set", "this account signs in with Google; use forgot password to add one")
	}
	if err != nil {
		return err
	}
	if _, err := s.pw.Verify(ctx, current, hash); err != nil {
		if errors.Is(err, password.ErrMismatch) {
			s.audit.Record(ctx, audit.PasswordChangeFailed, p.UserID, c.IP, nil)
			return apperr.New(http.StatusUnauthorized, "invalid_credentials", "current password is wrong").With("field", "currentPassword")
		}
		return err
	}
	if problem := password.Problem(next, email); problem != "" {
		return apperr.Unprocessable(problem, "choose a different password").With("field", "newPassword")
	}
	if current == next {
		return apperr.Unprocessable("password_unchanged", "the new password is the current one").With("field", "newPassword")
	}
	newHash, err := s.pw.Hash(ctx, next)
	if err != nil {
		return err
	}
	locale = c.Locale
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		// Compare-and-set on the old hash: two concurrent changes cannot both
		// win on the strength of the same current password.
		tag, err := tx.Exec(ctx, `UPDATE auth_identities SET password_hash = $3, updated_at = now() WHERE user_id = $1 AND provider = 'password' AND password_hash = $2`,
			p.UserID, hash, newHash)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return apperr.Conflict("password_changed_concurrently", "try again")
		}
		if err := revokeOthers(ctx, tx, p.UserID, p.SessionID, "password_change"); err != nil {
			return err
		}
		return s.outbox.Enqueue(ctx, tx, mail.KindPasswordChanged, mail.PasswordChanged(locale, email), s.now().Add(24*time.Hour))
	})
	if err != nil {
		return err
	}
	s.outbox.Nudge()
	s.audit.Record(ctx, audit.PasswordChanged, p.UserID, c.IP, nil)
	return nil
}

// ---- Email change (the app does not offer this yet) ---------------------

type EmailChangeInput struct {
	NewEmail        string
	CurrentPassword string // for accounts with a password
	GoogleIDToken   string // for Google-only accounts: a fresh sign-in
}

// StartEmailChange sends a code to the new address after the caller proves
// it is really them (password, or a fresh Google sign-in). The address only
// becomes the account's email once the code is entered.
func (s *Service) StartEmailChange(ctx context.Context, p Principal, in EmailChangeInput, c Client) (FlowStarted, error) {
	email, err := NormalizeEmail(in.NewEmail)
	if err != nil {
		return FlowStarted{}, err
	}
	if err := s.limits.Hit(ctx, limitUserSensitive, p.UserID); err != nil {
		return FlowStarted{}, err
	}
	if err := s.limits.Hit(ctx, limitRegisterEmail, email); err != nil {
		return FlowStarted{}, err
	}
	if err := s.reauthenticate(ctx, p.UserID, in.CurrentPassword, in.GoogleIDToken); err != nil {
		return FlowStarted{}, err
	}
	var current string
	if err := s.pool.QueryRow(ctx, `SELECT email FROM user_emails WHERE user_id = $1 AND is_primary AND removed_at IS NULL`, p.UserID).Scan(&current); err != nil {
		return FlowStarted{}, err
	}
	if current == email {
		return FlowStarted{}, apperr.Unprocessable("email_unchanged", "that is already the account's email").With("field", "newEmail")
	}
	var out FlowStarted
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		uid := p.UserID
		_, code, link, started, err := s.newFlow(ctx, tx, PurposeEmailChange, email, &uid, nil, nil, c.Locale, true)
		if err != nil {
			return err
		}
		out = started
		return s.outbox.Enqueue(ctx, tx, mail.KindEmailChangeCode, s.codeMail(PurposeEmailChange, c.Locale, email, code, link), started.ExpiresAt)
	})
	if err != nil {
		return FlowStarted{}, err
	}
	s.outbox.Nudge()
	s.audit.Record(ctx, audit.EmailChangeRequested, p.UserID, c.IP, nil)
	return out, nil
}

// ConfirmEmailChange verifies the new address and makes it the account's
// email. The old address is told, and every other session ends.
func (s *Service) ConfirmEmailChange(ctx context.Context, p Principal, handle string, proof Proof, c Client) error {
	if err := proof.validate(); err != nil {
		return err
	}
	if err := s.limits.Hit(ctx, limitVerifyIP, c.IP); err != nil {
		return err
	}
	var oldEmail, newEmail string
	err := s.runTx(ctx, func(tx pgx.Tx) error {
		f, err := s.loadFlow(ctx, tx, handle, PurposeEmailChange, true)
		if err != nil {
			return err
		}
		if f.userID == nil || *f.userID != p.UserID {
			return apperr.NotFound("flow_not_found", "start again")
		}
		done, err := s.checkProof(ctx, tx, f, proof, c.IP)
		if err != nil || done {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT email FROM user_emails WHERE user_id = $1 AND is_primary AND removed_at IS NULL FOR UPDATE`, p.UserID).Scan(&oldEmail); err != nil {
			return err
		}
		newEmail = f.email
		if _, err := tx.Exec(ctx, `UPDATE user_emails SET is_primary = false, removed_at = now() WHERE user_id = $1 AND is_primary AND removed_at IS NULL`, p.UserID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO user_emails (user_id, email, is_primary, verified_at) VALUES ($1, $2, true, now())`, p.UserID, newEmail); err != nil {
			if store.IsUniqueViolation(err, "") {
				// Rolls back the whole change; the old address stays primary.
				return apperr.Conflict("email_in_use", "that address belongs to another account")
			}
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE auth_flows SET verified_at = now(), completed_at = now() WHERE id = $1`, f.id); err != nil {
			return err
		}
		if err := revokeOthers(ctx, tx, p.UserID, p.SessionID, "email_change"); err != nil {
			return err
		}
		return s.outbox.Enqueue(ctx, tx, mail.KindEmailChanged, mail.EmailChanged(f.locale, oldEmail, mail.MaskEmail(newEmail)), s.now().Add(24*time.Hour))
	})
	if err != nil {
		return err
	}
	if newEmail != "" {
		s.outbox.Nudge()
		s.audit.Record(ctx, audit.EmailChanged, p.UserID, c.IP, nil)
	}
	return nil
}

// reauthenticate asks for fresh proof before a sensitive change.
func (s *Service) reauthenticate(ctx context.Context, userID, pw, googleToken string) error {
	var hash *string
	var subject *string
	err := s.pool.QueryRow(ctx, `
		SELECT (SELECT password_hash FROM auth_identities WHERE user_id = $1 AND provider = 'password'),
		       (SELECT provider_subject FROM auth_identities WHERE user_id = $1 AND provider = 'google')`, userID).Scan(&hash, &subject)
	if err != nil {
		return err
	}
	if hash != nil {
		if pw == "" {
			return apperr.Validation("currentPassword", "required")
		}
		if _, err := s.pw.Verify(ctx, pw, *hash); err != nil {
			if errors.Is(err, password.ErrMismatch) {
				return apperr.New(http.StatusUnauthorized, "invalid_credentials", "current password is wrong").With("field", "currentPassword")
			}
			return err
		}
		return nil
	}
	if subject == nil {
		return apperr.Conflict("reauth_unavailable", "no way to confirm it's you")
	}
	if googleToken == "" {
		return apperr.Validation("googleIdToken", "required")
	}
	claims, err := s.verifyGoogle(ctx, googleToken)
	if err != nil {
		return err
	}
	if claims.Subject != *subject {
		return apperr.New(http.StatusUnauthorized, "invalid_credentials", "that Google account is not linked to this account")
	}
	return nil
}
