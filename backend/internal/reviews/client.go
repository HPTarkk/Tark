// Package reviews keeps a copy of the app's Cafe Bazaar reviews and sends
// developer replies, for the admin panel's Reviews page.
//
// Bazaar's reviews API (developers.cafebazaar.ir, "comments API") has two
// calls, and only those are used:
//
//   - GET  {base}/api/v0/reviews/       a page of reviews: next, previous, results
//   - POST {base}/api/v0/reviews/{id}/  a reply: {"text", "email"?}, 201 when accepted
//
// The API key travels in a header whose name Bazaar's developer panel shows
// (TARK_BAZAAR_REVIEWS_KEY_HEADER). It never leaves this process: it is not
// logged, stored, or put in an error.
//
// Pages are cursor based: each answer's "next" is the URL of the following
// page, or null on the last. Only next URLs on the configured host and path
// are followed, so an answer can never point the server somewhere else.
//
// Bazaar's public docs list fewer review fields than its newer API answers
// carry, so every field beyond id, user, text and rate is optional here.
package reviews

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Review is one review as Bazaar reports it.
type Review struct {
	ID             int64
	UserAccountID  string
	Text           string
	Rate           int
	PublishDate    *time.Time
	IsEdited       *bool
	Likes          *int
	Dislikes       *int
	AppVersionCode *int
	SDKVersion     *int
	Reply          *DeveloperReply
}

// DeveloperReply is the reply Bazaar shows under a review.
type DeveloperReply struct {
	Text        string
	Email       string
	Likes       *int
	Dislikes    *int
	PublishDate *time.Time
}

// Page is one page of reviews and the cursor of the next, "" on the last.
type Page struct {
	Reviews []Review
	Next    string
}

// API is Bazaar's reviews API as the service needs it. HTTPClient talks to
// Bazaar; Fake stands in for it in development and tests.
type API interface {
	// List returns the page at cursor ("" for the first).
	List(ctx context.Context, cursor string) (Page, error)
	// Reply sends a developer reply. email "" lets Bazaar use the account's
	// own address.
	Reply(ctx context.Context, reviewID int64, text, email string) error
}

// Error kinds. Every failure of the API is one of these, wrapped in *Error.
var (
	// ErrUnauthorized: Bazaar refused the API key (401/403).
	ErrUnauthorized = errors.New("reviews: API key refused")
	// ErrNotFound: Bazaar has no such review (404).
	ErrNotFound = errors.New("reviews: review not found")
	// ErrRateLimited: too many requests (429).
	ErrRateLimited = errors.New("reviews: rate limited")
	// ErrRefused: Bazaar turned the request down (other 4xx); Detail says why.
	ErrRefused = errors.New("reviews: request refused")
	// ErrUnavailable: a timeout, a 5xx or no answer at all. Says nothing
	// about the request itself; trying later may work.
	ErrUnavailable = errors.New("reviews: Bazaar unavailable")
	// ErrInvalidResponse: an answer that is not what the API documents.
	ErrInvalidResponse = errors.New("reviews: unexpected answer from Bazaar")
)

// Error is a failed call: its Kind is one of the errors above and Detail is
// Bazaar's "detail" text, when it sent one (cut to 300 characters).
type Error struct {
	Kind   error
	Status int
	Detail string
}

func (e *Error) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("%v (HTTP %d): %s", e.Kind, e.Status, e.Detail)
	}
	if e.Status != 0 {
		return fmt.Sprintf("%v (HTTP %d)", e.Kind, e.Status)
	}
	return e.Kind.Error()
}

func (e *Error) Unwrap() error { return e.Kind }

// Code is a short, stable name of an error's kind, for storage and pages.
func Code(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, ErrUnauthorized):
		return "unauthorized"
	case errors.Is(err, ErrNotFound):
		return "not_found"
	case errors.Is(err, ErrRateLimited):
		return "rate_limited"
	case errors.Is(err, ErrRefused):
		return "refused"
	case errors.Is(err, ErrInvalidResponse):
		return "invalid_response"
	}
	return "unavailable"
}

// Limits on what is read from Bazaar.
const (
	maxBody      = 4 << 20 // one page of reviews
	maxErrorBody = 16 << 10
	maxDetail    = 300
)

