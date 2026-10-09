package httpapi

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"

	apispec "github.com/HPTarkk/Tark/backend/api"
)

func testDeps(docs bool) Deps {
	return Deps{Docs: docs, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func get(h http.Handler, path string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
	return w
}

func TestDocsAreServedWhenEnabled(t *testing.T) {
	h := NewHandler(testDeps(true))

	page := get(h, "/docs/")
	if page.Code != http.StatusOK || !strings.Contains(page.Body.String(), "swagger-ui") {
		t.Fatalf("/docs/: %d", page.Code)
	}
	csp := page.Header().Get("Content-Security-Policy")
	if !strings.Contains(csp, "script-src 'self'") || strings.Contains(csp, "script-src 'self' 'unsafe-inline'") ||
		strings.Contains(csp, "unsafe-eval") || strings.Contains(csp, "http") {
		t.Errorf("docs CSP must allow only our own scripts: %s", csp)
	}
	// An inline script would be blocked by that policy; the page must not need one.
	for _, m := range regexp.MustCompile(`<script[^>]*>`).FindAllString(page.Body.String(), -1) {
		if !strings.Contains(m, "src=") {
			t.Errorf("inline script in docs page: %s", m)
		}
	}

	if r := get(h, "/docs"); r.Code != http.StatusMovedPermanently || r.Header().Get("Location") != "/docs/" {
		t.Errorf("/docs should redirect to /docs/: %d %s", r.Code, r.Header().Get("Location"))
	}
	for _, f := range []string{"/docs/swagger-ui-bundle.js", "/docs/swagger-ui.css", "/docs/swagger-initializer.js"} {
		if r := get(h, f); r.Code != http.StatusOK || r.Body.Len() == 0 {
			t.Errorf("%s: %d", f, r.Code)
		}
	}
	spec := get(h, "/openapi.yaml")
	body, _ := io.ReadAll(spec.Body)
	if spec.Code != http.StatusOK || string(body) != string(apispec.Spec) || !strings.HasPrefix(spec.Header().Get("Content-Type"), "application/yaml") {
		t.Errorf("/openapi.yaml: %d %s", spec.Code, spec.Header().Get("Content-Type"))
	}
	// The rest of the API keeps its strict policy.
	if csp := get(h, "/healthz").Header().Get("Content-Security-Policy"); !strings.HasPrefix(csp, "default-src 'none'") {
		t.Errorf("non-docs routes lost their CSP: %q", csp)
	}
}

func TestDocsAreAbsentWhenDisabled(t *testing.T) {
	h := NewHandler(testDeps(false))
	for _, p := range []string{"/docs", "/docs/", "/docs/swagger-ui-bundle.js", "/openapi.yaml"} {
		if r := get(h, p); r.Code != http.StatusNotFound {
			t.Errorf("%s answered %d with docs disabled", p, r.Code)
		}
	}
}

// The contract and the router must list the same operations. The test fails
// when a route is added without documenting it, or documented but removed.
func TestSpecMatchesRoutes(t *testing.T) {
	routes := map[string]bool{}
	err := chi.Walk(NewHandler(testDeps(true)).(chi.Routes), func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		route = strings.TrimSuffix(route, "/")
		if rest, ok := strings.CutPrefix(route, "/v1"); ok {
			routes[strings.ToLower(method)+" "+rest] = true
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	documented := map[string]bool{}
	var path string
	paths := regexp.MustCompile(`^  (/\S*):\s*$`)
	method := regexp.MustCompile(`^    (get|post|put|patch|delete):\s*$`)
	inPaths := false
	for _, line := range strings.Split(string(apispec.Spec), "\n") {
		// A Windows checkout may carry CRLF line endings.
		line = strings.TrimSuffix(line, "\r")
		switch {
		case line == "paths:":
			inPaths = true
		case inPaths && regexp.MustCompile(`^\S`).MatchString(line):
			inPaths = false
		case inPaths && paths.MatchString(line):
			path = paths.FindStringSubmatch(line)[1]
		case inPaths && method.MatchString(line):
			documented[method.FindStringSubmatch(line)[1]+" "+path] = true
		}
	}

	var missing, stale []string
	for r := range routes {
		if !documented[r] {
			missing = append(missing, r)
		}
	}
	for d := range documented {
		if !routes[d] {
			stale = append(stale, d)
		}
	}
	sort.Strings(missing)
	sort.Strings(stale)
	if len(missing) > 0 {
		t.Errorf("routes missing from api/openapi.yaml: %v", missing)
	}
	if len(stale) > 0 {
		t.Errorf("documented in api/openapi.yaml but not served: %v", stale)
	}
	if len(routes) < 20 {
		t.Fatalf("only %d routes found; the walk is broken", len(routes))
	}
}
