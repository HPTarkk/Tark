// Package billing verifies Cafe Bazaar subscriptions on the server and
// issues the signed entitlement the app checks offline.
//
// Rules this package keeps:
//   - Nothing the app says about dates or state is trusted; only Bazaar's
//     answer is.
//   - A purchase token belongs to one account (a unique index decides).
//   - Concurrent or repeated submissions of one token are serialised by a
//     row lock and give the same answer.
//   - A Bazaar outage never downgrades anyone: the last verified state is
//     served with bazaarChecked=false.
//   - Turning off auto-renew is never suspicious. Only a refund (revocation
//     before the paid period ends) puts an account in the conservative mode,
//     and one clean paid period afterwards takes it out again.
package billing

import (
	"context"
	"errors"
	"log/slog"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/audit"
	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
	"github.com/HPTarkk/Tark/backend/internal/secure"
)

const (
	// A stored state younger than this is served without asking Bazaar.
	freshFor = 6 * time.Hour
	// Two answers closer together than this for one purchase are wasteful.
	minRecheckGap = time.Minute
	// How long a subscription request may spend re-checking purchases with
	// Bazaar before answering from stored state.
	recheckBudget = 5 * time.Second
	// A token Bazaar used to know but now reports missing is only treated
	// as revoked after this many consecutive definitive answers, so one
	// inconsistent response cannot take anyone's subscription away.
	missingBeforeRevoked = 2
	// Definitive "not found" answers before a new token is called unknown.
	pendingMissingLimit = 3
	// Slack when comparing Bazaar's dates with ours.
	dateTolerance = 5 * time.Minute
	// Expired purchases are still re-checked occasionally for this long, in
	// case the same token renews late.
	expiredWatch = 30 * 24 * time.Hour
)

var (
	limitSubscriptionGet = ratelimit.Rule{Name: "subscription_get", Max: 60, Window: 10 * time.Minute}
	limitPurchasePost    = ratelimit.Rule{Name: "purchase_post", Max: 20, Window: 10 * time.Minute}
)

type Service struct {
	pool   *pgxpool.Pool
	bazaar Bazaar
	signer *Signer
	sealer *secure.Sealer
	lookup *secure.Hasher
	limits ratelimit.Limiter
	audit  *audit.Logger
	policy Policy
	plans  []Plan
	log    *slog.Logger
	now    func() time.Time
}

func NewService(pool *pgxpool.Pool, bz Bazaar, signer *Signer, sealer *secure.Sealer, lookup *secure.Hasher,
	limits ratelimit.Limiter, aud *audit.Logger, policy Policy, plans []Plan, log *slog.Logger) *Service {
	return &Service{pool: pool, bazaar: bz, signer: signer, sealer: sealer, lookup: lookup, limits: limits,
		audit: aud, policy: policy, plans: plans, log: log, now: time.Now}
}

// Plans lists the plans on sale, in the order to show them.
func (s *Service) Plans() []Plan { return slices.Clone(s.plans) }

func (s *Service) sells(sku string) bool {
	return slices.ContainsFunc(s.plans, func(p Plan) bool { return p.SKU == sku })
}

// Result is SubscriptionResponse.
type Result struct {
	Entitlement string
	// SKU is the product the entitlement is about ("" when none), so the
	// response can name the plan in the caller's language.
	SKU           string
	BazaarChecked bool
}

type purchase struct {
	id           string
	userID       string
	tokenEnc     []byte
	sku          string
	state        string
	initiatedAt  *time.Time
	validUntil   *time.Time
	autoRenewing bool
	refundedAt   *time.Time
	missing      int
	failures     int
	lastChecked  *time.Time
}

const purchaseColumns = `id, user_id, token_enc, sku, state, initiated_at, valid_until, auto_renewing, refunded_at,
	missing_count, check_failures, last_checked_at`

func scanPurchase(row pgx.Row) (*purchase, error) {
	var p purchase
	err := row.Scan(&p.id, &p.userID, &p.tokenEnc, &p.sku, &p.state, &p.initiatedAt, &p.validUntil, &p.autoRenewing,
		&p.refundedAt, &p.missing, &p.failures, &p.lastChecked)
	return &p, err
}

