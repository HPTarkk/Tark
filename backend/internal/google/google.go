// Package google verifies Google ID tokens the way Google documents it:
// RS256 signature against Google's published keys, issuer, audience (one of
// our own client ids), expiry, and a verified email. Nothing the app sends
// next to the token is trusted; name and email come from the token only.
//
// Google's keys are cached and kept after a failed refresh, because reaching
// googleapis.com from Iran can be disrupted for a while. Keys rotate every
// few weeks and overlap, so a cache a few days old still verifies.
//
// Some networks cannot fetch the keys at all (Google answers 403 to Iranian
// data centres). When no usable keys are held, the signature is checked by
// Google's own tokeninfo endpoint instead, which is reachable from there. Only
// its verdict on the signature is used: every claim is still read from the
// token and checked here.
package google

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Claims are the parts of a verified ID token the backend uses.
type Claims struct {
	Subject       string
	Email         string
	EmailVerified bool
	Name          string
	Nonce         string
	ExpiresAt     time.Time
}

var (
	ErrInvalid   = errors.New("google: id token invalid")
	ErrKeysUnset = errors.New("google: signing keys unavailable")
)

type Verifier struct {
	clientIDs map[string]struct{}
	jwksURL   string
	// tokenInfoURL, when set, is asked to check the signature while no
	// signing keys can be fetched.
	tokenInfoURL string
	http         *http.Client
	now          func() time.Time

	mu          sync.Mutex
	keys        map[string]*rsa.PublicKey
	fetchedAt   time.Time
	freshUntil  time.Time
	lastAttempt time.Time
}

// maxStale is how long cached keys are used when Google cannot be reached.
const maxStale = 7 * 24 * time.Hour

// clockSkew tolerates phones and servers that are slightly apart.
const clockSkew = 2 * time.Minute

func NewVerifier(clientIDs []string, jwksURL string, client *http.Client) *Verifier {
	ids := make(map[string]struct{}, len(clientIDs))
	for _, id := range clientIDs {
		ids[id] = struct{}{}
	}
	if client == nil {
		client = &http.Client{Timeout: 8 * time.Second}
	}
	return &Verifier{clientIDs: ids, jwksURL: jwksURL, http: client, now: time.Now}
}

// UseTokenInfo makes the verifier ask Google's tokeninfo endpoint (url) to
// check a token's signature whenever the signing keys cannot be fetched. Call
// it before the verifier is used. An empty url switches it off.
func (v *Verifier) UseTokenInfo(url string) { v.tokenInfoURL = url }

// Verify checks raw and returns its claims.
func (v *Verifier) Verify(ctx context.Context, raw string) (*Claims, error) {
	if len(raw) > 8192 {
		return nil, fmt.Errorf("%w: too long", ErrInvalid)
	}
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("%w: not a JWT", ErrInvalid)
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
		Typ string `json:"typ"`
	}
	if err := decodeSegment(parts[0], &header); err != nil {
		return nil, fmt.Errorf("%w: header", ErrInvalid)
	}
	// The algorithm is fixed, never taken from the token, so "none" or an
	// HMAC confusion attack cannot work.
	if header.Alg != "RS256" || header.Kid == "" {
		return nil, fmt.Errorf("%w: unexpected alg", ErrInvalid)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, fmt.Errorf("%w: signature encoding", ErrInvalid)
	}
	key, err := v.key(ctx, header.Kid)
	switch {
	case err == nil:
		digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
		if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig); err != nil {
			return nil, fmt.Errorf("%w: signature", ErrInvalid)
		}
	case errors.Is(err, ErrKeysUnset) && v.tokenInfoURL != "":
		if err := v.askGoogle(ctx, raw); err != nil {
			return nil, err
		}
	default:
		return nil, err
	}

	var c struct {
		Iss           string          `json:"iss"`
		Aud           json.RawMessage `json:"aud"`
		Azp           string          `json:"azp"`
		Sub           string          `json:"sub"`
		Email         string          `json:"email"`
		EmailVerified json.RawMessage `json:"email_verified"`
		Name          string          `json:"name"`
		Nonce         string          `json:"nonce"`
		Exp           json.Number     `json:"exp"`
		Iat           json.Number     `json:"iat"`
	}
	if err := decodeSegment(parts[1], &c); err != nil {
		return nil, fmt.Errorf("%w: payload", ErrInvalid)
	}
	if c.Iss != "accounts.google.com" && c.Iss != "https://accounts.google.com" {
		return nil, fmt.Errorf("%w: issuer", ErrInvalid)
	}
	if !v.audienceOK(c.Aud) {
		return nil, fmt.Errorf("%w: audience", ErrInvalid)
	}
	exp, err1 := c.Exp.Int64()
	iat, err2 := c.Iat.Int64()
	if err1 != nil || err2 != nil {
		return nil, fmt.Errorf("%w: times", ErrInvalid)
	}
	now := v.now()
	expires := time.Unix(exp, 0)
	if now.After(expires.Add(clockSkew)) {
		return nil, fmt.Errorf("%w: expired", ErrInvalid)
	}
	if time.Unix(iat, 0).After(now.Add(clockSkew)) {
		return nil, fmt.Errorf("%w: issued in the future", ErrInvalid)
	}
	if c.Sub == "" || len(c.Sub) > 255 {
		return nil, fmt.Errorf("%w: subject", ErrInvalid)
	}
	return &Claims{
		Subject:       c.Sub,
		Email:         c.Email,
		EmailVerified: boolClaim(c.EmailVerified),
		Name:          c.Name,
		Nonce:         c.Nonce,
		ExpiresAt:     expires,
	}, nil
}

