package admin

import (
	"fmt"
	"html/template"
	"io/fs"
	"math"
	"reflect"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

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
	"icon": icon,
	// avatar is the picture of an app avatar id (one of the app's own
	// avatars, copied into static/avatars), or "" for none or unknown.
	"avatar": func(v any) string {
		id, ok := v.(*string)
		if !ok || id == nil {
			return ""
		}
		n, err := strconv.Atoi(*id)
		if err != nil || n < 1 {
			return ""
		}
		name := "static/avatars/" + strconv.Itoa(n) + ".webp"
		if _, err := fs.Stat(assets, name); err != nil {
			return ""
		}
		return "/" + name
	},
	// initial is the first letter of a name, for the round avatars.
	"initial": func(s string) string {
		r, _ := utf8.DecodeRuneInString(strings.TrimSpace(s))
		if r == utf8.RuneError {
			return "?"
		}
		return string(unicode.ToUpper(r))
	},
	// level picks the colour of a JSON log line.
	"level": func(line string) string {
		switch {
		case strings.Contains(line, `"level":"ERROR"`):
			return "lv-error"
		case strings.Contains(line, `"level":"WARN"`):
			return "lv-warn"
		}
		return "lv-info"
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
	// when is a time (or *time.Time) in Tehran time, in the page's
	// calendar; nil and zero show a dash. day is a short chart label.
	m["when"] = func(v any) string {
		t, ok := timeOf(v)
		if !ok {
			return "-"
		}
		return formatWhen(lang, t)
	}
	m["day"] = func(t time.Time) string { return formatDay(lang, t) }
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

// icons are line drawings on a 24-unit grid, drawn in the text colour. They
// are inline SVG because the CSP allows no scripts and the panel has no
// icon font.
var icons = map[string]string{
	"dashboard": `<rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/>`,
	"system":    `<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>`,
	"users":     `<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>`,
	"security":  `<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>`,
	"mail":      `<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m22 7-10 6L2 7"/>`,
	"pricing":   `<path d="M20.6 13.4 13.4 20.6a2 2 0 0 1-2.8 0L2 12V2h10l8.6 8.6a2 2 0 0 1 0 2.8z"/><circle cx="7" cy="7" r="1.5"/>`,
	"backups":   `<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/><path d="M3 12c0 1.66 4 3 9 3s9-1.34 9-3"/>`,
	"admins":    `<circle cx="7.5" cy="15.5" r="4.5"/><path d="m10.7 12.3 9.8-9.8M17 6l3 3M14.5 8.5l2 2"/>`,
	"activity":  `<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5M12 7v5l4 2"/>`,
	"logs":      `<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6M16 13H8M16 17H8M10 9H8"/>`,
	"account":   `<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>`,
	"signout":   `<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5M21 12H9"/>`,
	"menu":      `<path d="M4 6h16M4 12h16M4 18h16"/>`,
	"close":     `<path d="M18 6 6 18M6 6l12 12"/>`,
	"search":    `<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>`,
	"globe":     `<circle cx="12" cy="12" r="10"/><path d="M2 12h20M12 2a15 15 0 0 1 4 10 15 15 0 0 1-4 10 15 15 0 0 1-4-10 15 15 0 0 1 4-10z"/>`,
	"alert":     `<path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/>`,
	"check":     `<path d="M20 6 9 17l-5-5"/>`,
	"trend":     `<path d="m22 7-8.5 8.5-5-5L2 17"/><path d="M16 7h6v6"/>`,
	"crown":     `<path d="m2 8 4 11h12l4-11-6 4-4-8-4 8z"/>`,
	"zap":       `<path d="M13 2 3 14h9l-1 8 10-12h-9z"/>`,
	"server":    `<rect x="2" y="3" width="20" height="8" rx="2"/><rect x="2" y="13" width="20" height="8" rx="2"/><path d="M6 7h.01M6 17h.01"/>`,
	"cloud":     `<path d="M17.5 19H9a7 7 0 1 1 6.7-9h1.8a4.5 4.5 0 1 1 0 9z"/>`,
	"phone":     `<rect x="6" y="2" width="12" height="20" rx="2"/><path d="M11 18h2"/>`,
	"gift":      `<rect x="3" y="8" width="18" height="4" rx="1"/><path d="M12 8v13M19 12v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-7M7.5 8a2.5 2.5 0 0 1 0-5C11 3 12 8 12 8s1-5 4.5-5a2.5 2.5 0 0 1 0 5"/>`,
	"card":      `<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M2 10h20"/>`,
	"trash":     `<path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>`,
	"ban":       `<circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/>`,
	"refresh":   `<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>`,
	"plus":      `<path d="M12 5v14M5 12h14"/>`,
	"eye":       `<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>`,
	"flag":      `<path d="M4 22V4a1 1 0 0 1 1-1h12l-2 4 2 4H5"/>`,
	"send":      `<path d="m22 2-7 20-4-9-9-4z"/><path d="M22 2 11 13"/>`,
	"info":      `<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>`,
	"clock":     `<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>`,
	"lock":      `<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>`,
	"chart":     `<path d="M3 3v18h18"/><path d="M8 17v-5M13 17V8M18 17v-9"/>`,
	"home":      `<path d="m3 10 9-7 9 7v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M9 22V12h6v10"/>`,
}

func icon(name string) template.HTML {
	return template.HTML(`<svg class="i" viewBox="0 0 24 24" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">` + icons[name] + `</svg>`)
}
