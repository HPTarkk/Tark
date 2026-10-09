package app_test

// End-to-end tests: the real HTTP handler, the real services and a real
// PostgreSQL. Only the outside world is faked (mail server, Google's key
// endpoint, Cafe Bazaar).
//
//	TARK_TEST_DATABASE_URL=postgres://tark:tark@localhost:5432/tark_test go test ./...
//
// The tests reset the database's public schema, so never point this at a
// database you care about.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/app"
	"github.com/HPTarkk/Tark/backend/internal/billing"
	"github.com/HPTarkk/Tark/backend/internal/config"
	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/password"
	"github.com/HPTarkk/Tark/backend/internal/store"
	"github.com/HPTarkk/Tark/backend/internal/testutil"
)

const googleAud = "tark-test.apps.googleusercontent.com"

type captureSender struct {
	mu   sync.Mutex
	sent []mail.Message
}

func (c *captureSender) Send(_ context.Context, m mail.Message) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sent = append(c.sent, m)
	return nil
}

func (c *captureSender) to(addr string) []mail.Message {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []mail.Message
	for _, m := range c.sent {
		if m.To == addr {
			out = append(out, m)
		}
	}
	return out
}

type env struct {
	t      *testing.T
	srv    *httptest.Server
	pool   *pgxpool.Pool
	app    *app.App
	mail   *captureSender
	google *testutil.GoogleFake
	bazaar *billing.FakeBazaar
	pub    ed25519.PublicKey
	ipSeq  atomic.Int64
}

func key(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }

func setup(t *testing.T) *env { t.Helper(); return setupPools(t, 10, 4) }

// setupPools wires the app the way tarkd does: a main pool for requests and
// a small auxiliary pool for audit and rate-limit writes.
func setupPools(t *testing.T, mainConns, auxConns int32, tweaks ...func(*config.Config)) *env {
	t.Helper()
	url := os.Getenv("TARK_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TARK_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := store.Open(ctx, url, mainConns)
	if err != nil {
		t.Fatal(err)
	}
	aux, err := store.Open(ctx, url, auxConns)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	g := testutil.NewGoogleFake()
	cfg := &config.Config{
		Env: "development", LinkBaseURL: "https://tarkk.ir",
		ClientIPHeader: "X-Forwarded-For",
		TrustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("::1/128")},
		Keys: config.Keys{TokenKey: key(1), LookupKey: key(2), DataKey: key(3), Pepper: key(4),
			EntitlementSeeds: map[string][]byte{"k1": key(5)}, EntitlementKID: "k1"},
		Google:             config.GoogleConfig{ClientIDs: []string{googleAud}, RequireNonce: true, JWKSURL: g.Server.URL},
		Bazaar:             config.BazaarConfig{SKUs: []string{"tark_premium_1m", "tark_premium_3m", "tark_premium_6m", "tark_premium_12m"}},
		Policy:             config.EntitlementPolicy{GraceHours: 72, RefreshDays: 5, SuspiciousOfflineHrs: 72},
		AccessTokenTTL:     15 * time.Minute,
		RefreshTokenTTL:    180 * 24 * time.Hour,
		SessionMaxLifetime: 365 * 24 * time.Hour,
		PasswordHashSlots:  4,
	}
	for _, tweak := range tweaks {
		tweak(cfg)
	}
	sender := &captureSender{}
	bz := &billing.FakeBazaar{}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	params := password.Params{MemoryKiB: 8 * 1024, Iterations: 1, Parallelism: 1}
	a, err := app.Build(cfg, pool, log, app.Options{Sender: sender, Bazaar: bz, PasswordParams: &params, AuxPool: aux})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(a.Handler)
	pubB64 := a.Signer.PublicKeys()["k1"]
	pub, _ := base64.RawURLEncoding.DecodeString(pubB64)
	e := &env{t: t, srv: srv, pool: pool, app: a, mail: sender, google: g, bazaar: bz, pub: pub}
	t.Cleanup(func() {
		srv.Close()
		g.Server.Close()
		pool.Close()
		aux.Close()
	})
	return e
}

// caller is one phone: its own IP and install key.
type caller struct {
	e       *env
	ip      string
	install string
	access  string
	refresh string
}

func (e *env) phone() *caller {
	n := e.ipSeq.Add(1)
	install := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{byte(n)}, 32))
	return &caller{e: e, ip: fmt.Sprintf("10.0.%d.%d", n/250, n%250+1), install: install}
}

type resp struct {
	status int
	body   map[string]any
	header http.Header
}

func (r resp) str(k string) string {
	s, _ := r.body[k].(string)
	return s
}

func (c *caller) do(method, path string, body any, headers ...string) resp {
	c.e.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, c.e.srv.URL+path, rd)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", c.ip)
	req.Header.Set("X-Tark-Platform", "android")
	req.Header.Set("X-Tark-Install-Key", c.install)
	if c.access != "" {
		req.Header.Set("Authorization", "Bearer "+c.access)
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		c.e.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	out := resp{status: res.StatusCode, header: res.Header, body: map[string]any{}}
	_ = json.Unmarshal(raw, &out.body)
	return out
}

func (c *caller) signedIn(r resp) {
	c.e.t.Helper()
	if r.status != http.StatusOK || r.str("accessToken") == "" {
		c.e.t.Fatalf("expected a session, got %d %v", r.status, r.body)
	}
	c.access, c.refresh = r.str("accessToken"), r.str("refreshToken")
}

func expect(t *testing.T, r resp, status int, code string) {
	t.Helper()
	if r.status != status || (code != "" && r.str("code") != code) {
		t.Fatalf("want %d %s, got %d %v", status, code, r.status, r.body)
	}
}

var codeRe = regexp.MustCompile(`(?m)^(\d{6})$`)
var linkRe = regexp.MustCompile(`https://tarkk\.ir/v/[a-z]+#([A-Za-z0-9_-]+)`)

// lastMail delivers the outbox and returns the newest message to addr.
func (e *env) lastMail(addr string) mail.Message {
	e.t.Helper()
	if _, err := e.app.Outbox.DeliverPending(context.Background()); err != nil {
		e.t.Fatal(err)
	}
	msgs := e.mail.to(addr)
	if len(msgs) == 0 {
		e.t.Fatalf("no mail to %s", addr)
	}
	return msgs[len(msgs)-1]
}

func codeOf(t *testing.T, m mail.Message) (string, string) {
	t.Helper()
	c := codeRe.FindStringSubmatch(m.Text)
	l := linkRe.FindStringSubmatch(m.Text)
	if c == nil || l == nil {
		t.Fatalf("no code or link in %q", m.Text)
	}
	return c[1], l[1]
}

func wrong(code string) string {
	if code == "000000" {
		return "111111"
	}
	return "000000"
}

