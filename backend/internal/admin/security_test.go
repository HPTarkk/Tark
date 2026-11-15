package admin

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

// Anyone who knows an admin's address can fill the address-wide sign-in
// counter. A browser that has signed in as that admin before must still get
// through, and a stranger must still be stopped.
func TestStrangerCannotLockAnAdminOut(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	temp, err := CreateAdmin(ctx, e.deps, "owner@example.com", "Owner", RoleOwner, "")
	if err != nil {
		t.Fatal(err)
	}
	ip := "203.0.113.7"
	e.srv.ClientIP = func(*http.Request) string { return ip }

	own := e.browser()
	_, secret := own.signIn("owner@example.com", temp, nil)
	if _, err := e.deps.Pool.Exec(ctx, `DELETE FROM admin_sessions`); err != nil {
		t.Fatal(err)
	}

	// The stranger guesses from one address after another.
	stranger := e.browser()
	try := func(b *browser, pw string) int {
		t.Helper()
		_, body := b.get("/login")
		code, _ := b.post("/login", url.Values{"pre": {field(t, body, "pre")}, "email": {"owner@example.com"}, "password": {pw}})
		return code
	}
	for i := range ruleLoginEmail.Max {
		ip = fmt.Sprintf("198.51.100.%d", i+1)
		if code := try(stranger, "not-the-password"); code != http.StatusUnauthorized {
			t.Fatalf("guess %d: %d", i, code)
		}
	}
	ip = "198.51.100.200"
	if code := try(stranger, temp); code != http.StatusTooManyRequests {
		t.Fatalf("the address-wide limit did not hold for an unknown browser: %d", code)
	}

	// The admin's own browser is not held back by it.
	ip = "203.0.113.7"
	if body, _ := own.signIn("owner@example.com", temp, secret); !strings.Contains(body, "password") {
		t.Fatalf("the admin's own browser did not get in:\n%s", body)
	}

	// The mark only skips the address-wide counter: wrong passwords from one
	// source are still counted, mark or not.
	if _, err := e.deps.Pool.Exec(ctx, `DELETE FROM admin_sessions`); err != nil {
		t.Fatal(err)
	}
	ip = "203.0.113.99"
	for i := range ruleLoginEmailIP.Max {
		if code := try(own, "not-the-password"); code != http.StatusUnauthorized {
			t.Fatalf("own wrong guess %d: %d", i, code)
		}
	}
	if code := try(own, temp); code != http.StatusTooManyRequests {
		t.Fatalf("the per-source limit did not hold: %d", code)
	}

	// A mark made for another admin is worth nothing.
	other, err := CreateAdmin(ctx, e.deps, "other@example.com", "Other", RoleOwner, "")
	if err != nil || other == "" {
		t.Fatal(err)
	}
	var ownerID, otherID string
	if err := e.deps.Pool.QueryRow(ctx, `SELECT (SELECT id FROM admin_users WHERE email = 'owner@example.com'),
		(SELECT id FROM admin_users WHERE email = 'other@example.com')`).Scan(&ownerID, &otherID); err != nil {
		t.Fatal(err)
	}
	r, _ := http.NewRequest(http.MethodGet, "/login", nil)
	r.AddCookie(&http.Cookie{Name: e.srv.knownCookieName(), Value: e.srv.knownToken(otherID)})
	if e.srv.knownBrowser(r, ownerID) || !e.srv.knownBrowser(r, otherID) || e.srv.knownBrowser(r, "") {
		t.Fatal("the known-browser mark is not tied to its admin")
	}
}

func TestOversizedFormIsRefused(t *testing.T) {
	e := setup(t)
	b := e.browser()
	_, body := b.get("/login")
	code, _ := b.post("/login", url.Values{"pre": {field(t, body, "pre")}, "email": {"a@example.com"},
		"password": {strings.Repeat("x", 2*maxBody)}})
	if code != http.StatusForbidden {
		t.Fatalf("a body over the limit was read: %d", code)
	}
}

