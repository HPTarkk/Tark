package store_test

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/store"
)

// Needs TARK_TEST_DATABASE_URL (the test wipes its public schema).
func open(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TARK_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TARK_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := store.Open(ctx, url, 4)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return pool
}

// Every foreign key column must have an index that serves "rows referencing
// this parent", or deleting a parent scans the whole child table.
func TestEveryForeignKeyIsIndexed(t *testing.T) {
	pool := open(t)
	rows, err := pool.Query(context.Background(), `
		SELECT c.conrelid::regclass::text, a.attname
		FROM pg_constraint c
		JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
		WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
		AND NOT EXISTS (
			SELECT 1 FROM pg_index i
			WHERE i.indrelid = c.conrelid AND i.indkey[0] = c.conkey[1]
			-- A partial index only counts when its predicate is just "not null"
			-- (a foreign key lookup never matches NULL anyway).
			AND (i.indpred IS NULL OR pg_get_expr(i.indpred, i.indrelid) ILIKE '%IS NOT NULL%'))`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var table, col string
		if err := rows.Scan(&table, &col); err != nil {
			t.Fatal(err)
		}
		t.Errorf("foreign key %s.%s has no usable index", table, col)
	}
}

func TestSweepClearsMoreThanOneBatch(t *testing.T) {
	pool := open(t)
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `
		INSERT INTO users (name) VALUES ('u');
		INSERT INTO sessions (user_id, expires_at) SELECT id, now() + interval '1 day' FROM users;
		INSERT INTO refresh_tokens (session_id, token_hash, expires_at)
			SELECT s.id, sha256((g::text || s.id::text)::bytea), now() - interval '2 days'
			FROM sessions s, generate_series(1, 12000) g;
		-- a rotation chain: every token but the first points at its predecessor
		UPDATE refresh_tokens c SET parent_id = p.id FROM refresh_tokens p
			WHERE p.token_hash = sha256(((SELECT 1)::text || c.session_id::text)::bytea) AND p.id <> c.id AND c.id > p.id;
		INSERT INTO google_nonces (nonce_hash, expires_at) VALUES ('\x01', now() + interval '1 hour')`); err != nil {
		t.Fatal(err)
	}
	err := store.Sweep(ctx, pool,
		store.SweepRule{Table: "refresh_tokens", Where: `expires_at < now() - interval '1 day'`},
		store.SweepRule{Table: "google_nonces", Where: `expires_at < now()`})
	if err != nil {
		t.Fatal(err)
	}
	var left, nonces int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM refresh_tokens), (SELECT count(*) FROM google_nonces)`).Scan(&left, &nonces); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Errorf("%d expired refresh tokens left", left)
	}
	if nonces != 1 {
		t.Error("a live row must survive the sweep")
	}
}

func TestSweepKeepsGoingAfterAFailingRule(t *testing.T) {
	pool := open(t)
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `INSERT INTO google_nonces (nonce_hash, expires_at) VALUES ('\x02', now() - interval '1 hour')`); err != nil {
		t.Fatal(err)
	}
	err := store.Sweep(ctx, pool,
		store.SweepRule{Table: "no_such_table", Where: `true`},
		store.SweepRule{Table: "google_nonces", Where: `expires_at < now()`})
	if err == nil {
		t.Fatal("the failing rule must be reported")
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM google_nonces`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("later rules must still run: n=%d err=%v", n, err)
	}
}
