package auth

import (
	"context"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/audit"
	"github.com/HPTarkk/Tark/backend/internal/mail"
)

type DeleteAccountInput struct {
	// ConfirmEmail is the account's email, typed by the person. A tap on
	// "yes" is not enough to delete an account.
	ConfirmEmail string
	// Fresh proof it is really them: the password, or for a Google-only
	// account a new Google sign-in.
	CurrentPassword string
	GoogleIDToken   string
	// Required while a paid Bazaar period is running: the person has seen
	// that deleting the account does not cancel the Bazaar subscription.
	SubscriptionAcknowledged bool
}

// DeleteAccount removes the account and everything tied to it, at once and
// for good. It needs three things: a signed-in session, fresh proof of the
// password (or a new Google sign-in), and the account's email typed out.
//
// Bazaar purchases are deleted with the account, so a purchase token is
// free again: the same person can restore their purchase in a new account.
// It can still only belong to one account at a time. Security events stay
// for their normal year, without the account id.
func (s *Service) DeleteAccount(ctx context.Context, p Principal, in DeleteAccountInput, c Client) error {
	if err := s.limits.Hit(ctx, limitUserSensitive, p.UserID); err != nil {
		return err
	}
	var email string
	if err := s.pool.QueryRow(ctx, `SELECT email FROM user_emails WHERE user_id = $1 AND is_primary AND removed_at IS NULL`, p.UserID).Scan(&email); err != nil {
		return err
	}
	typed, err := NormalizeEmail(in.ConfirmEmail)
	if err != nil || typed != email {
		return apperr.Unprocessable("confirmation_mismatch", "type the account's email to confirm").With("field", "confirmEmail")
	}
	if err := s.reauthenticate(ctx, p.UserID, in.CurrentPassword, in.GoogleIDToken); err != nil {
		if e, ok := apperr.As(err); ok && e.Status == http.StatusUnauthorized {
			s.audit.Record(ctx, audit.AccountDeleteFailed, p.UserID, c.IP, nil)
		}
		return err
	}

	if !in.SubscriptionAcknowledged {
		var paid, renewing bool
		err := s.pool.QueryRow(ctx, `
			SELECT count(*) > 0, coalesce(bool_or(auto_renewing), false) FROM bazaar_purchases
			WHERE user_id = $1 AND state = 'active' AND valid_until > now()`, p.UserID).Scan(&paid, &renewing)
		if err != nil {
			return err
		}
		if paid {
			return apperr.Conflict("subscription_active", "deleting the account does not cancel the Bazaar subscription; confirm with subscriptionAcknowledged").
				With("autoRenewing", renewing)
		}
	}

	locale := c.Locale
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		// The row lock makes a concurrent sign-in, refresh or profile change
		// wait, then find nothing.
		tag, err := tx.Exec(ctx, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, p.UserID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return apperr.Unauthorized("account not found")
		}
		if err := s.outbox.Enqueue(ctx, tx, mail.KindAccountDeleted, mail.AccountDeleted(locale, email), s.now().Add(24*time.Hour)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE audit_events SET user_id = NULL WHERE user_id = $1`, p.UserID); err != nil {
			return err
		}
		// Replays of this account's writes could hold a signed entitlement.
		if _, err := tx.Exec(ctx, `DELETE FROM idempotency_keys WHERE scope = $1`, "user:"+p.UserID); err != nil {
			return err
		}
		// Everything else (emails, identities, sessions, refresh tokens,
		// flows, purchases, subscription history) goes by ON DELETE CASCADE.
		_, err = tx.Exec(ctx, `DELETE FROM users WHERE id = $1`, p.UserID)
		return err
	})
	if err != nil {
		return err
	}
	s.outbox.Nudge()
	s.audit.Record(ctx, audit.AccountDeleted, "", c.IP, nil)
	return nil
}
