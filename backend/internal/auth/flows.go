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
	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

// Flow purposes, and the path segment of their email links.
const (
	PurposeRegister    = "register"
	PurposeReset       = "password_reset"
	PurposeEmailChange = "email_change"
)

var linkPaths = map[string]string{
	PurposeRegister:    "register",
	PurposeReset:       "reset",
	PurposeEmailChange: "email",
}

// FlowStarted is what the app gets back when a flow starts or a code is
// resent. It looks the same whether or not the address has an account.
type FlowStarted struct {
	FlowID            string
	ExpiresAt         time.Time
	ResendAvailableAt time.Time
}

// Proof is what the app presents to verify a flow: the code the person
// typed, or the token from the email link. Exactly one is set.
type Proof struct {
	Code      string
	LinkToken string
}

func (p Proof) validate() error {
	switch {
	case p.Code != "" && p.LinkToken != "":
		return apperr.Validation("code", "send either code or linkToken, not both")
	case p.Code != "":
		if len(p.Code) != CodeLength {
			return apperr.Validation("code", "wrong length")
		}
		for i := 0; i < len(p.Code); i++ {
			if p.Code[i] < '0' || p.Code[i] > '9' {
				return apperr.Validation("code", "digits only")
			}
		}
	case p.LinkToken != "":
		if len(p.LinkToken) < 20 || len(p.LinkToken) > 128 {
			return apperr.Validation("linkToken", "malformed")
		}
	default:
		return apperr.Validation("code", "code or linkToken is required")
	}
	return nil
}

type flowRow struct {
	id           string
	purpose      string
	email        string
	userID       *string
	name         *string
	passwordHash *string
	locale       string
	codeHash     []byte
	linkHash     []byte
	attempts     int
	sends        int
	lastSentAt   *time.Time
	expiresAt    time.Time
	verifiedAt   *time.Time
	completedAt  *time.Time
}

