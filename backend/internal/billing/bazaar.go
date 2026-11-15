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

// Bazaar is the store's developer API as the billing service needs it. Only
// BazaarHTTP depends on the details of that API.
type Bazaar interface {
	Subscription(ctx context.Context, sku, purchaseToken string) (Subscription, error)
}

// BazaarHTTP talks to pardakht.cafebazaar.ir with Bazaar's current Payment
// API, which replaced the OAuth method (client id, client secret and a
// refresh token traded for access tokens):
//
//   - One token per app, made in Pishkhan (the app's "API پیشخان بازار" page,
//     "دریافت توکن جدید"), sent on every request in the
//     CAFEBAZAAR-PISHKHAN-API-SECRET header. There is nothing to refresh.
//   - GET {base}/api/applications/{package}/subscriptions/{sku}/purchases/{token}
//     -> initiationTimestampMsec, validUntilTimestampMsec, autoRenewing.
//     A success does not mean active; validUntil is compared with our clock.
//     The token must be the subscription's original purchase token.
//   - Only a 404 whose body says not_found is a definitive "no such
//     purchase". Bazaar also answers 404 for a package it does not know, and
//     a refused token, a timeout or a 5xx say nothing about the purchase, so
//     all of those are "unknown" and never downgrade anyone.
//
// The API never reports refunds or cancellations; see applyAnswer and
// applyMissing for how the service infers them.
type BazaarHTTP struct {
	BaseURL     string
	PackageName string
	// APIToken is the app's Payment API token. It only ever travels in the
	// request header and is never logged or put in an error.
	APIToken string
	HTTP     *http.Client
}

// bazaarSecretHeader carries the app token (the same header Pishkhan's other
// APIs use).
const bazaarSecretHeader = "CAFEBAZAAR-PISHKHAN-API-SECRET"

func (b *BazaarHTTP) client() *http.Client {
	if b.HTTP != nil {
		return b.HTTP
	}
	return &http.Client{
		Timeout: 8 * time.Second,
		// The token is a header of our own, which Go would carry along to
		// wherever a redirect points: it must not follow one anywhere.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func (b *BazaarHTTP) Subscription(ctx context.Context, sku, purchaseToken string) (Subscription, error) {
	u := fmt.Sprintf("%s/api/applications/%s/subscriptions/%s/purchases/%s",
		b.BaseURL, url.PathEscape(b.PackageName), url.PathEscape(sku), url.PathEscape(purchaseToken))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return Subscription{}, err
	}
	req.Header.Set(bazaarSecretHeader, b.APIToken)
	req.Header.Set("Accept", "application/json")

	resp, err := b.client().Do(req)
	if err != nil {
		return Subscription{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusOK:
	case resp.StatusCode == http.StatusNotFound:
		code, about := bazaarError(body)
		if code == "not_found" && !strings.Contains(about, "package") && !strings.Contains(about, "application") {
			return Subscription{}, ErrNotFound
		}
		// The package name is wrong, or something in between answered: that
		// is our setup, not a verdict on this purchase.
		return Subscription{}, fmt.Errorf("%w: status 404 (%s); check the package name and the API address", ErrUnavailable, orUnknown(code))
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		// Every verification stops until the token is replaced, so the error names it.
		return Subscription{}, fmt.Errorf("%w: bazaar refused the Payment API token (status %d); check TARK_BAZAAR_PAYMENT_API_TOKEN", ErrUnavailable, resp.StatusCode)
	default:
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

// bazaarError reads Bazaar's error body ({"error": ..., "error_description":
// ...}), lower-cased. Both are empty when the body is not that.
func bazaarError(body []byte) (code, description string) {
	var e struct {
		Error       string `json:"error"`
		Description string `json:"error_description"`
	}
	if json.Unmarshal(body, &e) != nil {
		return "", ""
	}
	return strings.ToLower(strings.TrimSpace(e.Error)), strings.ToLower(e.Description)
}

func orUnknown(code string) string {
	if code == "" || len(code) > 40 {
		return "no error code"
	}
	return code
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
