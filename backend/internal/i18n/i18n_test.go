package i18n

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/HPTarkk/Tark/backend/internal/mail"
)

func TestFromHeader(t *testing.T) {
	cases := map[string]string{
		"":                        EN,
		"fa":                      FA,
		"fa-IR":                   FA,
		"FA_ir":                   FA,
		"en-US,en;q=0.9":          EN,
		"de-DE,fa;q=0.8,en;q=0.5": FA,
		"en;q=0.4, fa;q=0.9":      FA,
		"fa;q=0, en":              EN,
		"fa;q=0":                  EN,
		"de, fr":                  EN,
		"fa;q=abc, en;q=0.1":      EN,
		"en, fa":                  EN,
		"fa, en":                  FA,
		"*":                       EN,
		strings.Repeat("x,", 200): EN,
	}
	for header, want := range cases {
		if got := FromHeader(header); got != want {
			t.Errorf("FromHeader(%q) = %q, want %q", header, got, want)
		}
	}
}

func TestDigits(t *testing.T) {
	if got := Digits(FA, 3); got != "۳" {
		t.Errorf("Digits(fa, 3) = %q", got)
	}
	if got := GroupedDigits(FA, 1250000); got != "۱٬۲۵۰٬۰۰۰" {
		t.Errorf("GroupedDigits(fa) = %q", got)
	}
	if got := GroupedDigits(EN, 99000); got != "99,000" {
		t.Errorf("GroupedDigits(en) = %q", got)
	}
	if got := GroupedDigits(EN, 100); got != "100" {
		t.Errorf("GroupedDigits(en, 100) = %q", got)
	}
}

func TestSupportEmailMatchesMail(t *testing.T) {
	if supportEmail != mail.SupportEmail {
		t.Fatalf("supportEmail %q != mail.SupportEmail %q", supportEmail, mail.SupportEmail)
	}
}

func TestErrorMessageRefinements(t *testing.T) {
	if got := ErrorMessage(FA, "code_invalid", map[string]any{"attemptsLeft": 2}); !strings.Contains(got, "۲") {
		t.Errorf("attempts not filled: %q", got)
	}
	if got := ErrorMessage(EN, "invalid_request", map[string]any{"field": "email"}); !strings.Contains(got, "email") {
		t.Errorf("field wording missing: %q", got)
	}
	if got := ErrorMessage(EN, "account_disabled", nil); !strings.Contains(got, mail.SupportEmail) {
		t.Errorf("email not filled: %q", got)
	}
	if got := ErrorMessage(EN, "no_such_code", nil); got != errorMessages["internal_error"].en {
		t.Errorf("unknown code: %q", got)
	}
}

func TestEveryMessageHasBothLanguages(t *testing.T) {
	all := map[string]text{"attempts": codeWithAttempts, "wrongPassword": wrongPassword}
	for k, v := range errorMessages {
		all[k] = v
	}
	for k, v := range fieldMessages {
		all["field:"+k] = v
	}
	for k, v := range all {
		if strings.TrimSpace(v.en) == "" || strings.TrimSpace(v.fa) == "" {
			t.Errorf("%s is missing a language", k)
		}
		if strings.ContainsAny(v.fa, "{}") != strings.ContainsAny(v.en, "{}") {
			t.Errorf("%s: placeholders differ between languages", k)
		}
	}
}

// codeLiteral finds the code argument of every apperr constructor, plus
// the codes password.Problem returns.
var codeLiteral = regexp.MustCompile(`apperr\.(?:New\([^,]+,\s*|BadRequest\(|Conflict\(|Unprocessable\(|NotFound\(|Unavailable\()"([a-z_]+)"|Code:\s*"([a-z_]+)"|return "([a-z]+_[a-z_]+)"`)

func TestEveryCodeHasMessage(t *testing.T) {
	root := filepath.Join("..")
	found := map[string]bool{"unauthorized": true, "rate_limited": true}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") ||
			strings.Contains(path, string(filepath.Separator)+"i18n"+string(filepath.Separator)) ||
			strings.Contains(path, string(filepath.Separator)+"admin"+string(filepath.Separator)) {
			return nil
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		isPassword := strings.HasSuffix(path, filepath.Join("password", "password.go"))
		for _, m := range codeLiteral.FindAllStringSubmatch(string(src), -1) {
			switch {
			case m[1] != "":
				found[m[1]] = true
			case m[2] != "":
				found[m[2]] = true
			case m[3] != "" && isPassword:
				found[m[3]] = true
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(found) < 30 {
		t.Fatalf("found only %d codes; is the pattern still right?", len(found))
	}
	for code := range found {
		if !HasErrorMessage(code) {
			t.Errorf("Problem code %q has no message in errorMessages", code)
		}
	}
}
