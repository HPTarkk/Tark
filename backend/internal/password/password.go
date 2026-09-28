// Package password hashes and checks account passwords with Argon2id.
//
// The input to Argon2id is HMAC-SHA256(pepper, password), where the pepper
// is a server secret that never enters the database. A database dump alone
// is therefore not enough to start guessing passwords offline.
//
// Hashing is memory-hard on purpose, which also makes it the easiest thing
// to abuse for denial of service. A semaphore bounds how many hashes run at
// once, so a flood of logins queues instead of exhausting memory.
package password

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
	"golang.org/x/text/unicode/norm"
)

// Params are the Argon2id cost settings. Stored with every hash, so they can
// be raised later and old hashes upgraded on the next successful login.
type Params struct {
	MemoryKiB   uint32
	Iterations  uint32
	Parallelism uint8
}

// DefaultParams follow OWASP's Argon2id guidance (m=46 MiB, t=1, p=1),
// which keeps one hash around tens of milliseconds on a small VPS.
var DefaultParams = Params{MemoryKiB: 46 * 1024, Iterations: 1, Parallelism: 1}

const (
	saltLen = 16
	keyLen  = 32

	MinLength = 8
	// MaxLength bounds work per request. 128 characters is far beyond any
	// passphrase people type and keeps the HMAC input small.
	MaxLength = 128
)

var (
	ErrMismatch = errors.New("password: mismatch")
	ErrFormat   = errors.New("password: unrecognised hash format")
)

type Hasher struct {
	pepper []byte
	params Params
	slots  chan struct{}
	dummy  string
}

// New builds a Hasher. concurrency bounds simultaneous hashes.
func New(pepper []byte, params Params, concurrency int) (*Hasher, error) {
	if len(pepper) < 32 {
		return nil, errors.New("password: pepper must be at least 32 bytes")
	}
	if concurrency < 1 {
		concurrency = 1
	}
	h := &Hasher{
		pepper: append([]byte(nil), pepper...),
		params: params,
		slots:  make(chan struct{}, concurrency),
	}
	dummy, err := h.hash(context.Background(), "tark-dummy-password-for-timing")
	if err != nil {
		return nil, err
	}
	h.dummy = dummy
	return h, nil
}

// Hash returns the PHC-formatted Argon2id hash of pw.
func (h *Hasher) Hash(ctx context.Context, pw string) (string, error) {
	return h.hash(ctx, pw)
}

func (h *Hasher) hash(ctx context.Context, pw string) (string, error) {
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key, err := h.derive(ctx, pw, salt, h.params)
	if err != nil {
		return "", err
	}
	enc := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, h.params.MemoryKiB, h.params.Iterations, h.params.Parallelism,
		enc.EncodeToString(salt), enc.EncodeToString(key)), nil
}

// Verify checks pw against encoded. needsRehash reports that the hash was
// made with weaker settings than the current ones.
func (h *Hasher) Verify(ctx context.Context, pw, encoded string) (needsRehash bool, err error) {
	params, salt, want, err := parse(encoded)
	if err != nil {
		return false, err
	}
	got, err := h.derive(ctx, pw, salt, params)
	if err != nil {
		return false, err
	}
	if subtle.ConstantTimeCompare(got, want) != 1 {
		return false, ErrMismatch
	}
	return params != h.params, nil
}

// VerifyDummy spends the same time as a real check. Called when there is no
// account (or no password) to check against, so response time does not
// reveal whether an email is registered.
func (h *Hasher) VerifyDummy(ctx context.Context, pw string) {
	_, _ = h.Verify(ctx, pw, h.dummy)
}

func (h *Hasher) derive(ctx context.Context, pw string, salt []byte, p Params) ([]byte, error) {
	select {
	case h.slots <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	defer func() { <-h.slots }()

	mac := hmac.New(sha256.New, h.pepper)
	mac.Write([]byte(Normalize(pw)))
	return argon2.IDKey(mac.Sum(nil), salt, p.Iterations, p.MemoryKiB, p.Parallelism, keyLen), nil
}

func parse(encoded string) (Params, []byte, []byte, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return Params{}, nil, nil, ErrFormat
	}
	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return Params{}, nil, nil, ErrFormat
	}
	var p Params
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &p.MemoryKiB, &p.Iterations, &p.Parallelism); err != nil {
		return Params{}, nil, nil, ErrFormat
	}
	// Refuse absurd stored parameters rather than letting a tampered row
	// allocate gigabytes.
	if p.MemoryKiB < 8*1024 || p.MemoryKiB > 1024*1024 || p.Iterations < 1 || p.Iterations > 20 || p.Parallelism < 1 || p.Parallelism > 16 {
		return Params{}, nil, nil, ErrFormat
	}
	enc := base64.RawStdEncoding
	salt, err := enc.DecodeString(parts[4])
	if err != nil || len(salt) < 8 {
		return Params{}, nil, nil, ErrFormat
	}
	key, err := enc.DecodeString(parts[5])
	if err != nil || len(key) < 16 {
		return Params{}, nil, nil, ErrFormat
	}
	return p, salt, key, nil
}

// Normalize applies NFKC so the same passphrase typed on different
// keyboards (for example Persian vs Arabic presentation forms) matches.
func Normalize(pw string) string {
	return norm.NFKC.String(pw)
}

// Problem explains why a new password is refused, or "" when it is fine.
// The codes are stable; the app shows its own wording for each.
func Problem(pw, email string) string {
	if !utf8.ValidString(pw) {
		return "password_invalid"
	}
	n := utf8.RuneCountInString(Normalize(pw))
	if n < MinLength {
		return "password_too_short"
	}
	if n > MaxLength {
		return "password_too_long"
	}
	for _, r := range pw {
		if unicode.IsControl(r) {
			return "password_invalid"
		}
	}
	lower := strings.ToLower(Normalize(pw))
	if _, common := commonPasswords[lower]; common {
		return "password_too_common"
	}
	if allSame(lower) {
		return "password_too_common"
	}
	if email != "" {
		local, _, _ := strings.Cut(strings.ToLower(email), "@")
		if lower == strings.ToLower(email) || (len(local) >= 4 && lower == local) {
			return "password_matches_email"
		}
	}
	return ""
}

func allSame(s string) bool {
	var first rune
	for i, r := range s {
		if i == 0 {
			first = r
			continue
		}
		if r != first {
			return false
		}
	}
	return true
}

// commonPasswords is a short list of the passwords that top every breach
// corpus. It is not a substitute for a breached-password service; it only
// stops the worst choices.
var commonPasswords = func() map[string]struct{} {
	list := []string{
		"12345678", "123456789", "1234567890", "12345678910", "password", "password1",
		"password123", "qwerty123", "qwertyuiop", "11111111", "00000000", "iloveyou",
		"abc12345", "abcd1234", "1q2w3e4r", "1q2w3e4r5t", "qwerty12", "asdfghjk",
		"asdfghjkl", "zxcvbnm1", "87654321", "12341234", "11223344", "123123123",
		"passw0rd", "p@ssw0rd", "p@ssword", "welcome1", "sunshine", "princess",
		"football", "baseball", "superman", "dragon12", "monkey12", "letmein1",
		"trustno1", "whatever", "starwars", "computer", "internet", "google123",
		"iran1234", "tehran123", "12qwaszx", "q1w2e3r4", "a1b2c3d4", "admin123",
		"changeme", "default1", "tark1234", "tarkk123",
	}
	m := make(map[string]struct{}, len(list))
	for _, p := range list {
		m[p] = struct{}{}
	}
	return m
}()
