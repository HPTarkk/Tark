package auth

import (
	"net/mail"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
)

const (
	MaxNameRunes = 50
	maxEmailLen  = 254
)

// NormalizeEmail trims and lower-cases an address and checks it is a plain
// ASCII address (no display name, no comments). ASCII only on purpose: it
// rules out look-alike characters in account emails.
func NormalizeEmail(raw string) (string, error) {
	e := strings.ToLower(strings.TrimSpace(raw))
	if e == "" || len(e) > maxEmailLen {
		return "", apperr.Validation("email", "missing or too long")
	}
	for i := 0; i < len(e); i++ {
		c := e[i]
		if c <= ' ' || c >= 0x7f {
			return "", apperr.Validation("email", "must be plain ASCII without spaces")
		}
	}
	addr, err := mail.ParseAddress(e)
	if err != nil || addr.Address != e || addr.Name != "" {
		return "", apperr.Validation("email", "not an email address")
	}
	local, domain, ok := strings.Cut(e, "@")
	if !ok || local == "" || len(local) > 64 || strings.Contains(domain, "@") ||
		!strings.Contains(domain, ".") || strings.HasPrefix(domain, ".") || strings.HasSuffix(domain, ".") ||
		strings.Contains(domain, "..") {
		return "", apperr.Validation("email", "not an email address")
	}
	return e, nil
}

// NormalizeName cleans a display name. Names are shown to other people in a
// room, so characters that can reorder or hide text (bidi overrides,
// invisible formatting) are refused. ZWNJ and ZWJ stay allowed: Persian
// writing and emoji need them.
func NormalizeName(raw string) (string, error) {
	if !utf8.ValidString(raw) {
		return "", apperr.Validation("name", "not valid UTF-8")
	}
	n := norm.NFC.String(raw)
	n = strings.Join(strings.FieldsFunc(n, unicode.IsSpace), " ")
	count := utf8.RuneCountInString(n)
	if count == 0 {
		return "", apperr.Validation("name", "empty")
	}
	if count > MaxNameRunes {
		return "", apperr.Validation("name", "too long")
	}
	for _, r := range n {
		switch {
		case r == '‌' || r == '‍':
		case unicode.IsControl(r), unicode.Is(unicode.Cf, r), unicode.Is(unicode.Co, r), r == utf8.RuneError:
			return "", apperr.Validation("name", "contains characters that cannot be shown")
		}
	}
	return n, nil
}

var avatarPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// NormalizeAvatar validates an avatar id. The set of avatars ships with the
// app, so the server checks the shape only; an app that does not know an
// id shows its fallback avatar.
func NormalizeAvatar(raw *string) (*string, error) {
	if raw == nil {
		return nil, nil
	}
	if !avatarPattern.MatchString(*raw) {
		return nil, apperr.Validation("avatarId", "must match ^[a-z0-9][a-z0-9_-]{0,31}$")
	}
	v := *raw
	return &v, nil
}

var installKeyPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)

// ValidInstallKey checks the X-Tark-Install-Key shape (32 bytes base64url).
func ValidInstallKey(k string) bool { return installKeyPattern.MatchString(k) }

// NormalizePlatform accepts the two platforms sign-in exists on.
func NormalizePlatform(p string) (string, error) {
	switch p {
	case "":
		return "", nil
	case "android", "ios":
		return p, nil
	}
	return "", apperr.Validation("platform", "must be android or ios")
}