// newFlow inserts a flow and returns its handle and, when the flow can be
// completed, its code and link token. A decoy flow (sendable=false) has no
// code at all: it exists so the response for an unknown address looks the
// same as for a known one, and it can never be verified.
func (s *Service) newFlow(ctx context.Context, tx pgx.Tx, purpose, email string, userID, name, pwHash *string,
	locale string, sendable bool) (handle, code, link string, started FlowStarted, err error) {
	now := s.now()
	id := secure.NewUUID()
	handle = secure.RandomToken(24)
	var codeHash, linkHash []byte
	sends := 0
	var lastSent *time.Time
	if sendable {
		code = secure.RandomDigits(CodeLength)
		link = secure.RandomToken(32)
		codeHash = s.hash("flow-code", id, code)
		linkHash = s.hash("flow-link", id, link)
		sends = 1
		lastSent = &now
	}
	expires := now.Add(flowTTL)
	_, err = tx.Exec(ctx, `
		INSERT INTO auth_flows (id, handle_hash, purpose, email, user_id, name, password_hash, locale,
			code_hash, link_hash, sends, last_sent_at, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
		id, s.hash("flow-handle", handle), purpose, email, userID, name, pwHash, locale,
		codeHash, linkHash, sends, lastSent, expires)
	if err != nil {
		return "", "", "", FlowStarted{}, err
	}
	return handle, code, link, FlowStarted{FlowID: handle, ExpiresAt: expires, ResendAvailableAt: now.Add(resendCooldown)}, nil
}

func (s *Service) linkURL(purpose, token string) string {
	// The token rides in the fragment, which browsers and link scanners do
	// not send to any server; only the app that opens the link reads it.
	return s.cfg.LinkBaseURL + "/v/" + linkPaths[purpose] + "#" + token
}

func (s *Service) codeMail(purpose, locale, to, code, link string) mail.Message {
	d := mail.CodeMail{Code: code, Link: s.linkURL(purpose, link), Minutes: int(flowTTL / time.Minute)}
	switch purpose {
	case PurposeReset:
		return mail.ResetCode(locale, to, d)
	case PurposeEmailChange:
		return mail.EmailChangeCode(locale, to, d)
	default:
		return mail.RegisterCode(locale, to, d)
	}
}

func (s *Service) loadFlow(ctx context.Context, q store.Querier, handle, purpose string, lock bool) (*flowRow, error) {
	if len(handle) < 20 || len(handle) > 64 {
		return nil, apperr.NotFound("flow_not_found", "start again")
	}
	sql := `SELECT id, purpose, email, user_id, name, password_hash, locale, code_hash, link_hash, attempts, sends,
		last_sent_at, expires_at, verified_at, completed_at FROM auth_flows WHERE handle_hash = $1`
	if lock {
		sql += ` FOR UPDATE`
	}
	var f flowRow
	err := q.QueryRow(ctx, sql, s.hash("flow-handle", handle)).Scan(&f.id, &f.purpose, &f.email, &f.userID, &f.name,
		&f.passwordHash, &f.locale, &f.codeHash, &f.linkHash, &f.attempts, &f.sends, &f.lastSentAt, &f.expiresAt,
		&f.verifiedAt, &f.completedAt)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && f.purpose != purpose) {
		return nil, apperr.NotFound("flow_not_found", "start again")
	}
	if err != nil {
		return nil, err
	}
	return &f, nil
}

func (s *Service) proofMatches(f *flowRow, p Proof) bool {
	if p.Code != "" {
		return f.codeHash != nil && secure.Equal(f.codeHash, s.hash("flow-code", f.id, p.Code))
	}
	return f.linkHash != nil && secure.Equal(f.linkHash, s.hash("flow-link", f.id, p.LinkToken))
}

// checkProof applies the attempt rules to a locked flow. It returns
// (alreadyDone=true) when the flow was completed moments ago with the same
// proof, so a retried request whose answer was lost can succeed again.
func (s *Service) checkProof(ctx context.Context, tx pgx.Tx, f *flowRow, p Proof, ip string) (alreadyDone bool, err error) {
	now := s.now()
	if f.completedAt != nil {
		if now.Sub(*f.completedAt) <= completedReplay && s.proofMatches(f, p) {
			return true, nil
		}
		return false, apperr.Conflict("flow_completed", "this flow is finished")
	}
	if !now.Before(f.expiresAt) {
		return false, apperr.New(http.StatusGone, "flow_expired", "start again")
	}
	if f.attempts >= maxCodeAttempts {
		return false, apperr.New(http.StatusLocked, "code_locked", "too many wrong codes; request a new one")
	}
	if !s.proofMatches(f, p) {
		f.attempts++
		if _, err := tx.Exec(ctx, `UPDATE auth_flows SET attempts = attempts + 1 WHERE id = $1`, f.id); err != nil {
			return false, err
		}
		s.audit.Record(ctx, audit.CodeFailed, deref(f.userID), ip, map[string]any{"purpose": f.purpose, "attempt": f.attempts})
		left := maxCodeAttempts - f.attempts
		if left <= 0 {
			s.audit.Record(ctx, audit.FlowLocked, deref(f.userID), ip, map[string]any{"purpose": f.purpose})
			return false, &committedError{apperr.New(http.StatusLocked, "code_locked", "too many wrong codes; request a new one")}
		}
		// The failed attempt must be counted even though the request fails,
		// so this error is returned after the transaction commits.
		return false, &committedError{apperr.Unprocessable("code_invalid", "wrong code").With("attemptsLeft", left)}
	}
	return false, nil
}

// committedError marks a failure whose transaction must still commit (to
// keep an attempt counter). runTx unwraps it after committing.
type committedError struct{ err *apperr.Error }

func (e *committedError) Error() string { return e.err.Error() }

// runTx runs fn in a transaction. A committedError commits and is then
// returned as the plain apperr.
func (s *Service) runTx(ctx context.Context, fn func(tx pgx.Tx) error) error {
	var pending *apperr.Error
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		err := fn(tx)
		var ce *committedError
		if errors.As(err, &ce) {
			pending = ce.err
			return nil
		}
		return err
	})
	if err != nil {
		return err
	}
	if pending != nil {
		return pending
	}
	return nil
}

// Resend issues a fresh code and link for an open flow. The old code stops
// working, and the attempt counter restarts with the new code.
func (s *Service) Resend(ctx context.Context, purpose, handle string, principal *Principal, c Client) (FlowStarted, error) {
	if err := s.limits.Hit(ctx, limitVerifyIP, c.IP); err != nil {
		return FlowStarted{}, err
	}
	var out FlowStarted
	err := s.runTx(ctx, func(tx pgx.Tx) error {
		f, err := s.loadFlow(ctx, tx, handle, purpose, true)
		if err != nil {
			return err
		}
		if purpose == PurposeEmailChange && (principal == nil || f.userID == nil || *f.userID != principal.UserID) {
			return apperr.NotFound("flow_not_found", "start again")
		}
		now := s.now()
		if f.completedAt != nil {
			return apperr.Conflict("flow_completed", "this flow is finished")
		}
		if !now.Before(f.expiresAt) {
			return apperr.New(http.StatusGone, "flow_expired", "start again")
		}
		// A decoy flow answers exactly like a real one but sends nothing.
		lastSent := f.lastSentAt
		if lastSent == nil {
			created := f.expiresAt.Add(-flowTTL)
			lastSent = &created
		}
		if next := lastSent.Add(resendCooldown); now.Before(next) {
			return apperr.RateLimited(next.Sub(now))
		}
		if f.sends >= maxSendsPerFlow || (f.codeHash == nil && f.sends+1 >= maxSendsPerFlow) {
			return apperr.New(http.StatusTooManyRequests, "resend_limit", "start again")
		}
		expires := now.Add(flowTTL)
		if f.codeHash == nil {
			if _, err := tx.Exec(ctx, `UPDATE auth_flows SET sends = sends + 1, last_sent_at = now(), expires_at = $2 WHERE id = $1`, f.id, expires); err != nil {
				return err
			}
		} else {
			code := secure.RandomDigits(CodeLength)
			link := secure.RandomToken(32)
			if _, err := tx.Exec(ctx, `
				UPDATE auth_flows SET code_hash = $2, link_hash = $3, attempts = 0, sends = sends + 1,
					last_sent_at = now(), expires_at = $4 WHERE id = $1`,
				f.id, s.hash("flow-code", f.id, code), s.hash("flow-link", f.id, link), expires); err != nil {
				return err
			}
			kind := map[string]string{PurposeRegister: mail.KindRegisterCode, PurposeReset: mail.KindResetCode, PurposeEmailChange: mail.KindEmailChangeCode}[purpose]
			if err := s.outbox.Enqueue(ctx, tx, kind, s.codeMail(purpose, f.locale, f.email, code, link), expires); err != nil {
				return err
			}
		}
		out = FlowStarted{FlowID: handle, ExpiresAt: expires, ResendAvailableAt: now.Add(resendCooldown)}
		return nil
	})
	if err != nil {
		return FlowStarted{}, err
	}
	s.outbox.Nudge()
	return out, nil
}

// ---- Registration -------------------------------------------------------

type RegisterInput struct {
	Email    string
	Password string
	Name     string
}

// Register starts email + password sign-up. The answer is the same whether
// or not the address already has an account; the owner of an existing
// account gets an email saying so instead of a code.
func (s *Service) Register(ctx context.Context, in RegisterInput, c Client) (FlowStarted, error) {
	email, err := NormalizeEmail(in.Email)
	if err != nil {
		return FlowStarted{}, err
	}
	name, err := NormalizeName(in.Name)
	if err != nil {
		return FlowStarted{}, err
	}
	if problem := password.Problem(in.Password, email); problem != "" {
		return FlowStarted{}, apperr.Unprocessable(problem, "choose a different password").With("field", "password")
	}
	if err := s.limits.Hit(ctx, limitRegisterIP, c.IP); err != nil {
		return FlowStarted{}, err
	}
	if err := s.limits.Hit(ctx, limitRegisterEmail, email); err != nil {
		return FlowStarted{}, err
	}
	// Hash before looking anything up, so both branches take the same time.
	pwHash, err := s.pw.Hash(ctx, in.Password)
	if err != nil {
		return FlowStarted{}, err
	}

	var out FlowStarted
	var existing string
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT user_id FROM user_emails WHERE email = $1 AND removed_at IS NULL`, email).Scan(&existing)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if existing != "" {
			_, _, _, started, err := s.newFlow(ctx, tx, PurposeRegister, email, nil, nil, nil, c.Locale, false)
			if err != nil {
				return err
			}
			out = started
			return s.outbox.Enqueue(ctx, tx, mail.KindRegisterExisting, mail.RegisterExisting(c.Locale, email), s.now().Add(flowTTL))
		}
		_, code, link, started, err := s.newFlow(ctx, tx, PurposeRegister, email, nil, &name, &pwHash, c.Locale, true)
		if err != nil {
			return err
		}
		out = started
		return s.outbox.Enqueue(ctx, tx, mail.KindRegisterCode, s.codeMail(PurposeRegister, c.Locale, email, code, link), started.ExpiresAt)
	})
	if err != nil {
		return FlowStarted{}, err
	}
	s.outbox.Nudge()
	if existing != "" {
		s.audit.Record(ctx, audit.RegisterExistingEmail, existing, c.IP, nil)
	} else {
		s.audit.Record(ctx, audit.RegisterStarted, "", c.IP, nil)
	}
	return out, nil
}

