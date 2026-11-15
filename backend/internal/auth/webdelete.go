package auth

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/audit"
	"github.com/HPTarkk/Tark/backend/internal/mail"
)

// Deleting an account from the website, for someone who can't use the app
// (no phone, a lost password, a Google account they no longer have).
//
// An email that claims to come from the account's address proves nothing:
// the From line can be forged. So the website asks for the address, and
// the server mails a one-time link to it. Opening that link proves control
// of the inbox — the same proof a password reset accepts — and the page
// it opens shows what will go and asks for a typed confirmation before
// anything is deleted.
//
// The link carries the flow's handle and its link token together in the
// URL fragment ("<handle>.<token>"), which browsers never send to a server;
// the page posts it to the API itself.

const PurposeAccountDelete = "account_delete"

// WebDeleteRequested is the same for every address, known or not.
type WebDeleteRequested struct {
	ExpiresAt time.Time
}

// RequestWebDelete mails a deletion link to the address when it has an
// account. The answer never says whether it does.
func (s *Service) RequestWebDelete(ctx context.Context, rawEmail string, c Client) (WebDeleteRequested, error) {
	email, err := NormalizeEmail(rawEmail)
	if err != nil {
		return WebDeleteRequested{}, err
	}
	if err := s.limits.Hit(ctx, limitWebDeleteIP, c.IP); err != nil {
		return WebDeleteRequested{}, err
	}
	if err := s.limits.Hit(ctx, limitWebDeleteEmail, email); err != nil {
		return WebDeleteRequested{}, err
	}
	var out WebDeleteRequested
	var userID string
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		// Any status: a suspended account can still be deleted by its owner.
		err := tx.QueryRow(ctx, `SELECT user_id FROM user_emails WHERE email = $1 AND is_primary AND removed_at IS NULL`, email).Scan(&userID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if userID == "" {
			// A decoy, so both answers cost the same database work.
			_, _, _, started, err := s.newFlow(ctx, tx, PurposeAccountDelete, email, nil, nil, nil, c.Locale, false)
			out = WebDeleteRequested{ExpiresAt: started.ExpiresAt}
			return err
		}
		// Only the newest link works.
		if _, err := tx.Exec(ctx, `UPDATE auth_flows SET expires_at = now() WHERE purpose = 'account_delete' AND user_id = $1 AND completed_at IS NULL AND expires_at > now()`, userID); err != nil {
			return err
		}
		handle, _, link, started, err := s.newFlow(ctx, tx, PurposeAccountDelete, email, &userID, nil, nil, c.Locale, true)
		if err != nil {
			return err
		}
		out = WebDeleteRequested{ExpiresAt: started.ExpiresAt}
		msg := mail.DeleteLink(c.Locale, email, s.webDeleteURL(c.Locale, handle, link), int(flowTTL/time.Minute))
		return s.outbox.Enqueue(ctx, tx, mail.KindDeleteLink, msg, started.ExpiresAt)
	})
	if err != nil {
		return WebDeleteRequested{}, err
	}
	s.outbox.Nudge()
	s.audit.Record(ctx, audit.AccountDeleteRequested, userID, c.IP, map[string]any{"known": userID != ""})
	return out, nil
}

func (s *Service) webDeleteURL(locale, handle, link string) string {
	prefix := ""
	if locale == "fa" {
		prefix = "/fa"
	}
	return s.cfg.LinkBaseURL + prefix + "/confirm-delete#" + handle + "." + link
}

// splitWebDeleteToken parses "<handle>.<token>" from the link's fragment.
func splitWebDeleteToken(raw string) (handle, link string, err error) {
	handle, link, ok := strings.Cut(strings.TrimSpace(raw), ".")
	if !ok || len(handle) < 20 || len(handle) > 64 || len(link) < 20 || len(link) > 128 {
		return "", "", apperr.NotFound("flow_not_found", "this link is not valid; ask for a new one")
	}
	return handle, link, nil
}

// WebDeleteAccount is what the confirmation page shows before deleting.
type WebDeleteAccount struct {
	Email                string
	Name                 string
	AvatarID             *string
	CreatedAt            time.Time
	ExpiresAt            time.Time
	SubscriptionActive   bool
	SubscriptionRenewing bool
	SubscriptionUntil    *time.Time
}

