package httpapi

import (
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
