package admin

import (
	"strings"
	"testing"
)

func TestQRSVG(t *testing.T) {
	svg, err := qrSVG(otpauthURL([]byte("12345678901234567890"), "owner@example.com"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(svg)
	if !strings.HasPrefix(s, `<svg class="qr"`) || !strings.Contains(s, "h1v1h-1z") || !strings.HasSuffix(s, "</svg>") {
		t.Fatalf("unexpected svg: %.120s", s)
	}
}