// openWebDelete checks a link inside tx and returns its flow and account.
func (s *Service) openWebDelete(ctx context.Context, tx pgx.Tx, token string, c Client) (*flowRow, error) {
	handle, link, err := splitWebDeleteToken(token)
	if err != nil {
		return nil, err
	}
	f, err := s.loadFlow(ctx, tx, handle, PurposeAccountDelete, true)
	if err != nil {
		return nil, err
	}
	done, err := s.checkProof(ctx, tx, f, Proof{LinkToken: link}, c.IP)
	if err != nil {
		return nil, err
	}
	if done || f.userID == nil {
		return nil, apperr.Conflict("flow_completed", "this link was already used")
	}
	// The address must still be the account's: a link sent before an email
	// change no longer proves anything about the account.
	var still bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM user_emails WHERE user_id = $1 AND email = $2 AND is_primary AND removed_at IS NULL)`,
		*f.userID, f.email).Scan(&still); err != nil {
		return nil, err
	}
	if !still {
		return nil, apperr.Conflict("flow_completed", "this link no longer works; ask for a new one")
	}
	return f, nil
}

// InspectWebDelete answers the confirmation page: whose account the link
// is for, and whether a paid Bazaar period is running. It changes nothing.
func (s *Service) InspectWebDelete(ctx context.Context, token string, c Client) (WebDeleteAccount, error) {
	if err := s.limits.Hit(ctx, limitVerifyIP, c.IP); err != nil {
		return WebDeleteAccount{}, err
	}
	var out WebDeleteAccount
	err := s.runTx(ctx, func(tx pgx.Tx) error {
		f, err := s.openWebDelete(ctx, tx, token, c)
		if err != nil {
			return err
		}
		out.Email = f.email
		out.ExpiresAt = f.expiresAt
		if err := tx.QueryRow(ctx, `SELECT name, avatar_id, created_at FROM users WHERE id = $1`, *f.userID).
			Scan(&out.Name, &out.AvatarID, &out.CreatedAt); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `
			SELECT count(*) > 0, coalesce(bool_or(auto_renewing), false), max(valid_until) FROM bazaar_purchases
			WHERE user_id = $1 AND state = 'active' AND valid_until > now()`, *f.userID).
			Scan(&out.SubscriptionActive, &out.SubscriptionRenewing, &out.SubscriptionUntil)
	})
	return out, err
}

type WebDeleteInput struct {
	Token string
	// Confirmation is the word the page asks the person to type.
	Confirmation             string
	SubscriptionAcknowledged bool
}

// ConfirmationWords are the words the page asks for, by locale. Either
// language's word is accepted, whatever the page's language.
var ConfirmationWords = map[string]string{"en": "DELETE", "fa": "حذف"}

// confirmationMatches compares what was typed with the words, ignoring
// case, spaces, zero-width joiners and Arabic letter forms a Persian
// keyboard on some phones types instead of the Persian ones.
func confirmationMatches(typed string) bool {
	norm := func(v string) string {
		v = strings.NewReplacer("ي", "ی", "ك", "ک", "ى", "ی").Replace(v)
		return strings.Map(func(r rune) rune {
			if unicode.IsSpace(r) || r == '‌' || r == '‍' || r == '‎' || r == '‏' {
				return -1
			}
			return unicode.ToLower(r)
		}, v)
	}
	got := norm(typed)
	if got == "" {
		return false
	}
	for _, w := range ConfirmationWords {
		if got == norm(w) {
			return true
		}
	}
	return false
}

// ConfirmWebDelete deletes the account the link is for, at once and for
// good, as the in-app deletion does.
func (s *Service) ConfirmWebDelete(ctx context.Context, in WebDeleteInput, c Client) error {
	if err := s.limits.Hit(ctx, limitVerifyIP, c.IP); err != nil {
		return err
	}
	if !confirmationMatches(in.Confirmation) {
		return apperr.Unprocessable("confirmation_mismatch", "type the confirmation word").With("field", "confirmation")
	}
	var userID, email, locale string
	err := s.runTx(ctx, func(tx pgx.Tx) error {
		f, err := s.openWebDelete(ctx, tx, in.Token, c)
		if err != nil {
			return err
		}
		userID, email, locale = *f.userID, f.email, f.locale
		if !in.SubscriptionAcknowledged {
			var paid, renewing bool
			if err := tx.QueryRow(ctx, `
				SELECT count(*) > 0, coalesce(bool_or(auto_renewing), false) FROM bazaar_purchases
				WHERE user_id = $1 AND state = 'active' AND valid_until > now()`, userID).Scan(&paid, &renewing); err != nil {
				return err
			}
			if paid {
				return apperr.Conflict("subscription_active", "deleting the account does not cancel the Bazaar subscription; confirm with subscriptionAcknowledged").
					With("autoRenewing", renewing)
			}
		}
		_, err = tx.Exec(ctx, `UPDATE auth_flows SET verified_at = now() WHERE id = $1`, f.id)
		return err
	})
	if err != nil {
		return err
	}
	if c.Locale != "" {
		locale = c.Locale
	}
	if err := s.deleteNow(ctx, userID, email, locale); err != nil {
		if e, ok := apperr.As(err); ok && e.Status == http.StatusUnauthorized {
			// Deleted a moment ago by another tap or another way.
			return apperr.Conflict("flow_completed", "this account was already deleted")
		}
		return err
	}
	s.audit.Record(ctx, audit.AccountDeleted, "", c.IP, map[string]any{"via": "web_link"})
	return nil
}
