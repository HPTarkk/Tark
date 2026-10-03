package admin

import (
	"io/fs"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"
)

// Every key a template or the Go code asks for exists, in both languages,
// with the same placeholders.
func TestEveryTextKnown(t *testing.T) {
	var used []string
	tmplKey := regexp.MustCompile(`\bt "([a-zA-Z0-9.]+)"`)
	names, _ := fs.Glob(assets, "templates/*.html")
	for _, n := range names {
		b, _ := fs.ReadFile(assets, n)
		for _, m := range tmplKey.FindAllStringSubmatch(string(b), -1) {
			used = append(used, m[1])
		}
	}
	goKey := regexp.MustCompile(`\bT\([a-zA-Z.()]+, "([a-zA-Z0-9.]+)"|\btr\([a-zA-Z(),]+, "([a-zA-Z0-9.]+)"`)
	files, _ := fs.Glob(os.DirFS("."), "*.go")
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, _ := os.ReadFile(f)
		for _, m := range goKey.FindAllStringSubmatch(string(b), -1) {
			used = append(used, m[1]+m[2])
		}
	}
	if len(used) < 200 {
		t.Fatalf("found only %d keys in use; the patterns above are broken", len(used))
	}
	for _, k := range used {
		if _, ok := texts[k]; !ok {
			t.Errorf("no text for %q", k)
		}
	}
	verb := regexp.MustCompile(`%[-+# 0-9.\[\]]*[a-zA-Z%]`)
	for k, v := range texts {
		if v[0] == "" || v[1] == "" {
			t.Errorf("%s: a language is empty", k)
		}
		if en, fa := verb.FindAllString(v[0], -1), verb.FindAllString(v[1], -1); strings.Join(en, " ") != strings.Join(fa, " ") {
			t.Errorf("%s: placeholders differ: %v vs %v", k, en, fa)
		}
	}
}

func TestSafeNext(t *testing.T) {
	for in, want := range map[string]string{
		"":                     "/",
		"/users?q=a@b.c":       "/users?q=a@b.c",
		"/users/x":             "/users/x",
		"//evil.example":       "/",
		"https://evil.example": "/",
		"/\\\\evil.example":    "/",
		"users":                "/",
	} {
		if got := safeNext(in); got != want {
			t.Errorf("safeNext(%q) = %q, want %q", in, got, want)
		}
	}
}

// The panel opens in Persian, right to left, and the switch keeps the page.
func TestLanguageSwitch(t *testing.T) {
	e := setup(t)
	b := e.persianBrowser()
	_, body := b.get("/login")
	if !strings.Contains(body, `<html lang="fa" dir="rtl">`) || !strings.Contains(body, tr(langFA, "login.lead")) {
		t.Fatalf("login is not Persian by default:\n%s", body)
	}
	if !strings.Contains(body, `href="/lang/en?next=%2flogin"`) {
		t.Fatalf("no switch to English:\n%s", body)
	}
	b.c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	res, err := b.c.Get(e.ts.URL + "/lang/en?next=%2Flogin")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/login" {
		t.Fatalf("switch: %d %s", res.StatusCode, res.Header.Get("Location"))
	}
	b.c.CheckRedirect = nil
	if _, body := b.get("/login"); !strings.Contains(body, `<html lang="en" dir="ltr">`) || !strings.Contains(body, "Sign in with your admin email") {
		t.Fatalf("switch did not stick:\n%s", body)
	}
	if code, _ := b.get("/lang/de"); code != http.StatusNotFound {
		t.Fatalf("unknown language: %d", code)
	}
	// A refused sign-in answers in Persian too.
	p := e.persianBrowser()
	_, body = p.get("/login")
	if _, body := p.post("/login", map[string][]string{"pre": {field(t, body, "pre")}, "email": {"x@example.com"}, "password": {"nope"}}); !strings.Contains(body, tr(langFA, "login.wrong")) {
		t.Fatalf("refusal not in Persian:\n%s", body)
	}
}