func TestPanelHeadersAndCookieNames(t *testing.T) {
	e := setup(t)
	e.srv.Secure = true
	res, err := http.Get(e.ts.URL + "/login")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	for name, want := range map[string]string{
		"Cross-Origin-Opener-Policy":   "same-origin",
		"Cross-Origin-Resource-Policy": "same-origin",
		"X-Frame-Options":              "DENY",
		"X-Content-Type-Options":       "nosniff",
		"Referrer-Policy":              "no-referrer",
	} {
		if got := res.Header.Get(name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	if csp := res.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'none'") ||
		strings.Contains(csp, "unsafe") || !strings.Contains(csp, "frame-ancestors 'none'") {
		t.Errorf("CSP = %q", csp)
	}
	var pre *http.Cookie
	for _, c := range res.Cookies() {
		if c.Name == "__Host-tark_admin_pre" {
			pre = c
		}
	}
	if pre == nil || !pre.Secure || !pre.HttpOnly || pre.SameSite != http.SameSiteStrictMode || pre.Path != "/" || pre.Domain != "" {
		t.Fatalf("sign-in form cookie = %+v", pre)
	}
	if e.srv.cookieName() != "__Host-tark_admin" || e.srv.knownCookieName() != "__Host-tark_admin_known" {
		t.Fatal("production cookies must carry the __Host- prefix")
	}
}

func TestAdminNameAndEmailRefuseControlCharacters(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	for _, name := range []string{"Two\nLines", "Carriage\rReturn", "Nul\x00", "Esc\x1b[31m"} {
		if _, err := CreateAdmin(ctx, e.deps, "n@example.com", name, RoleViewer, ""); !errors.Is(err, errBadName) {
			t.Errorf("name %q: %v", name, err)
		}
	}
	for _, email := range []string{"a\tb@example.com", "a@exam\x00ple.com"} {
		if _, err := CreateAdmin(ctx, e.deps, email, "N", RoleViewer, ""); !errors.Is(err, errBadEmail) {
			t.Errorf("email %q: %v", email, err)
		}
	}
	if _, err := CreateAdmin(ctx, e.deps, "n@example.com", "نام فارسی", RoleViewer, ""); err != nil {
		t.Fatalf("an ordinary name was refused: %v", err)
	}
}

// A stolen session must not be a way to guess the password behind it.
func TestPasswordChangeGuessesAreLimited(t *testing.T) {
	e := setup(t)
	temp, err := CreateAdmin(context.Background(), e.deps, "a@example.com", "A", RoleOwner, "")
	if err != nil {
		t.Fatal(err)
	}
	b := e.browser()
	body, _ := b.signIn("a@example.com", temp, nil)
	csrf := field(t, body, "csrf")
	next := "a-long-new-passphrase"
	form := func(current string) url.Values {
		return url.Values{"csrf": {csrf}, "current": {current}, "new": {next}, "again": {next}}
	}
	for i := range rulePasswordChange.Max {
		if code, _ := b.post("/account/password", form("wrong-guess")); code != http.StatusUnauthorized {
			t.Fatalf("guess %d: %d", i, code)
		}
	}
	if code, _ := b.post("/account/password", form(temp)); code != http.StatusTooManyRequests {
		t.Fatalf("over the limit: %d", code)
	}
	// A right password before the limit clears the count.
	if err := e.deps.Limits.Reset(context.Background(), rulePasswordChange, adminID(t, e, "a@example.com")); err != nil {
		t.Fatal(err)
	}
	if code, _ := b.post("/account/password", form("wrong-guess")); code != http.StatusUnauthorized {
		t.Fatalf("after reset: %d", code)
	}
	if code, _ := b.post("/account/password", form(temp)); code != http.StatusOK {
		t.Fatalf("right password: %d", code)
	}
}

func adminID(t *testing.T, e *env, email string) string {
	t.Helper()
	var id string
	if err := e.deps.Pool.QueryRow(context.Background(), `SELECT id FROM admin_users WHERE email = $1`, email).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}
