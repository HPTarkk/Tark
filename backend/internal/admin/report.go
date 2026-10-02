package admin

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/mail"
)

// The weekly summary goes out on Monday at 05:00 UTC (08:30 in Tehran).
const (
	reportWeekday = time.Monday
	reportHourUTC = 5
)

// RunReports sends the weekly summary email until ctx ends.
func (s *Server) RunReports(ctx context.Context) {
	t := time.NewTicker(15 * time.Minute)
	defer t.Stop()
	for {
		if _, err := s.SendWeeklyIfDue(ctx); err != nil {
			s.Log.ErrorContext(ctx, "weekly report failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// lastReportTime is the most recent scheduled send at or before now.
func lastReportTime(now time.Time) time.Time {
	now = now.UTC()
	d := time.Date(now.Year(), now.Month(), now.Day(), reportHourUTC, 0, 0, 0, time.UTC)
	for d.Weekday() != reportWeekday || d.After(now) {
		d = d.Add(-24 * time.Hour)
	}
	return d
}

// SendWeeklyIfDue sends the summary once per scheduled time. Claiming the
// run and queueing the email happen in one transaction, so several
// instances, or a crash halfway, never send it twice or lose it.
func (s *Server) SendWeeklyIfDue(ctx context.Context) (bool, error) {
	if len(s.AlertEmails) == 0 {
		return false, nil
	}
	due := lastReportTime(s.now())
	sent := false
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			INSERT INTO job_runs (name, last_run_at) VALUES ('weekly_report', $1)
			ON CONFLICT (name) DO UPDATE SET last_run_at = $1 WHERE job_runs.last_run_at < $1`, due)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		st, err := loadStats(ctx, tx)
		if err != nil {
			return err
		}
		msg := weeklyMessage(s.ServerName, st, due)
		for _, to := range s.AlertEmails {
			msg.To = to
			if err := s.Mailer.Enqueue(ctx, tx, "weekly_report", msg, s.now().Add(48*time.Hour)); err != nil {
				return err
			}
		}
		sent = true
		return nil
	})
	if sent {
		s.Mailer.Nudge()
	}
	return sent, err
}

func weeklyMessage(server string, st *Stats, at time.Time) mail.Message {
	prefix := "[Tarkk] "
	if server != "" {
		prefix = "[Tarkk " + server + "] "
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Tarkk weekly summary, %s\n\n", at.Format("2006-01-02"))
	fmt.Fprintf(&b, "ACCOUNTS\n  %d in total, %d new this week, %d new in 30 days\n", st.UsersTotal, st.UsersNew7, st.UsersNew30)
	fmt.Fprintf(&b, "  %d signed-in accounts used the app this week\n", st.Active7)
	fmt.Fprintf(&b, "  %d deleted in 30 days, %d disabled\n\n", st.Deleted30, st.Disabled)
	fmt.Fprintf(&b, "SUBSCRIPTIONS\n  %d active subscribers", st.Subscribers)
	for _, p := range st.ByPlan {
		fmt.Fprintf(&b, ", %s: %d", p.SKU, p.Count)
	}
	fmt.Fprintf(&b, "\n  %d new purchases and %d ended in 30 days\n", st.NewSubs30, st.SubsEnded30)
	fmt.Fprintf(&b, "  %d active with auto-renew off (%d end within 7 days)\n", st.RenewOff, st.Expiring7)
	fmt.Fprintf(&b, "  %d refunded in 30 days, %d accounts flagged suspicious\n\n", st.Refunded30, st.Suspicious)
	fmt.Fprintf(&b, "HEALTH (last 24 hours)\n  Email: %d sent, %d dropped, %d waiting\n", st.MailSent24, st.MailFailed24, st.MailPending)
	fmt.Fprintf(&b, "  Failed sign-ins: %d, lockouts: %d, reused refresh tokens: %d\n", st.FailedLogins, st.Lockouts, st.TokenReuse)
	if st.LastBackup != nil {
		fmt.Fprintf(&b, "  Last good backup: %s\n", st.LastBackup.UTC().Format("2006-01-02 15:04 UTC"))
	} else {
		b.WriteString("  No backup yet\n")
	}
	if len(st.AlertsFiring) > 0 {
		fmt.Fprintf(&b, "  Alerts firing now: %s\n", strings.Join(st.AlertsFiring, ", "))
	}
	b.WriteString("\nRevenue is in the Bazaar developer console. More detail in the admin panel.\n")
	return mail.Message{Subject: prefix + "Weekly summary", Text: b.String()}
}
