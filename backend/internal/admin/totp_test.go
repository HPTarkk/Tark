package admin

import (
	"strings"
	"testing"
	"time"
)

// RFC 6238 appendix B, SHA-1 vectors (8 digits there; the last 6 here).
func TestTOTPVectors(t *testing.T) {
	secret := []byte("12345678901234567890")
	for unix, want := range map[int64]string{
		59: "287082", 1111111109: "081804", 1111111111: "050471", 1234567890: "005924", 2000000000: "279037",
	} {
		if got := totpCode(secret, unix/totpStep); got != want {
			t.Errorf("t=%d: got %s, want %s", unix, got, want)
		}
	}
}

func TestVerifyTOTPSkewAndReplay(t *testing.T) {
	secret := newTOTPSecret()
	now := time.Unix(1_800_000_000, 0)
	step := now.Unix() / totpStep
	if got := verifyTOTP(secret, totpCode(secret, step-1), now, 0); got != step-1 {
		t.Fatalf("previous step: got %d", got)
	}
	if got := verifyTOTP(secret, totpCode(secret, step-2), now, 0); got != 0 {
		t.Fatal("accepted a code two steps old")
	}
	if got := verifyTOTP(secret, totpCode(secret, step), now, step); got != 0 {
		t.Fatal("accepted a replayed code")
	}
	if got := verifyTOTP(secret, "12345", now, 0); got != 0 {
		t.Fatal("accepted a short code")
	}
	u := otpauthURL(secret, "pedi@example.com")
	if !strings.HasPrefix(u, "otpauth://totp/Tarkk%20admin:pedi@example.com?") || !strings.Contains(u, "secret=") {
		t.Fatalf("url = %s", u)
	}
}