// VerifyRegistration checks the code or link and, on success, creates the
// account and signs the app in, so the app moves straight on without
// another tap.
func (s *Service) VerifyRegistration(ctx context.Context, handle string, p Proof, c Client) (SignedIn, error) {
	if err := p.validate(); err != nil {
		return SignedIn{}, err
	}
	if err := s.limits.Hit(ctx, limitVerifyIP, c.IP); err != nil {
		return SignedIn{}, err
	}
	var out SignedIn
	err := s.runTx(ctx, func(tx pgx.Tx) error {
		f, err := s.loadFlow(ctx, tx, handle, PurposeRegister, true)
		if err != nil {
			return err
		}
		done, err := s.checkProof(ctx, tx, f, p, c.IP)
		if err != nil {
			return err
		}
		if done {
			if f.userID == nil {
				return apperr.Conflict("flow_completed", "this flow is finished")
			}
			tokens, err := s.startSession(ctx, tx, *f.userID, c)
			out = SignedIn{Tokens: tokens, UserID: *f.userID}
			return err
		}
		if f.name == nil || f.passwordHash == nil {
			// Decoy flows have no code, so proofMatches never lets one here.
			return apperr.Conflict("flow_completed", "this flow is finished")
		}

		var userID string
		if err := tx.QueryRow(ctx, `INSERT INTO users (name) VALUES ($1) RETURNING id`, *f.name).Scan(&userID); err != nil {
			return err
		}
		// The unique index decides races: if the address was taken since the
		// flow began (another sign-up, or Google), this insert fails.
		if _, err := tx.Exec(ctx, `SAVEPOINT email_insert`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO user_emails (user_id, email, is_primary, verified_at) VALUES ($1, $2, true, now())`, userID, f.email); err != nil {
			if store.IsUniqueViolation(err, "") {
				if _, rbErr := tx.Exec(ctx, `ROLLBACK TO SAVEPOINT email_insert`); rbErr != nil {
					return rbErr
				}
				if _, err := tx.Exec(ctx, `UPDATE auth_flows SET completed_at = now() WHERE id = $1`, f.id); err != nil {
					return err
				}
				// Undo the orphan user row inside this same transaction.
				if _, err := tx.Exec(ctx, `DELETE FROM users WHERE id = $1`, userID); err != nil {
					return err
				}
				return &committedError{apperr.Conflict("email_already_registered", "sign in instead")}
			}
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO auth_identities (user_id, provider, password_hash) VALUES ($1, 'password', $2)`, userID, *f.passwordHash); err != nil {
			return err
		}
		// The held password hash is no longer needed on the flow.
		if _, err := tx.Exec(ctx, `UPDATE auth_flows SET verified_at = now(), completed_at = now(), user_id = $2, password_hash = NULL WHERE id = $1`, f.id, userID); err != nil {
			return err
		}
		// Other sign-ups started for this address can no longer finish.
		if _, err := tx.Exec(ctx, `UPDATE auth_flows SET expires_at = now() WHERE purpose = 'register' AND email = $1 AND id <> $2 AND completed_at IS NULL`, f.email, f.id); err != nil {
			return err
		}
		tokens, err := s.startSession(ctx, tx, userID, c)
		if err != nil {
			return err
		}
		out = SignedIn{Tokens: tokens, UserID: userID, NewAccount: true}
		return nil
	})
	if err != nil {
		return SignedIn{}, err
	}
	if out.NewAccount {
		s.audit.Record(ctx, audit.RegisterCompleted, out.UserID, c.IP, map[string]any{"via": proofKind(p)})
	}
	return out, nil
}

