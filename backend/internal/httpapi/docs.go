package httpapi

import (
	"io/fs"
	"net/http"

	"github.com/go-chi/chi/v5"

	apispec "github.com/HPTarkk/Tark/backend/api"
)

// docsCSP lets the Swagger UI page run its own bundled script and style, call
// the server it was loaded from, and nothing else. The rest of the API keeps
// the strict default-src 'none' policy.
const docsCSP = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
	"img-src 'self' data:; font-src 'self' data:; connect-src 'self'; base-uri 'none'; " +
	"form-action 'none'; frame-ancestors 'none'"

// mountDocs serves the OpenAPI contract at /openapi.yaml and Swagger UI at
// /docs. Everything comes from the binary (embedded), so the page works
// without reaching a CDN. Only mounted when TARK_DOCS_ENABLED is on.
func mountDocs(r chi.Router) {
	ui, err := fs.Sub(apispec.UI, "swaggerui")
	if err != nil {
		panic(err) // the directory is embedded at build time
	}
	files := http.StripPrefix("/docs/", http.FileServerFS(ui))

	r.Get("/openapi.yaml", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/yaml; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		_, _ = w.Write(apispec.Spec)
	})
	r.Get("/docs", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/docs/", http.StatusMovedPermanently)
	})
	r.Get("/docs/*", func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", docsCSP)
		h.Set("Cache-Control", "public, max-age=3600")
		files.ServeHTTP(w, r)
	})
}
