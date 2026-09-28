package secure

import (
	"bytes"
	"testing"
)

func TestSealerBindsAssociatedData(t *testing.T) {
	s, err := NewSealer(bytes.Repeat([]byte{7}, KeySize))
	if err != nil {
		t.Fatal(err)
	}
	ct := s.Seal([]byte("purchase-token"), []byte("row-1"))
	if pt, err := s.Open(ct, []byte("row-1")); err != nil || string(pt) != "purchase-token" {
		t.Fatalf("open: %q %v", pt, err)
	}
	if _, err := s.Open(ct, []byte("row-2")); err == nil {
		t.Fatal("ciphertext moved to another row still opened")
	}
	ct[len(ct)-1] ^= 1
	if _, err := s.Open(ct, []byte("row-1")); err == nil {
		t.Fatal("tampered ciphertext opened")
	}
}

func TestHasherDomainSeparation(t *testing.T) {
	h, _ := NewHasher(bytes.Repeat([]byte{1}, KeySize))
	if Equal(h.Sum("a", "bc"), h.Sum("ab", "c")) {
		t.Fatal("length prefixing failed")
	}
	if Equal(h.Sum("code", "x"), h.Sum("link", "x")) {
		t.Fatal("domains collide")
	}
}

func TestRandomDigits(t *testing.T) {
	for range 100 {
		d := RandomDigits(6)
		if len(d) != 6 {
			t.Fatal(d)
		}
		for _, c := range d {
			if c < '0' || c > '9' {
				t.Fatal(d)
			}
		}
	}
}

func TestDecodeKey(t *testing.T) {
	if _, err := DecodeKey("k", "c2hvcnQ"); err == nil {
		t.Fatal("short key accepted")
	}
	if _, err := DecodeKey("k", B64(bytes.Repeat([]byte{2}, 32))); err != nil {
		t.Fatal(err)
	}
}
