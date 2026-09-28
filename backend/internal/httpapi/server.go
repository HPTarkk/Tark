// Package httpapi is the HTTP layer: routing, middleware, and translating
// JSON to service calls and back. It holds no business rules.
package httpapi

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/netip"
	"runtime/debug"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/auth"
	"github.com/HPTarkk/Tark/backend/internal/billing"
	"github.com/HPTarkk/Tark/backend/internal/idempotency"
	"github.com/HPTarkk/Tark/backend/internal/profile"
)

type Deps struct {
	Pool           *pgxpool.Pool
	Auth           *auth.Service
	Profile        *profile.Service
	Billing        *billing.Service
	Idempotency    *idempotency.Store
	Log            *slog.Logger
	ClientIPHeader string
	TrustedProxies []netip.Prefix
}

type api struct{ Deps }

// NewHandler builds the whole HTTP surface.
func NewHandler(d Deps) http.Handler {
	a := &api{d}
	ips := ipResolver{header: d.ClientIPHeader, trusted: d.TrustedProxies}

	r := chi.NewRouter()
	r.Use(a.recoverer, a.requestContext(ips), securityHeaders, a.accessLog)
	r.NotFound(func(w http.ResponseWriter, r *http.Request) {
		writeError(w, r, a.Log, apperr.NotFound("not_found", ""))
	})
	r.MethodNotAllowed(func(w http.ResponseWriter, r *http.Request) {
		writeError(w, r, a.Log, apperr.New(http.StatusMethodNotAllowed, "method_not_allowed", ""))
	})

	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) })
	r.Get("/readyz", a.ready)

	r.Route("/v1", func(r chi.Router) {
		r.Use(limitBody)

		r.Route("/auth", func(r chi.Router) {
			r.With(a.idempotent(false, false)).Post("/register", a.register)
			r.Post("/register/resend", a.resend(auth.PurposeRegister))
			r.Post("/register/verify", a.verifyRegistration)
			r.Post("/login", a.login)

			r.Post("/google/nonce", a.googleNonce)
			r.Post("/google", a.google)
			r.Post("/google/link", a.googleLink)
			r.Post("/google/complete", a.googleComplete)

			r.Post("/token/refresh", a.refresh)

			r.With(a.idempotent(false, false)).Post("/password/forgot", a.forgot)
			r.Post("/password/forgot/resend", a.resend(auth.PurposeReset))
			r.Post("/password/forgot/verify", a.verifyReset)
			r.Post("/password/reset", a.reset)

			r.Group(func(r chi.Router) {
				r.Use(a.authenticated)
				r.Post("/logout", a.logout)
				r.Post("/logout-all", a.logoutAll)
				r.Post("/password/change", a.changePassword)
				r.Post("/email-change", a.startEmailChange)
				r.Post("/email-change/resend", a.resend(auth.PurposeEmailChange))
				r.Post("/email-change/verify", a.confirmEmailChange)
			})
		})

		r.Group(func(r chi.Router) {
			r.Use(a.authenticated)
			r.Get("/profile", a.getProfile)
			r.Put("/profile", a.putProfile)
			r.Post("/account/delete", a.deleteAccount)

			r.Group(func(r chi.Router) {
				r.Use(a.requireInstallKey)
				r.Get("/subscription", a.getSubscription)
				r.With(a.idempotent(true, true)).Post("/subscription/bazaar/purchases", a.submitPurchase)
			})
		})
	})
	return r
}

