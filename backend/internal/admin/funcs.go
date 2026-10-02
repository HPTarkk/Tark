package admin

import (
	"fmt"
	"html/template"
	"reflect"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/metrics"
)

var funcs = template.FuncMap{
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
		return t.UTC().Format("2006-01-02 15:04")
	},
	"day": func(t time.Time) string { return t.UTC().Format("01-02") },
	// ago is "3h ago", "5d ago".
	"ago": func(v any) string {
		t, ok := timeOf(v)
		if !ok {
			return "never"
		}
		d := time.Since(t)
		switch {
		case d < time.Minute:
			return "just now"
		case d < time.Hour:
			return fmt.Sprintf("%dm ago", int(d.Minutes()))
		case d < 48*time.Hour:
			return fmt.Sprintf("%dh ago", int(d.Hours()))
		}
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	},
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
