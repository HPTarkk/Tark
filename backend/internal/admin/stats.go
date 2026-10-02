package admin

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/store"
)

// Stats are the dashboard numbers. All come from tables the service keeps
// anyway; nothing is collected for the panel.
type Stats struct {
	UsersTotal      int
	UsersNew7       int
	UsersNew30      int
	SignupsEmail30  int
	SignupsGoogle30 int
	Active7         int // accounts with a session seen in the last 7 days
	Disabled        int
	Deleted30       int

	Subscribers int
	ByPlan      []PlanCount
	NewSubs30   int
	RenewOff    int // active but auto-renew off: likely to end
	Expiring7   int // ending within 7 days without auto-renew
	Refunded30  int
	Suspicious  int
	SubsEnded30 int

	MailSent24   int
	MailFailed24 int
	MailPending  int
	FailedLogins int // last 24h
	Lockouts     int // last 24h
	TokenReuse   int // last 24h
	AlertsFiring []string
	LastBackup   *time.Time
	LastBackupOK bool
	SignupsByDay []DayCount
	SignupDayMax int
}

type PlanCount struct {
	SKU   string
	Count int
}

type DayCount struct {
	Day   time.Time
	Count int
}

func loadStats(ctx context.Context, q store.Querier) (*Stats, error) {
	st := &Stats{}
	if err := q.QueryRow(ctx, `
		SELECT
		  (SELECT count(*) FROM users),
		  (SELECT count(*) FROM users WHERE created_at > now() - interval '7 days'),
		  (SELECT count(*) FROM users WHERE created_at > now() - interval '30 days'),
		  (SELECT count(*) FROM users u WHERE u.created_at > now() - interval '30 days'
		     AND EXISTS (SELECT 1 FROM auth_identities i WHERE i.user_id = u.id AND i.provider = 'password')),
		  (SELECT count(*) FROM users u WHERE u.created_at > now() - interval '30 days'
		     AND NOT EXISTS (SELECT 1 FROM auth_identities i WHERE i.user_id = u.id AND i.provider = 'password')),
		  (SELECT count(DISTINCT user_id) FROM sessions WHERE revoked_at IS NULL AND last_seen_at > now() - interval '7 days'),
		  (SELECT count(*) FROM users WHERE status = 'disabled'),
		  (SELECT count(*) FROM audit_events WHERE kind = 'account.deleted' AND at > now() - interval '30 days')`).
		Scan(&st.UsersTotal, &st.UsersNew7, &st.UsersNew30, &st.SignupsEmail30, &st.SignupsGoogle30,
			&st.Active7, &st.Disabled, &st.Deleted30); err != nil {
		return nil, err
	}
	if err := q.QueryRow(ctx, `
		SELECT
		  (SELECT count(DISTINCT user_id) FROM bazaar_purchases WHERE state = 'active' AND valid_until > now()),
		  (SELECT count(*) FROM bazaar_purchases WHERE created_at > now() - interval '30 days' AND state IN ('active', 'expired')),
		  (SELECT count(*) FROM bazaar_purchases WHERE state = 'active' AND valid_until > now() AND NOT auto_renewing),
		  (SELECT count(*) FROM bazaar_purchases WHERE state = 'active' AND NOT auto_renewing
		     AND valid_until BETWEEN now() AND now() + interval '7 days'),
		  (SELECT count(*) FROM bazaar_purchases WHERE refunded_at > now() - interval '30 days'),
		  (SELECT count(*) FROM subscription_accounts WHERE suspicious_since IS NOT NULL),
		  (SELECT count(*) FROM bazaar_purchases WHERE state = 'expired' AND valid_until > now() - interval '30 days')`).
		Scan(&st.Subscribers, &st.NewSubs30, &st.RenewOff, &st.Expiring7, &st.Refunded30, &st.Suspicious, &st.SubsEnded30); err != nil {
		return nil, err
	}
	rows, err := q.Query(ctx, `
		SELECT sku, count(DISTINCT user_id) FROM bazaar_purchases
		WHERE state = 'active' AND valid_until > now() GROUP BY sku ORDER BY sku`)
	if err != nil {
		return nil, err
	}
	st.ByPlan, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (PlanCount, error) {
		var p PlanCount
		return p, row.Scan(&p.SKU, &p.Count)
	})
	if err != nil {
		return nil, err
	}
	if err := q.QueryRow(ctx, `
		SELECT
		  (SELECT count(*) FROM mail_outbox WHERE sent_at > now() - interval '24 hours'),
		  (SELECT count(*) FROM mail_outbox WHERE failed_at > now() - interval '24 hours'),
		  (SELECT count(*) FROM mail_outbox WHERE sent_at IS NULL AND failed_at IS NULL),
		  (SELECT count(*) FROM audit_events WHERE at > now() - interval '24 hours'
		     AND kind IN ('login.failed', 'flow.code_failed', 'google.token_rejected', 'google.link_failed', 'password.change_failed')),
		  (SELECT count(*) FROM audit_events WHERE at > now() - interval '24 hours' AND kind IN ('flow.locked', 'login.throttled')),
		  (SELECT count(*) FROM audit_events WHERE at > now() - interval '24 hours' AND kind = 'session.refresh_reuse')`).
		Scan(&st.MailSent24, &st.MailFailed24, &st.MailPending, &st.FailedLogins, &st.Lockouts, &st.TokenReuse); err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `SELECT key FROM alert_state WHERE firing ORDER BY key`)
	if err != nil {
		return nil, err
	}
	if st.AlertsFiring, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
		return nil, err
	}
	var ok *bool
	if err := q.QueryRow(ctx, `
		SELECT max(finished_at), (SELECT ok FROM backup_runs WHERE finished_at IS NOT NULL ORDER BY id DESC LIMIT 1)
		FROM backup_runs WHERE ok`).Scan(&st.LastBackup, &ok); err != nil {
		return nil, err
	}
	st.LastBackupOK = ok != nil && *ok
	rows, err = q.Query(ctx, `
		SELECT d::date, count(u.id)
		FROM generate_series(date_trunc('day', now()) - interval '29 days', date_trunc('day', now()), interval '1 day') d
		LEFT JOIN users u ON u.created_at >= d AND u.created_at < d + interval '1 day'
		GROUP BY d ORDER BY d`)
	if err != nil {
		return nil, err
	}
	st.SignupsByDay, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (DayCount, error) {
		var d DayCount
		return d, row.Scan(&d.Day, &d.Count)
	})
	if err != nil {
		return nil, err
	}
	for _, d := range st.SignupsByDay {
		st.SignupDayMax = max(st.SignupDayMax, d.Count)
	}
	return st, nil
}
