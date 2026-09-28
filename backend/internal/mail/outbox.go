package mail

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

// Outbox queues messages in the database and delivers them.
type Outbox struct {
	pool   *pgxpool.Pool
	sealer *secure.Sealer
	sender Sender
	log    *slog.Logger
	wake   chan struct{}
}

func NewOutbox(pool *pgxpool.Pool, sealer *secure.Sealer, sender Sender, log *slog.Logger) *Outbox {
	return &Outbox{pool: pool, sealer: sealer, sender: sender, log: log, wake: make(chan struct{}, 1)}
}

// Enqueue adds m to the queue inside tx. The message is only sent if tx
// commits. discardAfter is when the message stops being useful (its code
// expires); undelivered by then, it is dropped rather than sent late.
func (o *Outbox) Enqueue(ctx context.Context, tx store.Querier, kind string, m Message, discardAfter time.Time) error {
	id := secure.NewUUID()
	body, err := json.Marshal(m)
	if err != nil {
		return err
	}
	ad := []byte("mail:" + id)
	_, err = tx.Exec(ctx, `
		INSERT INTO mail_outbox (id, kind, recipient, body, discard_after)
		VALUES ($1, $2, $3, $4, $5)`,
		id, kind, o.sealer.Seal([]byte(m.To), ad), o.sealer.Seal(body, ad), discardAfter)
	return err
}

// Nudge tells the worker there is new mail, so a verification code goes
// out within moments instead of on the next poll. Call after commit.
func (o *Outbox) Nudge() {
	select {
	case o.wake <- struct{}{}:
	default:
	}
}

// Run delivers queued mail until ctx ends. Safe to run on several
// instances at once: rows are claimed with SKIP LOCKED.
func (o *Outbox) Run(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		for {
			n, err := o.DeliverPending(ctx)
			if err != nil {
				o.log.ErrorContext(ctx, "mail outbox batch failed", "err", err)
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
		case <-o.wake:
		}
	}
}

type claimed struct {
	id           string
	kind         string
	recipient    []byte
	body         []byte
	attempts     int
	discardAfter time.Time
}

// DeliverPending sends one batch of due messages and reports how many it
// claimed.
func (o *Outbox) DeliverPending(ctx context.Context) (int, error) {
	// Claiming pushes next_try_at forward, so a crashed worker's messages
	// are picked up again later instead of being lost or sent twice at once.
	rows, err := o.pool.Query(ctx, `
		UPDATE mail_outbox SET attempts = attempts + 1, next_try_at = now() + interval '2 minutes'
		WHERE id IN (
			SELECT id FROM mail_outbox
			WHERE sent_at IS NULL AND failed_at IS NULL AND next_try_at <= now()
			ORDER BY next_try_at LIMIT 10
			FOR UPDATE SKIP LOCKED)
		RETURNING id, kind, recipient, body, attempts, discard_after`)
	if err != nil {
		return 0, err
	}
	var batch []claimed
	for rows.Next() {
		var c claimed
		if err := rows.Scan(&c.id, &c.kind, &c.recipient, &c.body, &c.attempts, &c.discardAfter); err != nil {
			rows.Close()
			return 0, err
		}
		batch = append(batch, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	for _, c := range batch {
		o.deliver(ctx, c)
	}
	return len(batch), nil
}

func (o *Outbox) deliver(ctx context.Context, c claimed) {
	if time.Now().After(c.discardAfter) {
		o.finish(ctx, c.id, false)
		o.log.WarnContext(ctx, "mail discarded after it expired undelivered", "id", c.id, "kind", c.kind, "attempts", c.attempts)
		return
	}
	ad := []byte("mail:" + c.id)
	to, err1 := o.sealer.Open(c.recipient, ad)
	body, err2 := o.sealer.Open(c.body, ad)
	var m Message
	if err1 != nil || err2 != nil || json.Unmarshal(body, &m) != nil {
		o.finish(ctx, c.id, false)
		o.log.ErrorContext(ctx, "mail row could not be decrypted; dropped", "id", c.id)
		return
	}
	m.To = string(to)

	sendCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	err := o.sender.Send(sendCtx, m)
	cancel()
	if err == nil {
		o.finish(ctx, c.id, true)
		o.log.InfoContext(ctx, "mail sent", "id", c.id, "kind", c.kind)
		return
	}
	// Back off: 10s, 20s, 40s … capped at 10 minutes.
	backoff := time.Duration(10<<min(c.attempts-1, 6)) * time.Second
	backoff = min(backoff, 10*time.Minute)
	if _, err := o.pool.Exec(ctx, `UPDATE mail_outbox SET next_try_at = now() + $2::interval WHERE id = $1`, c.id, backoff); err != nil {
		o.log.ErrorContext(ctx, "mail reschedule failed", "id", c.id, "err", err)
	}
	o.log.WarnContext(ctx, "mail send failed; will retry", "id", c.id, "kind", c.kind, "attempts", c.attempts, "err", err)
}

// finish wipes the message content either way: once sent (or abandoned)
// there is no reason to keep a code or an address around.
func (o *Outbox) finish(ctx context.Context, id string, sent bool) {
	column := "failed_at"
	if sent {
		column = "sent_at"
	}
	if _, err := o.pool.Exec(ctx,
		`UPDATE mail_outbox SET `+column+` = now(), body = NULL, recipient = '\x'::bytea WHERE id = $1`, id); err != nil {
		o.log.ErrorContext(ctx, "mail finish failed", "id", id, "err", err)
	}
}

// Sweep removes delivered or abandoned rows after a while.
func Sweep(ctx context.Context, db store.Querier, olderThan time.Duration) error {
	_, err := db.Exec(ctx, `DELETE FROM mail_outbox WHERE (sent_at IS NOT NULL OR failed_at IS NOT NULL) AND created_at < now() - $1::interval`, olderThan)
	return err
}