// askGoogle has Google itself check raw's signature. Google answers 200 only
// for a token it signed that has not expired, and 400 for anything else. The
// claims in its answer are compared with the token's, never used in place of
// them, so the checks in Verify stay the only ones that decide.
func (v *Verifier) askGoogle(ctx context.Context, raw string) error {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	// In the body, not the address: addresses end up in logs along the way.
	body := strings.NewReader("id_token=" + url.QueryEscape(raw))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, v.tokenInfoURL, body)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrKeysUnset, err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := v.http.Do(req)
	if err != nil {
		return fmt.Errorf("%w: tokeninfo: %v", ErrKeysUnset, err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusBadRequest:
		return fmt.Errorf("%w: refused by Google", ErrInvalid)
	case resp.StatusCode != http.StatusOK:
		return fmt.Errorf("%w: tokeninfo status %d", ErrKeysUnset, resp.StatusCode)
	}
	var info struct {
		Sub string `json:"sub"`
		Aud string `json:"aud"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&info); err != nil {
		return fmt.Errorf("%w: tokeninfo answer", ErrKeysUnset)
	}
	var own struct {
		Sub string          `json:"sub"`
		Aud json.RawMessage `json:"aud"`
	}
	parts := strings.Split(raw, ".")
	if err := decodeSegment(parts[1], &own); err != nil {
		return fmt.Errorf("%w: payload", ErrInvalid)
	}
	var aud string
	_ = json.Unmarshal(own.Aud, &aud)
	// An answer about some other token is not an answer about this one.
	if info.Sub == "" || info.Sub != own.Sub || info.Aud == "" || info.Aud != aud {
		return fmt.Errorf("%w: tokeninfo answer does not match the token", ErrInvalid)
	}
	return nil
}

func (v *Verifier) audienceOK(raw json.RawMessage) bool {
	var single string
	if json.Unmarshal(raw, &single) == nil {
		_, ok := v.clientIDs[single]
		return ok
	}
	// Google issues a single audience; a list is accepted only if every
	// entry is ours.
	var list []string
	if json.Unmarshal(raw, &list) != nil || len(list) == 0 {
		return false
	}
	for _, a := range list {
		if _, ok := v.clientIDs[a]; !ok {
			return false
		}
	}
	return true
}

// email_verified has been seen both as a JSON bool and as a string.
func boolClaim(raw json.RawMessage) bool {
	var b bool
	if json.Unmarshal(raw, &b) == nil {
		return b
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s == "true"
	}
	return false
}

func decodeSegment(seg string, into any) error {
	b, err := base64.RawURLEncoding.DecodeString(seg)
	if err != nil {
		return err
	}
	dec := json.NewDecoder(strings.NewReader(string(b)))
	dec.UseNumber()
	return dec.Decode(into)
}

func (v *Verifier) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	v.mu.Lock()
	defer v.mu.Unlock()

	now := v.now()
	if k, ok := v.keys[kid]; ok && now.Before(v.freshUntil) {
		return k, nil
	}
	// Refresh when the cache is stale or the kid is new (Google rotated),
	// but at most once every 30 seconds so unknown kids cannot turn us into
	// a request amplifier against Google.
	if now.Sub(v.lastAttempt) > 30*time.Second {
		v.lastAttempt = now
		if err := v.refresh(ctx); err != nil && v.keys == nil {
			return nil, fmt.Errorf("%w: %v", ErrKeysUnset, err)
		}
	}
	if k, ok := v.keys[kid]; ok && now.Sub(v.fetchedAt) < maxStale {
		return k, nil
	}
	if v.keys == nil || now.Sub(v.fetchedAt) >= maxStale {
		return nil, ErrKeysUnset
	}
	return nil, fmt.Errorf("%w: unknown key id", ErrInvalid)
}

func (v *Verifier) refresh(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.jwksURL, nil)
	if err != nil {
		return err
	}
	resp, err := v.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("jwks status %d", resp.StatusCode)
	}
	var set struct {
		Keys []struct {
			Kty string `json:"kty"`
			Kid string `json:"kid"`
			Alg string `json:"alg"`
			Use string `json:"use"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&set); err != nil {
		return err
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" || (k.Alg != "" && k.Alg != "RS256") || (k.Use != "" && k.Use != "sig") {
			continue
		}
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil || len(e) > 4 {
			continue
		}
		pub := &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
		if pub.N.BitLen() < 2048 {
			continue
		}
		keys[k.Kid] = pub
	}
	if len(keys) == 0 {
		return errors.New("jwks has no usable keys")
	}
	now := v.now()
	v.keys = keys
	v.fetchedAt = now
	v.freshUntil = now.Add(cacheFor(resp.Header.Get("Cache-Control")))
	return nil
}

// cacheFor honours Cache-Control max-age (Google sends several hours),
// bounded to a sensible range.
func cacheFor(cc string) time.Duration {
	for _, part := range strings.Split(cc, ",") {
		part = strings.TrimSpace(part)
		if v, ok := strings.CutPrefix(part, "max-age="); ok {
			if s, err := strconv.Atoi(v); err == nil {
				d := time.Duration(s) * time.Second
				return min(max(d, 5*time.Minute), 24*time.Hour)
			}
		}
	}
	return time.Hour
}
