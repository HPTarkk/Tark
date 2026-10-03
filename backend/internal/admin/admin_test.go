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
	"github.com/HPTarkk/Tark/backend/internal/metrics"
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

type fakeAccounts struct{ deleted []string }

func (f *fakeAccounts) DeleteByAdmin(_ context.Context, userID, locale string) error {
	f.deleted = append(f.deleted, userID+":"+locale)
	return nil
}

type fakeBilling struct{ checked []string }

func (f *fakeBilling) RecheckNow(_ context.Context, id string) (bool, error) {
	f.checked = append(f.checked, id)
	return true, nil
}

type env struct {
	accounts *fakeAccounts
	billing  *fakeBilling
	t        *testing.T
	srv      *Server
	ts       *httptest.Server
	mailer   *fakeMailer
	deps     Deps
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
	fa, fb := &fakeAccounts{}, &fakeBilling{}
	d := Deps{
		Accounts: fa, Billing: fb, Plans: testPlans(),
		Pool: pool, Passwords: pw, Lookup: lookup, Sealer: sealer, Limits: ratelimit.NewPG(pool, lookup), Mailer: fm,
		AlertEmails: []string{"owner@example.com"}, ServerName: "api.test",
		ClientIP: func(*http.Request) string { return "203.0.113.7" },
		Log:      slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:  metrics.New(pool), LogDir: t.TempDir(),
	}
	srv, err := New(d)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return &env{t: t, srv: srv, ts: ts, mailer: fm, deps: d, accounts: fa, billing: fb}
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

// owner returns a signed-in owner whose password change is done.
func (e *env) owner(email string) *browser {
	e.t.Helper()
	temp, err := CreateAdmin(context.Background(), e.deps, email, "Owner", RoleOwner, "")
	if err != nil {
		e.t.Fatal(err)
	}
	b := e.browser()
	body, _ := b.signIn(email, temp, nil)
	if code, _ := b.post("/account/password", url.Values{"csrf": {field(e.t, body, "csrf")}, "current": {temp},
		"new": {"owner-passphrase-123"}, "again": {"owner-passphrase-123"}}); code != http.StatusOK {
		e.t.Fatalf("password change: %d", code)
	}
	return b
}

func TestUserActions(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	const uid = "11111111-1111-1111-1111-111111111111"
	const pid = "33333333-3333-3333-3333-333333333333"
	for _, q := range []string{
		`INSERT INTO users (id, name) VALUES ('` + uid + `', 'Rider')`,
		`INSERT INTO user_emails (user_id, email, is_primary, verified_at) VALUES ('` + uid + `', 'rider@example.com', true, now())`,
		`INSERT INTO sessions (user_id, expires_at) VALUES ('` + uid + `', now() + interval '1 day'), ('` + uid + `', now() + interval '1 day')`,
		`INSERT INTO bazaar_purchases (id, user_id, token_hash, token_enc, sku, state) VALUES ('` + pid + `', '` + uid + `', '\x01', '\x01', 'tark_premium_1m', 'active')`,
		`INSERT INTO subscription_accounts (user_id, suspicious_since) VALUES ('` + uid + `', now())`,
	} {
		if _, err := e.deps.Pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	b := e.owner("boss@example.com")
	page := "/users/" + uid
	do := func(action string, form url.Values) string {
		t.Helper()
		_, body := b.get(page)
		form.Set("csrf", field(t, body, "csrf"))
		code, body := b.post(page+"/"+action, form)
		if code != http.StatusOK {
			t.Fatalf("%s: %d\n%s", action, code, body)
		}
		return body
	}
	count := func(sql string) int {
		t.Helper()
		var n int
		if err := e.deps.Pool.QueryRow(ctx, sql).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	// A reason is required.
	_, body := b.get(page)
	if code, _ := b.post(page+"/disable", url.Values{"csrf": {field(t, body, "csrf")}}); code != http.StatusBadRequest {
		t.Fatalf("disable without reason: %d", code)
	}
	do("disable", url.Values{"reason": {"chargeback fraud"}})
	if count(`SELECT count(*) FROM users WHERE status = 'disabled'`) != 1 || count(`SELECT count(*) FROM sessions WHERE revoked_at IS NULL`) != 0 {
		t.Fatal("disable did not disable and sign out")
	}
	do("enable", url.Values{"reason": {"cleared"}})
	if count(`SELECT count(*) FROM users WHERE status = 'active'`) != 1 {
		t.Fatal("not enabled")
	}
	if _, err := e.deps.Pool.Exec(ctx, `INSERT INTO sessions (user_id, expires_at) VALUES ($1, now() + interval '1 day')`, uid); err != nil {
		t.Fatal(err)
	}
	if body := do("signout", url.Values{}); !strings.Contains(body, "Signed out on 1 device") {
		t.Fatalf("signout:\n%s", body)
	}
	do("recheck", url.Values{"purchase": {pid}})
	if len(e.billing.checked) != 1 || e.billing.checked[0] != pid {
		t.Fatalf("rechecked %v", e.billing.checked)
	}
	// Another account's purchase id is refused.
	_, body = b.get(page)
	if code, _ := b.post(page+"/recheck", url.Values{"csrf": {field(t, body, "csrf")}, "purchase": {"44444444-4444-4444-4444-444444444444"}}); code != http.StatusNotFound {
		t.Fatalf("foreign purchase: %d", code)
	}

	if body := do("grant", url.Values{"months": {"3"}, "reason": {"beta tester"}}); !strings.Contains(body, "Premium given until") {
		t.Fatalf("grant:\n%s", body)
	}
	if count(`SELECT count(*) FROM premium_grants WHERE revoked_at IS NULL AND ends_at > now() + interval '80 days'`) != 1 ||
		count(`SELECT count(*) FROM subscription_events WHERE kind = 'premium_granted'`) != 1 {
		t.Fatal("grant not stored and tracked")
	}
	var gid string
	if err := e.deps.Pool.QueryRow(ctx, `SELECT id FROM premium_grants`).Scan(&gid); err != nil {
		t.Fatal(err)
	}
	_, body = b.get(page)
	if code, _ := b.post(page+"/grant", url.Values{"csrf": {field(t, body, "csrf")}, "months": {"24"}, "reason": {"too long"}}); code != http.StatusBadRequest {
		t.Fatalf("24 months: %d", code)
	}
	do("revoke-grant", url.Values{"grant": {gid}, "reason": {"tester left"}})
	if count(`SELECT count(*) FROM premium_grants WHERE revoked_at IS NOT NULL AND revoked_by IS NOT NULL`) != 1 {
		t.Fatal("grant not revoked")
	}
	do("clear-suspicious", url.Values{"reason": {"Bazaar confirmed mistake"}})
	if count(`SELECT count(*) FROM subscription_accounts WHERE suspicious_since IS NOT NULL`) != 0 {
		t.Fatal("flag not cleared")
	}

	// Deleting needs the exact address.
	_, body = b.get(page)
	if code, _ := b.post(page+"/delete", url.Values{"csrf": {field(t, body, "csrf")}, "confirm": {"someone@example.com"}, "reason": {"request"}, "locale": {"fa"}}); code != http.StatusBadRequest {
		t.Fatalf("wrong confirmation: %d", code)
	}
	if len(e.accounts.deleted) != 0 {
		t.Fatal("deleted without confirmation")
	}
	do("delete", url.Values{"confirm": {"Rider@example.com"}, "reason": {"request by email"}, "locale": {"fa"}})
	if len(e.accounts.deleted) != 1 || e.accounts.deleted[0] != uid+":fa" {
		t.Fatalf("deleted %v", e.accounts.deleted)
	}

	var kinds string
	if err := e.deps.Pool.QueryRow(ctx, `SELECT string_agg(kind, ',' ORDER BY id) FROM admin_events WHERE kind NOT LIKE 'admin.%' AND kind <> 'user.viewed'`).Scan(&kinds); err != nil {
		t.Fatal(err)
	}
	want := "user.disabled,user.enabled,user.signed_out,purchase.rechecked,premium.granted,premium.revoked,subscription.suspicious_cleared,user.deleted"
	if kinds != want {
		t.Fatalf("recorded %s\nwant     %s", kinds, want)
	}
	if count(`SELECT count(*) FROM admin_events WHERE kind = 'user.deleted' AND target_user IS NULL AND details->>'reason' = 'request by email'`) != 1 {
		t.Fatal("deletion record keeps a link to the account or lost its reason")
	}
}

func TestSupportCannotDoOwnerActions(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	const uid = "11111111-1111-1111-1111-111111111111"
	if _, err := e.deps.Pool.Exec(ctx, `INSERT INTO users (id, name) VALUES ($1, 'Rider')`, uid); err != nil {
		t.Fatal(err)
	}
	owner := e.owner("boss@example.com")
	_, body := owner.get("/admins")
	_, body = owner.post("/admins", url.Values{"csrf": {field(t, body, "csrf")}, "name": {"Sup"}, "email": {"sup@example.com"}, "role": {"support"}})
	temp := regexp.MustCompile(`<code class="key">([A-Za-z0-9_-]+)</code>`).FindStringSubmatch(body)[1]
	sup := e.browser()
	body, _ = sup.signIn("sup@example.com", temp, nil)
	_, body = sup.post("/account/password", url.Values{"csrf": {field(t, body, "csrf")}, "current": {temp}, "new": {"support-passphrase-1"}, "again": {"support-passphrase-1"}})
	_, body = sup.get("/users/" + uid)
	if strings.Contains(body, "Give premium") || strings.Contains(body, "Delete account") {
		t.Fatal("support sees owner actions")
	}
	csrf := field(t, body, "csrf")
	for _, a := range []string{"grant", "revoke-grant", "clear-suspicious", "delete"} {
		if code, _ := sup.post("/users/"+uid+"/"+a, url.Values{"csrf": {csrf}, "reason": {"try it"}, "months": {"1"}}); code != http.StatusForbidden {
			t.Fatalf("support %s: %d", a, code)
		}
	}
	if code, _ := sup.post("/pricing", url.Values{"csrf": {csrf}, "base": {"99000"}}); code != http.StatusForbidden {
		t.Fatalf("support pricing: %d", code)
	}
	if code, _ := sup.post("/users/"+uid+"/signout", url.Values{"csrf": {csrf}}); code != http.StatusOK {
		t.Fatalf("support signout: %d", code)
	}
}

func TestSystemAndLogsPages(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	e.deps.Metrics.ObserveRequest("POST", "/v1/auth/login", 200, 40*time.Millisecond)
	e.deps.Metrics.ObserveRequest("POST", "/v1/auth/login", 500, 3*time.Second)
	if _, err := e.deps.Pool.Exec(ctx, `INSERT INTO alert_state (key, firing, since, detail) VALUES ('slow', true, now(), '9 of 20 requests were slow')`); err != nil {
		t.Fatal(err)
	}
	today := time.Now().UTC().Format(time.DateOnly)
	lines := `{"time":"t1","level":"INFO","msg":"request","route":"/v1/auth/login"}
{"time":"t2","level":"ERROR","msg":"backup failed","err":"disk full"}
{"time":"t3","level":"WARN","msg":"alert","key":"slow"}
`
	if err := os.WriteFile(e.deps.LogDir+"/tark-"+today+".log", []byte(lines), 0o600); err != nil {
		t.Fatal(err)
	}

	owner := e.owner("boss@example.com")
	code, body := owner.get("/system")
	if code != http.StatusOK || !strings.Contains(body, "POST /v1/auth/login") || !strings.Contains(body, "9 of 20 requests were slow") ||
		!strings.Contains(body, "firing since") {
		t.Fatalf("system page: %d %s", code, body)
	}
	code, body = owner.get("/logs?level=WARN&days=7")
	if code != http.StatusOK || !strings.Contains(body, "backup failed") || !strings.Contains(body, "&#34;key&#34;:&#34;slow&#34;") ||
		strings.Contains(body, "&#34;msg&#34;:&#34;request&#34;") {
		t.Fatalf("logs page (warn): %d %s", code, body)
	}
	if strings.Index(body, "&#34;key&#34;:&#34;slow&#34;") > strings.Index(body, "backup failed") {
		t.Fatal("logs are not newest first")
	}
	_, body = owner.get("/logs?q=DISK+FULL")
	if !strings.Contains(body, "backup failed") || strings.Contains(body, "&#34;key&#34;:&#34;slow&#34;") {
		t.Fatalf("logs page (text): %s", body)
	}

	_, body = owner.get("/admins")
	_, body = owner.post("/admins", url.Values{"csrf": {field(t, body, "csrf")}, "name": {"Vee"}, "email": {"vee@example.com"}, "role": {"viewer"}})
	temp := regexp.MustCompile(`<code class="key">([A-Za-z0-9_-]+)</code>`).FindStringSubmatch(body)[1]
	viewer := e.browser()
	body, _ = viewer.signIn("vee@example.com", temp, nil)
	viewer.post("/account/password", url.Values{"csrf": {field(t, body, "csrf")}, "current": {temp}, "new": {"viewer-passphrase-1"}, "again": {"viewer-passphrase-1"}})
	if code, _ := viewer.get("/system"); code != http.StatusOK {
		t.Fatalf("viewer system: %d", code)
	}
	if code, _ := viewer.get("/logs"); code != http.StatusForbidden {
		t.Fatalf("viewer logs: %d", code)
	}
}