func (c *caller) register(email, pw, name string) {
	c.e.t.Helper()
	r := c.do("POST", "/v1/auth/register", map[string]any{"email": email, "password": pw, "name": name, "locale": "en"})
	expect(c.e.t, r, http.StatusAccepted, "")
	code, _ := codeOf(c.e.t, c.e.lastMail(email))
	c.signedIn(c.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": r.str("flowId"), "code": code}))
}

// ---- tests ---------------------------------------------------------------

func TestRegistrationWithCode(t *testing.T) {
	e := setup(t)
	p := e.phone()

	r := p.do("POST", "/v1/auth/register", map[string]any{"email": "New@Example.com", "password": "a good passphrase", "name": "  Sara  "})
	expect(t, r, http.StatusAccepted, "")
	spec := r.body["code"].(map[string]any)
	if spec["length"].(float64) != 6 || spec["alphabet"] != "digits" {
		t.Fatalf("code spec %v", spec)
	}
	flow := r.str("flowId")
	code, _ := codeOf(t, e.lastMail("new@example.com"))

	bad := p.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": flow, "code": wrong(code)})
	expect(t, bad, http.StatusUnprocessableEntity, "code_invalid")
	if bad.body["attemptsLeft"].(float64) != 4 {
		t.Fatalf("attemptsLeft %v", bad.body)
	}
	ok := p.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": flow, "code": code})
	p.signedIn(ok)
	prof := ok.body["profile"].(map[string]any)
	if prof["name"] != "Sara" || prof["email"] != "new@example.com" || ok.body["newAccount"] != true || prof["avatarId"] != nil {
		t.Fatalf("profile %v", ok.body)
	}

	// The answer to the verify call got lost; the app retries. It is
	// signed in again rather than told the flow is over.
	again := p.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": flow, "code": code})
	expect(t, again, http.StatusOK, "")

	// A second sign-up for the same address answers identically but only
	// tells the owner.
	other := e.phone()
	dup := other.do("POST", "/v1/auth/register", map[string]any{"email": "new@example.com", "password": "another passphrase", "name": "X"})
	expect(t, dup, http.StatusAccepted, "")
	if len(dup.body) != len(r.body) {
		t.Fatalf("responses differ in shape: %v vs %v", dup.body, r.body)
	}
	if !strings.Contains(e.lastMail("new@example.com").Subject, "already have") {
		t.Fatal("owner was not told about the second sign-up")
	}
	expect(t, other.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": dup.str("flowId"), "code": code}),
		http.StatusUnprocessableEntity, "code_invalid")
}

func TestRegistrationWithLinkAndLockout(t *testing.T) {
	e := setup(t)
	p := e.phone()
	r := p.do("POST", "/v1/auth/register", map[string]any{"email": "link@example.com", "password": "a good passphrase", "name": "Ali"})
	code, link := codeOf(t, e.lastMail("link@example.com"))
	_ = code

	// The link alone is useless on another phone: it needs the flow id
	// that only the phone that signed up holds.
	stranger := e.phone()
	expect(t, stranger.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": "x" + strings.Repeat("A", 31), "linkToken": link}),
		http.StatusNotFound, "flow_not_found")

	p.signedIn(p.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": r.str("flowId"), "linkToken": link}))

	// Five wrong codes lock a flow; the sixth try is refused even if right.
	q := e.phone()
	r2 := q.do("POST", "/v1/auth/register", map[string]any{"email": "lock@example.com", "password": "a good passphrase", "name": "L"})
	good, _ := codeOf(t, e.lastMail("lock@example.com"))
	for i := 0; i < 4; i++ {
		expect(t, q.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": r2.str("flowId"), "code": wrong(good)}), 422, "code_invalid")
	}
	expect(t, q.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": r2.str("flowId"), "code": wrong(good)}), 423, "code_locked")
	expect(t, q.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": r2.str("flowId"), "code": good}), 423, "code_locked")

	// Resending is on a cooldown.
	expect(t, q.do("POST", "/v1/auth/register/resend", map[string]any{"flowId": r2.str("flowId")}), 429, "rate_limited")
	if _, err := e.pool.Exec(context.Background(), `UPDATE auth_flows SET last_sent_at = now() - interval '2 minutes'`); err != nil {
		t.Fatal(err)
	}
	expect(t, q.do("POST", "/v1/auth/register/resend", map[string]any{"flowId": r2.str("flowId")}), 202, "")
	fresh, _ := codeOf(t, e.lastMail("lock@example.com"))
	q.signedIn(q.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": r2.str("flowId"), "code": fresh}))
}

func TestLoginRefreshLogout(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.register("login@example.com", "a good passphrase", "Reza")

	q := e.phone()
	unknown := q.do("POST", "/v1/auth/login", map[string]any{"email": "nobody@example.com", "password": "whatever123"})
	wrongPw := q.do("POST", "/v1/auth/login", map[string]any{"email": "login@example.com", "password": "not the one"})
	expect(t, unknown, 401, "invalid_credentials")
	expect(t, wrongPw, 401, "invalid_credentials")
	if fmt.Sprint(unknown.body) != fmt.Sprint(wrongPw.body) {
		t.Fatalf("login failures differ: %v vs %v", unknown.body, wrongPw.body)
	}
	q.signedIn(q.do("POST", "/v1/auth/login", map[string]any{"email": "LOGIN@example.com", "password": "a good passphrase"}))

	// Rotation: the old refresh token works once.
	old := q.refresh
	r := q.do("POST", "/v1/auth/token/refresh", map[string]any{"refreshToken": old})
	expect(t, r, 200, "")
	next := r.str("refreshToken")
	// A retry of the same refresh within seconds (answer lost) still works.
	retry := q.do("POST", "/v1/auth/token/refresh", map[string]any{"refreshToken": old})
	expect(t, retry, 200, "")
	// The token from the lost answer is burned.
	expect(t, q.do("POST", "/v1/auth/token/refresh", map[string]any{"refreshToken": next}), 401, "session_ended")
	// ... and that reuse ended the session for everyone holding it.
	expect(t, q.do("POST", "/v1/auth/token/refresh", map[string]any{"refreshToken": retry.str("refreshToken")}), 401, "session_ended")
	expect(t, q.do("GET", "/v1/profile", nil), 401, "unauthorized")

	// Logout ends the access token immediately.
	expect(t, p.do("GET", "/v1/profile", nil), 200, "")
	expect(t, p.do("POST", "/v1/auth/logout", nil), 204, "")
	expect(t, p.do("GET", "/v1/profile", nil), 401, "unauthorized")
}

func TestLoginThrottle(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.register("throttle@example.com", "a good passphrase", "T")
	q := e.phone()
	for i := 0; i < 5; i++ {
		expect(t, q.do("POST", "/v1/auth/login", map[string]any{"email": "throttle@example.com", "password": "nope nope"}), 401, "invalid_credentials")
	}
	r := q.do("POST", "/v1/auth/login", map[string]any{"email": "throttle@example.com", "password": "a good passphrase"})
	expect(t, r, 429, "rate_limited")
	if r.header.Get("Retry-After") == "" {
		t.Fatal("no Retry-After")
	}
	// Another phone is not locked out by this one's failures.
	e.phone().signedIn(e.phone().do("POST", "/v1/auth/login", map[string]any{"email": "throttle@example.com", "password": "a good passphrase"}))
}

// Wrong passwords from many places fill the address-wide counter, which
// would otherwise lock the owner out too. A phone that has signed in to the
// account before is not held back by that counter.
func TestKnownDeviceIsNotLockedOutByOthers(t *testing.T) {
	e := setup(t)
	owner := e.phone()
	owner.register("owner@example.com", "a good passphrase", "O")
	for attacker := 0; attacker < 4; attacker++ {
		q := e.phone()
		for i := 0; i < 5; i++ {
			expect(t, q.do("POST", "/v1/auth/login", map[string]any{"email": "owner@example.com", "password": "nope nope"}), 401, "invalid_credentials")
		}
	}
	// A phone never seen on this account is held back, even with the right password.
	expect(t, e.phone().do("POST", "/v1/auth/login", map[string]any{"email": "owner@example.com", "password": "a good passphrase"}), 429, "rate_limited")
	// The owner's own phone still gets in.
	owner.signedIn(owner.do("POST", "/v1/auth/login", map[string]any{"email": "owner@example.com", "password": "a good passphrase"}))
	// And it still has its own per-device limit.
	for i := 0; i < 5; i++ {
		expect(t, owner.do("POST", "/v1/auth/login", map[string]any{"email": "owner@example.com", "password": "nope nope"}), 401, "invalid_credentials")
	}
	expect(t, owner.do("POST", "/v1/auth/login", map[string]any{"email": "owner@example.com", "password": "a good passphrase"}), 429, "rate_limited")
}

func TestForgotAndChangePassword(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.register("reset@example.com", "a good passphrase", "R")
	other := e.phone()
	other.signedIn(other.do("POST", "/v1/auth/login", map[string]any{"email": "reset@example.com", "password": "a good passphrase"}))

	q := e.phone()
	unknown := q.do("POST", "/v1/auth/password/forgot", map[string]any{"email": "ghost@example.com"})
	known := q.do("POST", "/v1/auth/password/forgot", map[string]any{"email": "reset@example.com"})
	expect(t, unknown, 202, "")
	expect(t, known, 202, "")
	if len(e.mail.to("ghost@example.com")) != 0 {
		t.Fatal("mail sent to an address without an account")
	}
	code, _ := codeOf(t, e.lastMail("reset@example.com"))
	v := q.do("POST", "/v1/auth/password/forgot/verify", map[string]any{"flowId": known.str("flowId"), "code": code})
	expect(t, v, 200, "")
	weak := q.do("POST", "/v1/auth/password/reset", map[string]any{"resetTicket": v.str("resetTicket"), "newPassword": "password"})
	expect(t, weak, 422, "password_too_common")
	q.signedIn(q.do("POST", "/v1/auth/password/reset", map[string]any{"resetTicket": v.str("resetTicket"), "newPassword": "a brand new phrase"}))
	expect(t, q.do("POST", "/v1/auth/password/reset", map[string]any{"resetTicket": v.str("resetTicket"), "newPassword": "yet another phrase"}), 410, "ticket_expired")

	// Every earlier session ended with the reset.
	expect(t, p.do("GET", "/v1/profile", nil), 401, "")
	expect(t, other.do("GET", "/v1/profile", nil), 401, "")
	if !strings.Contains(e.lastMail("reset@example.com").Subject, "password was changed") {
		t.Fatal("no password-changed notice")
	}

	// Change password needs the current one and keeps this session only.
	second := e.phone()
	second.signedIn(second.do("POST", "/v1/auth/login", map[string]any{"email": "reset@example.com", "password": "a brand new phrase"}))
	expect(t, q.do("POST", "/v1/auth/password/change", map[string]any{"currentPassword": "wrong one", "newPassword": "third phrase here"}), 401, "invalid_credentials")
	expect(t, q.do("POST", "/v1/auth/password/change", map[string]any{"currentPassword": "a brand new phrase", "newPassword": "third phrase here"}), 204, "")
	expect(t, q.do("GET", "/v1/profile", nil), 200, "")
	expect(t, second.do("GET", "/v1/profile", nil), 401, "")
	expect(t, e.phone().do("POST", "/v1/auth/login", map[string]any{"email": "reset@example.com", "password": "a brand new phrase"}), 401, "invalid_credentials")
}

// Each reset flow allows a few wrong codes and a new flow brings a new code,
// so wrong codes are also capped per address across flows. Hitting the cap
// never strands the owner: the link in the email still works.
func TestWrongCodesAreCappedAcrossFlows(t *testing.T) {
	e := setup(t)
	e.phone().register("target@example.com", "a good passphrase", "T")

	start := func() (*caller, string) {
		q := e.phone()
		f := q.do("POST", "/v1/auth/password/forgot", map[string]any{"email": "target@example.com"})
		expect(t, f, 202, "")
		return q, f.str("flowId")
	}
	// Four flows of five wrong codes each use up the daily cap of 20.
	for flow := 0; flow < 4; flow++ {
		q, id := start()
		good, _ := codeOf(t, e.lastMail("target@example.com"))
		for i := 0; i < 4; i++ {
			expect(t, q.do("POST", "/v1/auth/password/forgot/verify", map[string]any{"flowId": id, "code": wrong(good)}), 422, "code_invalid")
		}
		expect(t, q.do("POST", "/v1/auth/password/forgot/verify", map[string]any{"flowId": id, "code": wrong(good)}), 423, "code_locked")
	}

	// A fifth flow: codes are refused now, even the right one...
	q, id := start()
	good, link := codeOf(t, e.lastMail("target@example.com"))
	expect(t, q.do("POST", "/v1/auth/password/forgot/verify", map[string]any{"flowId": id, "code": good}), 429, "rate_limited")
	// ...but the link still lets the owner in.
	expect(t, q.do("POST", "/v1/auth/password/forgot/verify", map[string]any{"flowId": id, "linkToken": link}), 200, "")

	// Other addresses are unaffected.
	other := e.phone()
	r := other.do("POST", "/v1/auth/register", map[string]any{"email": "bystander@example.com", "password": "a good passphrase", "name": "B"})
	code, _ := codeOf(t, e.lastMail("bystander@example.com"))
	other.signedIn(other.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": r.str("flowId"), "code": code}))
}

func (c *caller) googleToken(sub, email, name string) string {
	n := c.do("POST", "/v1/auth/google/nonce", nil)
	expect(c.e.t, n, 200, "")
	return c.e.google.Token(testutil.Claims{Sub: sub, Email: email, Name: name, Aud: googleAud, EmailVerified: true, Nonce: n.str("nonce")})
}

func TestGoogleSignInAndLinking(t *testing.T) {
	e := setup(t)
	p := e.phone()

	// New Google user; the app sends the name it already has locally.
	tok := p.googleToken("g-1", "Gina@Gmail.com", "Gina From Google")
	r := p.do("POST", "/v1/auth/google", map[string]any{"idToken": tok, "name": "Gina"})
	p.signedIn(r)
	if r.body["profile"].(map[string]any)["name"] != "Gina" || r.body["newAccount"] != true {
		t.Fatalf("%v", r.body)
	}
	// The same ID token cannot be used twice.
	expect(t, e.phone().do("POST", "/v1/auth/google", map[string]any{"idToken": tok}), 401, "google_token_invalid")
	// A token without one of our nonces is refused.
	noNonce := e.google.Token(testutil.Claims{Sub: "g-1", Email: "gina@gmail.com", Aud: googleAud, EmailVerified: true})
	expect(t, p.do("POST", "/v1/auth/google", map[string]any{"idToken": noNonce}), 401, "google_token_invalid")
	// Signing in again with Google finds the account by Google's id.
	p.signedIn(p.do("POST", "/v1/auth/google", map[string]any{"idToken": p.googleToken("g-1", "gina@gmail.com", "")}))

	// No name anywhere: the app is asked for one.
	q := e.phone()
	nr := q.do("POST", "/v1/auth/google", map[string]any{"idToken": q.googleToken("g-2", "noname@gmail.com", "")})
	expect(t, nr, 422, "name_required")
	q.signedIn(q.do("POST", "/v1/auth/google/complete", map[string]any{"ticket": nr.str("ticket"), "name": "Nima"}))

	// An address with a password account: linking needs that password.
	w := e.phone()
	w.register("both@gmail.com", "a good passphrase", "Both")
	lr := w.do("POST", "/v1/auth/google", map[string]any{"idToken": w.googleToken("g-3", "both@gmail.com", "B")})
	expect(t, lr, 409, "link_required")
	if lr.str("email") != "bo•••@gmail.com" {
		t.Fatalf("masked email %q", lr.str("email"))
	}
	bad := w.do("POST", "/v1/auth/google/link", map[string]any{"ticket": lr.str("ticket"), "password": "not it"})
	expect(t, bad, 401, "invalid_credentials")
	w.signedIn(w.do("POST", "/v1/auth/google/link", map[string]any{"ticket": lr.str("ticket"), "password": "a good passphrase"}))
	prof := w.do("GET", "/v1/profile", nil)
	if fmt.Sprint(prof.body["signInMethods"]) != "[google password]" {
		t.Fatalf("methods %v", prof.body)
	}
	// From now on Google signs straight in; the password still works too.
	w.signedIn(w.do("POST", "/v1/auth/google", map[string]any{"idToken": w.googleToken("g-3", "both@gmail.com", "")}))
	e.phone().signedIn(e.phone().do("POST", "/v1/auth/login", map[string]any{"email": "both@gmail.com", "password": "a good passphrase"}))

	// Unverified Google emails are refused.
	u := e.phone()
	n := u.do("POST", "/v1/auth/google/nonce", nil)
	unv := e.google.Token(testutil.Claims{Sub: "g-4", Email: "x@gmail.com", Aud: googleAud, Nonce: n.str("nonce")})
	expect(t, u.do("POST", "/v1/auth/google", map[string]any{"idToken": unv, "name": "X"}), 422, "google_email_unverified")
}

func TestPendingSignupCannotHijackGoogleOwner(t *testing.T) {
	e := setup(t)
	// Someone starts a password sign-up with a victim's address but cannot
	// verify it. The real owner then signs in with Google.
	attacker := e.phone()
	r := attacker.do("POST", "/v1/auth/register", map[string]any{"email": "victim@gmail.com", "password": "attacker phrase", "name": "Evil"})
	code, _ := codeOf(t, e.lastMail("victim@gmail.com"))
	owner := e.phone()
	owner.signedIn(owner.do("POST", "/v1/auth/google", map[string]any{"idToken": owner.googleToken("g-v", "victim@gmail.com", "Victim")}))
	// Even with the code (say the victim forwarded the email), the stale
	// sign-up cannot finish.
	expect(t, attacker.do("POST", "/v1/auth/register/verify", map[string]any{"flowId": r.str("flowId"), "code": code}), 410, "flow_expired")
}

func TestProfile(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.register("prof@example.com", "a good passphrase", "Old")
	g := p.do("GET", "/v1/profile", nil)
	etag := g.header.Get("ETag")
	up := p.do("PUT", "/v1/profile", map[string]any{"name": "New Name", "avatarId": "f03"}, "If-Match", etag)
	expect(t, up, 200, "")
	if up.body["name"] != "New Name" || up.body["avatarId"] != "f03" || up.header.Get("ETag") == etag {
		t.Fatalf("%v", up.body)
	}
	// Writing from a stale copy is refused instead of silently undoing.
	expect(t, p.do("PUT", "/v1/profile", map[string]any{"name": "Stale"}, "If-Match", etag), 412, "profile_changed")
	// A retried identical PUT with the old ETag is fine.
	expect(t, p.do("PUT", "/v1/profile", map[string]any{"name": "New Name", "avatarId": "f03"}, "If-Match", etag), 200, "")
	expect(t, p.do("PUT", "/v1/profile", map[string]any{"name": "N", "avatarId": "../x"}), 400, "invalid_request")
	// Clearing the avatar.
	cl := p.do("PUT", "/v1/profile", map[string]any{"name": "N", "avatarId": nil})
	if cl.body["avatarId"] != nil {
		t.Fatalf("%v", cl.body)
	}
	// Email cannot be changed through the profile.
	p.do("PUT", "/v1/profile", map[string]any{"name": "N", "email": "evil@example.com"})
	if p.do("GET", "/v1/profile", nil).body["email"] != "prof@example.com" {
		t.Fatal("email changed through PUT /profile")
	}
}

func TestEmailChange(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.register("old@example.com", "a good passphrase", "E")
	other := e.phone()
	other.signedIn(other.do("POST", "/v1/auth/login", map[string]any{"email": "old@example.com", "password": "a good passphrase"}))

	expect(t, p.do("POST", "/v1/auth/email-change", map[string]any{"newEmail": "new@example.com", "currentPassword": "wrong"}), 401, "invalid_credentials")
	r := p.do("POST", "/v1/auth/email-change", map[string]any{"newEmail": "new@example.com", "currentPassword": "a good passphrase"})
	expect(t, r, 202, "")
	code, _ := codeOf(t, e.lastMail("new@example.com"))
	// Another account cannot finish this account's change.
	intruder := e.phone()
	intruder.register("intruder@example.com", "a good passphrase", "I")
	expect(t, intruder.do("POST", "/v1/auth/email-change/verify", map[string]any{"flowId": r.str("flowId"), "code": code}), 404, "flow_not_found")

	done := p.do("POST", "/v1/auth/email-change/verify", map[string]any{"flowId": r.str("flowId"), "code": code})
	expect(t, done, 200, "")
	if done.body["email"] != "new@example.com" {
		t.Fatalf("%v", done.body)
	}
	if !strings.Contains(e.lastMail("old@example.com").Text, "ne•••@example.com") {
		t.Fatal("old address not told")
	}
	expect(t, other.do("GET", "/v1/profile", nil), 401, "")
	e.phone().signedIn(e.phone().do("POST", "/v1/auth/login", map[string]any{"email": "new@example.com", "password": "a good passphrase"}))
	expect(t, e.phone().do("POST", "/v1/auth/login", map[string]any{"email": "old@example.com", "password": "a good passphrase"}), 401, "")
}

// decodeEntitlement verifies the token the way the app does and returns
// its payload.
func (e *env) decodeEntitlement(tok, install string) map[string]any {
	e.t.Helper()
	parts := strings.Split(tok, ".")
	if len(parts) != 4 || parts[0] != "v1" {
		e.t.Fatalf("token shape %q", tok)
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[3])
	if !ed25519.Verify(e.pub, []byte(parts[0]+"."+parts[1]+"."+parts[2]), sig) {
		e.t.Fatal("entitlement signature invalid")
	}
	body, _ := base64.RawURLEncoding.DecodeString(parts[2])
	var m map[string]any
	_ = json.Unmarshal(body, &m)
	if m["ik"] != install {
		e.t.Fatalf("bound to %v, want %s", m["ik"], install)
	}
	return m
}

func TestSubscription(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.register("sub@example.com", "a good passphrase", "S")

	none := p.do("GET", "/v1/subscription", nil)
	expect(t, none, 200, "")
	if e.decodeEntitlement(none.str("entitlement"), p.install)["st"] != "none" {
		t.Fatal("expected none")
	}
	expect(t, p.do("GET", "/v1/subscription", nil, "X-Tark-Install-Key", "short"), 400, "invalid_request")

	idem := "3b241101-e2bb-4255-8caf-4136c566a962"
	body := map[string]any{"sku": "tark_premium_1m", "purchaseToken": "tok-1"}
	expect(t, p.do("POST", "/v1/subscription/bazaar/purchases", body), 400, "invalid_request") // no key
	r := p.do("POST", "/v1/subscription/bazaar/purchases", body, "Idempotency-Key", idem)
	expect(t, r, 200, "")
	m := e.decodeEntitlement(r.str("entitlement"), p.install)
	if m["st"] != "active" || m["ar"] != true || m["sus"] != false || m["sku"] != "tark_premium_1m" {
		t.Fatalf("%v", m)
	}
	if r.str("planTitle") != "Tark Premium, 1 month" {
		t.Fatalf("planTitle %q", r.str("planTitle"))
	}
	if fa := p.do("GET", "/v1/subscription", nil, "Accept-Language", "fa-IR"); fa.str("planTitle") != "اشتراک یک ماهه تَرک" {
		t.Fatalf("Persian planTitle %q", fa.str("planTitle"))
	}
	// Same key, same body: the first answer again.
	rep := p.do("POST", "/v1/subscription/bazaar/purchases", body, "Idempotency-Key", idem)
	if rep.header.Get("Idempotent-Replayed") != "true" || rep.str("entitlement") != r.str("entitlement") {
		t.Fatal("not replayed")
	}
	// Same key, different body.
	expect(t, p.do("POST", "/v1/subscription/bazaar/purchases", map[string]any{"sku": "tark_premium_1m", "purchaseToken": "tok-2"}, "Idempotency-Key", idem),
		422, "idempotency_mismatch")

	// The token belongs to this account only.
	q := e.phone()
	q.register("thief@example.com", "a good passphrase", "T")
	expect(t, q.do("POST", "/v1/subscription/bazaar/purchases", body, "Idempotency-Key", "0d2e7c1a-7777-4bbb-8ccc-123456789abc"), 409, "purchase_owned_elsewhere")

	// Unknown to Bazaar: the first answers may just be a fresh purchase not
	// visible yet; the third definitive "not found" makes it invalid.
	inv := map[string]any{"sku": "tark_premium_1m", "purchaseToken": "invalid-x"}
	for i := 0; i < 2; i++ {
		expect(t, q.do("POST", "/v1/subscription/bazaar/purchases", inv, "Idempotency-Key", "0d2e7c1a-7777-4bbb-8ccc-123456789abd"), 503, "purchase_not_found_yet")
		if _, err := e.pool.Exec(context.Background(), `UPDATE bazaar_purchases SET last_checked_at = now() - interval '2 minutes' WHERE state = 'pending'`); err != nil {
			t.Fatal(err)
		}
	}
	expect(t, q.do("POST", "/v1/subscription/bazaar/purchases", inv, "Idempotency-Key", "0d2e7c1a-7777-4bbb-8ccc-123456789abd"), 422, "purchase_invalid")

	// Bazaar down on first submission: retry later, nothing is lost.
	down := q.do("POST", "/v1/subscription/bazaar/purchases", map[string]any{"sku": "tark_premium_12m", "purchaseToken": "down-1"},
		"Idempotency-Key", "0d2e7c1a-7777-4bbb-8ccc-123456789abe")
	expect(t, down, 503, "bazaar_unavailable")
	e.bazaar.Set("down-1", billing.Subscription{InitiatedAt: time.Now(), ValidUntil: time.Now().Add(180 * 24 * time.Hour), AutoRenewing: false}, nil)
	up := q.do("POST", "/v1/subscription/bazaar/purchases", map[string]any{"sku": "tark_premium_12m", "purchaseToken": "down-1"},
		"Idempotency-Key", "0d2e7c1a-7777-4bbb-8ccc-123456789abe")
	expect(t, up, 200, "")
	if mm := e.decodeEntitlement(up.str("entitlement"), q.install); mm["st"] != "active" || mm["ar"] != false || mm["sus"] != false {
		t.Fatalf("auto-renew off must stay active and unsuspicious: %v", mm)
	}

	// Stale state + Bazaar outage: last known state, bazaarChecked=false,
	// never a downgrade.
	ctx := context.Background()
	stale := func() {
		if _, err := e.pool.Exec(ctx, `UPDATE bazaar_purchases SET last_checked_at = now() - interval '7 hours'`); err != nil {
			t.Fatal(err)
		}
	}
	stale()
	e.bazaar.Set("tok-1", billing.Subscription{}, billing.ErrUnavailable)
	g := p.do("GET", "/v1/subscription", nil)
	if g.body["bazaarChecked"] != false || e.decodeEntitlement(g.str("entitlement"), p.install)["st"] != "active" {
		t.Fatalf("outage downgraded: %v", g.body)
	}

	// One "not found" is treated as a glitch; the second, before the period
	// ends, is a refund and turns on the conservative mode.
	e.bazaar.Set("tok-1", billing.Subscription{}, billing.ErrNotFound)
	stale()
	if st := e.decodeEntitlement(p.do("GET", "/v1/subscription", nil).str("entitlement"), p.install)["st"]; st != "active" {
		t.Fatalf("one missing answer changed state to %v", st)
	}
	stale()
	ref := e.decodeEntitlement(p.do("GET", "/v1/subscription", nil).str("entitlement"), p.install)
	if ref["st"] != "refunded" || ref["sus"] != true {
		t.Fatalf("refund not detected: %v", ref)
	}

	// A new, clean paid period that has run its course clears the mode.
	e.bazaar.Set("tok-3", billing.Subscription{InitiatedAt: time.Now(), ValidUntil: time.Now().Add(30 * 24 * time.Hour), AutoRenewing: true}, nil)
	n := p.do("POST", "/v1/subscription/bazaar/purchases", map[string]any{"sku": "tark_premium_1m", "purchaseToken": "tok-3"},
		"Idempotency-Key", "0d2e7c1a-7777-4bbb-8ccc-123456789abf")
	if mm := e.decodeEntitlement(n.str("entitlement"), p.install); mm["st"] != "active" || mm["sus"] != true {
		t.Fatalf("new purchase while suspicious: %v", mm)
	}
	// Move the refund 40 days into the past, then let tok-3's month end.
	if _, err := e.pool.Exec(ctx, `
		UPDATE subscription_accounts SET suspicious_since = now() - interval '40 days';
		UPDATE bazaar_purchases SET refunded_at = now() - interval '40 days' WHERE state = 'refunded';
		UPDATE bazaar_purchases SET initiated_at = now() - interval '30 days', valid_until = now() - interval '1 hour' WHERE state = 'active';`); err != nil {
		t.Fatal(err)
	}
	e.bazaar.Set("tok-3", billing.Subscription{InitiatedAt: time.Now().Add(-30 * 24 * time.Hour), ValidUntil: time.Now().Add(-time.Hour), AutoRenewing: false}, nil)
	stale()
	fin := e.decodeEntitlement(p.do("GET", "/v1/subscription", nil).str("entitlement"), p.install)
	if fin["st"] != "expired" || fin["sus"] != false {
		t.Fatalf("clean period did not clear the mode: %v", fin)
	}
}

func TestPlans(t *testing.T) {
	e := setup(t)
	check := func(lang string, want []string) {
		t.Helper()
		r := e.phone().do("GET", "/v1/subscription/plans", nil, "Accept-Language", lang)
		expect(t, r, 200, "")
		plans, _ := r.body["plans"].([]any)
		if len(plans) != len(want) {
			t.Fatalf("%s: %v", lang, r.body)
		}
		for i, raw := range plans {
			p := raw.(map[string]any)
			if p["title"] != want[i] {
				t.Errorf("%s plan %d: title %v, want %s", lang, i, p["title"], want[i])
			}
		}
		if r.header.Get("Content-Language") != lang[:2] {
			t.Errorf("Content-Language %q", r.header.Get("Content-Language"))
		}
	}
	check("en", []string{"Tark Premium, 1 month", "Tark Premium, 3 months", "Tark Premium, 6 months", "Tark Premium, 1 year"})
	check("fa-IR,en;q=0.5", []string{"اشتراک یک ماهه تَرک", "اشتراک سه ماهه تَرک", "اشتراک شش ماهه تَرک", "اشتراک یک ساله تَرک"})

	r := e.phone().do("GET", "/v1/subscription/plans", nil)
	p := r.body["plans"].([]any)[1].(map[string]any)
	if p["sku"] != "tark_premium_3m" || p["months"] != float64(3) || p["days"] != float64(90) {
		t.Fatalf("%v", p)
	}
}

// The 5-minute test product is refused unless the server sells it, and
// sold only where TARK_BAZAAR_SKUS lists it.
func TestTestPlan(t *testing.T) {
	body := map[string]any{"sku": billing.TestSKU, "purchaseToken": "test-tok"}
	idem := "5c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f"

	prod := setup(t)
	p := prod.phone()
	p.register("prod@example.com", "a good passphrase", "P")
	expect(t, p.do("POST", "/v1/subscription/bazaar/purchases", body, "Idempotency-Key", idem), 400, "invalid_request")
	for _, raw := range p.do("GET", "/v1/subscription/plans", nil).body["plans"].([]any) {
		if raw.(map[string]any)["sku"] == billing.TestSKU {
			t.Fatal("production lists the test plan")
		}
	}

	test := setupPools(t, 10, 4, func(c *config.Config) {
		c.Bazaar.SKUs = append(c.Bazaar.SKUs, billing.TestSKU)
	})
	q := test.phone()
	q.register("tester@example.com", "a good passphrase", "T")
	plans := q.do("GET", "/v1/subscription/plans", nil, "Accept-Language", "fa").body["plans"].([]any)
	last := plans[len(plans)-1].(map[string]any)
	if last["sku"] != billing.TestSKU || last["minutes"] != float64(5) || last["months"] != float64(0) || last["title"] != "اشتراک تست ۵ دقیقه‌ای تَرک" {
		t.Fatalf("%v", last)
	}
	test.bazaar.Set("test-tok", billing.Subscription{InitiatedAt: time.Now(), ValidUntil: time.Now().Add(5 * time.Minute), AutoRenewing: true}, nil)
	r := q.do("POST", "/v1/subscription/bazaar/purchases", body, "Idempotency-Key", idem)
	expect(t, r, 200, "")
	if m := test.decodeEntitlement(r.str("entitlement"), q.install); m["st"] != "active" || m["sku"] != billing.TestSKU {
		t.Fatalf("%v", m)
	}
	if r.str("planTitle") != "Tark Premium, 5-minute test" {
		t.Fatalf("planTitle %q", r.str("planTitle"))
	}

	// Renewal turned off in Bazaar: an ordinary GET serves the stored answer,
	// one that asks for no-cache (the subscription page) sees the change.
	test.bazaar.Set("test-tok", billing.Subscription{InitiatedAt: time.Now(), ValidUntil: time.Now().Add(5 * time.Minute), AutoRenewing: false}, nil)
	if _, err := test.pool.Exec(context.Background(), `UPDATE bazaar_purchases SET last_checked_at = now() - interval '2 minutes'`); err != nil {
		t.Fatal(err)
	}
	if m := test.decodeEntitlement(q.do("GET", "/v1/subscription", nil).str("entitlement"), q.install); m["ar"] != true {
		t.Fatalf("stored answer not served: %v", m)
	}
	if m := test.decodeEntitlement(q.do("GET", "/v1/subscription", nil, "Cache-Control", "no-cache").str("entitlement"), q.install); m["st"] != "active" || m["ar"] != false {
		t.Fatalf("fresh check missed the cancelled renewal: %v", m)
	}
}

func TestErrorsAreInTheCallersLanguage(t *testing.T) {
	e := setup(t)
	en := e.phone().do("GET", "/v1/subscription", nil)
	expect(t, en, 401, "unauthorized")
	if en.str("message") != "You've been signed out. Please sign in again." {
		t.Fatalf("en message %q", en.str("message"))
	}
	fa := e.phone().do("GET", "/v1/subscription", nil, "Accept-Language", "fa")
	if fa.str("message") != "از حسابت خارج شدی. لطفاً دوباره وارد شو." {
		t.Fatalf("fa message %q", fa.str("message"))
	}
	nf := e.phone().do("GET", "/v1/nothing-here", nil, "Accept-Language", "fa")
	expect(t, nf, 404, "not_found")
	if nf.str("message") == "" || nf.header.Get("Content-Language") != "fa" {
		t.Fatalf("404 not localized: %v %v", nf.body, nf.header)
	}
}

func TestSubscriptionNeedsSignIn(t *testing.T) {
	e := setup(t)
	expect(t, e.phone().do("GET", "/v1/subscription", nil), 401, "unauthorized")
	expect(t, e.phone().do("GET", "/v1/profile", nil, "Authorization", "Bearer tat1.forged.token"), 401, "unauthorized")
}

func TestConcurrentPurchaseSubmissions(t *testing.T) {
	e := setup(t)
	a, b := e.phone(), e.phone()
	a.register("a@example.com", "a good passphrase", "A")
	b.register("b@example.com", "a good passphrase", "B")
	body := map[string]any{"sku": "tark_premium_12m", "purchaseToken": "shared-token"}
	var wg sync.WaitGroup
	results := make([]int, 2)
	for i, c := range []*caller{a, b} {
		wg.Add(1)
		go func(i int, c *caller) {
			defer wg.Done()
			results[i] = c.do("POST", "/v1/subscription/bazaar/purchases", body, "Idempotency-Key", fmt.Sprintf("0d2e7c1a-7777-4bbb-8ccc-00000000000%d", i)).status
		}(i, c)
	}
	wg.Wait()
	if !((results[0] == 200 && results[1] == 409) || (results[0] == 409 && results[1] == 200)) {
		t.Fatalf("exactly one account should own the token, got %v", results)
	}
}

func TestAccountDeletion(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.register("gone@example.com", "a good passphrase", "Gone")
	other := e.phone()
	other.signedIn(other.do("POST", "/v1/auth/login", map[string]any{"email": "gone@example.com", "password": "a good passphrase"}))
	buy := map[string]any{"sku": "tark_premium_12m", "purchaseToken": "tok-del"}
	expect(t, p.do("POST", "/v1/subscription/bazaar/purchases", buy, "Idempotency-Key", "0f4c7a51-1b8e-4d52-9a3c-6b1e2d3f4a5b"), 200, "")

	ok := map[string]any{"confirmEmail": " Gone@Example.com ", "currentPassword": "a good passphrase", "locale": "en"}
	// A tap is not a confirmation: the email has to be typed.
	expect(t, p.do("POST", "/v1/account/delete", map[string]any{"currentPassword": "a good passphrase"}), 422, "confirmation_mismatch")
	expect(t, p.do("POST", "/v1/account/delete", map[string]any{"confirmEmail": "other@example.com", "currentPassword": "a good passphrase"}), 422, "confirmation_mismatch")
	expect(t, p.do("POST", "/v1/account/delete", map[string]any{"confirmEmail": "gone@example.com", "currentPassword": "not it"}), 401, "invalid_credentials")
	expect(t, p.do("POST", "/v1/account/delete", map[string]any{"confirmEmail": "gone@example.com"}), 400, "")
	// A running paid period needs its own acknowledgement.
	sub := p.do("POST", "/v1/account/delete", ok)
	expect(t, sub, 409, "subscription_active")
	if sub.body["autoRenewing"] != true {
		t.Fatalf("%v", sub.body)
	}
	expect(t, e.phone().do("POST", "/v1/account/delete", ok), 401, "")

	ok["subscriptionAcknowledged"] = true
	expect(t, p.do("POST", "/v1/account/delete", ok), 204, "")
	if m := e.lastMail("gone@example.com"); m.Subject != "Your Tark account was deleted" {
		t.Fatalf("last mail %q", m.Subject)
	}

	// Every session is gone, and so is the account.
	expect(t, p.do("GET", "/v1/profile", nil), 401, "")
	expect(t, other.do("GET", "/v1/profile", nil), 401, "")
	expect(t, other.do("POST", "/v1/auth/token/refresh", map[string]any{"refreshToken": other.refresh}), 401, "")
	expect(t, e.phone().do("POST", "/v1/auth/login", map[string]any{"email": "gone@example.com", "password": "a good passphrase"}), 401, "invalid_credentials")
	var left int
	if err := e.pool.QueryRow(context.Background(), `
		SELECT (SELECT count(*) FROM users) + (SELECT count(*) FROM user_emails) + (SELECT count(*) FROM sessions)
		     + (SELECT count(*) FROM bazaar_purchases) + (SELECT count(*) FROM audit_events WHERE user_id IS NOT NULL)
		     + (SELECT count(*) FROM idempotency_keys WHERE scope LIKE 'user:%')`).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Fatalf("%d rows still tied to the deleted account", left)
	}

	// The address can sign up again, and the purchase can be restored there.
	n := e.phone()
	n.register("gone@example.com", "another passphrase", "Back")
	expect(t, n.do("POST", "/v1/subscription/bazaar/purchases", buy, "Idempotency-Key", "7d2e9c14-3a6b-4f81-b5d0-2c9e8a7f6b13"), 200, "")
}

func TestGoogleOnlyAccountDeletion(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.signedIn(p.do("POST", "/v1/auth/google", map[string]any{"idToken": p.googleToken("g-del", "gdel@gmail.com", "G"), "name": "G"}))
	body := map[string]any{"confirmEmail": "gdel@gmail.com"}
	expect(t, p.do("POST", "/v1/account/delete", body), 400, "")
	body["googleIdToken"] = p.googleToken("g-someone-else", "x@gmail.com", "")
	expect(t, p.do("POST", "/v1/account/delete", body), 401, "invalid_credentials")
	body["googleIdToken"] = p.googleToken("g-del", "gdel@gmail.com", "")
	expect(t, p.do("POST", "/v1/account/delete", body), 204, "")
	// The Google account can make a fresh account afterwards.
	q := e.phone()
	r := q.do("POST", "/v1/auth/google", map[string]any{"idToken": q.googleToken("g-del", "gdel@gmail.com", ""), "name": "G"})
	q.signedIn(r)
	if r.body["newAccount"] != true {
		t.Fatalf("%v", r.body)
	}
}

// Audit and rate-limit writes happen while a request holds a transaction
// connection. On a shared pool, as many concurrent requests as there are
// connections each wait for a second one and none ever gets it (measured
// before the auxiliary pool existed: 40 of 40 requests hung on a pool of 4).
func TestSmallPoolDoesNotDeadlock(t *testing.T) {
	e := setupPools(t, 4, 2)
	const n = 40
	flows := make([]string, n)
	for i := range flows {
		r := e.phone().do("POST", "/v1/auth/register", map[string]any{
			"email": fmt.Sprintf("pool%d@example.com", i), "password": "a good passphrase", "name": "P"})
		expect(t, r, http.StatusAccepted, "")
		flows[i] = r.str("flowId")
	}
	var wg sync.WaitGroup
	statuses := make([]int, n)
	for i := range flows {
		wg.Add(1)
		go func() {
			defer wg.Done()
			body, _ := json.Marshal(map[string]any{"flowId": flows[i], "code": "000000"})
			req, _ := http.NewRequest("POST", e.srv.URL+"/v1/auth/register/verify", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Forwarded-For", fmt.Sprintf("10.8.%d.%d", i/200, i%200+1))
			res, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
			if err != nil {
				statuses[i] = -1
				return
			}
			res.Body.Close()
			statuses[i] = res.StatusCode
		}()
	}
	wg.Wait()
	for i, st := range statuses {
		if st != http.StatusUnprocessableEntity && st != http.StatusLocked {
			t.Fatalf("request %d got %d; a wrong code must be answered, not hang", i, st)
		}
	}
}

// Bazaar can take seconds to answer. No database connection or row lock may
// be held meanwhile, or a slow Bazaar starves the pool for everyone.
func TestNoDatabaseConnectionHeldWhileAskingBazaar(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.register("bazaar-pool@example.com", "a good passphrase", "B")

	var held []int32
	e.bazaar.OnCall = func() { held = append(held, e.pool.Stat().AcquiredConns()) }

	r := p.do("POST", "/v1/subscription/bazaar/purchases", map[string]any{"sku": "tark_premium_1m", "purchaseToken": "tok-pool-1"},
		"Idempotency-Key", "6f1c1e0e-5a58-4f5e-9d63-0a4b6a2f9c01")
	expect(t, r, http.StatusOK, "")

	// Make the purchase stale so GET /subscription asks Bazaar again.
	if _, err := e.pool.Exec(context.Background(), `UPDATE bazaar_purchases SET last_checked_at = now() - interval '7 hours'`); err != nil {
		t.Fatal(err)
	}
	expect(t, p.do("GET", "/v1/subscription", nil), http.StatusOK, "")

	if len(held) < 2 {
		t.Fatalf("expected Bazaar to be asked by submit and by the stale re-check, got %d calls", len(held))
	}
	for i, n := range held {
		// The request's own authentication check has returned its connection
		// by now; nothing may be acquired.
		if n != 0 {
			t.Errorf("call %d: %d database connection(s) held while Bazaar was being asked", i, n)
		}
	}
}

// Parallel guesses must be counted atomically: with a check-then-count lockout
// every request in a burst passes the check before any is counted. The
// per-address limit is 20 an hour, however many IPs the guesses come from.
func TestParallelGuessesAreCountedAtomically(t *testing.T) {
	e := setup(t)
	e.phone().register("burst@example.com", "a good passphrase", "B")

	const n = 60
	var wg sync.WaitGroup
	var wrong, limited atomic.Int64
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := e.phone().do("POST", "/v1/auth/login", map[string]any{"email": "burst@example.com", "password": "not the password"})
			switch r.status {
			case http.StatusUnauthorized:
				wrong.Add(1)
			case http.StatusTooManyRequests:
				limited.Add(1)
			}
		}()
	}
	wg.Wait()
	if wrong.Load() > 20 || wrong.Load()+limited.Load() != n {
		t.Fatalf("%d guesses reached the password check (limit 20), %d were limited, of %d", wrong.Load(), limited.Load(), n)
	}

	// The right password from a fresh phone is refused too while locked out.
	expect(t, e.phone().do("POST", "/v1/auth/login", map[string]any{"email": "burst@example.com", "password": "a good passphrase"}), 429, "rate_limited")
}

// A correct password hands the attempt back, so a person who signs in
// normally never drifts towards the limit.
func TestSuccessfulLoginsDoNotUseUpTheLimit(t *testing.T) {
	e := setup(t)
	p := e.phone()
	p.register("steady@example.com", "a good passphrase", "S")
	q := e.phone()
	for i := 0; i < 30; i++ {
		q.signedIn(q.do("POST", "/v1/auth/login", map[string]any{"email": "steady@example.com", "password": "a good passphrase"}))
		if i%10 == 9 {
			q = e.phone() // a new IP now and then keeps clear of the per-IP cap
		}
	}
}

// Premium given in the admin panel shows in the entitlement while it runs,
// loses to a longer paid period, and stops when revoked.
func TestPremiumGrantAndAdminDeletion(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	p := e.phone()
	p.register("gift@example.com", "a good passphrase", "G")
	var uid string
	if err := e.pool.QueryRow(ctx, `SELECT user_id FROM user_emails WHERE email = 'gift@example.com'`).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	st := func() map[string]any {
		return e.decodeEntitlement(p.do("GET", "/v1/subscription", nil).str("entitlement"), p.install)
	}
	if st()["st"] != "none" {
		t.Fatal("expected none before the grant")
	}
	var gid string
	if err := e.pool.QueryRow(ctx, `INSERT INTO premium_grants (user_id, reason, ends_at) VALUES ($1, 'tester', now() + interval '30 days') RETURNING id`, uid).Scan(&gid); err != nil {
		t.Fatal(err)
	}
	got := st()
	if got["st"] != "active" || got["sku"] != "comp" || got["ar"] != false || got["until"] == nil {
		t.Fatalf("with a grant: %v", got)
	}
	if _, err := e.pool.Exec(ctx, `UPDATE premium_grants SET revoked_at = now() WHERE id = $1`, gid); err != nil {
		t.Fatal(err)
	}
	if st()["st"] != "none" {
		t.Fatal("revoked grant still counts")
	}

	if err := e.app.AdminDeps.Accounts.DeleteByAdmin(ctx, uid, "fa"); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := e.pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE id = $1`, uid).Scan(&n); err != nil || n != 0 {
		t.Fatalf("account still there: %d %v", n, err)
	}
	if m := e.lastMail("gift@example.com"); m.Subject == "" {
		t.Fatal("no deletion email")
	}
	expect(t, p.do("GET", "/v1/subscription", nil), 401, "")
}

func TestRequestMetrics(t *testing.T) {
	e := setup(t)
	p := e.phone()
	expect(t, p.do("POST", "/v1/auth/login", map[string]any{"email": "nobody@example.com", "password": "whatever123"}), 401, "invalid_credentials")
	p.do("GET", "/wp-admin/setup.php", nil)
	p.do("GET", "/also/not/here", nil)
	p.do("BREW", "/v1/profile", nil)
	routes := e.app.Metrics.Now().Routes
	if r := routes["POST /v1/auth/login"]; r.ByClass[2] != 1 || r.Latency.N != 1 {
		t.Fatalf("login: %+v", r)
	}
	// Unmatched paths and made-up methods share rows, so scanners cannot
	// grow the table.
	if r := routes["GET (no route)"]; r.Requests() != 2 {
		t.Fatalf("no route: %+v", routes)
	}
	for k := range routes {
		if strings.Contains(k, "wp-admin") || strings.Contains(k, "BREW") {
			t.Fatalf("raw path or method recorded: %q", k)
		}
	}
}
