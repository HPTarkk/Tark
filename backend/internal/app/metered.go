package app

import (
	"context"
	"errors"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/billing"
	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/metrics"
)

// meteredBazaar counts calls to Bazaar. "Not found" is an answer, not a
// failure: only errors that say nothing about the purchase count as failed.
type meteredBazaar struct {
	billing.Bazaar
	m *metrics.Registry
}

func (b meteredBazaar) Subscription(ctx context.Context, sku, token string) (billing.Subscription, error) {
	start := time.Now()
	s, err := b.Bazaar.Subscription(ctx, sku, token)
	b.m.ObserveBazaar(err == nil || errors.Is(err, billing.ErrNotFound), time.Since(start))
	return s, err
}

// meteredSender counts attempts to hand an email to the mail server.
type meteredSender struct {
	mail.Sender
	m *metrics.Registry
}

func (s meteredSender) Send(ctx context.Context, msg mail.Message) error {
	start := time.Now()
	err := s.Sender.Send(ctx, msg)
	s.m.ObserveMail(err == nil, time.Since(start))
	return err
}
