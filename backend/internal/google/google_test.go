package google_test

import (
	"context"
	"errors"
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
