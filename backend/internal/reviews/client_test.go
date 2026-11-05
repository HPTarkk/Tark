package reviews

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testKey = "s3cret-key-never-shown"

// bazaar is a stand-in for Bazaar's API: it checks the key header and
// serves whatever handle returns.
func bazaar(t *testing.T, handle func(w http.ResponseWriter, r *http.Request)) (*HTTPClient, *httptest.Server) {
	t.Helper()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Test-Key") != testKey {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"detail":"Authentication credentials were not provided."}`)
			return
		}
		handle(w, r)
	}))
	t.Cleanup(ts.Close)
	return &HTTPClient{BaseURL: ts.URL, KeyHeader: "X-Test-Key", Key: testKey}, ts
}

func TestClientWalksPagesByCursor(t *testing.T) {
	var cursors []string
	c, ts := bazaar(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v0/reviews/" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		cur := r.URL.Query().Get("cursor")
		cursors = append(cursors, cur)
		switch cur {
		case "":
			// The documented example, plus fields the docs leave out.
			_, _ = io.WriteString(w, `{"next":"`+"http://"+r.Host+`/api/v0/reviews/?cursor=cD0yMDIx","previous":null,"results":[
				{"id":122281167,"user_account_id":"c5ac6283-c46a-4b9c-9e58-a8b05f1eed6a","text":"عالی بود\r\nممنون","rate":5,
				 "publish_date":"2021-11-29T17:40:28.184113+03:30","is_edited":true,"likes":3,"dislikes":-1,
				 "app_version_code":39,"sdk_version":34,
				 "developer_reply":{"text":"Thanks!","email":"support@tarkk.ir","likes":2,"publish_date":"2021-11-30T10:00:00+03:30"}}]}`)
		case "cD0yMDIx":
			_, _ = io.WriteString(w, `{"next":null,"results":[{"id":"7","user_account_id":42,"text":null,"rate":"2","developer_reply":{"text":"  "}}]}`)
		default:
			t.Errorf("cursor %q", cur)
		}
	})
	_ = ts
	p, err := c.List(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if p.Next != "cD0yMDIx" || len(p.Reviews) != 1 {
		t.Fatalf("page 1: %+v", p)
	}
	r := p.Reviews[0]
	if r.ID != 122281167 || r.Rate != 5 || r.Text != "عالی بود\nممنون" || r.UserAccountID != "c5ac6283-c46a-4b9c-9e58-a8b05f1eed6a" {
		t.Fatalf("review: %+v", r)
	}
	if r.PublishDate == nil || !r.PublishDate.Equal(time.Date(2021, 11, 29, 14, 10, 28, 184113000, time.UTC)) {
		t.Fatalf("date: %v", r.PublishDate)
	}
	if r.IsEdited == nil || !*r.IsEdited || *r.Likes != 3 || r.Dislikes != nil || *r.AppVersionCode != 39 || *r.SDKVersion != 34 {
		t.Fatalf("optional fields: %+v", r)
	}
	if r.Reply == nil || r.Reply.Text != "Thanks!" || r.Reply.Email != "support@tarkk.ir" || *r.Reply.Likes != 2 || r.Reply.PublishDate == nil {
		t.Fatalf("reply: %+v", r.Reply)
	}

	p, err = c.List(context.Background(), p.Next)
	if err != nil {
		t.Fatal(err)
	}
	r = p.Reviews[0]
	if p.Next != "" || r.ID != 7 || r.Rate != 2 || r.UserAccountID != "42" || r.Text != "" || r.PublishDate != nil || r.Reply != nil {
		t.Fatalf("page 2: %+v %+v", p, r)
	}
	if strings.Join(cursors, ",") != ",cD0yMDIx" {
		t.Fatalf("cursors: %q", cursors)
	}
}

func TestClientRefusesForeignOrLoopingNext(t *testing.T) {
	for name, next := range map[string]string{
		"other host":  `"https://evil.example/api/v0/reviews/?cursor=x"`,
		"other path":  `"/api/v0/other/?cursor=x"`,
		"no cursor":   `"/api/v0/reviews/?page=2"`,
		"same cursor": `"/api/v0/reviews/?cursor=abc"`,
	} {
		t.Run(name, func(t *testing.T) {
			c, _ := bazaar(t, func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.WriteString(w, `{"next":`+next+`,"results":[]}`)
			})
			_, err := c.List(context.Background(), "abc")
			if !errors.Is(err, ErrInvalidResponse) {
				t.Fatalf("got %v", err)
			}
		})
	}
}

