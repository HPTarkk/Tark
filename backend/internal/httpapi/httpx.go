package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/i18n"
	"github.com/HPTarkk/Tark/backend/internal/secure"
)

// maxBody bounds every request body. Nothing in this API needs more.
const maxBody = 16 << 10

type ctxKey int

const (
	keyRequestID ctxKey = iota
	keyClientIP
	keyPrincipal
)

// writeJSON sends v with no caching: every answer is personal.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeError turns any error into a Problem. Only apperr values reach the
// client with their code; everything else is logged and answered with a
// bare internal_error. Every Problem carries a people-facing message in
// the request's language (Accept-Language).
func writeError(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	ae, ok := apperr.As(err)
	if !ok {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			ae = apperr.Unavailable("timeout", "", 2*time.Second)
		} else {
			log.ErrorContext(r.Context(), "internal error", "err", err, "path", r.URL.Path, "request_id", requestID(r.Context()))
			ae = apperr.New(http.StatusInternalServerError, "internal_error", "")
		}
	}
	body := map[string]any{"code": ae.Code, "message": i18n.ErrorMessage(i18n.From(r.Context()), ae.Code, ae.Extra)}
	if ae.Detail != "" {
		body["detail"] = ae.Detail
	}
	if ae.RetryAfter > 0 {
		body["retryAfterMs"] = ae.RetryAfter.Milliseconds()
		w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(ae.RetryAfter.Seconds()))))
	}
	for k, v := range ae.Extra {
		if _, taken := body[k]; !taken {
			body[k] = v
		}
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(ae.Status)
	_ = json.NewEncoder(w).Encode(body)
}

// decode reads a JSON body into v. Unknown fields are allowed so a newer
// app can talk to an older server; trailing data is not.
func decode(r *http.Request, v any) error {
	if ct := r.Header.Get("Content-Type"); ct != "" && !strings.HasPrefix(ct, "application/json") {
		return apperr.New(http.StatusUnsupportedMediaType, "unsupported_media_type", "send application/json")
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			return apperr.New(http.StatusRequestEntityTooLarge, "body_too_large", "")
		}
		return apperr.BadRequest("invalid_request", "could not read body")
	}
	dec := json.NewDecoder(strings.NewReader(string(body)))
	if err := dec.Decode(v); err != nil {
		return apperr.BadRequest("invalid_request", "body is not valid JSON for this endpoint")
	}
	if dec.More() {
		return apperr.BadRequest("invalid_request", "unexpected data after the JSON body")
	}
	return nil
}

func requestID(ctx context.Context) string {
	id, _ := ctx.Value(keyRequestID).(string)
	return id
}

func clientIP(ctx context.Context) string {
	ip, _ := ctx.Value(keyClientIP).(string)
	return ip
}

// ipResolver finds the real client address. A forwarding header is only
// believed when the direct peer is one of our own proxies (ArvanCloud's
// edge or the load balancer); otherwise anyone could pick their own IP and
// dodge every per-IP limit.
type ipResolver struct {
	header  string
	trusted []netip.Prefix
}

func (x ipResolver) isTrusted(a netip.Addr) bool {
	for _, p := range x.trusted {
		if p.Contains(a.Unmap()) {
			return true
		}
	}
	return false
}

// canonical is the string every per-IP limit and log hash is keyed on. An
// IPv6 address is reduced to its /64: a single subscriber or server is
// normally handed a whole /64, so keying on the full address would give one
// attacker 2^64 "different" IPs and make every per-IP limit meaningless.
func canonical(a netip.Addr) string {
	a = a.Unmap()
	if a.Is6() {
		return netip.PrefixFrom(a, 64).Masked().Addr().String() + "/64"
	}
	return a.String()
}

func (x ipResolver) resolve(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	peer = peer.Unmap()
	if x.header == "" || !x.isTrusted(peer) {
		return canonical(peer)
	}
	// Walk the chain from the right: the first address that is not one of
	// our proxies is the client.
	values := strings.Split(r.Header.Get(x.header), ",")
	for i := len(values) - 1; i >= 0; i-- {
		a, err := netip.ParseAddr(strings.TrimSpace(values[i]))
		if err != nil {
			break
		}
		a = a.Unmap()
		if !x.isTrusted(a) {
			return canonical(a)
		}
	}
	return canonical(peer)
}

func newRequestID() string { return secure.RandomToken(9) }

// statusRecorder notes the status for the access log.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

// ClientIPResolver returns a function that finds a request's real client
// address with the same rules as the API (forwarding header trusted only
// from TrustedProxies, IPv6 keyed by /64). The admin panel uses it.
func ClientIPResolver(header string, trusted []netip.Prefix) func(*http.Request) string {
	return ipResolver{header: header, trusted: trusted}.resolve
}
