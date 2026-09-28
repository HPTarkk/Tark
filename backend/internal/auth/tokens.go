package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/secure"
)

// Access tokens are short-lived and HMAC-signed: `tat1.<payload>.<mac>`.
// They only name a session; the session row is checked on every request,
// so revoking a session cuts off its access token at once rather than when
// the token expires.
const accessPrefix = "tat1"

// Refresh tokens are opaque random strings, stored only as lookup hashes.
const refreshPrefix = "trt1_"

type accessClaims struct {
	SID string `json:"sid"`
	UID string `json:"uid"`
	Exp int64  `json:"exp"`
}

var errBadToken = errors.New("auth: bad access token")

type tokenSigner struct {
	key []byte
	now func() time.Time
}

func (s tokenSigner) mac(msg string) []byte {
	m := hmac.New(sha256.New, s.key)
	m.Write([]byte(msg))
	return m.Sum(nil)
}

func (s tokenSigner) issue(sessionID, userID string, ttl time.Duration) (string, time.Time) {
	exp := s.now().Add(ttl).Truncate(time.Second)
	body, _ := json.Marshal(accessClaims{SID: sessionID, UID: userID, Exp: exp.Unix()})
	signed := accessPrefix + "." + secure.B64(body)
	return signed + "." + secure.B64(s.mac(signed)), exp
}

func (s tokenSigner) parse(token string) (accessClaims, error) {
	if len(token) > 512 {
		return accessClaims{}, errBadToken
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] != accessPrefix {
		return accessClaims{}, errBadToken
	}
	sig, err := secure.UnB64(parts[2])
	if err != nil || !secure.Equal(sig, s.mac(parts[0]+"."+parts[1])) {
		return accessClaims{}, errBadToken
	}
	body, err := secure.UnB64(parts[1])
	if err != nil {
		return accessClaims{}, errBadToken
	}
	var c accessClaims
	if err := json.Unmarshal(body, &c); err != nil || c.SID == "" || c.UID == "" {
		return accessClaims{}, errBadToken
	}
	if !s.now().Before(time.Unix(c.Exp, 0)) {
		return accessClaims{}, errBadToken
	}
	return c, nil
}

func newRefreshToken() string { return refreshPrefix + secure.RandomToken(32) }
