package billing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Subscription is what Cafe Bazaar reports about one subscription purchase.
type Subscription struct {
	InitiatedAt  time.Time
	ValidUntil   time.Time
	AutoRenewing bool
}

var (
	// ErrNotFound is a definitive answer: Bazaar does not know this token
	// (never valid, or revoked).
	ErrNotFound = errors.New("bazaar: purchase not found")
	// ErrUnavailable covers timeouts, 5xx and anything else that says
	// nothing about the purchase. Never a reason to downgrade anyone.
	ErrUnavailable = errors.New("bazaar: unavailable")
)

// Bazaar is the store's developer API as the billing service needs it.
// Kept behind an interface because the exact API has not been checked
// against Bazaar's documentation yet (the docs host is blocked where this
// was written); only BazaarHTTP depends on those details.
type Bazaar interface {
	Subscription(ctx context.Context, sku, purchaseToken string) (Subscription, error)
}

// BazaarHTTP talks to pardakht.cafebazaar.ir.
//
// Per Bazaar's developer API docs (v2), summarised in the project's
// backend-design/bazaar-billing.md:
//   - OAuth: POST {base}/auth/token/ with grant_type=refresh_token,
//     client_id, client_secret, refresh_token -> access_token, expires_in.
//     The refresh token is long-lived and not rotated.
//   - GET {base}/api/applications/{package}/subscriptions/{sku}/purchases/{token}/
//     -> initiationTimestampMsec, validUntilTimestampMsec, autoRenewing.
//     A success does not mean active; validUntil is compared with our clock.
//     Only 404 not_found is definitive; anything else means "unknown".
//
// The API never reports refunds or cancellations; see applyAnswer and
// applyMissing for how the service infers them.
type BazaarHTTP struct {
	BaseURL      string
	PackageName  string
	ClientID     string
	ClientSecret string
	RefreshToken string
	HTTP         *http.Client

	mu          sync.Mutex
	accessToken string
	accessUntil time.Time
	// refreshing is closed when the refresh in flight ends (nil when none);
	// refreshErr is how it ended. One refresh serves every caller waiting,
	// and none of them holds mu while Bazaar answers.
	refreshing chan struct{}
	refreshErr error
}

func (b *BazaarHTTP) client() *http.Client {
	if b.HTTP != nil {
		return b.HTTP
	}
	return &http.Client{Timeout: 8 * time.Second}
}

// token returns a live access token. rejected is a token Bazaar just
// refused; it is never handed out again, which forces a refresh unless
// another caller has already replaced it.
func (b *BazaarHTTP) token(ctx context.Context, rejected string) (string, error) {
	for {
		b.mu.Lock()
		if b.accessToken != "" && b.accessToken != rejected && time.Now().Before(b.accessUntil) {
			token := b.accessToken
			b.mu.Unlock()
			return token, nil
		}
		if wait := b.refreshing; wait != nil {
			b.mu.Unlock()
			select {
			case <-wait:
				b.mu.Lock()
				err := b.refreshErr
				b.mu.Unlock()
				if err != nil {
					return "", err
				}
				continue
			case <-ctx.Done():
				return "", fmt.Errorf("%w: %v", ErrUnavailable, ctx.Err())
			}
		}
		done := make(chan struct{})
		b.refreshing = done
		b.mu.Unlock()

		// Not tied to this caller's request: others may be waiting on it.
		fetchCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 8*time.Second)
		token, until, err := b.fetchToken(fetchCtx)
		cancel()

		b.mu.Lock()
		if err == nil {
			b.accessToken, b.accessUntil = token, until
		}
		b.refreshErr = err
		b.refreshing = nil
		close(done)
		b.mu.Unlock()
		return token, err
	}
}

