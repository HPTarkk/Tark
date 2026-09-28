// Package idempotency makes retried writes safe. A request carrying an
// Idempotency-Key is run once; repeating it with the same key and body
// replays the first successful answer, and the same key with a different
// body is refused. Failed answers are not stored, so a retry after a
// failure (for example Bazaar being down) runs again.
package idempotency

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/secure"
)

// Header is the request header carrying the key.
const Header = "Idempotency-Key"

var keyPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// ValidKey reports whether k is a UUID, the only accepted key format.
func ValidKey(k string) bool { return keyPattern.MatchString(k) }

type Store struct {
	pool   *pgxpool.Pool
	sealer *secure.Sealer
	lookup *secure.Hasher
	ttl    time.Duration
}

func New(pool *pgxpool.Pool, sealer *secure.Sealer, lookup *secure.Hasher, ttl time.Duration) *Store {
	return &Store{pool: pool, sealer: sealer, lookup: lookup, ttl: ttl}
}

// Outcome of Begin.
type Outcome int

const (
	Run      Outcome = iota // first time: run the handler, then Finish
	Replay                  // answered before: send Status and Body
	Mismatch                // same key, different request
	Busy                    // the first request is still running
)

type Begun struct {
	Outcome Outcome
	Status  int
	Body    []byte
}

// abandonAfter is when an in-progress record is assumed to belong to a
// request that died, so a retry may take it over.
const abandonAfter = 2 * time.Minute

// Begin records the key, or reports what happened to it before. The
// request fingerprint is a keyed hash, because request bodies can contain
// passwords.
func (s *Store) Begin(ctx context.Context, scope, key, method, path string, body []byte) (Begun, error) {
	fingerprint := s.lookup.Sum("idempotency", scope, method, path, string(body))
	tag, err := s.pool.Exec(ctx, `
		INSERT INTO idempotency_keys (scope, key, request_hash, state, expires_at)
		VALUES ($1, $2, $3, 'in_progress', $4)
		ON CONFLICT (scope, key) DO UPDATE SET request_hash = EXCLUDED.request_hash, created_at = now(), expires_at = EXCLUDED.expires_at
		WHERE idempotency_keys.state = 'in_progress' AND idempotency_keys.created_at < now() - $5::interval
			AND idempotency_keys.request_hash = EXCLUDED.request_hash`,
		scope, key, fingerprint, time.Now().Add(s.ttl), abandonAfter)
	if err != nil {
		return Begun{}, err
	}
	if tag.RowsAffected() == 1 {
		return Begun{Outcome: Run}, nil
	}
	var hash, sealed []byte
	var state string
	var status *int
	err = s.pool.QueryRow(ctx, `SELECT request_hash, state, status, body FROM idempotency_keys WHERE scope = $1 AND key = $2`,
		scope, key).Scan(&hash, &state, &status, &sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		// Deleted between the two statements (the first attempt failed).
		return s.Begin(ctx, scope, key, method, path, body)
	}
	if err != nil {
		return Begun{}, err
	}
	if !secure.Equal(hash, fingerprint) {
		return Begun{Outcome: Mismatch}, nil
	}
	if state != "done" || status == nil {
		return Begun{Outcome: Busy}, nil
	}
	plain, err := s.sealer.Open(sealed, []byte("idem:"+scope+":"+key))
	if err != nil {
		return Begun{}, err
	}
	return Begun{Outcome: Replay, Status: *status, Body: plain}, nil
}

// Finish stores a successful answer, or forgets the key after a failure.
func (s *Store) Finish(ctx context.Context, scope, key string, status int, body []byte) error {
	if status < 200 || status >= 300 {
		_, err := s.pool.Exec(ctx, `DELETE FROM idempotency_keys WHERE scope = $1 AND key = $2 AND state = 'in_progress'`, scope, key)
		return err
	}
	_, err := s.pool.Exec(ctx, `UPDATE idempotency_keys SET state = 'done', status = $3, body = $4 WHERE scope = $1 AND key = $2`,
		scope, key, status, s.sealer.Seal(body, []byte("idem:"+scope+":"+key)))
	return err
}

// Recorder captures a handler's answer so it can be stored.
type Recorder struct {
	http.ResponseWriter
	Status int
	Buf    bytes.Buffer
}

func (r *Recorder) WriteHeader(code int) {
	r.Status = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *Recorder) Write(b []byte) (int, error) {
	if r.Status == 0 {
		r.Status = http.StatusOK
	}
	r.Buf.Write(b)
	return r.ResponseWriter.Write(b)
}
