package admin

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Every kind the backend writes has words, an icon and a tone, so no table
// falls back to a bare code.
func TestEveryEventKindNamed(t *testing.T) {
	var kinds []string
	patterns := []*regexp.Regexp{
		regexp.MustCompile(`s\.record\(ctx, [^,]+, "([a-z_.]+)"`),
		regexp.MustCompile(`s\.act\("([a-z_.]+)"`),
		regexp.MustCompile(`kind(?: :)?= "([a-z_.]+)"`),
		regexp.MustCompile(`\t\w+ += "([a-z_]+\.[a-z_]+)"`),             // audit constants
		regexp.MustCompile(`event\(ctx, tx, [^,]+, [^,]+, "([a-z_]+)"`), // billing
		regexp.MustCompile(`INSERT INTO subscription_events \(user_id, kind, details\) VALUES \(\$1, '([a-z_]+)'`),
	}
	for _, dir := range []string{".", "../audit", "../billing"} {
		files, _ := filepath.Glob(filepath.Join(dir, "*.go"))
		for _, f := range files {
			if strings.HasSuffix(f, "_test.go") || strings.HasSuffix(f, "events.go") {
				continue
			}
			b, _ := os.ReadFile(f)
			for _, re := range patterns {
				for _, m := range re.FindAllStringSubmatch(string(b), -1) {
					kinds = append(kinds, m[1])
				}
			}
		}
	}
	if len(kinds) < 50 {
		t.Fatalf("found only %d kinds; the patterns above are broken", len(kinds))
	}
	for _, k := range kinds {
		if _, ok := eventKinds[k]; !ok {
			t.Errorf("no look for event kind %q", k)
		}
	}
	for k, v := range eventKinds {
		if _, ok := texts["ev."+k]; !ok {
			t.Errorf("no words for event kind %q", k)
		}
		if _, ok := icons[v.icon]; !ok {
			t.Errorf("%s: no icon %q", k, v.icon)
		}
	}
}

func TestEventLabel(t *testing.T) {
	got := string(eventLabel(langFA, "user.email_revealed"))
	for _, want := range []string{`class="ev t-warn"`, `title="user.email_revealed"`, tr(langFA, "ev.user.email_revealed"), `<svg`} {
		if !strings.Contains(got, want) {
			t.Errorf("label lacks %q:\n%s", want, got)
		}
	}
	if got := string(eventLabel(langEN, "new.<kind>")); got != `<code class="kind">new.&lt;kind&gt;</code>` {
		t.Errorf("unknown kind = %s", got)
	}
}

func TestEventDetails(t *testing.T) {
	for _, raw := range []string{"", "{}", " {} ", "null"} {
		if got := eventDetails(langFA, raw); got != "" {
			t.Errorf("%q shows %q", raw, got)
		}
	}
	got := string(eventDetails(langFA, `{"role": "viewer", "email": "a@b.co"}`))
	for _, want := range []string{tr(langFA, "dk.email"), `dir="ltr">a@b.co</bdi>`, tr(langFA, "role.viewer"), `title="{&#34;role&#34;: &#34;viewer&#34;, &#34;email&#34;: &#34;a@b.co&#34;}"`} {
		if !strings.Contains(got, want) {
			t.Errorf("details lack %q:\n%s", want, got)
		}
	}
	if strings.Index(got, tr(langFA, "dk.email")) > strings.Index(got, tr(langFA, "dk.role")) {
		t.Errorf("email should come before role:\n%s", got)
	}
	for raw, want := range map[string]string{
		`{"emails": 1}`:                 `Emails</span><span class="v">1<`,
		`{"months": 3}`:                 "3 months",
		`{"months": 1}`:                 "1 month",
		`{"known": false}`:              ">no<",
		`{"purpose": "password_reset"}`: "password reset",
		`{"reason": "token_revoked"}`:   "Bazaar revoked the purchase",
		`{"base": 1250000}`:             "1,250,000 Toman",
		`{"grant": "0b6c1e9a-1111-4222-8333-944445555666"}`: `title="0b6c1e9a-1111-4222-8333-944445555666">0b6c1e9a<`,
		`{"multipliers": {"m3": 2.7, "m1": 1}}`:             `m1 ×1</bdi><span class="sep" aria-hidden="true">·</span><bdi class="ltr" dir="ltr">m3 ×2.7`,
		`{"reason": "<b>x</b>"}`:                            "&lt;b&gt;x&lt;/b&gt;",
		`[1, 2]`:                                            `<code class="raw">[1, 2]</code>`,
		`{"until": "2026-10-03T08:00:00Z"}`:                 "3 Oct 2026",
	} {
		if got := string(eventDetails(langEN, raw)); !strings.Contains(got, want) {
			t.Errorf("%s: want %q in\n%s", raw, want, got)
		}
	}
	if got := string(eventDetails(langEN, `{"reason": "asked by support"}`)); !strings.Contains(got, `class="kv note"`) {
		t.Errorf("free reason is not a note:\n%s", got)
	}
}