// HTTPClient talks to Bazaar's reviews API.
type HTTPClient struct {
	// BaseURL is https://sandoghche.cafebazaar.ir in production.
	BaseURL string
	// KeyHeader and Key are the API key header name and value from Bazaar's
	// developer panel.
	KeyHeader string
	Key       string
	HTTP      *http.Client
}

func (c *HTTPClient) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{
		Timeout: 10 * time.Second,
		// The key is a header: it must not follow a redirect anywhere else.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func (c *HTTPClient) listURL() string { return strings.TrimRight(c.BaseURL, "/") + "/api/v0/reviews/" }

func (c *HTTPClient) List(ctx context.Context, cursor string) (Page, error) {
	u := c.listURL()
	if cursor != "" {
		u += "?" + url.Values{"cursor": {cursor}}.Encode()
	}
	var raw rawPage
	if err := c.do(ctx, http.MethodGet, u, nil, http.StatusOK, &raw); err != nil {
		return Page{}, err
	}
	page := Page{Reviews: make([]Review, 0, len(raw.Results))}
	for _, r := range raw.Results {
		rv, err := r.review()
		if err != nil {
			return Page{}, &Error{Kind: ErrInvalidResponse, Detail: err.Error()}
		}
		page.Reviews = append(page.Reviews, rv)
	}
	if raw.Next != nil && *raw.Next != "" {
		next, err := c.cursorOf(*raw.Next)
		if err != nil {
			return Page{}, &Error{Kind: ErrInvalidResponse, Detail: err.Error()}
		}
		if next == cursor {
			return Page{}, &Error{Kind: ErrInvalidResponse, Detail: "next page is the same page"}
		}
		page.Next = next
	}
	return page, nil
}

// cursorOf takes the cursor out of a next URL, refusing one that points
// anywhere but the list endpoint on the configured host.
func (c *HTTPClient) cursorOf(next string) (string, error) {
	base, err := url.Parse(c.listURL())
	if err != nil {
		return "", err
	}
	u, err := url.Parse(next)
	if err != nil {
		return "", errors.New("next is not a URL")
	}
	if u.IsAbs() && (u.Scheme != base.Scheme || !strings.EqualFold(u.Host, base.Host)) {
		return "", errors.New("next points at another host")
	}
	if strings.TrimRight(u.Path, "/") != strings.TrimRight(base.Path, "/") {
		return "", errors.New("next points at another path")
	}
	cur := u.Query().Get("cursor")
	if cur == "" || len(cur) > 2048 {
		return "", errors.New("next has no usable cursor")
	}
	return cur, nil
}

func (c *HTTPClient) Reply(ctx context.Context, reviewID int64, text, email string) error {
	body := map[string]string{"text": text}
	if email != "" {
		body["email"] = email
	}
	raw, _ := json.Marshal(body)
	return c.do(ctx, http.MethodPost, c.listURL()+strconv.FormatInt(reviewID, 10)+"/", raw, http.StatusCreated, nil)
}

func (c *HTTPClient) do(ctx context.Context, method, u string, body []byte, want int, out any) error {
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, rd)
	if err != nil {
		return &Error{Kind: ErrUnavailable}
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json;charset=UTF-8")
	req.Header.Set(c.KeyHeader, c.Key)
	res, err := c.client().Do(req)
	if err != nil {
		// The URL holds no secret, but the transport error is reduced to a
		// kind anyway: it never needs to reach a page.
		return &Error{Kind: ErrUnavailable}
	}
	defer res.Body.Close()
	if res.StatusCode != want {
		// Accept any 2xx for a reply: Bazaar documents 201.
		if out == nil && res.StatusCode >= 200 && res.StatusCode < 300 {
			_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, maxErrorBody))
			return nil
		}
		return statusError(res)
	}
	if out == nil {
		_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, maxErrorBody))
		return nil
	}
	dec := json.NewDecoder(io.LimitReader(res.Body, maxBody))
	if err := dec.Decode(out); err != nil {
		return &Error{Kind: ErrInvalidResponse, Status: res.StatusCode}
	}
	return nil
}

