package admin

import (
	"fmt"
	"html/template"
	"math"
	"reflect"
	"strconv"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/i18n"
	"github.com/HPTarkk/Tark/backend/internal/metrics"
)

var funcs = template.FuncMap{
	// money writes a whole amount with thousands separators: 1,250,000.
	"money": func(n int64) string { return i18n.GroupedDigits(i18n.EN, n) },
	// factor writes a multiplier without trailing zeros: 2.7, 1.15, 9.
	"factor":  func(f float64) string { return strconv.FormatFloat(f, 'f', -1, 64) },
	"round":   func(f float64) int64 { return int64(math.Round(f)) },
	"latency": latency,
	"list":    func(v ...int) []int { return v },
	"p":       func(h metrics.Hist, q float64) string { return latency(h.Quantile(q)) },
	"bytes":   func(n uint64) string { return fmt.Sprintf("%.1f MB", float64(n)/(1<<20)) },
	"dur":     func(d time.Duration) string { return d.Round(time.Millisecond).String() },
	// when formats a time (or *time.Time) in UTC; nil and zero show a dash.
	"when": func(v any) string {
		t, ok := timeOf(v)
		if !ok {
			return "-"
		}
		// Isolated, so date and time keep their order inside Persian text.
		return "\u2066" + t.UTC().Format("2006-01-02 15:04") + "\u2069"
	},
	"day": func(t time.Time) string { return t.UTC().Format("01-02") },
	// bar maps a count to one of ten height classes for the CSS bar chart
	// (the CSP forbids inline styles).
	"bar": func(n, max int) int {
		if max == 0 || n == 0 {
			return 0
		}
		return 1 + (n*9)/max
	},
	"deref": func(v any) any {
		rv := reflect.ValueOf(v)
		if !rv.IsValid() || (rv.Kind() == reflect.Pointer && rv.IsNil()) {
			return ""
		}
		if rv.Kind() == reflect.Pointer {
			return rv.Elem().Interface()
		}
		return v
	},
	"short": func(s string) string {
		if len(s) > 8 {
			return s[:8]
		}
		return s
	},
	"mb": func(v any) string {
		rv := reflect.ValueOf(v)
		if !rv.IsValid() || (rv.Kind() == reflect.Pointer && rv.IsNil()) {
			return "-"
		}
		if rv.Kind() == reflect.Pointer {
			rv = rv.Elem()
		}
		return fmt.Sprintf("%.1f MB", float64(rv.Int())/(1<<20))
	},
}

// funcsFor adds the functions whose output depends on the language: t looks
// up a text, ago says how long ago in words, and code names a stored code.
func funcsFor(lang string) template.FuncMap {
	m := template.FuncMap{}
	for k, v := range funcs {
		m[k] = v
	}
	dir := "ltr"
	if lang == langFA {
		dir = "rtl"
	}
	m["lang"] = func() string { return lang }
	m["dir"] = func() string { return dir }
	m["t"] = func(key string, args ...any) string { return tr(lang, key, args...) }
	// code names a stored code (a role, a status) in words, or keeps it as
	// it is when there is no text for it.
	m["code"] = func(prefix string, v any) string {
		c := fmt.Sprint(v)
		if _, ok := texts[prefix+"."+c]; ok {
			return tr(lang, prefix+"."+c)
		}
		return c
	}
	// ago is "3h ago", "5d ago".
	m["ago"] = func(v any) string {
		t, ok := timeOf(v)
		if !ok {
			return tr(lang, "never")
		}
		d := time.Since(t)
		switch {
		case d < time.Minute:
			return tr(lang, "ago.now")
		case d < time.Hour:
			return tr(lang, "ago.m", int(d.Minutes()))
		case d < 48*time.Hour:
			return tr(lang, "ago.h", int(d.Hours()))
		}
		return tr(lang, "ago.d", int(d.Hours()/24))
	}
	return m
}

func timeOf(v any) (time.Time, bool) {
	switch t := v.(type) {
	case time.Time:
		return t, !t.IsZero()
	case *time.Time:
		if t == nil || t.IsZero() {
			return time.Time{}, false
		}
		return *t, true
	}
	return time.Time{}, false
}
