package billing

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testAPIToken = "app-token-from-pishkhan"

// fakeBazaarAPI serves the Payment API's subscription lookup. answers maps a
// purchase token to the status and body to send; any other token is an
// active subscription.
type fakeBazaarAPI struct {
	answers map[string]fakeAnswer
	paths   []string
}

type fakeAnswer struct {
	status int
	body   string
	delay  time.Duration
}

func (f *fakeBazaarAPI) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.paths = append(f.paths, r.URL.EscapedPath())
		if r.Method != http.MethodGet {
			t.Errorf("method %s, want GET", r.Method)
		}
		if strings.Contains(r.URL.Path, "/auth/token") {
			t.Errorf("the OAuth token endpoint must not be called any more: %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "" || r.URL.RawQuery != "" {
			t.Errorf("the token must travel only in the %s header", bazaarSecretHeader)
		}
		if r.Header.Get(bazaarSecretHeader) != testAPIToken {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		token := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		if a, ok := f.answers[token]; ok {
			time.Sleep(a.delay)
			w.WriteHeader(a.status)
			_, _ = w.Write([]byte(a.body))
			return
		}
		_, _ = w.Write([]byte(`{"kind":"androidpublisher#subscriptionPurchase","initiationTimestampMsec":1000,"validUntilTimestampMsec":2000000000000,"autoRenewing":true,"linkedSubscriptionToken":"x"}`))
	})
}

func newTestBazaar(t *testing.T, f *fakeBazaarAPI) *BazaarHTTP {
	srv := httptest.NewServer(f.handler(t))
	t.Cleanup(srv.Close)
	return &BazaarHTTP{BaseURL: srv.URL, PackageName: "com.example", APIToken: testAPIToken, HTTP: srv.Client()}
}

func TestBazaarSubscriptionRequestAndAnswer(t *testing.T) {
	f := &fakeBazaarAPI{}
	b := newTestBazaar(t, f)
	sub, err := b.Subscription(context.Background(), "tark_premium_1m", "tok/with space")
	if err != nil {
		t.Fatal(err)
	}
	if !sub.AutoRenewing || !sub.InitiatedAt.Equal(time.UnixMilli(1000)) || !sub.ValidUntil.Equal(time.UnixMilli(2000000000000)) {
		t.Fatalf("unexpected answer %+v", sub)
	}
	// One request, no token exchange before it, path values escaped, no
	// trailing slash.
	want := "/api/applications/com.example/subscriptions/tark_premium_1m/purchases/tok%2Fwith%20space"
	if len(f.paths) != 1 || f.paths[0] != want {
		t.Fatalf("requests %q, want only %q", f.paths, want)
	}
}

func TestBazaarMissingPurchaseIsNotFound(t *testing.T) {
	b := newTestBazaar(t, &fakeBazaarAPI{answers: map[string]fakeAnswer{
		"unknown": {status: 404, body: `{"error":"not_found","error_description":"The requested purchase is not found!"}`},
	}})
	if _, err := b.Subscription(context.Background(), "plan", "unknown"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

// Nothing here is a verdict on the purchase, so none of it may ever look
// like "Bazaar does not know this token": that would take a paying user's
// subscription away.
func TestBazaarEverythingElseIsUnavailable(t *testing.T) {
	cases := map[string]fakeAnswer{
		"wrong-package":  {status: 404, body: `{"error":"not_found","error_description":"The requested package is not found!"}`},
		"other-404-code": {status: 404, body: `{"error":"invalid_value","error_description":"x"}`},
		"plain-404":      {status: 404, body: `<html>404 Not Found</html>`},
		"empty-404":      {status: 404},
		"forbidden":      {status: 403, body: `{"error":"access_denied"}`},
		"unauthorized":   {status: 401, body: `{"error":"invalid_credentials"}`},
		"server-error":   {status: 500},
		"bad-gateway":    {status: 502, body: `<html>Bad Gateway</html>`},
		"rate-limited":   {status: 429},
		"not-json":       {status: 200, body: `<html>maintenance</html>`},
		"no-valid-until": {status: 200, body: `{"autoRenewing":true}`},
	}
	b := newTestBazaar(t, &fakeBazaarAPI{answers: cases})
	for token := range cases {
		_, err := b.Subscription(context.Background(), "plan", token)
		if !errors.Is(err, ErrUnavailable) || errors.Is(err, ErrNotFound) {
			t.Errorf("%s: want ErrUnavailable, got %v", token, err)
		}
		if err != nil && strings.Contains(err.Error(), testAPIToken) {
			t.Errorf("%s: the error carries the API token: %v", token, err)
		}
	}
}

func TestBazaarRefusedTokenIsUnavailableAndNamesTheSetting(t *testing.T) {
	b := newTestBazaar(t, &fakeBazaarAPI{})
	b.APIToken = "wrong"
	_, err := b.Subscription(context.Background(), "plan", "tok")
	if !errors.Is(err, ErrUnavailable) || !strings.Contains(err.Error(), "TARK_BAZAAR_PAYMENT_API_TOKEN") {
		t.Fatalf("want ErrUnavailable naming the setting, got %v", err)
	}
	if strings.Contains(err.Error(), "wrong") {
		t.Fatalf("the error carries the token: %v", err)
	}
}

func TestBazaarTimeoutAndUnreachableAreUnavailable(t *testing.T) {
	b := newTestBazaar(t, &fakeBazaarAPI{answers: map[string]fakeAnswer{"slow": {status: 200, delay: 300 * time.Millisecond}}})
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if _, err := b.Subscription(ctx, "plan", "slow"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("timeout: want ErrUnavailable, got %v", err)
	}
	gone := &BazaarHTTP{BaseURL: "http://127.0.0.1:1", PackageName: "com.example", APIToken: testAPIToken}
	if _, err := gone.Subscription(context.Background(), "plan", "tok"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("unreachable: want ErrUnavailable, got %v", err)
	}
}
