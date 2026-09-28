package mail

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// FailoverSender tries each sender in order until one accepts the message.
//
// It exists for Iran's network: a provider abroad (Gmail) can become
// unreachable from a server inside Iran during an international outage,
// while a provider inside Iran keeps working. A sender that just failed is
// skipped for Cooldown, so during an outage each email goes straight to the
// next provider instead of waiting for the first one to time out.
//
// If every sender fails, the error goes back to the outbox, which retries
// later with backoff.
type FailoverSender struct {
	Senders  []NamedSender
	Cooldown time.Duration // default 2 minutes
	Log      *slog.Logger

	mu       sync.Mutex
	downTill []time.Time
	now      func() time.Time
}

type NamedSender struct {
	Name string
	Sender
}

func (f *FailoverSender) Send(ctx context.Context, m Message) error {
	now := time.Now
	if f.now != nil {
		now = f.now
	}
	cooldown := f.Cooldown
	if cooldown == 0 {
		cooldown = 2 * time.Minute
	}

	f.mu.Lock()
	if len(f.downTill) != len(f.Senders) {
		f.downTill = make([]time.Time, len(f.Senders))
	}
	var up, down []int
	for i := range f.Senders {
		if now().Before(f.downTill[i]) {
			down = append(down, i)
		} else {
			up = append(up, i)
		}
	}
	f.mu.Unlock()

	// Senders in their cooldown are still tried last, so a message goes out
	// whenever any provider works.
	var errs []error
	for _, i := range append(up, down...) {
		s := f.Senders[i]
		err := s.Send(ctx, m)
		f.mu.Lock()
		if err == nil {
			f.downTill[i] = time.Time{}
		} else {
			f.downTill[i] = now().Add(cooldown)
		}
		f.mu.Unlock()
		if err == nil {
			if i > 0 && f.Log != nil {
				f.Log.WarnContext(ctx, "mail sent through a backup provider", "provider", s.Name)
			}
			return nil
		}
		if f.Log != nil {
			f.Log.WarnContext(ctx, "mail provider failed", "provider", s.Name, "err", err)
		}
		errs = append(errs, fmt.Errorf("%s: %w", s.Name, err))
		if ctx.Err() != nil {
			break
		}
	}
	return errors.Join(errs...)
}
