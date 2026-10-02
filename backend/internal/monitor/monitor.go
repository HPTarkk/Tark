// Package monitor watches the service and emails the people in
// TARK_ALERT_EMAILS when something needs a human: internal errors, mail not
// going out, Bazaar unreachable, signs of an attack, a filling disk, or a
// missing backup.
//
// Every check reads data the service already keeps (the database and an
// in-process error counter). Alerts carry counts only, never personal data.
// What the monitor cannot see is its own server going down; an outside
// uptime check on /readyz covers that (see DEPLOYMENT.md).
package monitor

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

// Thresholds. Deliberately in one place: tune them here once there is real
// traffic to tune against.
const (
	ServerErrorWindow    = 5 * time.Minute
	ServerErrorThreshold = 10 // HTTP 500s inside the window

	SecurityWindow        = 15 * time.Minute
	FailedSignInThreshold = 50 // wrong passwords, wrong codes, rejected Google tokens
	LockoutThreshold      = 20 // locked flows and throttled sign-ins
	TokenReuseThreshold   = 3  // refresh-token reuse (a sign of a stolen token)

	MailStuckAttempts = 3

	BazaarFailures = 3                // consecutive failed checks of one purchase
	BazaarOverdue  = 30 * time.Minute // a purchase check this late means the worker is stuck

	DiskUsedPercent = 80

	BackupMaxAge = 26 * time.Hour

	// While an alert keeps firing it is repeated this often.
	RemindEvery = 6 * time.Hour
)

// Counter counts HTTP 500 responses. The HTTP layer increments it; the
// monitor reads it.
type Counter struct{ n atomic.Int64 }

func (c *Counter) Inc()         { c.n.Add(1) }
func (c *Counter) Value() int64 { return c.n.Load() }

// Mailer is the part of the mail outbox the monitor uses.
type Mailer interface {
	Enqueue(ctx context.Context, tx store.Querier, kind string, m mail.Message, discardAfter time.Time) error
	Nudge()
}

type Settings struct {
	// Recipients of alert emails. Empty means alerts are only logged.
	Recipients []string
	// DiskPath is a path on the disk to watch (the backup directory, which
	// shares the server's disk). Empty skips the disk check.
	DiskPath string
	// Backups enables the backup age check.
	Backups bool
	// Server names this deployment in the email subject, e.g. api.tarkk.ir.
	Server string
}

type Monitor struct {
	pool    *pgxpool.Pool
	mailer  Mailer
	errs    *Counter
	set     Settings
	log     *slog.Logger
	now     func() time.Time
	started time.Time
	checks  []check

	mu      sync.Mutex
	samples []sample
}

type sample struct {
	at time.Time
	n  int64
}

// check reports whether an alert condition holds and what was seen.
type check struct {
	key   string
	title string
	eval  func(ctx context.Context) (bool, string, error)
}

func New(pool *pgxpool.Pool, mailer Mailer, errs *Counter, set Settings, log *slog.Logger) *Monitor {
	m := &Monitor{pool: pool, mailer: mailer, errs: errs, set: set, log: log, now: time.Now}
	m.started = m.now()
	m.checks = []check{
		{"server_errors", "The API is returning internal errors", m.serverErrors},
		{"mail", "Email is not going out", m.mailCheck},
		{"bazaar", "Bazaar purchase checks are failing", m.bazaarCheck},
		{"security", "Unusual sign-in failures (possible attack)", m.securityCheck},
	}
	if set.DiskPath != "" {
		m.checks = append(m.checks, check{"disk", "The server disk is filling up", m.diskCheck})
	}
	if set.Backups {
		m.checks = append(m.checks, check{"backup", "Database backups are failing or late", m.backupCheck})
	}
	return m
}

