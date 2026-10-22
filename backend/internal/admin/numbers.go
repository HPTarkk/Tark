package admin

import (
	"fmt"
	"math"
	"reflect"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Every number the panel shows goes through here, so a Persian page shows
// Persian digits, separators and units ("۱٬۲۵۰", "۲٫۷", "۹۷٪",
// "۲۱٫۳ مگابایت") and an English one Latin ones. Ids, codes, emails, routes
// and log lines are not numbers and never come here: they stay exactly as
// stored, so they can be copied and searched. Form fields keep Latin digits
// in their values (the digit font draws them Persian), and every parser
// takes Persian digits too.

// localNum writes a Latin number string (digits, grouping commas, a decimal
// point, a percent sign) in lang's style. Anything else in s is kept.
func localNum(lang, s string) string {
	if lang != langFA {
		return s
	}
	var b strings.Builder
	b.Grow(len(s) * 2)
	digit := func(i int) bool { return i >= 0 && i < len(s) && s[i] >= '0' && s[i] <= '9' }
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c >= '0' && c <= '9':
			b.WriteRune('۰' + rune(c-'0'))
		case c == ',' && digit(i-1) && digit(i+1):
			b.WriteRune('٬')
		case c == '.' && digit(i-1) && digit(i+1):
			b.WriteRune('٫')
		case c == '%' && digit(i-1):
			b.WriteRune('٪')
		default:
			r, n := utf8.DecodeRuneInString(s[i:])
			b.WriteRune(r)
			i += n - 1
		}
	}
	return b.String()
}

// grouped writes a whole number with thousands separators: 1,250,000.
func grouped(n int64) string {
	raw := strconv.FormatInt(n, 10)
	neg := strings.HasPrefix(raw, "-")
	raw = strings.TrimPrefix(raw, "-")
	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	for i := range len(raw) {
		if i > 0 && (len(raw)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteByte(raw[i])
	}
	return b.String()
}

// intOf reads any integer kind (or a pointer to one). ok is false for
// anything else, and for a nil pointer.
func intOf(v any) (int64, bool) {
	rv := reflect.ValueOf(v)
	if rv.Kind() == reflect.Pointer {
		if rv.IsNil() {
			return 0, false
		}
		rv = rv.Elem()
	}
	switch rv.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return rv.Int(), true
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return int64(rv.Uint()), true
	}
	return 0, false
}

// num is a count: "1,250" or "۱٬۲۵۰"; nil shows a dash. A float is
// written as short as it reads exactly (2.7), anything else as it is.
func num(lang string, v any) string {
	if n, ok := intOf(v); ok {
		return localNum(lang, grouped(n))
	}
	switch f := v.(type) {
	case float64:
		return decimal(lang, f)
	case float32:
		return decimal(lang, float64(f))
	case nil:
		return "-"
	}
	rv := reflect.ValueOf(v)
	if rv.Kind() == reflect.Pointer && rv.IsNil() {
		return "-"
	}
	return localNum(lang, fmt.Sprint(v))
}

// decimal writes a number without trailing zeros: 2.7, 1.15, 9.
func decimal(lang string, f float64) string {
	return localNum(lang, strconv.FormatFloat(f, 'f', -1, 64))
}

// pct is a whole percentage: "12%" or "۱۲٪".
func pct(lang string, v any) string {
	if n, ok := intOf(v); ok {
		return localNum(lang, strconv.FormatInt(n, 10)+"%")
	}
	return localNum(lang, fmt.Sprint(v))
}

// megabytes is a size in MB with one decimal: "21.3 MB", "۲۱٫۳ مگابایت".
func megabytes(lang string, n float64) string {
	return tr(lang, "unit.mb", localNum(lang, strconv.FormatFloat(n/(1<<20), 'f', 1, 64)))
}

// latencyIn is a histogram bucket's upper bound, "≤ 250 ms" or
// "≤ ۲۵۰ میلی‌ثانیه"; +Inf is "> 10 s" and nothing measured is a dash.
func latencyIn(lang string, sec float64) string {
	switch {
	case math.IsInf(sec, 1):
		return "> " + tr(lang, "unit.s", localNum(lang, "10"))
	case sec == 0:
		return "-"
	case sec < 1:
		return "≤ " + tr(lang, "unit.ms", localNum(lang, strconv.Itoa(int(sec*1000))))
	}
	return "≤ " + tr(lang, "unit.s", decimal(lang, sec))
}

// duration is a short wait: "0 ms", "12 ms", "1.5 s", "3 min".
func duration(lang string, d time.Duration) string {
	switch {
	case d < time.Second:
		return tr(lang, "unit.ms", localNum(lang, strconv.FormatInt(d.Milliseconds(), 10)))
	case d < time.Minute:
		return tr(lang, "unit.s", decimal(lang, math.Round(d.Seconds()*10)/10))
	}
	return tr(lang, "span.m", int(d.Minutes()))
}

// localArg makes a number given to a text print in lang's digits, whatever
// verb the text uses for it.
type localArg struct {
	lang string
	v    any
}

func (a localArg) Format(f fmt.State, verb rune) {
	fmt.Fprint(f, localNum(a.lang, fmt.Sprintf(fmt.FormatString(f, verb), a.v)))
}

// localArgs wraps the numbers among a text's args; strings (names, emails,
// codes, dates already written) pass through untouched.
func localArgs(lang string, args []any) []any {
	if lang != langFA {
		return args
	}
	out := make([]any, len(args))
	for i, a := range args {
		switch a.(type) {
		case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64, float32, float64:
			out[i] = localArg{lang, a}
		default:
			out[i] = a
		}
	}
	return out
}
