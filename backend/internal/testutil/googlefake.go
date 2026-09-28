// Package testutil holds fakes shared by tests.
package testutil

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"time"
)

// GoogleFake publishes a JWKS and signs ID tokens with the matching key,
// so tests exercise the real verifier.
type GoogleFake struct {
	Server *httptest.Server
	key    *rsa.PrivateKey
	Kid    string
}

func NewGoogleFake() *GoogleFake {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	g := &GoogleFake{key: key, Kid: "test-kid"}
	g.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b64 := base64.RawURLEncoding
		w.Header().Set("Cache-Control", "public, max-age=3600")
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kty": "RSA", "alg": "RS256", "use": "sig", "kid": g.Kid,
			"n": b64.EncodeToString(key.N.Bytes()),
			"e": b64.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
		}}})
	}))
	return g
}

// Claims are the ID token fields tests usually vary.
type Claims struct {
	Sub, Email, Name, Aud, Nonce, Iss string
	EmailVerified                     bool
	Exp                               time.Time
}

func (g *GoogleFake) Token(c Claims) string {
	if c.Iss == "" {
		c.Iss = "https://accounts.google.com"
	}
	if c.Exp.IsZero() {
		c.Exp = time.Now().Add(time.Hour)
	}
	header := map[string]string{"alg": "RS256", "kid": g.Kid, "typ": "JWT"}
	payload := map[string]any{
		"iss": c.Iss, "aud": c.Aud, "azp": c.Aud, "sub": c.Sub, "email": c.Email,
		"email_verified": c.EmailVerified, "name": c.Name, "nonce": c.Nonce,
		"iat": time.Now().Add(-time.Minute).Unix(), "exp": c.Exp.Unix(),
	}
	return g.sign(header, payload)
}

// Raw signs any header and payload, for malformed-token tests.
func (g *GoogleFake) Raw(header map[string]string, payload map[string]any) string {
	return g.sign(header, payload)
}

func (g *GoogleFake) sign(header map[string]string, payload map[string]any) string {
	b64 := base64.RawURLEncoding
	h, _ := json.Marshal(header)
	p, _ := json.Marshal(payload)
	signed := b64.EncodeToString(h) + "." + b64.EncodeToString(p)
	digest := sha256.Sum256([]byte(signed))
	sig, err := rsa.SignPKCS1v15(rand.Reader, g.key, crypto.SHA256, digest[:])
	if err != nil {
		panic(err)
	}
	return signed + "." + b64.EncodeToString(sig)
}