// Get returns the caller's entitlement, re-checking Bazaar first for any
// purchase whose stored state is stale. fresh asks for running purchases to
// be re-checked however recent the last answer is (the subscription page
// does this, so a renewal turned off in Bazaar shows at once); minRecheckGap
// still applies.
func (s *Service) Get(ctx context.Context, userID, installKey, ip string, fresh bool) (Result, error) {
	if err := s.limits.Hit(ctx, limitSubscriptionGet, userID); err != nil {
		return Result{}, err
	}
	now := s.now()
	staleBefore := now.Add(-freshFor)
	if fresh {
		staleBefore = now
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id FROM bazaar_purchases
		WHERE user_id = $1 AND (
			state = 'pending'
			OR (state = 'active' AND (last_checked_at IS NULL OR last_checked_at < $2 OR valid_until <= $3))
			OR (state = 'expired' AND valid_until > $3 - $4::interval AND (last_checked_at IS NULL OR last_checked_at < $3 - interval '24 hours')))
		AND (last_checked_at IS NULL OR last_checked_at < $3 - $5::interval)`,
		userID, staleBefore, now, expiredWatch, minRecheckGap)
	if err != nil {
		return Result{}, err
	}
	var stale []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return Result{}, err
		}
		stale = append(stale, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return Result{}, err
	}

	// Each question can take up to 8 s while Bazaar is slow. Past the budget
	// the rest are left to the worker and the answer goes out from what is
	// stored, marked unchecked, so one account's backlog never holds a
	// request (and its connection) for a long run of Bazaar timeouts.
	checked := true
	budgetEnd := s.now().Add(recheckBudget)
	for _, id := range stale {
		if !s.now().Before(budgetEnd) {
			checked = false
			break
		}
		ok, err := s.recheck(ctx, id, ip)
		if err != nil {
			return Result{}, err
		}
		checked = checked && ok
	}
	token, sku, err := s.issue(ctx, s.pool, userID, installKey)
	if err != nil {
		return Result{}, err
	}
	return Result{Entitlement: token, SKU: sku, BazaarChecked: checked}, nil
}

// Submit binds a purchase token to the caller and verifies it with Bazaar.
func (s *Service) Submit(ctx context.Context, userID, installKey, sku, purchaseToken, ip string) (Result, error) {
	// Any plan id is accepted, not only the ones on sale: a plan taken off
	// sale still has subscribers whose renewals and restores must verify.
	// Bazaar itself refuses an id that was never created in the panel.
	// The 5-minute test plan is the exception: only a server that sells it
	// accepts it, so a test purchase never unlocks premium in production.
	p, ok := ParsePlan(sku)
	if !ok || (p.IsTest() && !s.sells(sku)) {
		return Result{}, apperr.Validation("sku", "unknown product")
	}
	if purchaseToken == "" || len(purchaseToken) > 512 {
		return Result{}, apperr.Validation("purchaseToken", "missing or too long")
	}
	if err := s.limits.Hit(ctx, limitPurchasePost, userID); err != nil {
		return Result{}, err
	}
	tokenHash := s.lookup.Sum("bazaar-token", purchaseToken)

	// Recorded on its own, before talking to Bazaar, so that if Bazaar is
	// down the purchase is still known and the background worker verifies
	// it even if the app never retries. The unique token_hash settles which
	// account a token belongs to, even when two accounts submit it at once.
	id := secure.NewUUID()
	enc := s.sealer.Seal([]byte(purchaseToken), []byte("bazaar:"+id))
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO bazaar_purchases (id, user_id, token_hash, token_enc, sku, state, next_check_at)
		VALUES ($1, $2, $3, $4, $5, 'pending', now() + interval '1 minute')
		ON CONFLICT (token_hash) DO NOTHING`, id, userID, tokenHash, enc, sku); err != nil {
		return Result{}, err
	}

	// Bazaar is asked before the transaction and its row lock begin: the call
	// can take seconds, and a connection held that long starves the pool when
	// Bazaar is slow. Whatever the answer, it is applied under the lock below.
	var info Subscription
	var askErr error
	asked := false
	if peek, err := scanPurchase(s.pool.QueryRow(ctx, `SELECT `+purchaseColumns+` FROM bazaar_purchases WHERE token_hash = $1`, tokenHash)); err != nil {
		return Result{}, err
	} else if peek.userID == userID && peek.sku == sku && peek.state != "invalid" && s.needsCheck(peek) {
		info, askErr = s.ask(ctx, sku, purchaseToken)
		asked = true
	}

	var result Result
	var notYet bool
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		p, err := scanPurchase(tx.QueryRow(ctx, `SELECT `+purchaseColumns+` FROM bazaar_purchases WHERE token_hash = $1 FOR UPDATE`, tokenHash))
		if err != nil {
			return err
		}
		if p.userID != userID {
			s.audit.Record(ctx, audit.PurchaseOwnedElsewhere, userID, ip, nil)
			return apperr.Conflict("purchase_owned_elsewhere", "this purchase belongs to another account")
		}
		if p.sku != sku {
			return apperr.Unprocessable("purchase_invalid", "the purchase is for a different product")
		}
		if p.state == "invalid" {
			return apperr.Unprocessable("purchase_invalid", "Bazaar does not recognise this purchase")
		}
		// Not stale any more means another request recorded an answer while
		// this one waited for the lock: that answer is just as good.
		if s.needsCheck(p) {
			ok := false
			if asked {
				if ok, err = s.record(ctx, tx, p, info, askErr, ip); err != nil {
					return err
				}
			}
			if ok && p.state == "pending" {
				// Bazaar doesn't know it yet; the attempt is committed and the
				// worker keeps looking.
				notYet = true
				return nil
			}
			if !ok {
				if p.state == "pending" {
					return apperr.Unavailable("bazaar_unavailable", "could not reach Cafe Bazaar; retry with the same Idempotency-Key", 30*time.Second)
				}
				result.BazaarChecked = false
			} else {
				result.BazaarChecked = true
			}
		} else {
			result.BazaarChecked = true
		}
		if p.state == "invalid" {
			// Commit the invalid state, then report it.
			return nil
		}
		token, sku, err := s.issue(ctx, tx, userID, installKey)
		result.Entitlement, result.SKU = token, sku
		return err
	})
	if err != nil {
		return Result{}, err
	}
	if notYet {
		return Result{}, apperr.Unavailable("purchase_not_found_yet", "Bazaar does not show this purchase yet; retry with the same Idempotency-Key", 10*time.Second)
	}
	if result.Entitlement == "" {
		s.audit.Record(ctx, audit.PurchaseInvalid, userID, ip, nil)
		return Result{}, apperr.Unprocessable("purchase_invalid", "Bazaar does not recognise this purchase")
	}
	return result, nil
}