func statusError(res *http.Response) error {
	e := &Error{Status: res.StatusCode}
	switch {
	case res.StatusCode == http.StatusUnauthorized || res.StatusCode == http.StatusForbidden:
		e.Kind = ErrUnauthorized
	case res.StatusCode == http.StatusNotFound:
		e.Kind = ErrNotFound
	case res.StatusCode == http.StatusTooManyRequests:
		e.Kind = ErrRateLimited
	case res.StatusCode >= 400 && res.StatusCode < 500:
		e.Kind = ErrRefused
	default:
		e.Kind = ErrUnavailable
	}
	var msg struct {
		Detail any `json:"detail"`
	}
	b, _ := io.ReadAll(io.LimitReader(res.Body, maxErrorBody))
	if json.Unmarshal(b, &msg) == nil {
		e.Detail = clip(detailText(msg.Detail), maxDetail)
	}
	return e
}

// detailText reads "detail" as Bazaar sends it: usually a string, sometimes
// a list of strings.
func detailText(v any) string {
	switch d := v.(type) {
	case string:
		return strings.TrimSpace(d)
	case []any:
		var parts []string
		for _, p := range d {
			if s, ok := p.(string); ok && strings.TrimSpace(s) != "" {
				parts = append(parts, strings.TrimSpace(s))
			}
		}
		return strings.Join(parts, " ")
	}
	return ""
}

// clip cuts s to n characters, never inside one, and drops control
// characters so the text is safe in a log line.
func clip(s string, n int) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, s)
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n]) + "…"
}

// ---- wire format ------------------------------------------------------------

type rawPage struct {
	Next    *string     `json:"next"`
	Results []rawReview `json:"results"`
}

type rawReview struct {
	ID             json.Number `json:"id"`
	UserAccountID  any         `json:"user_account_id"`
	Text           *string     `json:"text"`
	Rate           json.Number `json:"rate"`
	PublishDate    *string     `json:"publish_date"`
	IsEdited       *bool       `json:"is_edited"`
	Likes          *int        `json:"likes"`
	Dislikes       *int        `json:"dislikes"`
	AppVersionCode *int        `json:"app_version_code"`
	SDKVersion     *int        `json:"sdk_version"`
	DeveloperReply *rawReply   `json:"developer_reply"`
}

type rawReply struct {
	Text        *string `json:"text"`
	Email       *string `json:"email"`
	Likes       *int    `json:"likes"`
	Dislikes    *int    `json:"dislikes"`
	PublishDate *string `json:"publish_date"`
}

func (r rawReview) review() (Review, error) {
	id, err := r.ID.Int64()
	if err != nil || id <= 0 {
		return Review{}, errors.New("review without a valid id")
	}
	rate, err := r.Rate.Int64()
	if err != nil || rate < 1 || rate > 5 {
		return Review{}, fmt.Errorf("review %d has rate %q", id, r.Rate)
	}
	out := Review{
		ID: id, Rate: int(rate), UserAccountID: clip(stringOf(r.UserAccountID), 128),
		IsEdited: r.IsEdited, Likes: nonNegative(r.Likes), Dislikes: nonNegative(r.Dislikes),
		AppVersionCode: nonNegative(r.AppVersionCode), SDKVersion: nonNegative(r.SDKVersion),
	}
	if r.Text != nil {
		out.Text = cleanText(*r.Text)
	}
	out.PublishDate = parseTime(r.PublishDate)
	if d := r.DeveloperReply; d != nil && d.Text != nil && strings.TrimSpace(*d.Text) != "" {
		rep := &DeveloperReply{Text: cleanText(*d.Text), Likes: nonNegative(d.Likes), Dislikes: nonNegative(d.Dislikes),
			PublishDate: parseTime(d.PublishDate)}
		if d.Email != nil {
			rep.Email = clip(strings.TrimSpace(*d.Email), 254)
		}
		out.Reply = rep
	}
	return out, nil
}

// cleanText keeps a review's words and line breaks, and drops other control
// characters and anything beyond 5,000 characters.
func cleanText(s string) string {
	s = strings.ToValidUTF8(s, "")
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return r
		}
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > 5000 {
		s = string([]rune(s)[:5000])
	}
	return s
}

func stringOf(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	}
	return ""
}

func nonNegative(p *int) *int {
	if p == nil || *p < 0 {
		return nil
	}
	return p
}

// parseTime reads Bazaar's ISO 8601 dates ("2021-11-29T17:40:28.184113+03:30").
func parseTime(p *string) *time.Time {
	if p == nil || *p == "" {
		return nil
	}
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02T15:04:05.999999999", "2006-01-02"} {
		if t, err := time.Parse(layout, *p); err == nil {
			t = t.UTC()
			return &t
		}
	}
	return nil
}
