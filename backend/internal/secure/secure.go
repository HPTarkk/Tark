// Package secure holds the small cryptographic building blocks the rest of
// the backend shares: random secrets, keyed lookup hashes and authenticated
// encryption for the few values that must be stored recoverably.
//
// Everything here is standard library or golang.org/x/crypto. Nothing
// rolls its own primitive.
package secure

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"math/big"
)

// KeySize is the size of every symmetric key the backend is configured with.
const KeySize = 32

var b64 = base64.RawURLEncoding

// RandomToken returns n random bytes, base64url without padding. Used for
// refresh tokens, flow ids, tickets and link tokens: all of them are high
// entropy, so a fast keyed hash is enough to store them (see Hasher).
func RandomToken(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		// crypto/rand does not fail on supported platforms; if it ever does,
		// carrying on with a weak secret would be worse than stopping.
		panic(fmt.Sprintf("secure: crypto/rand failed: %v", err))
	}
	return b64.EncodeToString(buf)
}

// RandomDigits returns a uniformly random string of n decimal digits.
func RandomDigits(n int) string {
	out := make([]byte, n)
	ten := big.NewInt(10)
	for i := range out {
		d, err := rand.Int(rand.Reader, ten)
		if err != nil {
			panic(fmt.Sprintf("secure: crypto/rand failed: %v", err))
		}
		out[i] = byte('0' + d.Int64())
	}
	return string(out)
}

// Hasher computes keyed lookup hashes (HMAC-SHA256). It is used wherever a
// value must be found again but should not be readable from a database
// dump: token lookups, verification codes, rate-limit keys (so raw IPs and
// emails are never stored there) and idempotency request fingerprints.
//
// Domain separation: every call names what it hashes, so a hash of one kind
// can never be replayed as another.
type Hasher struct {
	key []byte
}

func NewHasher(key []byte) (*Hasher, error) {
	if len(key) != KeySize {
		return nil, fmt.Errorf("secure: lookup key must be %d bytes, got %d", KeySize, len(key))
	}
	return &Hasher{key: append([]byte(nil), key...)}, nil
}

func (h *Hasher) Sum(domain string, parts ...string) []byte {
	mac := hmac.New(sha256.New, h.key)
	writeLenPrefixed(mac, domain)
	for _, p := range parts {
		writeLenPrefixed(mac, p)
	}
	return mac.Sum(nil)
}

// SumHex is Sum as a string, for text keys (rate limits).
func (h *Hasher) SumString(domain string, parts ...string) string {
	return b64.EncodeToString(h.Sum(domain, parts...))
}

type byteWriter interface{ Write([]byte) (int, error) }

// writeLenPrefixed avoids ambiguity between ("ab","c") and ("a","bc").
func writeLenPrefixed(w byteWriter, s string) {
	var n [4]byte
	l := len(s)
	n[0], n[1], n[2], n[3] = byte(l>>24), byte(l>>16), byte(l>>8), byte(l)
	_, _ = w.Write(n[:])
	_, _ = w.Write([]byte(s))
}

// Equal compares two MACs in constant time.
func Equal(a, b []byte) bool {
	return subtle.ConstantTimeCompare(a, b) == 1
}

// Sealer encrypts values that the backend must be able to read back later,
// such as Bazaar purchase tokens (needed to re-check a subscription in the
// background) and queued emails. AES-256-GCM with a random nonce; the
// associated data binds a ciphertext to the row it belongs to, so a value
// cannot be moved to another row and still decrypt.
type Sealer struct {
	aead cipher.AEAD
}

// sealVersion prefixes every ciphertext so the key can be rotated later
// without guessing which key produced a stored value.
const sealVersion byte = 1

func NewSealer(key []byte) (*Sealer, error) {
	if len(key) != KeySize {
		return nil, fmt.Errorf("secure: data key must be %d bytes, got %d", KeySize, len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Sealer{aead: aead}, nil
}

func (s *Sealer) Seal(plaintext, associated []byte) []byte {
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic(fmt.Sprintf("secure: crypto/rand failed: %v", err))
	}
	out := make([]byte, 0, 1+len(nonce)+len(plaintext)+s.aead.Overhead())
	out = append(out, sealVersion)
	out = append(out, nonce...)
	return s.aead.Seal(out, nonce, plaintext, associated)
}

var ErrOpen = errors.New("secure: ciphertext rejected")

func (s *Sealer) Open(ciphertext, associated []byte) ([]byte, error) {
	ns := s.aead.NonceSize()
	if len(ciphertext) < 1+ns+s.aead.Overhead() || ciphertext[0] != sealVersion {
		return nil, ErrOpen
	}
	plain, err := s.aead.Open(nil, ciphertext[1:1+ns], ciphertext[1+ns:], associated)
	if err != nil {
		return nil, ErrOpen
	}
	return plain, nil
}

// DecodeKey parses a base64 (standard or URL, padded or not) key and checks
// its length.
func DecodeKey(name, value string) ([]byte, error) {
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(value); err == nil {
			if len(b) != KeySize {
				return nil, fmt.Errorf("%s must decode to %d bytes, got %d", name, KeySize, len(b))
			}
			return b, nil
		}
	}
	return nil, fmt.Errorf("%s is not valid base64", name)
}

// B64 encodes bytes the way every token on the wire is encoded.
func B64(b []byte) string { return b64.EncodeToString(b) }

// UnB64 decodes base64url without padding.
func UnB64(s string) ([]byte, error) { return b64.DecodeString(s) }

// NewUUID returns a random (version 4) UUID string.
func NewUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(fmt.Sprintf("secure: crypto/rand failed: %v", err))
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
