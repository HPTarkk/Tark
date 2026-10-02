package httpapi

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestResolveArvanRealIP(t *testing.T) {
	x := ipResolver{header: "ar-real-ip", trusted: []netip.Prefix{netip.MustParsePrefix("185.143.232.0/22")}}
	for _, c := range []struct{ peer, header, want string }{
		{"185.143.233.7:443", "5.160.1.2", "5.160.1.2"},     // through ArvanCloud's edge
		{"203.0.113.9:443", "5.160.1.2", "203.0.113.9"},     // straight to the server: header ignored
		{"185.143.233.7:443", "", "185.143.233.7"},          // edge without the header
		{"185.143.233.7:443", "not an ip", "185.143.233.7"}, // garbage is never believed
	} {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = c.peer
		if c.header != "" {
			r.Header.Set("Ar-Real-Ip", c.header)
		}
		if got := x.resolve(r); got != c.want {
			t.Errorf("peer %s header %q: got %s, want %s", c.peer, c.header, got, c.want)
		}
	}
}

// One attacker, one /64: every address in it is the same client.
func TestIPv6IsKeyedBySlash64(t *testing.T) {
	x := ipResolver{}
	get := func(peer string) string {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = peer
		return x.resolve(r)
	}
	a, b := get("[2001:db8:1:2::1]:443"), get("[2001:db8:1:2:ffff:ffff:ffff:ffff]:443")
	if a != b || a != "2001:db8:1:2::/64" {
		t.Errorf("same /64 must share a key: %s vs %s", a, b)
	}
	if c := get("[2001:db8:1:3::1]:443"); c == a {
		t.Error("different /64s must not share a key")
	}
	if got := get("[::ffff:203.0.113.9]:443"); got != "203.0.113.9" {
		t.Errorf("IPv4-mapped address must key as IPv4, got %s", got)
	}
	if got := get("203.0.113.9:443"); got != "203.0.113.9" {
		t.Errorf("IPv4 is unchanged, got %s", got)
	}
}

// Behind a trusted proxy the same reduction applies to the forwarded address.
func TestIPv6ForwardedIsKeyedBySlash64(t *testing.T) {
	x := ipResolver{header: "X-Forwarded-For", trusted: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")}}
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.1.1.1:5000"
	r.Header.Set("X-Forwarded-For", "2001:db8:aaaa:bbbb:1:2:3:4")
	if got := x.resolve(r); got != "2001:db8:aaaa:bbbb::/64" {
		t.Errorf("got %s", got)
	}
}

// /readyz is public: a flood of calls must not become a flood of pings.
func TestReadyCacheLimitsPings(t *testing.T) {
	var c readyCache
	pings := 0
	for i := 0; i < 200; i++ {
		if !c.check(func() bool { pings++; return true }) {
			t.Fatal("cached answer lost")
		}
	}
	if pings != 1 {
		t.Fatalf("200 calls within the cache window made %d pings", pings)
	}
	c.at = c.at.Add(-readyCacheFor - 1)
	if c.check(func() bool { pings++; return false }) || pings != 2 {
		t.Fatal("an expired answer must be refreshed")
	}
}

func TestBearerSchemeIsCaseInsensitive(t *testing.T) {
	a := &api{}
	for _, h := range []string{"Bearer tok", "bearer tok", "BEARER tok"} {
		called := false
		next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) { called = true })
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "/", nil)
		r.Header.Set("Authorization", h)
		func() {
			defer func() { _ = recover() }() // a nil Auth service is reached only when the scheme was accepted
			a.authenticated(next).ServeHTTP(w, r)
		}()
		if w.Code == http.StatusUnauthorized && w.Header().Get("WWW-Authenticate") == "Bearer" {
			t.Errorf("%q was rejected as a missing token", h)
		}
		_ = called
	}
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/", nil)
	a2 := &api{Deps: Deps{Log: slog.New(slog.NewTextHandler(io.Discard, nil))}}
	a2.authenticated(http.NotFoundHandler()).ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("no header: %d", w.Code)
	}
}
