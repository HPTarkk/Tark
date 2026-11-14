package google_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/google"
	"github.com/HPTarkk/Tark/backend/internal/testutil"
)

const aud = "tark-client.apps.googleusercontent.com"

func TestVerify(t *testing.T) {
	g := testutil.NewGoogleFake()
	defer g.Server.Close()
	v := google.NewVerifier([]string{aud}, g.Server.URL, nil)
	ctx := context.Background()

	good := testutil.Claims{Sub: "123", Email: "a@b.com", EmailVerified: true, Name: "A", Aud: aud, Nonce: "n"}
	c, err := v.Verify(ctx, g.Token(good))
	if err != nil {
		t.Fatal(err)
	}
	if c.Subject != "123" || !c.EmailVerified || c.Nonce != "n" {
		t.Fatalf("claims %+v", c)
	}

	bad := map[string]testutil.Claims{
		"wrong audience": {Sub: "1", Aud: "someone-else"},
		"wrong issuer":   {Sub: "1", Aud: aud, Iss: "https://evil.example"},
		"expired":        {Sub: "1", Aud: aud, Exp: time.Now().Add(-time.Hour)},
		"no subject":     {Aud: aud},
	}
	for name, claims := range bad {
		if _, err := v.Verify(ctx, g.Token(claims)); !errors.Is(err, google.ErrInvalid) {
			t.Errorf("%s: got %v", name, err)
		}
	}

	none := g.Raw(map[string]string{"alg": "none", "kid": g.Kid}, map[string]any{"sub": "1", "aud": aud})
	if _, err := v.Verify(ctx, none); !errors.Is(err, google.ErrInvalid) {
		t.Errorf("alg none accepted: %v", err)
	}
	tok := g.Token(good)
	if _, err := v.Verify(ctx, tok[:len(tok)-4]+"AAAA"); !errors.Is(err, google.ErrInvalid) {
		t.Errorf("bad signature accepted: %v", err)
	}
}

func TestUnreachableGoogle(t *testing.T) {
	g := testutil.NewGoogleFake()
	url := g.Server.URL
	g.Server.Close()
	v := google.NewVerifier([]string{aud}, url, nil)
	_, err := v.Verify(context.Background(), g.Token(testutil.Claims{Sub: "1", Aud: aud}))
	if !errors.Is(err, google.ErrKeysUnset) {
		t.Fatalf("expected ErrKeysUnset, got %v", err)
	}
}