func (a *api) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := a.Pool.Ping(ctx); err != nil {
		writeError(w, r, a.Log, apperr.Unavailable("not_ready", "", time.Second))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				if v == http.ErrAbortHandler {
					panic(v)
				}
				a.Log.ErrorContext(r.Context(), "panic", "value", v, "stack", string(debug.Stack()))
				writeError(w, r, a.Log, apperr.New(http.StatusInternalServerError, "internal_error", ""))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (a *api) requestContext(ips ipResolver) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			id := newRequestID()
			w.Header().Set("X-Request-Id", id)
			ctx := context.WithValue(r.Context(), keyRequestID, id)
			ctx = context.WithValue(ctx, keyClientIP, ips.resolve(r))
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// accessLog records method, route, status and timing. Never the query
// string, headers or body: they can carry tokens.
func (a *api) accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		route := r.URL.Path
		if rc := chi.RouteContext(r.Context()); rc != nil && rc.RoutePattern() != "" {
			route = rc.RoutePattern()
		}
		a.Log.InfoContext(r.Context(), "request", "method", r.Method, "route", route, "status", rec.status,
			"ms", time.Since(start).Milliseconds(), "request_id", requestID(r.Context()))
	})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Cache-Control", "no-store")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("Strict-Transport-Security", "max-age=31536000")
		next.ServeHTTP(w, r)
	})
}

func limitBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxBody)
		next.ServeHTTP(w, r)
	})
}

func (a *api) authenticated(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(h, "Bearer ")
		if !ok || token == "" {
			w.Header().Set("WWW-Authenticate", `Bearer`)
			writeError(w, r, a.Log, apperr.Unauthorized("missing access token"))
			return
		}
		p, err := a.Auth.Authenticate(r.Context(), token)
		if err != nil {
			w.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
			writeError(w, r, a.Log, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), keyPrincipal, p)))
	})
}

func principal(r *http.Request) auth.Principal {
	p, _ := r.Context().Value(keyPrincipal).(auth.Principal)
	return p
}

const installKeyHeader = "X-Tark-Install-Key"

func (a *api) requireInstallKey(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !auth.ValidInstallKey(r.Header.Get(installKeyHeader)) {
			writeError(w, r, a.Log, apperr.Validation(installKeyHeader, "missing or malformed"))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// idempotent wraps a retryable write. required makes the header
// mandatory; perUser scopes keys to the signed-in account.
func (a *api) idempotent(required, perUser bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := r.Header.Get(idempotency.Header)
			if key == "" && !required {
				next.ServeHTTP(w, r)
				return
			}
			if !idempotency.ValidKey(key) {
				writeError(w, r, a.Log, apperr.Validation(idempotency.Header, "must be a UUID"))
				return
			}
			body, err := io.ReadAll(r.Body)
			if err != nil {
				writeError(w, r, a.Log, apperr.New(http.StatusRequestEntityTooLarge, "body_too_large", ""))
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			scope := "anon"
			if perUser {
				scope = "user:" + principal(r).UserID
			}
			// The install key is part of the fingerprint: the stored answer is
			// an entitlement bound to it.
			fingerprintBody := append([]byte(r.Header.Get(installKeyHeader)+"\n"), body...)
			begun, err := a.Idempotency.Begin(r.Context(), scope, key, r.Method, r.URL.Path, fingerprintBody)
			if err != nil {
				writeError(w, r, a.Log, err)
				return
			}
			switch begun.Outcome {
			case idempotency.Mismatch:
				writeError(w, r, a.Log, apperr.Unprocessable("idempotency_mismatch", "this Idempotency-Key was used for a different request"))
				return
			case idempotency.Busy:
				writeError(w, r, a.Log, &apperr.Error{Status: http.StatusConflict, Code: "request_in_progress", RetryAfter: time.Second})
				return
			case idempotency.Replay:
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("Idempotent-Replayed", "true")
				w.WriteHeader(begun.Status)
				_, _ = w.Write(begun.Body)
				return
			}
			rec := &idempotency.Recorder{ResponseWriter: w}
			next.ServeHTTP(rec, r)
			// Stored even if the client has gone away: that is exactly the
			// case a retry needs the answer for.
			if err := a.Idempotency.Finish(context.WithoutCancel(r.Context()), scope, key, rec.Status, rec.Buf.Bytes()); err != nil {
				a.Log.ErrorContext(r.Context(), "idempotency finish failed", "err", err)
			}
		})
	}
}
