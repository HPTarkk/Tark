package admin

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"time"
)

// TOTP per RFC 6238 with the parameters every authenticator app supports:
// SHA-1, 6 digits, 30-second steps. One step of clock drift either way is
// accepted.
const (
	totpStep   = 30
	totpDigits = 6
	totpSkew   = 1
)

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

func newTOTPSecret() []byte {
	s := make([]byte, 20)
	if _, err := rand.Read(s); err != nil {
		panic(err)
	}
	return s
}

func totpCode(secret []byte, step int64) string {
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], uint64(step))
	mac := hmac.New(sha1.New, secret)
	mac.Write(msg[:])
	sum := mac.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	v := binary.BigEndian.Uint32(sum[off:off+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", v%1_000_000)
}

// verifyTOTP returns the matching time step, or 0. A step at or before
// lastStep is refused, so an observed code cannot be replayed.
func verifyTOTP(secret []byte, code string, now time.Time, lastStep int64) int64 {
	if len(code) != totpDigits {
		return 0
	}
	cur := now.Unix() / totpStep
	for d := -totpSkew; d <= totpSkew; d++ {
		step := cur + int64(d)
		if step <= lastStep {
			continue
		}
		if subtle.ConstantTimeCompare([]byte(totpCode(secret, step)), []byte(code)) == 1 {
			return step
		}
	}
	return 0
}

// otpauthURL is what authenticator apps accept as a link or QR code.
func otpauthURL(secret []byte, account string) string {
	v := url.Values{}
	v.Set("secret", b32.EncodeToString(secret))
	v.Set("issuer", "Tarkk admin")
	v.Set("algorithm", "SHA1")
	v.Set("digits", "6")
	v.Set("period", "30")
	return "otpauth://totp/" + url.PathEscape("Tarkk admin:"+account) + "?" + v.Encode()
}

// groupKey formats the secret for typing: groups of four.
func groupKey(secret []byte) string {
	s := b32.EncodeToString(secret)
	out := ""
	for i := 0; i < len(s); i += 4 {
		if i > 0 {
			out += " "
		}
		out += s[i:min(i+4, len(s))]
	}
	return out
}