// tokenInfoFake stands in for Google's tokeninfo endpoint: 200 with the
// token's sub and aud when the signature is good, 400 otherwise.
func tokenInfoFake(t *testing.T, g *testutil.GoogleFake, answer func(sub, aud string) (string, string)) *httptest.Server {
	t.Helper()
	inner := google.NewVerifier([]string{aud, "someone-else"}, g.Server.URL, nil)
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.RawQuery != "" {
			t.Errorf("the token must travel in a POST body, got %s %s", r.Method, r.URL)
		}
		raw := r.PostFormValue("id_token")
		c, err := inner.Verify(r.Context(), raw)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"invalid_token"}`))
			return
		}
		var payload struct {
			Aud string `json:"aud"`
		}
		seg, _ := base64.RawURLEncoding.DecodeString(strings.Split(raw, ".")[1])
		_ = json.Unmarshal(seg, &payload)
		sub, a := c.Subject, payload.Aud
		if answer != nil {
			sub, a = answer(sub, a)
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"sub": sub, "aud": a})
	}))
}

// refusingKeys answers the way Google does to a network it will not serve.
func refusingKeys() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
}

func TestTokenInfoWhenKeysAreRefused(t *testing.T) {
	g := testutil.NewGoogleFake()
	defer g.Server.Close()
	keys := refusingKeys()
	defer keys.Close()
	info := tokenInfoFake(t, g, nil)
	defer info.Close()
	ctx := context.Background()
	good := testutil.Claims{Sub: "123", Email: "a@b.com", EmailVerified: true, Name: "A", Aud: aud, Nonce: "n"}

	v := google.NewVerifier([]string{aud}, keys.URL, nil)
	v.UseTokenInfo(info.URL)
	c, err := v.Verify(ctx, g.Token(good))
	if err != nil {
		t.Fatal(err)
	}
	if c.Subject != "123" || c.Email != "a@b.com" || !c.EmailVerified || c.Nonce != "n" {
		t.Fatalf("claims %+v", c)
	}

	// Everything Verify checks by itself is still checked on this path.
	bad := map[string]testutil.Claims{
		"wrong audience": {Sub: "1", Aud: "someone-else"},
		"wrong issuer":   {Sub: "1", Aud: aud, Iss: "https://evil.example"},
		"expired":        {Sub: "1", Aud: aud, Exp: time.Now().Add(-time.Hour)},
		"no subject":     {Aud: aud},
	}
	for name, claims := range bad {
		if _, err := v.Verify(ctx, g.Token(claims)); !errors.Is(err, google.ErrInvalid) {
			t.Errorf("%s: got %v", name, err)
		}
	}
	tok := g.Token(good)
	if _, err := v.Verify(ctx, tok[:len(tok)-4]+"AAAA"); !errors.Is(err, google.ErrInvalid) {
		t.Errorf("bad signature accepted: %v", err)
	}
	// A token signed by someone who is not Google.
	other := testutil.NewGoogleFake()
	defer other.Server.Close()
	if _, err := v.Verify(ctx, other.Token(good)); !errors.Is(err, google.ErrInvalid) {
		t.Errorf("forged token accepted: %v", err)
	}

	// Without the fallback the old behaviour stays.
	plain := google.NewVerifier([]string{aud}, keys.URL, nil)
	if _, err := plain.Verify(ctx, g.Token(good)); !errors.Is(err, google.ErrKeysUnset) {
		t.Errorf("no fallback: got %v", err)
	}
}

func TestTokenInfoAnswerMustMatchTheToken(t *testing.T) {
	g := testutil.NewGoogleFake()
	defer g.Server.Close()
	keys := refusingKeys()
	defer keys.Close()
	ctx := context.Background()
	tok := g.Token(testutil.Claims{Sub: "123", Aud: aud})

	for name, answer := range map[string]func(string, string) (string, string){
		"other subject":  func(_, a string) (string, string) { return "999", a },
		"other audience": func(s, _ string) (string, string) { return s, "someone-else" },
		"empty":          func(_, _ string) (string, string) { return "", "" },
	} {
		info := tokenInfoFake(t, g, answer)
		v := google.NewVerifier([]string{aud}, keys.URL, nil)
		v.UseTokenInfo(info.URL)
		if _, err := v.Verify(ctx, tok); !errors.Is(err, google.ErrInvalid) {
			t.Errorf("%s: got %v", name, err)
		}
		info.Close()
	}
}

func TestTokenInfoUnreachable(t *testing.T) {
	g := testutil.NewGoogleFake()
	defer g.Server.Close()
	keys := refusingKeys()
	defer keys.Close()
	down := refusingKeys()
	defer down.Close()
	v := google.NewVerifier([]string{aud}, keys.URL, nil)
	v.UseTokenInfo(down.URL)
	// Not "invalid": the user did nothing wrong, the server could not check.
	if _, err := v.Verify(context.Background(), g.Token(testutil.Claims{Sub: "1", Aud: aud})); !errors.Is(err, google.ErrKeysUnset) {
		t.Fatalf("expected ErrKeysUnset, got %v", err)
	}
}

func TestKeysArePreferredOverTokenInfo(t *testing.T) {
	g := testutil.NewGoogleFake()
	defer g.Server.Close()
	asked := false
	info := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { asked = true }))
	defer info.Close()
	v := google.NewVerifier([]string{aud}, g.Server.URL, nil)
	v.UseTokenInfo(info.URL)
	if _, err := v.Verify(context.Background(), g.Token(testutil.Claims{Sub: "1", Aud: aud})); err != nil {
		t.Fatal(err)
	}
	if asked {
		t.Fatal("tokeninfo was asked although the keys were available")
	}
}
