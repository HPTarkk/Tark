package monitor

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

type fakeMailer struct {
	sent   []mail.Message
	nudges int
}

func (f *fakeMailer) Enqueue(_ context.Context, _ store.Querier, _ string, m mail.Message, _ time.Time) error {
	f.sent = append(f.sent, m)
	return nil
}

func (f *fakeMailer) Nudge() { f.nudges++ }

func (f *fakeMailer) take() []mail.Message {
	out := f.sent
	f.sent = nil
	return out
}

// Needs TARK_TEST_DATABASE_URL (the test wipes its public schema).
func setup(t *testing.T, set Settings) (*Monitor, *fakeMailer, *Counter, *pgxpool.Pool, *time.Time) {
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
	fm := &fakeMailer{}
	c := &Counter{}
	now := time.Now()
	m := New(pool, fm, c, set, slog.New(slog.NewTextHandler(io.Discard, nil)))
	m.now = func() time.Time { return now }
	m.started = now
	return m, fm, c, pool, &now
}

func exec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func TestAlertFiresRemindsAndResolves(t *testing.T) {
	m, fm, _, pool, now := setup(t, Settings{Recipients: []string{"a@example.com", "b@example.com"}, Server: "api.tarkk.ir"})
	ctx := context.Background()

	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	if got := fm.take(); len(got) != 0 {
		t.Fatalf("healthy service sent %d emails", len(got))
	}

	exec(t, pool, `INSERT INTO mail_outbox (kind, recipient, attempts, discard_after) VALUES ('register', '\x00', 4, now() + interval '1 hour')`)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	got := fm.take()
	if len(got) != 2 || got[0].To != "a@example.com" || got[1].To != "b@example.com" {
		t.Fatalf("emails = %+v", got)
	}
	if got[0].Subject != "[Tarkk api.tarkk.ir] ALERT: Email is not going out" {
		t.Fatalf("subject = %q", got[0].Subject)
	}
	if !strings.Contains(got[0].Text, "1 emails still unsent") || fm.nudges != 1 {
		t.Fatalf("text = %q, nudges = %d", got[0].Text, fm.nudges)
	}

	// Still firing a minute later: no new email.
	*now = now.Add(time.Minute)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	if got := fm.take(); len(got) != 0 {
		t.Fatalf("repeated after a minute: %+v", got)
	}

	// After the reminder interval: one reminder.
	*now = now.Add(RemindEvery)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	got = fm.take()
	if len(got) != 2 || !strings.Contains(got[0].Text, "STILL FIRING") {
		t.Fatalf("reminder = %+v", got)
	}

	// Fixed: one resolved email, then quiet.
	exec(t, pool, `UPDATE mail_outbox SET sent_at = now()`)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	got = fm.take()
	if len(got) != 2 || got[0].Subject != "[Tarkk api.tarkk.ir] Resolved: Email is not going out" {
		t.Fatalf("resolved = %+v", got)
	}
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	if got := fm.take(); len(got) != 0 {
		t.Fatalf("resolved twice: %+v", got)
	}
}

func TestStateSurvivesRestart(t *testing.T) {
	m, fm, _, pool, now := setup(t, Settings{Recipients: []string{"a@example.com"}})
	ctx := context.Background()
	exec(t, pool, `UPDATE bazaar_purchases SET check_failures = 0`) // table exists
	exec(t, pool, `INSERT INTO users (id, name) VALUES ('11111111-1111-1111-1111-111111111111', 'x')`)
	exec(t, pool, `INSERT INTO bazaar_purchases (user_id, token_hash, token_enc, sku, state, check_failures)
		VALUES ('11111111-1111-1111-1111-111111111111', '\x01', '\x01', 'tark_premium_1m', 'active', 5)`)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	if got := fm.take(); len(got) != 1 || !strings.Contains(got[0].Subject, "Bazaar") {
		t.Fatalf("emails = %+v", got)
	}
	// A new process (same database) does not announce it again.
	m2 := New(pool, fm, &Counter{}, m.set, m.log)
	m2.now = func() time.Time { return *now }
	if err := m2.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	if got := fm.take(); len(got) != 0 {
		t.Fatalf("restart re-announced: %+v", got)
	}
}

