package backup

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/store"
)

func key(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }

func seal(t *testing.T, data []byte, k []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	w, err := newSealWriter(&buf, k)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func open(data []byte, k []byte) ([]byte, error) {
	r, err := newOpenReader(bytes.NewReader(data), k)
	if err != nil {
		return nil, err
	}
	return io.ReadAll(r)
}

func TestSealRoundTripsEverySize(t *testing.T) {
	for _, n := range []int{0, 1, chunkSize - 1, chunkSize, chunkSize + 1, 3*chunkSize + 7} {
		data := bytes.Repeat([]byte("tark"), n/4+1)[:n]
		got, err := open(seal(t, data, key(1)), key(1))
		if err != nil {
			t.Fatalf("size %d: %v", n, err)
		}
		if !bytes.Equal(got, data) {
			t.Fatalf("size %d: data differs", n)
		}
	}
}

func TestSealRejectsTamperingTruncationAndWrongKey(t *testing.T) {
	data := bytes.Repeat([]byte{7}, 2*chunkSize+100)
	sealed := seal(t, data, key(1))

	if _, err := open(sealed, key(2)); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("wrong key: %v", err)
	}
	flipped := bytes.Clone(sealed)
	flipped[len(flipped)/2] ^= 1
	if _, err := open(flipped, key(1)); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("flipped byte: %v", err)
	}
	// Cut exactly after the first frame: every remaining frame is whole, so
	// only the missing last flag can tell the file is short.
	firstFrame := len(magic) + saltSize + 5 + chunkSize + 16
	if _, err := open(sealed[:firstFrame], key(1)); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("cut after a frame: %v", err)
	}
	if _, err := open(sealed[:len(sealed)-1], key(1)); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("cut short: %v", err)
	}
	if _, err := open(append(bytes.Clone(sealed), 0), key(1)); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("trailing byte: %v", err)
	}
}

// Needs TARK_TEST_DATABASE_URL; the user must be allowed to create databases.
func testDB(t *testing.T) (*pgxpool.Pool, string) {
	t.Helper()
	url := os.Getenv("TARK_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TARK_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := store.Open(ctx, url, 6)
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
	return pool, url
}

// emptyDB creates a fresh database next to the test one and returns a pool on it.
func emptyDB(t *testing.T, pool *pgxpool.Pool, url string) *pgxpool.Pool {
	t.Helper()
	ctx := context.Background()
	const name = "tark_restore_test"
	if _, err := pool.Exec(ctx, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)"); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatal(err)
	}
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.Database = name
	target, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		target.Close()
		pool.Exec(context.Background(), "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)") //nolint:errcheck
	})
	return target
}

