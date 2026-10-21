package admin

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

// Settings holds the theme, the language, the password change and the
// other sign-ins, for every role.
func TestSettings(t *testing.T) {
	e := setup(t)
	temp, err := CreateAdmin(context.Background(), e.deps, "viewer@example.com", "Vee", RoleViewer, "")
	if err != nil {
		t.Fatal(err)
	}
	b := e.browser()
	body, secret := b.signIn("viewer@example.com", temp, nil)
	if code, _ := b.post("/account/password", url.Values{"csrf": {field(t, body, "csrf")}, "current": {temp},
		"new": {"viewer-passphrase-1"}, "again": {"viewer-passphrase-1"}}); code != http.StatusOK {
		t.Fatalf("first password change: %d", code)
	}

	code, body := b.get("/settings")
	if code != http.StatusOK || !strings.Contains(body, `action="/settings/theme"`) || !strings.Contains(body, `href="/settings" class="on"`) {
		t.Fatalf("settings: %d\n%s", code, body)
	}
	if strings.Contains(body, "data-theme=") || !strings.Contains(body, `value="system" checked`) {
		t.Fatal("a fresh browser should follow the system theme")
	}
	// The language moved here from the menu.
	if strings.Contains(body, `href="/lang/`) {
		t.Fatal("the menu still has the language switch")
	}
	csrf := field(t, body, "csrf")

	// Theme: saved in this browser, and on every page, the sign-in pages too.
	if code, body := b.post("/settings/theme", url.Values{"csrf": {csrf}, "theme": {"dark"}}); code != http.StatusOK ||
		!strings.Contains(body, `data-theme="dark"`) || !strings.Contains(body, "Theme saved.") || !strings.Contains(body, `value="dark" checked`) {
		t.Fatalf("dark theme: %d\n%s", code, body)
	}
	if _, body := b.get("/"); !strings.Contains(body, `data-theme="dark"`) {
		t.Fatal("theme not kept on other pages")
	}
	if code, _ := b.post("/settings/theme", url.Values{"csrf": {csrf}, "theme": {"neon"}}); code != http.StatusBadRequest {
		t.Fatalf("unknown theme: %d", code)
	}
	if code, _ := b.post("/settings/theme", url.Values{"theme": {"light"}}); code != http.StatusForbidden {
		t.Fatalf("theme without csrf: %d", code)
	}
	if _, body := b.post("/settings/theme", url.Values{"csrf": {csrf}, "theme": {"system"}}); strings.Contains(body, "data-theme=") {
		t.Fatal("system theme still forced")
	}

	// Language.
	if _, body := b.post("/settings/language", url.Values{"csrf": {csrf}, "lang": {"fa"}}); !strings.Contains(body, `<html lang="fa" dir="rtl">`) ||
		!strings.Contains(body, tr(langFA, "settings.saved.language")) {
		t.Fatalf("language not saved:\n%s", body)
	}
	if code, _ := b.post("/settings/language", url.Values{"csrf": {csrf}, "lang": {"de"}}); code != http.StatusBadRequest {
		t.Fatalf("unknown language: %d", code)
	}
	b.post("/settings/language", url.Values{"csrf": {csrf}, "lang": {"en"}})

	// The old password address now opens Settings.
	if _, body := b.get("/account/password"); !strings.Contains(body, `id="password"`) {
		t.Fatal("/account/password does not lead to Settings")
	}

	// A second browser shows up as another sign-in.
	other := e.browser()
	other.signIn("viewer@example.com", "viewer-passphrase-1", secret)
	if _, body := b.get("/settings"); !strings.Contains(body, "on 1 other browsers") || !strings.Contains(body, `action="/settings/sessions"`) {
		t.Fatalf("other browser not counted:\n%s", body)
	}

	// A refused change stays on Settings with the reason.
	if code, body := b.post("/account/password", url.Values{"csrf": {csrf}, "current": {"wrong-one"}, "new": {"viewer-passphrase-2"}, "again": {"viewer-passphrase-2"}}); code != http.StatusUnauthorized ||
		!strings.Contains(body, tr(langEN, "pw.wrongCurrent")) || !strings.Contains(body, `id="sessions"`) {
		t.Fatalf("wrong current password: %d\n%s", code, body)
	}
	// A good one comes back to Settings and signs the other browser out.
	if code, body := b.post("/account/password", url.Values{"csrf": {csrf}, "current": {"viewer-passphrase-1"}, "new": {"viewer-passphrase-2"}, "again": {"viewer-passphrase-2"}}); code != http.StatusOK ||
		!strings.Contains(body, "Password changed.") || !strings.Contains(body, "Only this browser is signed in.") {
		t.Fatalf("password change: %d\n%s", code, body)
	}
	if _, body := other.get("/"); !strings.Contains(body, `action="/login"`) {
		t.Fatal("other browser still signed in after the password change")
	}

	// Signing the others out keeps this browser.
	other = e.browser()
	other.signIn("viewer@example.com", "viewer-passphrase-2", secret)
	if code, body := b.post("/settings/sessions", url.Values{"csrf": {csrf}}); code != http.StatusOK || !strings.Contains(body, "Every other browser was signed out.") {
		t.Fatalf("sign out others: %d\n%s", code, body)
	}
	if _, body := other.get("/"); !strings.Contains(body, `action="/login"`) {
		t.Fatal("other browser still signed in")
	}
	if code, _ := b.get("/settings"); code != http.StatusOK {
		t.Fatalf("this browser was signed out too: %d", code)
	}
	var n int
	if err := e.deps.Pool.QueryRow(context.Background(), `SELECT count(*) FROM admin_events WHERE kind = 'admin.sessions_ended'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("sessions_ended recorded %d times: %v", n, err)
	}
}
