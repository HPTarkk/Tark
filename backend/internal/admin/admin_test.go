package admin

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/password"
	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

type fakeMailer struct{ sent []mail.Message }

func (f *fakeMailer) Enqueue(_ context.Context, _ store.Querier, _ string, m mail.Message, _ time.Time) error {
	f.sent = append(f.sent, m)
	return nil
}
func (f *fakeMailer) Nudge() {}

type env struct {
	t      *testing.T
	srv    *Server
	ts     *httptest.Server
	mailer *fakeMailer
	deps   Deps
}

func setup(t *testing.T) *env {
	t.Helper()
	dbURL := os.Getenv("TARK_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TARK_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := store.Open(ctx, dbURL, 6)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	k := func(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }
	lookup, _ := secure.NewHasher(k(1))
	sealer, _ := secure.NewSealer(k(2))
	pw, err := password.New(k(3), password.Params{MemoryKiB: 8 * 1024, Iterations: 1, Parallelism: 1}, 2)
	if err != nil {
		t.Fatal(err)
	}
	fm := &fakeMailer{}
	d := Deps{
		Pool: pool, Passwords: pw, Lookup: lookup, Sealer: sealer, Limits: ratelimit.NewPG(pool, lookup), Mailer: fm,
		AlertEmails: []string{"owner@example.com"}, ServerName: "api.test",
		ClientIP: func(*http.Request) string { return "203.0.113.7" },
		Log:      slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	srv, err := New(d)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return &env{t: t, srv: srv, ts: ts, mailer: fm, deps: d}
}

type browser struct {
	e *env
	c *http.Client
}

func (e *env) browser() *browser {
	jar, _ := cookiejar.New(nil)
	return &browser{e: e, c: &http.Client{Jar: jar}}
}

func (b *browser) get(path string) (int, string) {
	b.e.t.Helper()
	res, err := b.c.Get(b.e.ts.URL + path)
	if err != nil {
		b.e.t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(body)
}

func (b *browser) post(path string, form url.Values) (int, string) {
	b.e.t.Helper()
	res, err := b.c.PostForm(b.e.ts.URL+path, form)
	if err != nil {
		b.e.t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(body)
}

var (
	hiddenRE = regexp.MustCompile(`name="(csrf|pre)" value="([^"]+)"`)
	keyRE    = regexp.MustCompile(`<code class="key">([A-Z2-7 ]+)</code>`)
)

func field(t *testing.T, body, name string) string {
	t.Helper()
	for _, m := range hiddenRE.FindAllStringSubmatch(body, -1) {
		if m[1] == name {
			return m[2]
		}
	}
	t.Fatalf("no %s field in:\n%s", name, body)
	return ""
}

// signIn goes through password, TOTP (enrolling on first use) and the forced
// password change. It returns the TOTP secret.
func (b *browser) signIn(email, pw string, secret []byte) (string, []byte) {
	t := b.e.t
	t.Helper()
	_, body := b.get("/login")
	code, body := b.post("/login", url.Values{"pre": {field(t, body, "pre")}, "email": {email}, "password": {pw}})
	if code != http.StatusOK || !strings.Contains(body, "code") {
		t.Fatalf("login: %d %s", code, body)
	}
	if secret == nil {
		m := keyRE.FindStringSubmatch(body)
		if m == nil {
			t.Fatalf("no enrolment key:\n%s", body)
		}
		var err error
		secret, err = b32.DecodeString(strings.ReplaceAll(m[1], " ", ""))
		if err != nil {
			t.Fatal(err)
		}
	}
	// Each sign-in needs a fresh step (codes cannot be reused).
	b.e.srv.now = func() time.Time { return time.Now().Add(time.Duration(len(b.e.mailer.sent)) * time.Minute) }
	totp := totpCode(secret, b.e.srv.now().Unix()/totpStep)
	code, body = b.post("/login/totp", url.Values{"csrf": {field(t, body, "csrf")}, "code": {totp}})
	if code != http.StatusOK {
		t.Fatalf("totp: %d %s", code, body)
	}
	return body, secret
}

func TestOwnerFlow(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	temp, err := CreateAdmin(ctx, e.deps, "Pedi@Example.com", "Pedi", RoleOwner, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := CreateAdmin(ctx, e.deps, "pedi@example.com", "Again", RoleOwner, ""); err == nil {
		t.Fatal("duplicate admin created")
	}

	// Nothing is reachable signed out.
	b := e.browser()
	for _, p := range []string{"/", "/users", "/admins", "/login/totp"} {
		if _, body := b.get(p); !strings.Contains(body, `action="/login"`) {
			t.Fatalf("%s reachable signed out", p)
		}
	}
	// Wrong password.
	_, body := b.get("/login")
	if code, _ := b.post("/login", url.Values{"pre": {field(t, body, "pre")}, "email": {"pedi@example.com"}, "password": {"nope"}}); code != http.StatusUnauthorized {
		t.Fatalf("wrong password: %d", code)
	}
	// The login form without its double-submit token is refused.
	if code, _ := b.post("/login", url.Values{"email": {"pedi@example.com"}, "password": {temp}}); code != http.StatusForbidden {
		t.Fatalf("login without pre token: %d", code)
	}

	body, secret := b.signIn("pedi@example.com", temp, nil)
	if !strings.Contains(body, "Choose your password") {
		t.Fatalf("not forced to change the password:\n%s", body)
	}
	if len(e.mailer.sent) != 1 || !strings.Contains(e.mailer.sent[0].Subject, "Admin sign-in: Pedi") {
		t.Fatalf("sign-in notice = %+v", e.mailer.sent)
	}
	// The dashboard waits for the password change.
	if _, body := b.get("/"); !strings.Contains(body, "Choose your password") {
		t.Fatal("dashboard reachable before the password change")
	}
	csrf := field(t, body, "csrf")
	if code, _ := b.post("/account/password", url.Values{"csrf": {csrf}, "current": {temp}, "new": {"short"}, "again": {"short"}}); code != http.StatusBadRequest {
		t.Fatalf("short password: %d", code)
	}
	// A POST without the CSRF token does nothing.
	if code, _ := b.post("/account/password", url.Values{"current": {temp}, "new": {"a-long-new-passphrase"}, "again": {"a-long-new-passphrase"}}); code != http.StatusForbidden {
		t.Fatalf("missing csrf: %d", code)
	}
	if code, body := b.post("/account/password", url.Values{"csrf": {csrf}, "current": {temp}, "new": {"a-long-new-passphrase"}, "again": {"a-long-new-passphrase"}}); code != http.StatusOK || !strings.Contains(body, "Dashboard") {
		t.Fatalf("password change: %d %s", code, body)
	}

	// Data for the pages.
	for _, q := range []string{
		`INSERT INTO users (id, name, created_at) VALUES ('11111111-1111-1111-1111-111111111111', 'Rider', now())`,
		`INSERT INTO user_emails (id, user_id, email, is_primary, verified_at) VALUES
			('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'rider@example.com', true, now())`,
		`INSERT INTO auth_identities (user_id, provider, password_hash) VALUES ('11111111-1111-1111-1111-111111111111', 'password', 'x')`,
		`INSERT INTO bazaar_purchases (user_id, token_hash, token_enc, sku, state, valid_until)
			VALUES ('11111111-1111-1111-1111-111111111111', '\x01', '\x01', 'tark_premium_12m', 'active', now() + interval '300 days')`,
		`INSERT INTO audit_events (kind, user_id) VALUES ('login.failed', '11111111-1111-1111-1111-111111111111')`,
	} {
		if _, err := e.deps.Pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	_, body = b.get("/")
	for _, want := range []string{"<p class=\"big\">1</p>", "tark_premium_12m: 1", "Failed sign-ins and codes: 1"} {
		if !strings.Contains(body, want) {
			t.Fatalf("dashboard lacks %q:\n%s", want, body)
		}
	}

	// Lookup by exact email; the address is masked until revealed.
	if _, body := b.get("/users?q=nobody@example.com"); !strings.Contains(body, "No account has that address") {
		t.Fatal("unknown email found something")
	}
	_, body = b.get("/users?q=Rider@example.com")
	if !strings.Contains(body, "ri***@example.com") || strings.Contains(body, "rider@example.com") {
		t.Fatalf("user page:\n%s", body)
	}
	_, body = b.post("/users/11111111-1111-1111-1111-111111111111/reveal",
		url.Values{"csrf": {field(t, body, "csrf")}, "email": {"22222222-2222-2222-2222-222222222222"}})
	if !strings.Contains(body, "<strong>rider@example.com</strong>") {
		t.Fatalf("reveal:\n%s", body)
	}
	var kinds string
	if err := e.deps.Pool.QueryRow(ctx, `SELECT string_agg(kind, ',' ORDER BY id) FROM admin_events WHERE target_user IS NOT NULL`).Scan(&kinds); err != nil {
		t.Fatal(err)
	}
	if kinds != "user.viewed,user.email_revealed" {
		t.Fatalf("recorded = %s", kinds)
	}
	for _, p := range []string{"/security", "/mail", "/backups", "/activity", "/admins"} {
		if code, body := b.get(p); code != http.StatusOK {
			t.Fatalf("%s: %d %s", p, code, body)
		}
	}

	// Add a viewer; the one-time password is shown once.
	_, body = b.get("/admins")
	_, body = b.post("/admins", url.Values{"csrf": {field(t, body, "csrf")}, "name": {"Sam"}, "email": {"sam@example.com"}, "role": {"viewer"}})
	m := regexp.MustCompile(`<code class="key">([A-Za-z0-9_-]+)</code>`).FindStringSubmatch(body)
	if m == nil {
		t.Fatalf("no one-time password:\n%s", body)
	}
	viewer := e.browser()
	vbody, _ := viewer.signIn("sam@example.com", m[1], nil)
	_, vbody = viewer.post("/account/password", url.Values{"csrf": {field(t, vbody, "csrf")}, "current": {m[1]},
		"new": {"viewer-passphrase-1"}, "again": {"viewer-passphrase-1"}})
	if !strings.Contains(vbody, "Dashboard") || strings.Contains(vbody, `href="/users"`) {
		t.Fatalf("viewer dashboard:\n%s", vbody)
	}
	for _, p := range []string{"/users", "/users/11111111-1111-1111-1111-111111111111", "/security", "/admins", "/backups"} {
		if code, _ := viewer.get(p); code != http.StatusForbidden {
			t.Fatalf("viewer reached %s: %d", p, code)
		}
	}

	// Disabling the viewer ends their session at once.
	var samID string
	if err := e.deps.Pool.QueryRow(ctx, `SELECT id FROM admin_users WHERE email = 'sam@example.com'`).Scan(&samID); err != nil {
		t.Fatal(err)
	}
	_, body = b.get("/admins")
	b.post("/admins/"+samID+"/disable", url.Values{"csrf": {field(t, body, "csrf")}})
	if _, body := viewer.get("/"); !strings.Contains(body, `action="/login"`) {
		t.Fatal("disabled admin still signed in")
	}

	// A second sign-in of the owner asks for a code, not enrolment, and the
	// code just used cannot be used again.
	b2 := e.browser()
	_, body = b2.get("/login")
	_, body = b2.post("/login", url.Values{"pre": {field(t, body, "pre")}, "email": {"pedi@example.com"}, "password": {"a-long-new-passphrase"}})
	if strings.Contains(body, "Set up your authenticator") {
		t.Fatal("asked to enrol again")
	}
	var last int64
	if err := e.deps.Pool.QueryRow(ctx, `SELECT totp_last_step FROM admin_users WHERE email = 'pedi@example.com'`).Scan(&last); err != nil {
		t.Fatal(err)
	}
	e.srv.now = func() time.Time { return time.Unix(last*totpStep, 0) }
	if code, _ := b2.post("/login/totp", url.Values{"csrf": {field(t, body, "csrf")}, "code": {totpCode(secret, last)}}); code != http.StatusUnauthorized {
		t.Fatalf("replayed code: %d", code)
	}
}

func TestTOTPAttemptsAreLimited(t *testing.T) {
	e := setup(t)
	temp, err := CreateAdmin(context.Background(), e.deps, "a@example.com", "A", RoleSupport, "")
	if err != nil {
		t.Fatal(err)
	}
	b := e.browser()
	_, body := b.get("/login")
	_, body = b.post("/login", url.Values{"pre": {field(t, body, "pre")}, "email": {"a@example.com"}, "password": {temp}})
	csrf := field(t, body, "csrf")
	for i := range ruleTOTP.Max {
		if code, _ := b.post("/login/totp", url.Values{"csrf": {csrf}, "code": {"000000"}}); code != http.StatusUnauthorized {
			t.Fatalf("attempt %d: %d", i, code)
		}
	}
	if code, _ := b.post("/login/totp", url.Values{"csrf": {csrf}, "code": {"000000"}}); code != http.StatusTooManyRequests {
		t.Fatalf("over the limit: %d", code)
	}
	if _, body := b.get("/login/totp"); !strings.Contains(body, `action="/login"`) {
		t.Fatal("session survived the lockout")
	}
}

func TestWeeklyReportOncePerWeek(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	monday := time.Date(2026, 10, 5, 6, 0, 0, 0, time.UTC)
	e.srv.now = func() time.Time { return monday }
	if lastReportTime(monday) != time.Date(2026, 10, 5, 5, 0, 0, 0, time.UTC) {
		t.Fatalf("last = %v", lastReportTime(monday))
	}
	if lastReportTime(monday.Add(-2*time.Hour)) != time.Date(2026, 9, 28, 5, 0, 0, 0, time.UTC) {
		t.Fatal("before 05:00 on Monday is still last week")
	}
	sent, err := e.srv.SendWeeklyIfDue(ctx)
	if err != nil || !sent {
		t.Fatalf("first: %v %v", sent, err)
	}
	if sent, _ := e.srv.SendWeeklyIfDue(ctx); sent {
		t.Fatal("sent twice")
	}
	e.srv.now = func() time.Time { return monday.Add(7 * 24 * time.Hour) }
	if sent, _ := e.srv.SendWeeklyIfDue(ctx); !sent {
		t.Fatal("next week not sent")
	}
	if len(e.mailer.sent) != 2 || !strings.Contains(e.mailer.sent[0].Text, "ACCOUNTS") ||
		e.mailer.sent[0].Subject != "[Tarkk api.test] Weekly summary" {
		t.Fatalf("mail = %+v", e.mailer.sent)
	}
}

func TestMaskEmail(t *testing.T) {
	for in, want := range map[string]string{
		"pedram@gmail.com": "pe***@gmail.com", "ab@x.ir": "a***@x.ir", "a@x.ir": "a***@x.ir", "bad": "***",
	} {
		if got := maskEmail(in); got != want {
			t.Errorf("%s: %s, want %s", in, got, want)
		}
	}
}
