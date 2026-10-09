package billing

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeBazaarAPI serves the two developer-API endpoints BazaarHTTP uses.
type fakeBazaarAPI struct {
	tokenCalls  atomic.Int32
	tokenDelay  time.Duration
	tokenStatus int
	// revoked access tokens answer 401 on the purchase endpoint.
	mu      sync.Mutex
	revoked map[string]bool
}

func (f *fakeBazaarAPI) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/auth/token/":
			n := f.tokenCalls.Add(1)
			time.Sleep(f.tokenDelay)
			if f.tokenStatus != 0 {
				w.WriteHeader(f.tokenStatus)
				return
			}
			fmt.Fprintf(w, `{"access_token":"access-%d","expires_in":3600}`, n)
		case strings.HasPrefix(r.URL.Path, "/api/applications/"):
			access := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			f.mu.Lock()
			bad := f.revoked[access]
			f.mu.Unlock()
			if bad {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if strings.Contains(r.URL.Path, "/purchases/unknown/") {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			fmt.Fprint(w, `{"initiationTimestampMsec":1000,"validUntilTimestampMsec":2000000000000,"autoRenewing":true}`)
		default:
			t.Errorf("unexpected request %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	})
}

func newTestBazaar(t *testing.T, f *fakeBazaarAPI) *BazaarHTTP {
	srv := httptest.NewServer(f.handler(t))
	t.Cleanup(srv.Close)
	return &BazaarHTTP{BaseURL: srv.URL, PackageName: "com.example", ClientID: "id", ClientSecret: "secret",
		RefreshToken: "refresh", HTTP: srv.Client()}
}

func TestBazaarConcurrentCallersShareOneTokenRefresh(t *testing.T) {
	f := &fakeBazaarAPI{tokenDelay: 50 * time.Millisecond}
	b := newTestBazaar(t, f)
	var wg sync.WaitGroup
	errs := make(chan error, 20)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := b.Subscription(context.Background(), "plan", "tok"); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	if n := f.tokenCalls.Load(); n != 1 {
		t.Fatalf("token endpoint called %d times, want 1", n)
	}
}

func TestBazaarRevokedTokenIsRefreshedOnce(t *testing.T) {
	f := &fakeBazaarAPI{revoked: map[string]bool{"access-1": true}}
	b := newTestBazaar(t, f)
	sub, err := b.Subscription(context.Background(), "plan", "tok")
	if err != nil {
		t.Fatal(err)
	}
	if !sub.AutoRenewing || sub.ValidUntil.IsZero() {
		t.Fatalf("unexpected answer %+v", sub)
	}
	if n := f.tokenCalls.Load(); n != 2 {
		t.Fatalf("token endpoint called %d times, want 2", n)
	}
	// The fresh token is reused afterwards.
	if _, err := b.Subscription(context.Background(), "plan", "tok"); err != nil {
		t.Fatal(err)
	}
	if n := f.tokenCalls.Load(); n != 2 {
		t.Fatalf("token endpoint called %d times after reuse, want 2", n)
	}
}

func TestBazaarWaiterGivesUpWithItsOwnContext(t *testing.T) {
	f := &fakeBazaarAPI{tokenDelay: 400 * time.Millisecond}
	b := newTestBazaar(t, f)
	go func() { _, _ = b.Subscription(context.Background(), "plan", "tok") }()
	time.Sleep(50 * time.Millisecond) // let the first caller start the refresh
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := b.Subscription(ctx, "plan", "tok")
	if !errors.Is(err, ErrUnavailable) {
		t.Fatalf("want ErrUnavailable, got %v", err)
	}
	if waited := time.Since(start); waited > 200*time.Millisecond {
		t.Fatalf("waiter was held %v behind the refresh", waited)
	}
}

func TestBazaarFailedRefreshIsReportedAsUnavailable(t *testing.T) {
	f := &fakeBazaarAPI{tokenStatus: http.StatusBadRequest}
	b := newTestBazaar(t, f)
	if _, err := b.Subscription(context.Background(), "plan", "tok"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("want ErrUnavailable, got %v", err)
	}
}

func TestBazaarUnknownPurchaseIsNotFound(t *testing.T) {
	b := newTestBazaar(t, &fakeBazaarAPI{})
	if _, err := b.Subscription(context.Background(), "plan", "unknown"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}
