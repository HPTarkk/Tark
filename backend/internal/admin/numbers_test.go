package admin

import (
	"math"
	"testing"
	"time"
)

func TestNumbers(t *testing.T) {
	n7, nilInt := int64(7), (*int64)(nil)
	for _, c := range []struct{ got, want string }{
		{num(langEN, 1250000), "1,250,000"},
		{num(langFA, 1250000), "۱٬۲۵۰٬۰۰۰"},
		{num(langFA, -1234), "-۱٬۲۳۴"},
		{num(langFA, 0), "۰"},
		{num(langFA, &n7), "۷"},
		{num(langFA, nilInt), "-"},
		{num(langFA, 2.75), "۲٫۷۵"},
		{num(langEN, uint64(999)), "999"},
		{pct(langFA, 12), "۱۲٪"},
		{pct(langEN, 12), "12%"},
		{localNum(langFA, "97%"), "۹۷٪"},
		{localNum(langFA, "-"), "-"},
		{localNum(langFA, "2026-10-21"), "۲۰۲۶-۱۰-۲۱"},
		{localNum(langFA, "1,000 و 2.5"), "۱٬۰۰۰ و ۲٫۵"},
		// a comma or dot that is not between digits is text, not a separator
		{localNum(langFA, "3, then 4."), "۳, then ۴."},
		{localNum(langEN, "1,000"), "1,000"},
		{decimal(langFA, 1.15), "۱٫۱۵"},
		{megabytes(langFA, 21.3*(1<<20)), "۲۱٫۳ مگابایت"},
		{megabytes(langEN, 1<<20), "1.0 MB"},
		{latencyIn(langFA, 0.5), "≤ ۵۰۰ میلی‌ثانیه"},
		{latencyIn(langEN, 0.25), "≤ 250 ms"},
		{latencyIn(langEN, 2.5), "≤ 2.5 s"},
		{latencyIn(langFA, math.Inf(1)), "> ۱۰ ثانیه"},
		{latencyIn(langFA, 0), "-"},
		{duration(langEN, 0), "0 ms"},
		{duration(langFA, 12*time.Millisecond), "۱۲ میلی‌ثانیه"},
		{duration(langEN, 1500*time.Millisecond), "1.5 s"},
		{duration(langFA, 3*time.Minute), "۳ دقیقه"},
	} {
		if c.got != c.want {
			t.Errorf("got %q, want %q", c.got, c.want)
		}
	}
}

func TestTextsWriteNumbersInThePageDigits(t *testing.T) {
	if got := tr(langFA, "dash.delta7", 12); got != "+۱۲ در ۷ روز" {
		t.Errorf("fa: %q", got)
	}
	if got := tr(langEN, "dash.delta7", 12); got != "+12 in 7 days" {
		t.Errorf("en: %q", got)
	}
	// Strings (names, emails, codes) are never changed.
	if got := tr(langFA, "confirm.grant.q", "rider5@example.com"); got != "به rider5@example.com نسخه ویژه بدی؟" {
		t.Errorf("fa string arg: %q", got)
	}
}
