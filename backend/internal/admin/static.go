package admin

import (
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"net/http"
	"sort"
	"strings"
)

// Pages are never cached (headers sets no-store), but their styles, fonts
// and pictures must be: fetched again on every click, the page first drew
// in a fallback font and then swapped to Vazirmatn, so the menu jumped on
// each page. Pages link static files under /static/<staticVer>/, a hash of
// all of them, and those answers are kept for a year; a new build gets a
// new hash, so a changed file is never served stale. admin.css names its
// fonts and icons by relative URLs, so they inherit the same prefix.
var staticVer, staticTags = hashStatic()

func hashStatic() (string, map[string]string) {
	tags := map[string]string{}
	var names []string
	_ = fs.WalkDir(assets, "static", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := fs.ReadFile(assets, p)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(b)
		name := strings.TrimPrefix(p, "static/")
		tags[name] = `"` + hex.EncodeToString(sum[:8]) + `"`
		names = append(names, name)
		return nil
	})
	sort.Strings(names)
	all := sha256.New()
	for _, n := range names {
		all.Write([]byte(n + "\x00" + tags[n] + "\x00"))
	}
	return hex.EncodeToString(all.Sum(nil))[:12], tags
}

// staticURL is the cacheable address of a file in static/.
func staticURL(name string) string { return "/static/" + staticVer + "/" + name }

// serveStatic answers /static/<ver>/<file> with a long cache and
// /static/<file> (an old tab's link from an earlier build, too) with
// revalidation by ETag.
func serveStatic(files http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(r.URL.Path, "/static/")
		cache := "no-cache"
		if head, rest, ok := strings.Cut(p, "/"); ok && isVer(head) {
			p = rest
			if head == staticVer {
				cache = "public, max-age=31536000, immutable"
			}
		}
		h := w.Header()
		h.Set("Cache-Control", cache)
		if tag, ok := staticTags[p]; ok {
			h.Set("ETag", tag)
		}
		r2 := r.Clone(r.Context())
		r2.URL.Path = "/" + p
		r2.URL.RawPath = ""
		files.ServeHTTP(w, r2)
	})
}

func isVer(s string) bool {
	if len(s) != len(staticVer) {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}
