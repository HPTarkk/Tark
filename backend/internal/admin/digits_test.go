package admin

import (
	"context"
	"html"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

var (
	// Parts of a page that are not numbers to read: scripts, styles,
	// pictures, codes and ids, values typed in or posted back, and text
	// marked left to right on purpose (emails, ids, raw details).
	verbatimRE = regexp.MustCompile(`(?s)<script.*?</script>|<style.*?</style>|<svg.*?</svg>|<code.*?</code>|<pre.*?</pre>|<textarea.*?</textarea>|<bdi class="v ltr".*?</bdi>|<bdi class="ltr".*?</bdi>|<span class="ltr email">.*?</span>|<title>.*?</title>`)
	tagRE      = regexp.MustCompile(`(?s)<[^>]*>`)
	// Shown attributes, which are read like text.
	shownAttrRE = regexp.MustCompile(`\s(?:title|aria-label|data-n|data-confirm|data-confirm-x|data-done)="([^"]*)"`)
	// Codes that are written with digits in Persian too.
	codesRE = regexp.MustCompile(`[0-9]xx|HTTP [0-9]+|fetch-backups\.ps1|2FAS|[0-9a-f]{8}`)
	latinRE = regexp.MustCompile(`[0-9]+`)
)

// latinDigitsIn lists the Latin digits a Persian reader would see on a page.
func latinDigitsIn(body string) []string {
	var seen []string
	check := func(s string) {
		s = codesRE.ReplaceAllString(html.UnescapeString(s), "")
		for _, m := range latinRE.FindAllStringIndex(s, -1) {
			from, to := max(0, m[0]-30), min(len(s), m[1]+30)
			seen = append(seen, strings.Join(strings.Fields(s[from:to]), " "))
		}
	}
	for _, m := range shownAttrRE.FindAllStringSubmatch(body, -1) {
		// A title may hold the stored id or details, raw, for hovering.
		v := html.UnescapeString(m[1])
		if strings.Contains(m[0], "title=") && (uuidish.MatchString(v) || strings.HasPrefix(v, "{")) {
			continue
		}
		check(m[1])
	}
	text := verbatimRE.ReplaceAllString(body, " ")
	text = tagRE.ReplaceAllString(text, " ")
	check(text)
	return seen
}

// TestPersianPagesWriteNumbersInPersian walks every page in Persian with
// data on it and fails on any number written in Latin digits, so a new
// number on a page cannot skip the shared formatting (numbers.go).
func TestPersianPagesWriteNumbersInPersian(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	const uid = "11111111-1111-1111-1111-111111111111"
	for _, q := range []string{
		`INSERT INTO users (id, name, created_at) VALUES ('` + uid + `', 'Rider', now() - interval '3 days')`,
		`INSERT INTO user_emails (user_id, email, is_primary, verified_at) VALUES ('` + uid + `', 'rider42@example.com', true, now())`,
		`INSERT INTO sessions (user_id, expires_at) VALUES ('` + uid + `', now() + interval '1 day')`,
		`INSERT INTO bazaar_purchases (id, user_id, token_hash, token_enc, sku, state) VALUES ('33333333-3333-3333-3333-333333333333', '` + uid + `', '\x01', '\x01', 'tark_premium_1m', 'active')`,
		`INSERT INTO subscription_accounts (user_id, suspicious_since) VALUES ('` + uid + `', now())`,
		`INSERT INTO alert_state (key, firing, since, detail) VALUES ('slow', true, now(), '9 of 20 requests were slow')`,
		`INSERT INTO backup_runs (finished_at, ok, file, bytes, row_count) VALUES (now(), true, 'tark-2026-10-21.dump', 23456789, 12345)`,
	} {
		if _, err := e.deps.Pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	for i := range 40 {
		e.deps.Metrics.ObserveRequest("POST", "/v1/auth/login", 200, time.Duration(20+i*40)*time.Millisecond)
	}
	e.deps.Metrics.ObserveRequest("GET", "/v1/me", 500, 3*time.Second)
	today := time.Now().UTC().Format(time.DateOnly)
	if err := os.WriteFile(e.deps.LogDir+"/tark-"+today+".log", []byte(`{"time":"t1","level":"ERROR","msg":"backup failed","ms":42}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	b := e.owner("boss@example.com")
	u, _ := url.Parse(e.ts.URL)
	b.c.Jar.SetCookies(u, []*http.Cookie{{Name: langCookie, Value: langFA}})
	// Some events and saved prices, so their tables have numbers in them.
	_, body := b.get("/pricing")
	b.post("/pricing", url.Values{"csrf": {field(t, body, "csrf")}, "base": {"99,000"}, "adjustment": {"1.15"},
		"mult_tark_premium_1m": {"1"}, "mult_tark_premium_3m": {"2.7"}, "mult_tark_premium_6m": {"5"}, "mult_tark_premium_12m": {"9"},
		"round_to": {"10,000"}, "ending": {"1,000"}})
	_, body = b.get("/users/" + uid)
	b.post("/users/"+uid+"/grant", url.Values{"csrf": {field(t, body, "csrf")}, "months": {"3"}, "reason": {"thanks for testing"}})

	for _, p := range []string{"/", "/system", "/users", "/users/" + uid, "/security", "/mail", "/admins", "/pricing", "/backups", "/activity", "/logs", "/logs?days=7", "/settings"} {
		code, body := b.get(p)
		if code != http.StatusOK {
			t.Errorf("%s: %d", p, code)
			continue
		}
		if !strings.Contains(body, `lang="fa"`) {
			t.Fatalf("%s is not in Persian", p)
		}
		for _, s := range latinDigitsIn(body) {
			t.Errorf("%s shows Latin digits: …%s…", p, s)
		}
	}
	// Signed out pages too.
	out := e.persianBrowser()
	for _, p := range []string{"/login"} {
		_, body := out.get(p)
		for _, s := range latinDigitsIn(body) {
			t.Errorf("%s shows Latin digits: …%s…", p, s)
		}
	}
}
