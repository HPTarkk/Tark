package auth

import (
	"strings"
	"testing"
	"time"
)

func TestNormalizeEmail(t *testing.T) {
	ok := map[string]string{
		"  Pedram@Gmail.COM ": "pedram@gmail.com",
		"a.b+tag@example.ir":  "a.b+tag@example.ir",
	}
	for in, want := range ok {
		got, err := NormalizeEmail(in)
		if err != nil || got != want {
			t.Errorf("NormalizeEmail(%q) = %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "no-at", "a@b", "a@@b.com", "Name <a@b.com>", "a b@c.com", "پدرام@gmail.com", "a@.com", "a@b..com"} {
		if _, err := NormalizeEmail(bad); err == nil {
			t.Errorf("NormalizeEmail(%q) accepted", bad)
		}
	}
}

func TestNormalizeName(t *testing.T) {
	got, err := NormalizeName("  علی‌رضا   احمدی ")
	if err != nil || got != "علی‌رضا احمدی" {
		t.Fatalf("persian name: %q %v", got, err)
	}
	for _, bad := range []string{"", "   ", "evil‮gnp.exe", "a\x00b", strings.Repeat("a", 51)} {
		if _, err := NormalizeName(bad); err == nil {
			t.Errorf("NormalizeName(%q) accepted", bad)
		}
	}
}

func TestNormalizeAvatar(t *testing.T) {
	good := "m01"
	if v, err := NormalizeAvatar(&good); err != nil || *v != "m01" {
		t.Fatal(err)
	}
	if v, err := NormalizeAvatar(nil); err != nil || v != nil {
		t.Fatal("nil avatar should stay nil")
	}
	bad := "../../etc"
	if _, err := NormalizeAvatar(&bad); err == nil {
		t.Fatal("bad avatar accepted")
	}
}

func TestAccessTokenTamper(t *testing.T) {
	s := tokenSigner{key: []byte("0123456789abcdef0123456789abcdef"), now: time.Now}
	tok, _ := s.issue("sid", "uid", 60e9)
	if _, err := s.parse(tok); err != nil {
		t.Fatal(err)
	}
	other := tokenSigner{key: []byte("fedcba9876543210fedcba9876543210"), now: time.Now}
	if _, err := other.parse(tok); err == nil {
		t.Fatal("token verified with another key")
	}
	if _, err := s.parse(tok[:len(tok)-2] + "AA"); err == nil {
		t.Fatal("tampered token accepted")
	}
}
