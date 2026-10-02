// Package ratelimit counts attempts in fixed windows.
//
// Counters live in PostgreSQL so every API instance shares them. The
// interface is small on purpose: moving to Redis later is one new
// implementation, not a change to callers.
package ratelimit

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

// Rule is one limit: at most Max hits per Window.
type Rule struct {
	Name   string
	Max    int
	Window time.Duration
}

type Limiter interface {
	// Hit counts one attempt against rule for subject and returns a
	// rate_limited error when the limit is exceeded.
	Hit(ctx context.Context, rule Rule, subject string) error
	// Peek reports whether subject is currently over the limit without
	// counting an attempt.
	Peek(ctx context.Context, rule Rule, subject string) error
	// Reset clears the counter, for example after a successful login.
	Reset(ctx context.Context, rule Rule, subject string) error
	// Refund gives one counted attempt back, for an attempt that turned out
	// not to be a failure.
	Refund(ctx context.Context, rule Rule, subject string) error
}

type PG struct {
	db     store.Querier
	hasher *secure.Hasher
	now    func() time.Time
}

func NewPG(db store.Querier, hasher *secure.Hasher) *PG {
	return &PG{db: db, hasher: hasher, now: time.Now}
}

func (l *PG) key(rule Rule, subject string) string {
	// Subjects are IPs, emails and account ids. Hashing keeps them out of
	// the table.
	return rule.Name + ":" + l.hasher.SumString("ratelimit", rule.Name, subject)
}

func (l *PG) Hit(ctx context.Context, rule Rule, subject string) error {
	now := l.now().UTC()
	var hits int
	var windowStart time.Time
	err := l.db.QueryRow(ctx, `
		INSERT INTO rate_limits (key, window_start, hits) VALUES ($1, $2, 1)
		ON CONFLICT (key) DO UPDATE SET
			hits = CASE WHEN rate_limits.window_start <= $2 - $3::interval THEN 1 ELSE rate_limits.hits + 1 END,
			window_start = CASE WHEN rate_limits.window_start <= $2 - $3::interval THEN $2 ELSE rate_limits.window_start END
		RETURNING hits, window_start`,
		l.key(rule, subject), now, rule.Window).Scan(&hits, &windowStart)
	if err != nil {
		return err
	}
	if hits > rule.Max {
		return apperr.RateLimited(retryAfter(windowStart, rule.Window, now))
	}
	return nil
}

func (l *PG) Peek(ctx context.Context, rule Rule, subject string) error {
	now := l.now().UTC()
	var hits int
	var windowStart time.Time
	err := l.db.QueryRow(ctx, `SELECT hits, window_start FROM rate_limits WHERE key = $1`,
		l.key(rule, subject)).Scan(&hits, &windowStart)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if windowStart.Add(rule.Window).After(now) && hits >= rule.Max {
		return apperr.RateLimited(retryAfter(windowStart, rule.Window, now))
	}
	return nil
}

func (l *PG) Reset(ctx context.Context, rule Rule, subject string) error {
	_, err := l.db.Exec(ctx, `DELETE FROM rate_limits WHERE key = $1`, l.key(rule, subject))
	return err
}

func (l *PG) Refund(ctx context.Context, rule Rule, subject string) error {
	_, err := l.db.Exec(ctx, `UPDATE rate_limits SET hits = greatest(hits - 1, 0) WHERE key = $1`, l.key(rule, subject))
	return err
}

func retryAfter(windowStart time.Time, window time.Duration, now time.Time) time.Duration {
	d := windowStart.Add(window).Sub(now)
	if d < time.Second {
		d = time.Second
	}
	return d
}

// Sweep deletes counters whose window ended long ago.
func Sweep(ctx context.Context, db store.Querier, olderThan time.Duration) error {
	return store.Sweep(ctx, db, store.SweepRule{
		Table: "rate_limits", Where: `window_start < now() - $1::interval`, Args: []any{olderThan}})
}
