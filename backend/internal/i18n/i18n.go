// Package i18n picks the language of a response and holds the people-facing
// text the API sends. Only English and Persian exist; anything else falls
// back to English.
package i18n

import (
	"context"
	"net/http"
	"strconv"
	"strings"
)

const (
	EN = "en"
	FA = "fa"
)

// Default is the language used when the caller names none we support.
const Default = EN

type ctxKey struct{}

// FromHeader picks the best supported language from an Accept-Language
// value: the highest q wins, ties go to the earlier tag, and a tag with
// q=0 is refused. "fa-IR" counts as Persian, "en-GB" as English.
func FromHeader(header string) string {
	best, bestQ := "", 0.0
	for _, part := range strings.Split(header, ",") {
		tag, params, _ := strings.Cut(strings.TrimSpace(part), ";")
		lang := supported(tag)
		if lang == "" {
			continue
		}
		q := 1.0
		for _, p := range strings.Split(params, ";") {
			k, v, ok := strings.Cut(strings.TrimSpace(p), "=")
			if ok && strings.EqualFold(strings.TrimSpace(k), "q") {
				parsed, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
				if err != nil || parsed < 0 || parsed > 1 {
					parsed = 0
				}
				q = parsed
			}
		}
		if q > bestQ {
			best, bestQ = lang, q
		}
	}
	if best == "" {
		return Default
	}
	return best
}

// Normalize maps any language tag to a supported one ("fa-IR" → "fa",
// "de" → "en"). An empty tag gives the default.
func Normalize(tag string) string {
	if lang := supported(tag); lang != "" {
		return lang
	}
	return Default
}

func supported(tag string) string {
	primary, _, _ := strings.Cut(strings.ToLower(strings.TrimSpace(tag)), "-")
	primary, _, _ = strings.Cut(primary, "_")
	switch primary {
	case EN, FA:
		return primary
	}
	return ""
}

// With stores the request's language in ctx.
func With(ctx context.Context, lang string) context.Context {
	return context.WithValue(ctx, ctxKey{}, lang)
}

// From returns the language stored by With, or the default.
func From(ctx context.Context) string {
	if lang, ok := ctx.Value(ctxKey{}).(string); ok {
		return lang
	}
	return Default
}

// Middleware reads Accept-Language once per request, stores the result in
// the context and tells caches that the body depends on it.
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lang := FromHeader(r.Header.Get("Accept-Language"))
		w.Header().Set("Content-Language", lang)
		w.Header().Add("Vary", "Accept-Language")
		next.ServeHTTP(w, r.WithContext(With(r.Context(), lang)))
	})
}

// Digits writes n with the digits of lang (Persian digits for fa).
func Digits(lang string, n int) string {
	s := strconv.Itoa(n)
	if lang != FA {
		return s
	}
	return persianDigits(s)
}

// GroupedDigits writes n with thousands separators in lang's style:
// "1,250,000" in English, "۱٬۲۵۰٬۰۰۰" in Persian.
func GroupedDigits(lang string, n int64) string {
	neg := n < 0
	if neg {
		n = -n
	}
	raw := strconv.FormatInt(n, 10)
	sep := ","
	if lang == FA {
		sep = "٬"
	}
	var b strings.Builder
	for i, r := range raw {
		if i > 0 && (len(raw)-i)%3 == 0 {
			b.WriteString(sep)
		}
		b.WriteRune(r)
	}
	out := b.String()
	if lang == FA {
		out = persianDigits(out)
	}
	if neg {
		out = "-" + out
	}
	return out
}

func persianDigits(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune('۰' + (r - '0'))
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}
