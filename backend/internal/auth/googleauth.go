package auth

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/audit"
	"github.com/HPTarkk/Tark/backend/internal/google"
	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/password"
	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

// GoogleNonce is handed to the Google SDK before sign-in; Google puts it in
// the ID token, and the server accepts each nonce once. That ties every ID
// token to a sign-in this server asked for, so a token captured elsewhere
// (or replayed) is refused.
type GoogleNonce struct {
	Nonce     string
	ExpiresAt time.Time
}

func (s *Service) NewGoogleNonce(ctx context.Context, c Client) (GoogleNonce, error) {
	if err := s.limits.Hit(ctx, limitGoogleIP, c.IP); err != nil {
		return GoogleNonce{}, err
	}
	nonce := secure.RandomToken(24)
	expires := s.now().Add(googleNonceTTL)
	if _, err := s.pool.Exec(ctx, `INSERT INTO google_nonces (nonce_hash, expires_at) VALUES ($1, $2)`,
		s.hash("google-nonce", nonce), expires); err != nil {
		return GoogleNonce{}, err
	}
	return GoogleNonce{Nonce: nonce, ExpiresAt: expires}, nil
}

// GoogleOutcome is either a sign-in, or a ticket the app must continue with.
type GoogleOutcome struct {
	SignedIn *SignedIn
	// Set with apperr code "link_required": the address already has a
	// password account; the app asks for that password and calls
	// LinkGoogle. Set with "name_required": a new account needs a name.
	Ticket          string
	TicketExpiresAt time.Time
	MaskedEmail     string
	SuggestedName   string
}

var errGoogleRejected = apperr.New(http.StatusUnauthorized, "google_token_invalid", "sign in with Google again")

func (s *Service) verifyGoogle(ctx context.Context, idToken string) (*google.Claims, error) {
	claims, err := s.google.Verify(ctx, idToken)
	if errors.Is(err, google.ErrKeysUnset) {
		s.log.WarnContext(ctx, "google keys unavailable", "reason", err.Error())
		return nil, apperr.Unavailable("google_unavailable", "could not reach Google to check the sign-in", 30*time.Second)
	}
	if err != nil {
		s.log.InfoContext(ctx, "google id token rejected", "reason", err.Error())
		return nil, errGoogleRejected
	}
	return claims, nil
}