func TestServerErrorsUseAWindow(t *testing.T) {
	m, fm, c, _, now := setup(t, Settings{Recipients: []string{"a@example.com"}})
	ctx := context.Background()
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	for range ServerErrorThreshold - 1 {
		c.Inc()
	}
	*now = now.Add(time.Minute)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	if got := fm.take(); len(got) != 0 {
		t.Fatalf("fired below the threshold: %+v", got)
	}
	c.Inc()
	*now = now.Add(time.Minute)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	if got := fm.take(); len(got) != 1 || !strings.Contains(got[0].Text, "10 internal errors") {
		t.Fatalf("emails = %+v", got)
	}
	// The errors age out of the window and the alert clears.
	for range 6 {
		*now = now.Add(time.Minute)
		if err := m.Evaluate(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if got := fm.take(); len(got) != 1 || !strings.Contains(got[0].Subject, "Resolved") {
		t.Fatalf("emails = %+v", got)
	}
}

func TestSecurityAndBackupChecks(t *testing.T) {
	m, fm, _, pool, now := setup(t, Settings{Recipients: []string{"a@example.com"}, Backups: true})
	ctx := context.Background()

	// No backup yet, but the server just started: quiet.
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	if got := fm.take(); len(got) != 0 {
		t.Fatalf("emails = %+v", got)
	}
	exec(t, pool, `INSERT INTO backup_runs (finished_at, ok, error) VALUES (now(), false, 'disk full')`)
	exec(t, pool, `INSERT INTO audit_events (kind) SELECT 'login.failed' FROM generate_series(1, $1)`, FailedSignInThreshold)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	got := fm.take()
	if len(got) != 1 || !strings.Contains(got[0].Text, "The last backup attempt failed: disk full") ||
		!strings.Contains(got[0].Text, "50 failed sign-ins") {
		t.Fatalf("emails = %+v", got)
	}
	// A good backup clears the backup alert; an old one raises it again.
	exec(t, pool, `INSERT INTO backup_runs (finished_at, ok) VALUES ($1, true)`, *now)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	if got := fm.take(); len(got) != 1 || !strings.Contains(got[0].Subject, "Resolved: Database backups") {
		t.Fatalf("emails = %+v", got)
	}
	*now = now.Add(BackupMaxAge + time.Hour)
	exec(t, pool, `DELETE FROM audit_events`)
	if err := m.Evaluate(ctx); err != nil {
		t.Fatal(err)
	}
	got = fm.take()
	if len(got) != 1 || !strings.Contains(got[0].Text, "The last good backup finished") {
		t.Fatalf("emails = %+v", got)
	}
}

func TestNoRecipientsOnlyLogs(t *testing.T) {
	m, fm, _, pool, _ := setup(t, Settings{})
	exec(t, pool, `INSERT INTO mail_outbox (kind, recipient, attempts, discard_after) VALUES ('register', '\x00', 4, now() + interval '1 hour')`)
	if err := m.Evaluate(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(fm.sent) != 0 || fm.nudges != 0 {
		t.Fatalf("sent %d, nudged %d", len(fm.sent), fm.nudges)
	}
	if err := m.SendTest(context.Background()); err == nil {
		t.Fatal("test email with no recipients succeeded")
	}
}

func TestDiskCheckReads(t *testing.T) {
	m := &Monitor{set: Settings{DiskPath: os.TempDir()}}
	_, detail, err := m.diskCheck(context.Background())
	if err != nil {
		t.Skip("no disk check on this platform:", err)
	}
	if !strings.Contains(detail, "% used") {
		t.Fatalf("detail = %q", detail)
	}
}