func TestClientRejectsBadReviews(t *testing.T) {
	for _, body := range []string{
		`{"results":[{"id":0,"rate":5}]}`,
		`{"results":[{"id":5,"rate":6}]}`,
		`{"results":[{"id":5}]}`,
		`not json`,
	} {
		c, _ := bazaar(t, func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, body) })
		if _, err := c.List(context.Background(), ""); !errors.Is(err, ErrInvalidResponse) {
			t.Fatalf("%s: got %v", body, err)
		}
	}
}

func TestClientReply(t *testing.T) {
	var got map[string]string
	c, _ := bazaar(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v0/reviews/122281167/" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
			t.Errorf("content type %q", r.Header.Get("Content-Type"))
		}
		got = nil
		_ = json.NewDecoder(r.Body).Decode(&got)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{}`)
	})
	if err := c.Reply(context.Background(), 122281167, "سلام", "support@tarkk.ir"); err != nil {
		t.Fatal(err)
	}
	if got["text"] != "سلام" || got["email"] != "support@tarkk.ir" {
		t.Fatalf("body %v", got)
	}
	if err := c.Reply(context.Background(), 122281167, "hi", ""); err != nil {
		t.Fatal(err)
	}
	if _, ok := got["email"]; ok || got["text"] != "hi" {
		t.Fatalf("no email should leave it out: %v", got)
	}
}

func TestClientErrorsNeverCarryTheKey(t *testing.T) {
	cases := []struct {
		status int
		body   string
		kind   error
		code   string
		detail string
	}{
		{401, `{"detail":"Invalid token."}`, ErrUnauthorized, "unauthorized", "Invalid token."},
		{403, ``, ErrUnauthorized, "unauthorized", ""},
		{404, `{"detail":"Not found."}`, ErrNotFound, "not_found", "Not found."},
		{429, `{"detail":"Request was throttled."}`, ErrRateLimited, "rate_limited", "Request was throttled."},
		{400, `{"detail":["Text is too long.","Try again."]}`, ErrRefused, "refused", "Text is too long. Try again."},
		{400, `{"detail":"` + strings.Repeat("x", 400) + `"}`, ErrRefused, "refused", strings.Repeat("x", 300) + "…"},
		{502, `<html>bad gateway</html>`, ErrUnavailable, "unavailable", ""},
	}
	for _, tc := range cases {
		c, _ := bazaar(t, func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(tc.status)
			_, _ = io.WriteString(w, tc.body)
		})
		err := c.Reply(context.Background(), 1, "hi", "")
		var e *Error
		if !errors.As(err, &e) || !errors.Is(err, tc.kind) || Code(err) != tc.code || e.Detail != tc.detail || e.Status != tc.status {
			t.Fatalf("%d: got %#v", tc.status, err)
		}
		if strings.Contains(err.Error(), testKey) {
			t.Fatalf("error shows the key: %v", err)
		}
	}

	// A wrong key is refused, and the message never echoes the one sent.
	c, _ := bazaar(t, func(http.ResponseWriter, *http.Request) {})
	c.Key = "wrong-key-value"
	if _, err := c.List(context.Background(), ""); !errors.Is(err, ErrUnauthorized) || strings.Contains(err.Error(), "wrong-key-value") {
		t.Fatalf("got %v", err)
	}

	// No answer at all: unavailable, without the address or the key.
	dead := &HTTPClient{BaseURL: "http://127.0.0.1:1", KeyHeader: "X-Test-Key", Key: testKey}
	if _, err := dead.List(context.Background(), ""); !errors.Is(err, ErrUnavailable) || strings.Contains(err.Error(), testKey) || strings.Contains(err.Error(), "127.0.0.1") {
		t.Fatalf("got %v", err)
	}
}

func TestClientDoesNotFollowRedirects(t *testing.T) {
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Test-Key") != "" {
			t.Error("the key followed a redirect")
		}
		_, _ = io.WriteString(w, `{"results":[]}`)
	}))
	defer other.Close()
	c, _ := bazaar(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/api/v0/reviews/", http.StatusFound)
	})
	if _, err := c.List(context.Background(), ""); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("got %v", err)
	}
}

func TestCleanTextAndClip(t *testing.T) {
	if got := cleanText("  a\x00b\r\nc\x1b  "); got != "ab\nc" {
		t.Fatalf("cleanText: %q", got)
	}
	if got := []rune(cleanText(strings.Repeat("ن", 6000))); len(got) != 5000 {
		t.Fatalf("cleanText kept %d", len(got))
	}
	if got := clip("ab\ncd", 10); got != "ab cd" {
		t.Fatalf("clip: %q", got)
	}
	if got := clip("سلام دنیا", 4); got != "سلام…" {
		t.Fatalf("clip: %q", got)
	}
}