// consumeGoogleToken marks the nonce and the token itself as used.
func (s *Service) consumeGoogleToken(ctx context.Context, tx pgx.Tx, idToken string, claims *google.Claims) error {
	if s.cfg.GoogleRequireNonce || claims.Nonce != "" {
		tag, err := tx.Exec(ctx, `UPDATE google_nonces SET used_at = now() WHERE nonce_hash = $1 AND used_at IS NULL AND expires_at > now()`,
			s.hash("google-nonce", claims.Nonce))
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return errGoogleRejected
		}
	}
	tag, err := tx.Exec(ctx, `INSERT INTO google_seen_tokens (token_hash, expires_at) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		s.hash("google-token", idToken), claims.ExpiresAt.Add(time.Hour))
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return errGoogleRejected
	}
	return nil
}

// GoogleSignIn handles every Google sign-in:
//   - known Google account: signed in.
//   - address already has a password account: "link_required" with a
//     ticket; the accounts are linked once the password is entered.
//   - new address: account created with the name the app sent (the name
//     it already has locally) or Google's name; if there is neither,
//     "name_required" with a ticket.
func (s *Service) GoogleSignIn(ctx context.Context, idToken, name string, c Client) (GoogleOutcome, error) {
	if err := s.limits.Hit(ctx, limitGoogleIP, c.IP); err != nil {
		return GoogleOutcome{}, err
	}
	claims, err := s.verifyGoogle(ctx, idToken)
	if err != nil {
		s.audit.Record(ctx, audit.GoogleTokenRejected, "", c.IP, nil)
		return GoogleOutcome{}, err
	}
	if !claims.EmailVerified || claims.Email == "" {
		return GoogleOutcome{}, apperr.Unprocessable("google_email_unverified", "this Google account has no verified email")
	}
	email, err := NormalizeEmail(claims.Email)
	if err != nil {
		return GoogleOutcome{}, apperr.Unprocessable("google_email_unsupported", "this Google account's email cannot be used")
	}
	chosenName := ""
	if name != "" {
		if chosenName, err = NormalizeName(name); err != nil {
			return GoogleOutcome{}, err
		}
	}

	var out GoogleOutcome
	var event, eventUser string
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.consumeGoogleToken(ctx, tx, idToken, claims); err != nil {
			return err
		}

		var userID, status string
		err := tx.QueryRow(ctx, `
			SELECT u.id, u.status FROM auth_identities i JOIN users u ON u.id = i.user_id
			WHERE i.provider = 'google' AND i.provider_subject = $1`, claims.Subject).Scan(&userID, &status)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if userID != "" {
			if status != "active" {
				return apperr.New(http.StatusForbidden, "account_disabled", "contact support")
			}
			tokens, err := s.startSession(ctx, tx, userID, c)
			out.SignedIn = &SignedIn{Tokens: tokens, UserID: userID}
			event, eventUser = audit.GoogleSignedIn, userID
			return err
		}

		var existing string
		var hasPassword, hasGoogle bool
		err = tx.QueryRow(ctx, `
			SELECT e.user_id,
				EXISTS (SELECT 1 FROM auth_identities WHERE user_id = e.user_id AND provider = 'password'),
				EXISTS (SELECT 1 FROM auth_identities WHERE user_id = e.user_id AND provider = 'google')
			FROM user_emails e WHERE e.email = $1 AND e.removed_at IS NULL`, email).Scan(&existing, &hasPassword, &hasGoogle)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if existing != "" {
			if hasGoogle || !hasPassword {
				// The address is on an account linked to a different Google
				// account. Linking a second one is not supported.
				return apperr.Conflict("account_conflict", "this email is linked to a different Google account")
			}
			ticket, expires, err := s.newGoogleTicket(ctx, tx, "link", claims, email, "", existing, c)
			if err != nil {
				return err
			}
			out.Ticket, out.TicketExpiresAt, out.MaskedEmail = ticket, expires, mail.MaskEmail(email)
			event, eventUser = audit.GoogleLinkRequired, existing
			return nil
		}

		if chosenName == "" {
			chosenName, _ = NormalizeName(claims.Name)
		}
		if chosenName == "" {
			suggested, _ := NormalizeName(claims.Name)
			ticket, expires, err := s.newGoogleTicket(ctx, tx, "signup", claims, email, suggested, "", c)
			if err != nil {
				return err
			}
			out.Ticket, out.TicketExpiresAt, out.SuggestedName = ticket, expires, suggested
			return nil
		}
		signed, err := s.createGoogleAccount(ctx, tx, claims.Subject, email, chosenName, c)
		if err != nil {
			return err
		}
		out.SignedIn = signed
		event, eventUser = audit.GoogleSignedUp, signed.UserID
		return nil
	})
	if err != nil {
		return GoogleOutcome{}, err
	}
	if event != "" {
		s.audit.Record(ctx, event, eventUser, c.IP, nil)
	}
	return out, nil
}

func (s *Service) newGoogleTicket(ctx context.Context, tx pgx.Tx, purpose string, claims *google.Claims, email, suggested, userID string, c Client) (string, time.Time, error) {
	ticket := secure.RandomToken(32)
	expires := s.now().Add(googleTicketTTL)
	var uid, sug, platform, install *string
	if userID != "" {
		uid = &userID
	}
	if suggested != "" {
		sug = &suggested
	}
	if c.Platform != "" {
		platform = &c.Platform
	}
	if c.InstallKey != "" {
		install = &c.InstallKey
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO google_tickets (ticket_hash, purpose, google_subject, email, suggested_name, user_id, platform, install_key, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		s.hash("google-ticket", ticket), purpose, claims.Subject, email, sug, uid, platform, install, expires)
	return ticket, expires, err
}

// createGoogleAccount inserts a user with a verified email (Google
// verified it) and a Google identity.
func (s *Service) createGoogleAccount(ctx context.Context, tx pgx.Tx, subject, email, name string, c Client) (*SignedIn, error) {
	var userID string
	if err := tx.QueryRow(ctx, `INSERT INTO users (name) VALUES ($1) RETURNING id`, name).Scan(&userID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO user_emails (user_id, email, is_primary, verified_at) VALUES ($1, $2, true, now())`, userID, email); err != nil {
		if store.IsUniqueViolation(err, "") {
			// Someone registered the address a moment ago. Asking the app to
			// sign in with Google again lands in the linking path.
			return nil, apperr.Conflict("retry_sign_in", "sign in with Google again")
		}
		return nil, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO auth_identities (user_id, provider, provider_subject) VALUES ($1, 'google', $2)`, userID, subject); err != nil {
		if store.IsUniqueViolation(err, "") {
			return nil, apperr.Conflict("retry_sign_in", "sign in with Google again")
		}
		return nil, err
	}
	// Sign-ups by email for this address can no longer finish.
	if _, err := tx.Exec(ctx, `UPDATE auth_flows SET expires_at = now() WHERE purpose = 'register' AND email = $1 AND completed_at IS NULL`, email); err != nil {
		return nil, err
	}
	tokens, err := s.startSession(ctx, tx, userID, c)
	if err != nil {
		return nil, err
	}
	return &SignedIn{Tokens: tokens, UserID: userID, NewAccount: true}, nil
}

type googleTicket struct {
	id, purpose, subject, email string
	userID                      *string
	attempts                    int
	expiresAt                   time.Time
	usedAt                      *time.Time
}

func (s *Service) loadGoogleTicket(ctx context.Context, tx pgx.Tx, ticket, purpose string) (*googleTicket, error) {
	if len(ticket) < 20 || len(ticket) > 128 {
		return nil, apperr.New(http.StatusGone, "ticket_expired", "sign in with Google again")
	}
	var t googleTicket
	err := tx.QueryRow(ctx, `
		SELECT id, purpose, google_subject, email, user_id, attempts, expires_at, used_at
		FROM google_tickets WHERE ticket_hash = $1 FOR UPDATE`, s.hash("google-ticket", ticket)).
		Scan(&t.id, &t.purpose, &t.subject, &t.email, &t.userID, &t.attempts, &t.expiresAt, &t.usedAt)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (t.purpose != purpose || t.usedAt != nil || !s.now().Before(t.expiresAt))) {
		return nil, apperr.New(http.StatusGone, "ticket_expired", "sign in with Google again")
	}
	if err != nil {
		return nil, err
	}
	if t.attempts >= maxTicketTries {
		return nil, apperr.New(http.StatusLocked, "ticket_locked", "sign in with Google again")
	}
	return &t, nil
}

// LinkGoogle finishes a "link_required" sign-in: the password of the
// existing account proves the person owns both, and Google is added as a
// second way in.
func (s *Service) LinkGoogle(ctx context.Context, ticket, pw string, c Client) (SignedIn, error) {
	if err := s.limits.Hit(ctx, limitGoogleIP, c.IP); err != nil {
		return SignedIn{}, err
	}
	var out SignedIn
	var email, userID string
	err := s.runTx(ctx, func(tx pgx.Tx) error {
		t, err := s.loadGoogleTicket(ctx, tx, ticket, "link")
		if err != nil {
			return err
		}
		if t.userID == nil {
			return apperr.New(http.StatusGone, "ticket_expired", "sign in with Google again")
		}
		userID, email = *t.userID, t.email
		// The same failure counters as password sign-in, counted up front like
		// there (see Login).
		emailIP := email + "|" + c.IP
		if err := s.reserveLoginAttempt(ctx, email, emailIP); err != nil {
			return err
		}
		failed := false
		defer func() {
			if !failed {
				s.refundLoginAttempt(ctx, email, emailIP)
			}
		}()
		var hash, status string
		err = tx.QueryRow(ctx, `
			SELECT i.password_hash, u.status FROM auth_identities i JOIN users u ON u.id = i.user_id
			WHERE i.user_id = $1 AND i.provider = 'password'`, userID).Scan(&hash, &status)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.New(http.StatusGone, "ticket_expired", "sign in with Google again")
		}
		if err != nil {
			return err
		}
		if _, err := s.pw.Verify(ctx, pw, hash); err != nil {
			if !errors.Is(err, password.ErrMismatch) {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE google_tickets SET attempts = attempts + 1 WHERE id = $1`, t.id); err != nil {
				return err
			}
			failed = true
			s.audit.Record(ctx, audit.GoogleLinkFailed, userID, c.IP, nil)
			s.audit.Record(ctx, audit.LoginFailed, userID, c.IP, map[string]any{"known": true})
			left := maxTicketTries - t.attempts - 1
			return &committedError{errInvalidCredentials.With("attemptsLeft", max(left, 0))}
		}
		if status != "active" {
			return apperr.New(http.StatusForbidden, "account_disabled", "contact support")
		}
		if _, err := tx.Exec(ctx, `INSERT INTO auth_identities (user_id, provider, provider_subject) VALUES ($1, 'google', $2)`, userID, t.subject); err != nil {
			if store.IsUniqueViolation(err, "") {
				return apperr.Conflict("account_conflict", "this Google account or this account is already linked")
			}
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE google_tickets SET used_at = now() WHERE id = $1`, t.id); err != nil {
			return err
		}
		tokens, err := s.startSession(ctx, tx, userID, c)
		if err != nil {
			return err
		}
		out = SignedIn{Tokens: tokens, UserID: userID}
		return s.outbox.Enqueue(ctx, tx, mail.KindGoogleLinked, mail.GoogleLinked(c.Locale, email), s.now().Add(24*time.Hour))
	})
	if err != nil {
		return SignedIn{}, err
	}
	s.outbox.Nudge()
	_ = s.limits.Reset(ctx, limitLoginEmailIP, email+"|"+c.IP)
	s.audit.Record(ctx, audit.GoogleLinked, userID, c.IP, nil)
	return out, nil
}

// CompleteGoogleSignup finishes a "name_required" sign-in.
func (s *Service) CompleteGoogleSignup(ctx context.Context, ticket, name string, c Client) (SignedIn, error) {
	if err := s.limits.Hit(ctx, limitGoogleIP, c.IP); err != nil {
		return SignedIn{}, err
	}
	clean, err := NormalizeName(name)
	if err != nil {
		return SignedIn{}, err
	}
	var out SignedIn
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		t, err := s.loadGoogleTicket(ctx, tx, ticket, "signup")
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE google_tickets SET used_at = now() WHERE id = $1`, t.id); err != nil {
			return err
		}
		signed, err := s.createGoogleAccount(ctx, tx, t.subject, t.email, clean, c)
		if err != nil {
			return err
		}
		out = *signed
		return nil
	})
	if err != nil {
		return SignedIn{}, err
	}
	s.audit.Record(ctx, audit.GoogleSignedUp, out.UserID, c.IP, nil)
	return out, nil
}