// needsCheck says whether a stored purchase is due for a Bazaar answer.
func (s *Service) needsCheck(p *purchase) bool {
	return p.state == "pending" || p.lastChecked == nil || s.now().Sub(*p.lastChecked) >= minRecheckGap
}

// ask puts one question to Bazaar. Call it without holding a database
// connection or a row lock.
func (s *Service) ask(ctx context.Context, sku, token string) (Subscription, error) {
	callCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	return s.bazaar.Subscription(callCtx, sku, token)
}

// CompSKU marks an entitlement that comes from premium given in the admin
// panel rather than from a Bazaar purchase.
const CompSKU = "comp"

// RecheckNow asks Bazaar about one purchase immediately (the admin panel's
// "check with Bazaar now"). It reports whether Bazaar answered.
func (s *Service) RecheckNow(ctx context.Context, purchaseID string) (bool, error) {
	return s.recheck(ctx, purchaseID, "")
}

// recheck asks Bazaar about one purchase, then records the answer.
func (s *Service) recheck(ctx context.Context, id, ip string) (bool, error) {
	p, err := scanPurchase(s.pool.QueryRow(ctx, `SELECT `+purchaseColumns+` FROM bazaar_purchases WHERE id = $1`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return true, nil // the account was deleted meanwhile
	}
	if err != nil {
		return false, err
	}
	if !s.needsCheck(p) {
		return true, nil
	}
	token, err := s.sealer.Open(p.tokenEnc, []byte("bazaar:"+p.id))
	if err != nil {
		s.log.ErrorContext(ctx, "purchase token could not be decrypted", "purchase", p.id)
		return false, nil
	}
	info, askErr := s.ask(ctx, p.sku, string(token))
	return s.apply(ctx, p.id, info, askErr, ip)
}

// apply locks a purchase and records an answer that was fetched without the
// lock. If someone else recorded one in the meantime, theirs stands.
func (s *Service) apply(ctx context.Context, id string, info Subscription, askErr error, ip string) (bool, error) {
	var ok bool
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		p, err := scanPurchase(tx.QueryRow(ctx, `SELECT `+purchaseColumns+` FROM bazaar_purchases WHERE id = $1 FOR UPDATE`, id))
		if errors.Is(err, pgx.ErrNoRows) {
			ok = true
			return nil
		}
		if err != nil {
			return err
		}
		if !s.needsCheck(p) {
			ok = true
			return nil
		}
		ok, err = s.record(ctx, tx, p, info, askErr, ip)
		return err
	})
	return ok, err
}

