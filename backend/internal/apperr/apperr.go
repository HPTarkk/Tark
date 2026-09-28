// Package apperr is the one error type handlers turn into a Problem
// response. Services return these for every failure a caller is meant to
// see; anything else is an internal error and reaches the client only as a
// bare 500 with no detail.
package apperr

import (
	"errors"
	"fmt"
	"net/http"
	"time"
)

// Error is a failure the client is allowed to know about. Code is stable
// and machine-readable (the app branches on it); Detail is for developers
// and is never shown to people.
type Error struct {
	Status     int
	Code       string
	Detail     string
	RetryAfter time.Duration
	// Extra fields merged into the Problem body (for example attemptsLeft).
	// Only ever filled with values that are safe for the caller to see.
	Extra map[string]any
}

func (e *Error) Error() string {
	if e.Detail == "" {
		return e.Code
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Detail)
}

// With returns a copy carrying one more Extra field.
func (e *Error) With(key string, value any) *Error {
	out := *e
	out.Extra = make(map[string]any, len(e.Extra)+1)
	for k, v := range e.Extra {
		out.Extra[k] = v
	}
	out.Extra[key] = value
	return &out
}

// As extracts an *Error from err's chain.
func As(err error) (*Error, bool) {
	var e *Error
	if errors.As(err, &e) {
		return e, true
	}
	return nil, false
}

func New(status int, code, detail string) *Error {
	return &Error{Status: status, Code: code, Detail: detail}
}

func BadRequest(code, detail string) *Error {
	return New(http.StatusBadRequest, code, detail)
}

func Unauthorized(detail string) *Error {
	return New(http.StatusUnauthorized, "unauthorized", detail)
}

func Conflict(code, detail string) *Error {
	return New(http.StatusConflict, code, detail)
}

func Unprocessable(code, detail string) *Error {
	return New(http.StatusUnprocessableEntity, code, detail)
}

func NotFound(code, detail string) *Error {
	return New(http.StatusNotFound, code, detail)
}

func RateLimited(retryAfter time.Duration) *Error {
	return &Error{
		Status:     http.StatusTooManyRequests,
		Code:       "rate_limited",
		RetryAfter: retryAfter,
	}
}

func Unavailable(code, detail string, retryAfter time.Duration) *Error {
	return &Error{
		Status:     http.StatusServiceUnavailable,
		Code:       code,
		Detail:     detail,
		RetryAfter: retryAfter,
	}
}

// Validation reports a malformed field. field names the JSON property.
func Validation(field, detail string) *Error {
	return (&Error{
		Status: http.StatusBadRequest,
		Code:   "invalid_request",
		Detail: detail,
	}).With("field", field)
}