func proofKind(p Proof) string {
	if p.LinkToken != "" {
		return "link"
	}
	return "code"
}

// ---- Forgot password ----------------------------------------------------

// ForgotPassword starts a reset. It answers the same way for every address;
// only an address with an account receives a code.
func (s *Service) ForgotPassword(ctx context.Context, rawEmail string, c Client) (FlowStarted, error) {
	email, err := NormalizeEmail(rawEmail)
	if err != nil {
		return FlowStarted{}, err
	}
	if err := s.limits.Hit(ctx, limitForgotIP, c.IP); err != nil {
		return FlowStarted{}, err
	}
	if err := s.limits.Hit(ctx, limitForgotEmail, email); err != nil {
		return FlowStarted{}, err
	}
	var out FlowStarted
	var userID string
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			SELECT e.user_id FROM user_emails e JOIN users u ON u.id = e.user_id
			WHERE e.email = $1 AND e.removed_at IS NULL AND u.status = 'active'`, email).Scan(&userID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if userID == "" {
			_, _, _, started, err := s.newFlow(ctx, tx, PurposeReset, email, nil, nil, nil, c.Locale, false)
			out = started
			return err
		}
		_, code, link, started, err := s.newFlow(ctx, tx, PurposeReset, email, &userID, nil, nil, c.Locale, true)
		if err != nil {
			return err
		}
		out = started
		return s.outbox.Enqueue(ctx, tx, mail.KindResetCode, s.codeMail(PurposeReset, c.Locale, email, code, link), started.ExpiresAt)
	})
	if err != nil {
		return FlowStarted{}, err
	}
	s.outbox.Nudge()
	s.audit.Record(ctx, audit.PasswordResetRequested, userID, c.IP, map[string]any{"known": userID != ""})
	return out, nil
}

// ResetTicket authorises choosing a new password, once.
type ResetTicket struct {
	Ticket    string
	ExpiresAt time.Time
}

// VerifyReset checks the code or link and hands back a ticket, so the app
// can move straight to the new-password screen.
func (s *Service) VerifyReset(ctx context.Context, handle string, p Proof, c Client) (ResetTicket, error) {
	if err := p.validate(); err != nil {
		return ResetTicket{}, err
	}
	if err := s.limits.Hit(ctx, limitVerifyIP, c.IP); err != nil {
		return ResetTicket{}, err
	}
	var out ResetTicket
	err := s.runTx(ctx, func(tx pgx.Tx) error {
		f, err := s.loadFlow(ctx, tx, handle, PurposeReset, true)
		if err != nil {
			return err
		}
		done, err := s.checkProof(ctx, tx, f, p, c.IP)
		if err != nil {
			return err
		}
		if done || f.userID == nil {
			return apperr.Conflict("flow_completed", "this flow is finished")
		}
		// Verifying again (a retry) replaces the ticket; only the newest works.
		ticket := secure.RandomToken(32)
		expires := minTime(s.now().Add(resetTicketTTL), f.expiresAt.Add(resetTicketTTL))
		if _, err := tx.Exec(ctx, `UPDATE auth_flows SET verified_at = coalesce(verified_at, now()), ticket_hash = $2, ticket_expires_at = $3 WHERE id = $1`,
			f.id, s.hash("reset-ticket", ticket), expires); err != nil {
			return err
		}
		out = ResetTicket{Ticket: ticket, ExpiresAt: expires}
		return nil
	})
	return out, err
}

// ResetPassword sets the new password, ends every other session and signs
// this app in. A Google-only account gains a password this way, which is
// safe because the flow proved control of the address.
func (s *Service) ResetPassword(ctx context.Context, ticket, newPassword string, c Client) (SignedIn, error) {
	if err := s.limits.Hit(ctx, limitVerifyIP, c.IP); err != nil {
		return SignedIn{}, err
	}
	if len(ticket) < 20 || len(ticket) > 128 {
		return SignedIn{}, apperr.New(http.StatusGone, "ticket_expired", "start again")
	}
	var out SignedIn
	var email, locale string
	err := s.runTx(ctx, func(tx pgx.Tx) error {
		var flowID string
		var userID *string
		var ticketEnd *time.Time
		var completed *time.Time
		err := tx.QueryRow(ctx, `
			SELECT id, user_id, email, locale, ticket_expires_at, completed_at FROM auth_flows
			WHERE ticket_hash = $1 AND purpose = 'password_reset' FOR UPDATE`, s.hash("reset-ticket", ticket)).
			Scan(&flowID, &userID, &email, &locale, &ticketEnd, &completed)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.New(http.StatusGone, "ticket_expired", "start again")
		}
		if err != nil {
			return err
		}
		if completed != nil || userID == nil || ticketEnd == nil || !s.now().Before(*ticketEnd) {
			return apperr.New(http.StatusGone, "ticket_expired", "start again")
		}
		if problem := password.Problem(newPassword, email); problem != "" {
			return apperr.Unprocessable(problem, "choose a different password").With("field", "newPassword")
		}
		hash, err := s.pw.Hash(ctx, newPassword)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO auth_identities (user_id, provider, password_hash) VALUES ($1, 'password', $2)
			ON CONFLICT (user_id) WHERE provider = 'password' DO UPDATE SET password_hash = EXCLUDED.password_hash, updated_at = now()`,
			*userID, hash); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE auth_flows SET completed_at = now(), ticket_hash = NULL WHERE id = $1`, flowID); err != nil {
			return err
		}
		// Every other open reset for this account is void now.
		if _, err := tx.Exec(ctx, `UPDATE auth_flows SET expires_at = now(), ticket_hash = NULL WHERE purpose = 'password_reset' AND user_id = $1 AND id <> $2 AND completed_at IS NULL`, *userID, flowID); err != nil {
			return err
		}
		if err := revokeOthers(ctx, tx, *userID, "", "password_reset"); err != nil {
			return err
		}
		tokens, err := s.startSession(ctx, tx, *userID, c)
		if err != nil {
			return err
		}
		out = SignedIn{Tokens: tokens, UserID: *userID}
		return s.outbox.Enqueue(ctx, tx, mail.KindPasswordChanged, mail.PasswordChanged(locale, email), s.now().Add(24*time.Hour))
	})
	if err != nil {
		return SignedIn{}, err
	}
	s.outbox.Nudge()
	_ = s.limits.Reset(ctx, limitLoginEmail, email)
	s.audit.Record(ctx, audit.PasswordReset, out.UserID, c.IP, nil)
	return out, nil
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