func seed(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	stmts := []string{
		`INSERT INTO users (id, name, avatar_id) VALUES
			('11111111-1111-1111-1111-111111111111', 'Pedi ✓', '13'),
			('22222222-2222-2222-2222-222222222222', 'Second', NULL)`,
		`INSERT INTO user_emails (user_id, email, is_primary, verified_at) VALUES
			('11111111-1111-1111-1111-111111111111', 'a@example.com', true, now())`,
		`INSERT INTO bazaar_purchases (user_id, token_hash, token_enc, sku, state, valid_until)
			VALUES ('11111111-1111-1111-1111-111111111111', '\x0102', '\xdeadbeef', 'tark_premium_1m', 'active', now() + interval '30 days')`,
		`INSERT INTO audit_events (kind, user_id, details) VALUES
			('login.succeeded', '11111111-1111-1111-1111-111111111111', '{"method":"password"}'),
			('login.failed', NULL, '{}')`,
	}
	for _, s := range stmts {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
}

func TestDumpRestoreRoundTrip(t *testing.T) {
	pool, url := testDB(t)
	seed(t, pool)
	ctx := context.Background()

	var buf bytes.Buffer
	sum, err := Dump(ctx, pool, &buf, key(9))
	if err != nil {
		t.Fatal(err)
	}
	if sum.Rows["users"] != 2 || sum.Rows["audit_events"] != 2 || sum.Rows["bazaar_purchases"] != 1 {
		t.Fatalf("rows = %v", sum.Rows)
	}
	if strings.Contains(buf.String(), "a@example.com") {
		t.Fatal("the backup holds an email address in the clear")
	}
	if _, err := Verify(bytes.NewReader(buf.Bytes()), key(9)); err != nil {
		t.Fatal(err)
	}
	if _, err := Verify(bytes.NewReader(buf.Bytes()), key(8)); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("wrong key verified: %v", err)
	}

	target := emptyDB(t, pool, url)
	got, err := Restore(ctx, target, bytes.NewReader(buf.Bytes()), key(9))
	if err != nil {
		t.Fatal(err)
	}
	if got.TotalRows() != sum.TotalRows() {
		t.Fatalf("restored %d rows, dumped %d", got.TotalRows(), sum.TotalRows())
	}

	var name, email, details string
	var tokenEnc []byte
	if err := target.QueryRow(ctx, `
		SELECT u.name, e.email, p.token_enc, (SELECT details::text FROM audit_events WHERE kind = 'login.succeeded')
		FROM users u JOIN user_emails e ON e.user_id = u.id JOIN bazaar_purchases p ON p.user_id = u.id`).
		Scan(&name, &email, &tokenEnc, &details); err != nil {
		t.Fatal(err)
	}
	if name != "Pedi ✓" || email != "a@example.com" || !bytes.Equal(tokenEnc, []byte{0xde, 0xad, 0xbe, 0xef}) ||
		details != `{"method": "password"}` {
		t.Fatalf("restored values differ: %q %q %x %q", name, email, tokenEnc, details)
	}
	// Identity sequences continue after the restored rows.
	var id int64
	if err := target.QueryRow(ctx, `INSERT INTO audit_events (kind) VALUES ('x') RETURNING id`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if id != 3 {
		t.Fatalf("next audit id = %d, want 3", id)
	}
	versions, err := pgx.CollectRows(must(target.Query(ctx, `SELECT version FROM schema_migrations ORDER BY version`)), pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(versions, ",") != strings.Join(store.Versions(), ",") {
		t.Fatalf("migrations after restore = %v", versions)
	}

	// A database with tables is never overwritten.
	if _, err := Restore(ctx, target, bytes.NewReader(buf.Bytes()), key(9)); err == nil {
		t.Fatal("restore into a non-empty database succeeded")
	}
}

func must(rows pgx.Rows, err error) pgx.Rows {
	if err != nil {
		panic(err)
	}
	return rows
}

func TestServiceBackupScheduleAndPrune(t *testing.T) {
	pool, _ := testDB(t)
	seed(t, pool)
	ctx := context.Background()
	dir := t.TempDir()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	s := NewService(pool, Settings{Dir: dir, Key: key(3), HourUTC: 23, KeepDays: 14}, log)
	now := time.Date(2026, 10, 2, 22, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }

	// Never backed up: due.
	if due, err := s.due(ctx); err != nil || !due {
		t.Fatalf("due = %v, %v; want true", due, err)
	}
	res, err := s.Backup(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if res.Summary.Rows["users"] != 2 {
		t.Fatalf("rows = %v", res.Summary.Rows)
	}
	info, err := os.Stat(filepath.Join(dir, res.File))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode().Perm())
	}
	// Backed up after yesterday's 23:00: not due until today's 23:00.
	if due, _ := s.due(ctx); due {
		t.Fatal("due right after a backup")
	}
	now = time.Date(2026, 10, 2, 23, 5, 0, 0, time.UTC)
	if due, _ := s.due(ctx); !due {
		t.Fatal("not due after the scheduled hour")
	}
	var ok bool
	var rows int64
	if err := pool.QueryRow(ctx, `SELECT ok, row_count FROM backup_runs ORDER BY id DESC LIMIT 1`).Scan(&ok, &rows); err != nil {
		t.Fatal(err)
	}
	if !ok || rows != res.Summary.TotalRows() {
		t.Fatalf("run = %v %d", ok, rows)
	}

	f, err := Open(dir, res.File)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	for _, bad := range []string{"../etc/passwd", "tark-1.tbk", ".partial-1"} {
		if _, err := Open(dir, bad); err == nil {
			t.Fatalf("Open(%q) succeeded", bad)
		}
	}

	// Pruning keeps the newest file even when everything is old.
	old := filepath.Join(dir, "tark-20260101-000000.tbk")
	if err := os.WriteFile(old, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	past := now.Add(-30 * 24 * time.Hour)
	os.Chtimes(old, past, past)                          //nolint:errcheck
	os.Chtimes(filepath.Join(dir, res.File), past, past) //nolint:errcheck
	if err := s.Prune(); err != nil {
		t.Fatal(err)
	}
	files, _ := List(dir)
	if len(files) != 1 || files[0].Name != res.File {
		t.Fatalf("after prune: %v", files)
	}

	// A failed attempt is recorded and not retried within the hour.
	s.set.Dir = filepath.Join(dir, "missing")
	if _, err := s.Backup(ctx); err == nil {
		t.Fatal("backup into a missing directory succeeded")
	}
	if err := pool.QueryRow(ctx, `SELECT ok FROM backup_runs ORDER BY id DESC LIMIT 1`).Scan(&ok); err != nil || ok {
		t.Fatalf("failed run recorded as ok=%v (%v)", ok, err)
	}
	if due, _ := s.due(ctx); due {
		t.Fatal("retried within the hour of a failure")
	}
	now = now.Add(61 * time.Minute)
	if due, _ := s.due(ctx); !due {
		t.Fatal("not retried an hour after a failure")
	}
}