// Run evaluates every minute until ctx ends.
func (m *Monitor) Run(ctx context.Context) {
	if len(m.set.Recipients) == 0 {
		m.log.WarnContext(ctx, "TARK_ALERT_EMAILS is empty: alerts are only written to the log")
	}
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		if err := m.Evaluate(ctx); err != nil {
			m.log.ErrorContext(ctx, "monitor evaluation failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// lockID lets one instance at a time evaluate, so several instances do not
// send the same email.
const lockID = 7342119003

type state struct {
	firing   bool
	since    *time.Time
	notified *time.Time
}

type change struct {
	check  check
	kind   string // "new", "still", "resolved"
	detail string
	since  time.Time
}

// Evaluate runs every check once, stores the result, and emails what
// changed.
func (m *Monitor) Evaluate(ctx context.Context) error {
	m.sample()
	type result struct {
		firing bool
		detail string
	}
	results := map[string]result{}
	var evalErrs []error
	for _, c := range m.checks {
		firing, detail, err := c.eval(ctx)
		if err != nil {
			// A check that cannot run keeps its previous state rather than
			// raising or clearing an alert on no information.
			evalErrs = append(evalErrs, fmt.Errorf("%s: %w", c.key, err))
			continue
		}
		results[c.key] = result{firing, detail}
	}

	var changes []change
	err := pgx.BeginFunc(ctx, m.pool, func(tx pgx.Tx) error {
		var got bool
		if err := tx.QueryRow(ctx, "SELECT pg_try_advisory_xact_lock($1)", lockID).Scan(&got); err != nil || !got {
			return err
		}
		prev, err := loadStates(ctx, tx)
		if err != nil {
			return err
		}
		now := m.now()
		for _, c := range m.checks {
			r, ok := results[c.key]
			if !ok {
				continue
			}
			p := prev[c.key]
			since, notified := p.since, p.notified
			switch {
			case r.firing && !p.firing:
				since, notified = &now, &now
				changes = append(changes, change{c, "new", r.detail, now})
			case r.firing && (notified == nil || now.Sub(*notified) >= RemindEvery):
				notified = &now
				changes = append(changes, change{c, "still", r.detail, deref(since, now)})
			case !r.firing && p.firing:
				changes = append(changes, change{c, "resolved", r.detail, deref(since, now)})
				since, notified = nil, nil
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO alert_state (key, firing, since, last_notified_at, detail, updated_at)
				VALUES ($1, $2, $3, $4, $5, now())
				ON CONFLICT (key) DO UPDATE SET firing = $2, since = $3, last_notified_at = $4, detail = $5, updated_at = now()`,
				c.key, r.firing, since, notified, r.detail); err != nil {
				return err
			}
		}
		if len(changes) == 0 {
			return nil
		}
		for _, ch := range changes {
			m.log.WarnContext(ctx, "alert", "key", ch.check.key, "state", ch.kind, "detail", ch.detail)
		}
		return m.enqueue(ctx, tx, render(m.set.Server, changes, now))
	})
	if err == nil && len(changes) > 0 && len(m.set.Recipients) > 0 {
		m.mailer.Nudge()
	}
	return errors.Join(append(evalErrs, err)...)
}

func deref(t *time.Time, def time.Time) time.Time {
	if t == nil {
		return def
	}
	return *t
}

func loadStates(ctx context.Context, tx pgx.Tx) (map[string]state, error) {
	rows, err := tx.Query(ctx, `SELECT key, firing, since, last_notified_at FROM alert_state`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]state{}
	for rows.Next() {
		var k string
		var s state
		if err := rows.Scan(&k, &s.firing, &s.since, &s.notified); err != nil {
			return nil, err
		}
		out[k] = s
	}
	return out, rows.Err()
}

func (m *Monitor) enqueue(ctx context.Context, tx store.Querier, msg mail.Message) error {
	for _, to := range m.set.Recipients {
		msg.To = to
		// An alert a day late is noise; drop it if it cannot go out by then.
		if err := m.mailer.Enqueue(ctx, tx, "alert", msg, m.now().Add(24*time.Hour)); err != nil {
			return err
		}
	}
	return nil
}

// SendTest queues a test email to every recipient, to prove alerts arrive.
func (m *Monitor) SendTest(ctx context.Context) error {
	if len(m.set.Recipients) == 0 {
		return errors.New("TARK_ALERT_EMAILS is empty")
	}
	msg := mail.Message{
		Subject: subjectPrefix(m.set.Server) + "Test alert",
		Text: "This is a test of Tarkk's alert emails, sent with `tarkd alert-test`.\n\n" +
			"If you are reading it, alerts reach you. Nothing is wrong.\n",
	}
	if err := m.enqueue(ctx, m.pool, msg); err != nil {
		return err
	}
	m.mailer.Nudge()
	return nil
}

func subjectPrefix(server string) string {
	if server == "" {
		return "[Tarkk] "
	}
	return "[Tarkk " + server + "] "
}

func render(server string, changes []change, now time.Time) mail.Message {
	sort.SliceStable(changes, func(i, j int) bool { return rank(changes[i].kind) < rank(changes[j].kind) })
	var firing, resolved []string
	for _, c := range changes {
		if c.kind == "resolved" {
			resolved = append(resolved, c.check.title)
		} else {
			firing = append(firing, c.check.title)
		}
	}
	subject := subjectPrefix(server)
	switch {
	case len(firing) > 0:
		subject += "ALERT: " + strings.Join(firing, "; ")
	default:
		subject += "Resolved: " + strings.Join(resolved, "; ")
	}
	var b strings.Builder
	for _, c := range changes {
		switch c.kind {
		case "new":
			fmt.Fprintf(&b, "FIRING: %s\n", c.check.title)
		case "still":
			fmt.Fprintf(&b, "STILL FIRING (since %s): %s\n", c.since.UTC().Format("2006-01-02 15:04 UTC"), c.check.title)
		case "resolved":
			fmt.Fprintf(&b, "RESOLVED after %s: %s\n", now.Sub(c.since).Round(time.Minute), c.check.title)
		}
		fmt.Fprintf(&b, "  %s\n  What to do: %s\n\n", c.detail, advice[c.check.key])
	}
	fmt.Fprintf(&b, "Checked at %s. Firing alerts are repeated every %s until they clear.\n",
		now.UTC().Format("2006-01-02 15:04 UTC"), RemindEvery)
	return mail.Message{Subject: subject, Text: b.String()}
}

func rank(kind string) int {
	switch kind {
	case "new":
		return 0
	case "still":
		return 1
	}
	return 2
}

var advice = map[string]string{
	"server_errors": "read the API log on the server (bash remote.sh status) for the errors.",
	"mail":          "check the SMTP settings and whether Gmail is reachable from the server; sign-up and reset codes are not arriving.",
	"bazaar":        "check the Bazaar API credentials and whether pardakht.cafebazaar.ir is reachable; purchases cannot be verified meanwhile.",
	"security":      "look at the recent security events; per-IP and per-account limits are already slowing the caller down.",
	"disk":          "free disk space on the server (old Docker images: docker image prune) before the database stops.",
	"backup":        "read the API log for the backup error; until it is fixed there is no fresh backup.",
}

func (m *Monitor) sample() {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	m.samples = append(m.samples, sample{now, m.errs.Value()})
	// Keep one sample at or before the window start, drop older ones.
	for len(m.samples) > 1 && now.Sub(m.samples[1].at) >= ServerErrorWindow {
		m.samples = m.samples[1:]
	}
}

func (m *Monitor) serverErrors(context.Context) (bool, string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	first, last := m.samples[0], m.samples[len(m.samples)-1]
	n := last.n - first.n
	return n >= ServerErrorThreshold,
		fmt.Sprintf("%d internal errors (HTTP 500) in the last %s; alert at %d.", n, ServerErrorWindow, ServerErrorThreshold), nil
}

func (m *Monitor) mailCheck(ctx context.Context) (bool, string, error) {
	var stuck, dropped int
	err := m.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE sent_at IS NULL AND failed_at IS NULL AND attempts >= $1),
		       count(*) FILTER (WHERE failed_at > now() - interval '1 hour')
		FROM mail_outbox`, MailStuckAttempts).Scan(&stuck, &dropped)
	if err != nil {
		return false, "", err
	}
	return stuck > 0 || dropped > 0,
		fmt.Sprintf("%d emails still unsent after %d or more tries; %d dropped undelivered in the last hour.", stuck, MailStuckAttempts, dropped), nil
}

func (m *Monitor) bazaarCheck(ctx context.Context) (bool, string, error) {
	var failing, overdue int
	err := m.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE check_failures >= $1),
		       count(*) FILTER (WHERE next_check_at < now() - $2::interval)
		FROM bazaar_purchases`, BazaarFailures, BazaarOverdue).Scan(&failing, &overdue)
	if err != nil {
		return false, "", err
	}
	return failing > 0 || overdue > 0,
		fmt.Sprintf("%d purchases failed their last %d or more checks; %d checks are more than %s overdue.",
			failing, BazaarFailures, overdue, BazaarOverdue), nil
}

func (m *Monitor) securityCheck(ctx context.Context) (bool, string, error) {
	var failed, locked, reuse int
	err := m.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE kind IN ('login.failed', 'flow.code_failed', 'google.token_rejected',
		                                       'google.link_failed', 'password.change_failed', 'account.delete_failed')),
		       count(*) FILTER (WHERE kind IN ('flow.locked', 'login.throttled')),
		       count(*) FILTER (WHERE kind = 'session.refresh_reuse')
		FROM audit_events WHERE at > now() - $1::interval`, SecurityWindow).Scan(&failed, &locked, &reuse)
	if err != nil {
		return false, "", err
	}
	return failed >= FailedSignInThreshold || locked >= LockoutThreshold || reuse >= TokenReuseThreshold,
		fmt.Sprintf("In the last %s: %d failed sign-ins or codes (alert at %d), %d lockouts (alert at %d), %d reused refresh tokens (alert at %d).",
			SecurityWindow, failed, FailedSignInThreshold, locked, LockoutThreshold, reuse, TokenReuseThreshold), nil
}

func (m *Monitor) diskCheck(context.Context) (bool, string, error) {
	total, free, err := diskSpace(m.set.DiskPath)
	if err != nil {
		return false, "", err
	}
	if total == 0 {
		return false, "", errors.New("disk reports zero size")
	}
	used := 100 - free*100/total
	return used >= DiskUsedPercent,
		fmt.Sprintf("Disk %d%% used, %s free of %s; alert at %d%%.", used, size(free), size(total), DiskUsedPercent), nil
}

func size(b uint64) string {
	const g = 1 << 30
	if b >= g {
		return fmt.Sprintf("%.1f GB", float64(b)/g)
	}
	return fmt.Sprintf("%d MB", b>>20)
}

func (m *Monitor) backupCheck(ctx context.Context) (bool, string, error) {
	var lastOK *time.Time
	var lastFailed *bool
	var lastErr *string
	err := m.pool.QueryRow(ctx, `
		SELECT (SELECT max(finished_at) FROM backup_runs WHERE ok),
		       r.ok, r.error
		FROM (SELECT 1) one
		LEFT JOIN LATERAL (SELECT NOT ok AS ok, error FROM backup_runs
		                   WHERE finished_at IS NOT NULL ORDER BY id DESC LIMIT 1) r ON true`).Scan(&lastOK, &lastFailed, &lastErr)
	if err != nil {
		return false, "", err
	}
	now := m.now()
	switch {
	case lastFailed != nil && *lastFailed:
		msg := "unknown error"
		if lastErr != nil {
			msg = *lastErr
		}
		return true, "The last backup attempt failed: " + msg, nil
	case lastOK == nil:
		// The first backup runs at startup; only a server that has been up a
		// while without one is a problem.
		if now.Sub(m.started) < 2*time.Hour {
			return false, "No backup yet; the first one runs shortly after startup.", nil
		}
		return true, "No backup has ever completed.", nil
	case now.Sub(*lastOK) > BackupMaxAge:
		return true, fmt.Sprintf("The last good backup finished %s ago; alert after %s.", now.Sub(*lastOK).Round(time.Minute), BackupMaxAge), nil
	}
	return false, fmt.Sprintf("Last good backup %s ago.", now.Sub(*lastOK).Round(time.Minute)), nil
}