// record applies Bazaar's answer, or its failure, to a locked purchase. It
// returns false when Bazaar gave no usable answer.
func (s *Service) record(ctx context.Context, tx pgx.Tx, p *purchase, info Subscription, askErr error, ip string) (bool, error) {
	now := s.now()

	switch {
	case errors.Is(askErr, ErrNotFound):
		return true, s.applyMissing(ctx, tx, p, now, ip)
	case askErr != nil:
		p.failures++
		backoff := min(time.Duration(1<<min(p.failures, 8))*time.Minute, 6*time.Hour)
		_, dbErr := tx.Exec(ctx, `UPDATE bazaar_purchases SET check_failures = check_failures + 1, next_check_at = $2, updated_at = now() WHERE id = $1`,
			p.id, now.Add(backoff))
		s.log.WarnContext(ctx, "bazaar check failed", "purchase", p.id, "err", askErr)
		return false, dbErr
	}
	return true, s.applyAnswer(ctx, tx, p, info, now, ip)
}

func (s *Service) applyMissing(ctx context.Context, tx pgx.Tx, p *purchase, now time.Time, ip string) error {
	if p.state == "pending" {
		// A purchase moments old may not be visible yet. Look again a few
		// times before calling the token unknown.
		p.missing++
		if p.missing < pendingMissingLimit {
			_, err := tx.Exec(ctx, `UPDATE bazaar_purchases SET missing_count = $2, last_checked_at = now(), next_check_at = now() + interval '1 minute', updated_at = now() WHERE id = $1`, p.id, p.missing)
			return err
		}
	}
	if p.state == "pending" || p.state == "invalid" {
		p.state = "invalid"
		_, err := tx.Exec(ctx, `UPDATE bazaar_purchases SET state = 'invalid', last_checked_at = now(), next_check_at = NULL, updated_at = now() WHERE id = $1`, p.id)
		return err
	}
	p.missing++
	if p.state == "active" && p.missing >= missingBeforeRevoked && p.validUntil != nil && now.Before(*p.validUntil) {
		return s.markRefunded(ctx, tx, p, now, ip, "token_revoked")
	}
	next := now.Add(time.Hour)
	state := p.state
	if p.missing >= missingBeforeRevoked && (p.validUntil == nil || !now.Before(*p.validUntil)) {
		// Gone after its period ended: nothing was taken back early.
		state, next = "expired", time.Time{}
	}
	p.state = state
	_, err := tx.Exec(ctx, `
		UPDATE bazaar_purchases SET missing_count = $2, state = $3, last_checked_at = now(), check_failures = 0,
			next_check_at = $4, updated_at = now() WHERE id = $1`, p.id, p.missing, state, nullTime(next))
	if err != nil {
		return err
	}
	return s.settleAccount(ctx, tx, p.userID, now)
}

