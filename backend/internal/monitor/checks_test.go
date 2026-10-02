package monitor

import (
	"context"
	"crypto/x509"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/metrics"
)

func quiet() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func TestSlowCheck(t *testing.T) {
	reg := metrics.New(nil)
	m := New(nil, &fakeMailer{}, &Counter{}, Settings{Metrics: reg}, quiet())
	ctx := context.Background()
	// Few requests: never fires, however slow.
	for range SlowMinRequests - 1 {
		reg.ObserveRequest("POST", "/v1/auth/login", 200, 3*time.Second)
	}
	if firing, _, _ := m.slowCheck(ctx); firing {
		t.Fatal("fired on too few requests")
	}
	// Health checks are left out of the count.
	for range 1000 {
		reg.ObserveRequest("GET", "/readyz", 200, time.Millisecond)
	}
	reg.ObserveRequest("POST", "/v1/auth/login", 200, 10*time.Millisecond)
	firing, detail, err := m.slowCheck(ctx)
	if err != nil || !firing || !strings.Contains(detail, "19 of 20 requests") {
		t.Fatalf("slow: %v %q %v", firing, detail, err)
	}
	for range 400 {
		reg.ObserveRequest("GET", "/v1/me", 200, 10*time.Millisecond)
	}
	if firing, _, _ := m.slowCheck(ctx); firing {
		t.Fatal("fired under the threshold")
	}
}

func TestDatabaseCheckWithoutPoolStaysQuiet(t *testing.T) {
	m := New(nil, &fakeMailer{}, &Counter{}, Settings{Metrics: metrics.New(nil)}, quiet())
	firing, detail, err := m.dbCheck(context.Background())
	if err != nil || firing || !strings.Contains(detail, "0 requests gave up") {
		t.Fatalf("%v %q %v", firing, detail, err)
	}
}

func TestCertCheck(t *testing.T) {
	ts := httptest.NewTLSServer(http.NotFoundHandler())
	defer ts.Close()
	leaf := ts.Certificate()
	roots := x509.NewCertPool()
	roots.AddCert(leaf)
	addr := strings.TrimPrefix(ts.URL, "https://")
	ctx := context.Background()

	now := time.Now()
	m := New(nil, &fakeMailer{}, &Counter{}, Settings{TLSAddr: addr, TLSNames: []string{"example.com"}, TLSRoots: roots}, quiet())
	m.now = func() time.Time { return now }
	firing, detail, err := m.certCheck(ctx)
	if err != nil || firing || !strings.Contains(detail, "example.com: ") || !strings.Contains(detail, "days left") {
		t.Fatalf("valid: %v %q %v", firing, detail, err)
	}
	// Close to expiry (the test certificate is valid for decades, so move
	// the clock instead); the hourly cache is skipped by moving past it.
	now = leaf.NotAfter.Add(-5 * 24 * time.Hour)
	firing, detail, _ = m.certCheck(ctx)
	if !firing || !strings.Contains(detail, "expires in 4 days") && !strings.Contains(detail, "expires in 5 days") {
		t.Fatalf("expiring: %v %q", firing, detail)
	}
	// Cached for an hour.
	m.certResult = certResult{false, "cached"}
	if _, d, _ := m.certCheck(ctx); d != "cached" {
		t.Fatal("not cached")
	}

	// A certificate the client does not trust (or for another name) fires.
	m2 := New(nil, &fakeMailer{}, &Counter{}, Settings{TLSAddr: addr, TLSNames: []string{"example.com"}}, quiet())
	firing, detail, err = m2.certCheck(ctx)
	if err != nil || !firing || !strings.Contains(detail, "not valid") {
		t.Fatalf("untrusted: %v %q %v", firing, detail, err)
	}

	// Nothing listening says nothing about the certificate.
	ts.Close()
	m3 := New(nil, &fakeMailer{}, &Counter{}, Settings{TLSAddr: addr, TLSNames: []string{"example.com"}, TLSRoots: roots}, quiet())
	if _, _, err := m3.certCheck(ctx); err == nil {
		t.Fatal("expected an error when the front end is down")
	}
}
