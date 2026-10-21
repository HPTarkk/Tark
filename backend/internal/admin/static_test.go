package admin

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Static files are cached between pages, so the menu does not redraw in a
// fallback font on every click.
func TestStaticFilesAreCached(t *testing.T) {
	srv, err := New(Deps{})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	get := func(path string, hdr ...string) *http.Response {
		t.Helper()
		req, _ := http.NewRequest("GET", ts.URL+path, nil)
		for i := 0; i+1 < len(hdr); i += 2 {
			req.Header.Set(hdr[i], hdr[i+1])
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, res.Body)
		res.Body.Close()
		return res
	}

	for _, f := range []string{"admin.css", "admin.js", "Vazirmatn-Regular.ttf", "VazirmatnDigits-Bold.woff2", "logo.png", "chevron.svg"} {
		res := get(staticURL(f))
		if res.StatusCode != http.StatusOK || res.Header.Get("Cache-Control") != "public, max-age=31536000, immutable" {
			t.Errorf("%s: %d %q", f, res.StatusCode, res.Header.Get("Cache-Control"))
		}
	}
	// Unversioned links, and links from an older build, still work and revalidate.
	for _, p := range []string{"/static/admin.css", "/static/0123456789ab/admin.css"} {
		res := get(p)
		tag := res.Header.Get("ETag")
		if res.StatusCode != http.StatusOK || res.Header.Get("Cache-Control") != "no-cache" || tag == "" {
			t.Fatalf("%s: %d %q %q", p, res.StatusCode, res.Header.Get("Cache-Control"), tag)
		}
		if res := get(p, "If-None-Match", tag); res.StatusCode != http.StatusNotModified {
			t.Errorf("%s revalidated: %d", p, res.StatusCode)
		}
	}
	if res := get(staticURL("nope.css")); res.StatusCode != http.StatusNotFound {
		t.Errorf("missing file: %d", res.StatusCode)
	}
	// Pages themselves are still never stored.
	if res := get("/healthz"); res.Header.Get("Cache-Control") != "no-store" {
		t.Errorf("page cache: %q", res.Header.Get("Cache-Control"))
	}
	if !strings.HasPrefix(staticURL("x"), "/static/"+staticVer+"/") || len(staticVer) != 12 {
		t.Errorf("staticURL: %s", staticURL("x"))
	}
}