func (s *Service) applyAnswer(ctx context.Context, tx pgx.Tx, p *purchase, info Subscription, now time.Time, ip string) error {
	// A period that Bazaar now reports as ending well before what it told us
	// earlier, and that has already ended, was cut short: a refund.
	if p.state == "active" && p.validUntil != nil && now.Before(*p.validUntil) &&
		info.ValidUntil.Before(p.validUntil.Add(-dateTolerance)) && !now.Before(info.ValidUntil) {
		return s.markRefunded(ctx, tx, p, now, ip, "period_shortened")
	}
	if p.state == "refunded" {
		// Refunds are final for a token; a later purchase is a new token.
		_, err := tx.Exec(ctx, `UPDATE bazaar_purchases SET last_checked_at = now(), next_check_at = NULL WHERE id = $1`, p.id)
		return err
	}

	grace := time.Duration(s.policy.GraceH) * time.Hour
	state := "active"
	var next time.Time
	switch {
	case now.Before(info.ValidUntil):
		// Mid-period checks catch refunds; one just after the end picks up
		// the renewal.
		next = minTime(now.Add(72*time.Hour), info.ValidUntil.Add(time.Hour))
	case info.AutoRenewing && now.Before(info.ValidUntil.Add(grace)):
		// The renewal is probably on its way; stay active through the grace
		// period and look again soon.
		next = now.Add(6 * time.Hour)
	default:
		state = "expired"
		if now.Before(info.ValidUntil.Add(expiredWatch)) {
			next = now.Add(72 * time.Hour)
		}
	}
	wasPending := p.state == "pending"
	p.state = state
	_, err := tx.Exec(ctx, `
		UPDATE bazaar_purchases SET state = $2, initiated_at = $3, valid_until = $4, auto_renewing = $5,
			missing_count = 0, check_failures = 0, last_checked_at = now(), last_verified_at = now(),
			next_check_at = $6, updated_at = now()
		WHERE id = $1`, p.id, state, info.InitiatedAt, info.ValidUntil, info.AutoRenewing, nullTime(next))
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO subscription_accounts (user_id, last_verified_at) VALUES ($1, now())
		ON CONFLICT (user_id) DO UPDATE SET last_verified_at = now(), updated_at = now()`, p.userID); err != nil {
		return err
	}
	if wasPending {
		if err := event(ctx, tx, p.userID, p.id, "verified", map[string]any{"sku": p.sku, "state": state}); err != nil {
			return err
		}
		s.audit.Record(ctx, audit.PurchaseVerified, p.userID, ip, map[string]any{"sku": p.sku})
	} else if p.validUntil != nil && info.ValidUntil.After(p.validUntil.Add(dateTolerance)) {
		if err := event(ctx, tx, p.userID, p.id, "renewed", nil); err != nil {
			return err
		}
	}
	if p.autoRenewing != info.AutoRenewing {
		kind := "auto_renew_on"
		if !info.AutoRenewing {
			kind = "auto_renew_off" // an ordinary choice, never suspicious
		}
		if err := event(ctx, tx, p.userID, p.id, kind, nil); err != nil {
			return err
		}
	}
	return s.settleAccount(ctx, tx, p.userID, now)
}

func (s *Service) markRefunded(ctx context.Context, tx pgx.Tx, p *purchase, now time.Time, ip, reason string) error {
	p.state = "refunded"
	if _, err := tx.Exec(ctx, `
		UPDATE bazaar_purchases SET state = 'refunded', refunded_at = $2, last_checked_at = now(), next_check_at = NULL,
			updated_at = now() WHERE id = $1`, p.id, now); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO subscription_accounts (user_id, suspicious_since) VALUES ($1, $2)
		ON CONFLICT (user_id) DO UPDATE SET suspicious_since = $2, updated_at = now()`, p.userID, now); err != nil {
		return err
	}
	if err := event(ctx, tx, p.userID, p.id, "refunded", map[string]any{"reason": reason}); err != nil {
		return err
	}
	s.audit.Record(ctx, audit.PurchaseRefunded, p.userID, ip, map[string]any{"reason": reason})
	return nil
}

// settleAccount lifts the conservative mode after one clean paid period
// that began after the refund.
func (s *Service) settleAccount(ctx context.Context, tx pgx.Tx, userID string, now time.Time) error {
	tag, err := tx.Exec(ctx, `
		UPDATE subscription_accounts a SET suspicious_since = NULL, updated_at = now()
		WHERE a.user_id = $1 AND a.suspicious_since IS NOT NULL AND EXISTS (
			SELECT 1 FROM bazaar_purchases p
			WHERE p.user_id = a.user_id AND p.state IN ('active', 'expired')
			AND p.initiated_at > a.suspicious_since AND p.valid_until <= $2)`, userID, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() > 0 {
		return event(ctx, tx, userID, "", "suspicious_cleared", nil)
	}
	return nil
}

type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// issue signs the account's current standing for installKey.
func (s *Service) issue(ctx context.Context, q querier, userID, installKey string) (token, sku string, err error) {
	payload, err := s.entitlement(ctx, q, userID, installKey)
	if err != nil {
		return "", "", err
	}
	token, err = s.signer.Sign(payload)
	if payload.SKU != nil {
		sku = *payload.SKU
	}
	return token, sku, err
}

func (s *Service) entitlement(ctx context.Context, q querier, userID, installKey string) (Payload, error) {
	now := s.now()
	var suspicious bool
	err := q.QueryRow(ctx, `SELECT suspicious_since IS NOT NULL FROM subscription_accounts WHERE user_id = $1`, userID).Scan(&suspicious)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return Payload{}, err
	}

	payload := Payload{Sub: userID, IK: installKey, St: "none", Sus: suspicious, Iat: now.UnixMilli(), Pol: s.policy}

	// The purchase that decides the answer: a running period beats anything
	// else (latest end first); otherwise the most recent one that ended.
	var state, sku string
	var until *time.Time
	var ar bool
	var refundedAt *time.Time
	err = q.QueryRow(ctx, `
		SELECT state, sku, valid_until, auto_renewing, refunded_at FROM bazaar_purchases
		WHERE user_id = $1 AND state IN ('active', 'expired', 'refunded') AND valid_until IS NOT NULL
		ORDER BY (state = 'active') DESC, coalesce(refunded_at, valid_until) DESC
		LIMIT 1`, userID).Scan(&state, &sku, &until, &ar, &refundedAt)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return Payload{}, err
	}
	if err == nil {
		payload.St = state
		payload.SKU = &sku
		end := until
		if state == "refunded" && refundedAt != nil {
			end = refundedAt
		}
		ms := end.UnixMilli()
		payload.Until = &ms
		payload.AR = ar && state == "active"
	}

	// Premium given from the admin panel counts when it runs longer than any
	// paid period (or there is none). It never renews by itself.
	var grantEnd *time.Time
	if err := q.QueryRow(ctx, `
		SELECT max(ends_at) FROM premium_grants
		WHERE user_id = $1 AND revoked_at IS NULL AND starts_at <= $2 AND ends_at > $2`, userID, now).Scan(&grantEnd); err != nil {
		return Payload{}, err
	}
	if grantEnd != nil && (payload.St != "active" || payload.Until == nil || grantEnd.UnixMilli() > *payload.Until) {
		ms := grantEnd.UnixMilli()
		compSKU := CompSKU
		payload.St, payload.SKU, payload.Until, payload.AR = "active", &compSKU, &ms, false
	}
	return payload, nil
}