// fetchToken trades the long-lived refresh token for an access token.
func (b *BazaarHTTP) fetchToken(ctx context.Context) (string, time.Time, error) {
	form := url.Values{
		"grant_type":    {"refresh_token"},
		"client_id":     {b.ClientID},
		"client_secret": {b.ClientSecret},
		"refresh_token": {b.RefreshToken},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.BaseURL+"/auth/token/", strings.NewReader(form.Encode()))
	if err != nil {
		return "", time.Time{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := b.client().Do(req)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("%w: token: %v", ErrUnavailable, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// Every verification stops until this is fixed (possibly by redoing
		// the one-time authorisation by hand), so the error names it.
		return "", time.Time{}, fmt.Errorf("%w: bazaar oauth refresh failed with status %d; check the developer API credentials", ErrUnavailable, resp.StatusCode)
	}
	var body struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&body); err != nil || body.AccessToken == "" {
		return "", time.Time{}, fmt.Errorf("%w: token response unreadable", ErrUnavailable)
	}
	life := time.Duration(body.ExpiresIn) * time.Second
	if life <= 0 {
		life = 30 * time.Minute
	}
	// Renew a minute early so a request never races the expiry.
	return body.AccessToken, time.Now().Add(life - time.Minute), nil
}

func (b *BazaarHTTP) Subscription(ctx context.Context, sku, purchaseToken string) (Subscription, error) {
	rejected := ""
	for attempt := 0; attempt < 2; attempt++ {
		access, err := b.token(ctx, rejected)
		if err != nil {
			return Subscription{}, err
		}
		u := fmt.Sprintf("%s/api/applications/%s/subscriptions/%s/purchases/%s/",
			b.BaseURL, url.PathEscape(b.PackageName), url.PathEscape(sku), url.PathEscape(purchaseToken))
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return Subscription{}, err
		}
		// The header, not ?access_token=, keeps the token out of access logs.
		req.Header.Set("Authorization", "Bearer "+access)

		resp, err := b.client().Do(req)
		if err != nil {
			return Subscription{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		resp.Body.Close()
		switch {
		case resp.StatusCode == http.StatusUnauthorized && attempt == 0:
			rejected = access
			continue // access token revoked early; get a new one once
		case resp.StatusCode == http.StatusNotFound:
			return Subscription{}, ErrNotFound
		case resp.StatusCode != http.StatusOK:
			return Subscription{}, fmt.Errorf("%w: status %d", ErrUnavailable, resp.StatusCode)
		}
		var raw struct {
			Initiation int64 `json:"initiationTimestampMsec"`
			ValidUntil int64 `json:"validUntilTimestampMsec"`
			AutoRenew  bool  `json:"autoRenewing"`
		}
		if err := json.Unmarshal(body, &raw); err != nil || raw.ValidUntil == 0 {
			// An answer we cannot read says nothing about the purchase.
			return Subscription{}, fmt.Errorf("%w: unreadable response", ErrUnavailable)
		}
		return Subscription{
			InitiatedAt:  time.UnixMilli(raw.Initiation).UTC(),
			ValidUntil:   time.UnixMilli(raw.ValidUntil).UTC(),
			AutoRenewing: raw.AutoRenew,
		}, nil
	}
	return Subscription{}, fmt.Errorf("%w: unauthorized", ErrUnavailable)
}

// FakeBazaar is for development and tests. Tokens starting with
// "invalid" are unknown, "down" is unavailable; anything else is a
// subscription that started now and runs for 30 days.
type FakeBazaar struct {
	mu     sync.Mutex
	Now    func() time.Time
	Answer map[string]Subscription
	Errors map[string]error
	// OnCall, if set, runs at the start of every question (tests use it to
	// look at what the caller is holding while Bazaar is being asked).
	OnCall func()
}

func (f *FakeBazaar) Set(token string, s Subscription, err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.Answer == nil {
		f.Answer, f.Errors = map[string]Subscription{}, map[string]error{}
	}
	delete(f.Answer, token)
	delete(f.Errors, token)
	if err != nil {
		f.Errors[token] = err
	} else {
		f.Answer[token] = s
	}
}

func (f *FakeBazaar) Subscription(_ context.Context, _ string, token string) (Subscription, error) {
	if f.OnCall != nil {
		f.OnCall()
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if err, ok := f.Errors[token]; ok {
		return Subscription{}, err
	}
	if s, ok := f.Answer[token]; ok {
		return s, nil
	}
	switch {
	case strings.HasPrefix(token, "invalid"):
		return Subscription{}, ErrNotFound
	case strings.HasPrefix(token, "down"):
		return Subscription{}, ErrUnavailable
	}
	now := time.Now
	if f.Now != nil {
		now = f.Now
	}
	start := now().UTC()
	return Subscription{InitiatedAt: start, ValidUntil: start.Add(30 * 24 * time.Hour), AutoRenewing: true}, nil
}