func event(ctx context.Context, tx pgx.Tx, userID, purchaseID, kind string, details map[string]any) error {
	if details == nil {
		details = map[string]any{}
	}
	var pid *string
	if purchaseID != "" {
		pid = &purchaseID
	}
	_, err := tx.Exec(ctx, `INSERT INTO subscription_events (user_id, purchase_id, kind, details) VALUES ($1, $2, $3, $4)`,
		userID, pid, kind, details)
	return err
}

// RunWorker re-checks due purchases in the background, so refunds and
// renewals are noticed even for people who never open the app. Safe on
// several instances: purchases are claimed with SKIP LOCKED.
func (s *Service) RunWorker(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		for {
			n, err := s.workBatch(ctx)
			if err != nil {
				s.log.ErrorContext(ctx, "billing worker batch failed", "err", err)
				break
			}
			if n == 0 {
				break
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *Service) workBatch(ctx context.Context) (int, error) {
	n := 0
	for range 20 {
		c, err := s.claim(ctx)
		if err != nil {
			return n, err
		}
		if c == nil {
			break
		}
		n++
		if c.token == "" {
			continue // could not be decrypted; already parked
		}
		info, askErr := s.ask(ctx, c.sku, c.token)
		if _, err := s.apply(ctx, c.id, info, askErr, ""); err != nil {
			return n, err
		}
	}
	return n, nil
}

type claim struct {
	id, sku, token string
}

// claim leases the most overdue purchase: next_check_at moves two minutes
// ahead, so no other instance takes it meanwhile and a worker that dies
// before recording an answer only delays that purchase. The lease ends the
// transaction before Bazaar is asked, so no connection or lock is held
// during the call.
func (s *Service) claim(ctx context.Context) (*claim, error) {
	var out *claim
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		p, err := scanPurchase(tx.QueryRow(ctx, `SELECT `+purchaseColumns+` FROM bazaar_purchases
			WHERE next_check_at IS NOT NULL AND next_check_at <= now() ORDER BY next_check_at LIMIT 1 FOR UPDATE SKIP LOCKED`))
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		token, err := s.sealer.Open(p.tokenEnc, []byte("bazaar:"+p.id))
		if err != nil {
			s.log.ErrorContext(ctx, "purchase token could not be decrypted; background checks stopped", "purchase", p.id)
			out = &claim{id: p.id}
			_, err := tx.Exec(ctx, `UPDATE bazaar_purchases SET next_check_at = NULL WHERE id = $1`, p.id)
			return err
		}
		out = &claim{id: p.id, sku: p.sku, token: string(token)}
		_, err = tx.Exec(ctx, `UPDATE bazaar_purchases SET next_check_at = now() + interval '2 minutes' WHERE id = $1`, p.id)
		return err
	})
	return out, err
}

func nullTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}
