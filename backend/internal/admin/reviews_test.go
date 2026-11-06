package admin

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/reviews"
)

// withReviews is setup with the Reviews section on, backed by a fake Bazaar
// that already holds n reviews, synced.
func withReviews(t *testing.T, n int) (*env, *reviews.Fake, *reviews.Service) {
	t.Helper()
	e := setup(t)
	fake := reviews.NewFake(n)
	svc := reviews.NewService(e.deps.Pool, fake, reviews.Settings{ReplyEmail: "support@tarkk.ir"}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if _, err := svc.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	e.deps.Reviews = svc
	srv, err := New(e.deps)
	if err != nil {
		t.Fatal(err)
	}
	e.ts.Close()
	e.srv, e.ts = srv, httptest.NewServer(srv.Handler())
	t.Cleanup(e.ts.Close)
	return e, fake, svc
}

// member adds an admin with role through the owner's Admins page and signs
// them in.
func (e *env) member(owner *browser, email string, role Role) *browser {
	e.t.Helper()
	_, body := owner.get("/admins")
	_, body = owner.post("/admins", url.Values{"csrf": {field(e.t, body, "csrf")}, "name": {"Member"}, "email": {email}, "role": {string(role)}})
	m := regexp.MustCompile(`<code class="key">([A-Za-z0-9_-]+)</code>`).FindStringSubmatch(body)
	if m == nil {
		e.t.Fatalf("no temporary password:\n%s", body)
	}
	b := e.browser()
	body, _ = b.signIn(email, m[1], nil)
	if code, _ := b.post("/account/password", url.Values{"csrf": {field(e.t, body, "csrf")}, "current": {m[1]},
		"new": {"member-passphrase-12"}, "again": {"member-passphrase-12"}}); code != http.StatusOK {
		e.t.Fatalf("password change: %d", code)
	}
	return b
}

// unanswered is a review in the fake with no reply yet.
func unanswered(t *testing.T, svc *reviews.Service) reviews.Item {
	t.Helper()
	items, _, err := svc.List(context.Background(), reviews.Filter{Status: reviews.StatusNeeds, Limit: 1})
	if err != nil || len(items) == 0 {
		t.Fatalf("no unanswered review: %v", err)
	}
	return items[0]
}

func TestReviewsOffShowsSetup(t *testing.T) {
	e := setup(t)
	owner := e.owner("boss@example.com")
	code, body := owner.get("/reviews")
	if code != http.StatusOK || !strings.Contains(body, "Reviews aren&#39;t set up yet") || !strings.Contains(body, "TARK_BAZAAR_REVIEWS_API_KEY") {
		t.Fatalf("%d\n%s", code, body)
	}
	if strings.Contains(body, `action="/reviews/sync"`) {
		t.Fatal("sync offered without a key")
	}
	sup := e.member(owner, "sup@example.com", RoleSupport)
	if _, body := sup.get("/"); strings.Contains(body, `href="/reviews"`) {
		t.Fatal("support sees a Reviews section that is off")
	}
	_, body = sup.get("/reviews")
	if code, _ := sup.post("/reviews/sync", url.Values{"csrf": {field(t, body, "csrf")}}); code != http.StatusNotFound {
		t.Fatalf("sync with reviews off: %d", code)
	}
}

func TestReviewsPage(t *testing.T) {
	e, _, svc := withReviews(t, 60)
	owner := e.owner("boss@example.com")
	code, body := owner.get("/reviews")
	if code != http.StatusOK {
		t.Fatalf("%d\n%s", code, body)
	}
	for _, want := range []string{`href="/reviews"`, "Need a reply", `class="rv-cards"`, `name="text"`, "support@tarkk.ir", `action="/reviews/sync"`} {
		if !strings.Contains(body, want) {
			t.Errorf("page lacks %q", want)
		}
	}
	// Persian, every filter, odd values: still a page.
	fa := e.persianBrowser()
	fa.c.Jar = owner.c.Jar
	u, _ := url.Parse(e.ts.URL)
	fa.c.Jar.SetCookies(u, []*http.Cookie{{Name: langCookie, Value: "fa"}})
	for _, q := range []string{
		"", "?status=all&sort=old", "?status=answered&r=1&r=5&v=39&sdk=34&days=30", "?status=awaiting",
		"?q=%25_%5C&r=9&r=x&v=-1&sdk=abc&days=13&n=99999&sort=nope&status=bogus&u=" + url.QueryEscape("<script>"),
		"?n=50&prev=25", "?sent=1&synced=1&new=3", "?syncerr=unauthorized", "?syncing=1",
	} {
		code, body := fa.get("/reviews" + q)
		if code != http.StatusOK || !strings.Contains(body, `dir="rtl"`) || strings.Contains(body, "<script>") {
			t.Fatalf("%s: %d", q, code)
		}
	}
	_ = svc
}

func TestReviewsReply(t *testing.T) {
	e, fake, svc := withReviews(t, 30)
	ctx := context.Background()
	owner := e.owner("boss@example.com")
	sup := e.member(owner, "sup@example.com", RoleSupport)
	it := unanswered(t, svc)
	id := strconv.FormatInt(it.ID, 10)
	_, body := sup.get("/reviews")
	csrf := field(t, body, "csrf")
	post := func(form url.Values) (int, string) {
		form.Set("csrf", csrf)
		return sup.post("/reviews/"+id+"/reply", form)
	}

	// No token: refused before anything else.
	if code, _ := sup.post("/reviews/"+id+"/reply", url.Values{"text": {"hi"}}); code != http.StatusForbidden {
		t.Fatalf("without csrf: %d", code)
	}
	// Refusals come back with the words kept and the reason shown.
	code, body := post(url.Values{"text": {"  "}, "back": {"/reviews?status=all"}})
	if code != http.StatusBadRequest || !strings.Contains(body, "Write something first.") {
		t.Fatalf("empty: %d", code)
	}
	code, body = post(url.Values{"text": {"Thanks <b>a lot</b>"}, "email": {"nope"}})
	if code != http.StatusBadRequest || !strings.Contains(body, "Thanks &lt;b&gt;a lot&lt;/b&gt;") || !strings.Contains(body, `aria-invalid="true"`) {
		t.Fatalf("bad email: %d", code)
	}
	fake.Fail = &reviews.Error{Kind: reviews.ErrRefused, Status: 400, Detail: "Text is <too> short."}
	code, body = post(url.Values{"text": {"ok"}})
	if code != http.StatusBadGateway || !strings.Contains(body, "Bazaar turned the reply down: Text is &lt;too&gt; short.") {
		t.Fatalf("refused: %d", code)
	}
	fake.Fail = nil
	if len(fake.Sent) != 0 {
		t.Fatalf("refused replies reached Bazaar: %+v", fake.Sent)
	}

	// Sent: back on the same view, the review pinned with its reply waiting.
	code, body = post(url.Values{"text": {"Thanks! Fixed in the next update."}, "email": {"help@tarkk.ir"}, "back": {"/reviews?status=needs&r=1"}})
	if code != http.StatusOK || !strings.Contains(body, "Reply sent.") || !strings.Contains(body, "Awaiting Bazaar") ||
		!strings.Contains(body, `id="review-`+id+`"`) || !strings.Contains(body, "Thanks! Fixed in the next update.") {
		t.Fatalf("sent: %d\n%s", code, body)
	}
	if len(fake.Sent) != 1 || fake.Sent[0].ReviewID != it.ID || fake.Sent[0].Email != "help@tarkk.ir" {
		t.Fatalf("Bazaar got %+v", fake.Sent)
	}
	var kind, details string
	if err := e.deps.Pool.QueryRow(ctx, `SELECT kind, details::text FROM admin_events ORDER BY id DESC LIMIT 1`).Scan(&kind, &details); err != nil {
		t.Fatal(err)
	}
	if kind != "review.replied" || !strings.Contains(details, id) || strings.Contains(details, "Thanks") {
		t.Fatalf("event %s %s", kind, details)
	}
	// A second reply while the first waits is refused.
	if code, body := post(url.Values{"text": {"again"}}); code != http.StatusConflict || !strings.Contains(body, "already waiting") {
		t.Fatalf("second: %d", code)
	}
	// An unknown review.
	if code, _ := sup.post("/reviews/12345/reply", url.Values{"csrf": {csrf}, "text": {"hi"}}); code != http.StatusNotFound {
		t.Fatalf("unknown review: %d", code)
	}
	// "back" never leaves the Reviews page.
	res, err := (&http.Client{Jar: sup.c.Jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}).
		PostForm(e.ts.URL+"/reviews/"+strconv.FormatInt(unanswered(t, svc).ID, 10)+"/reply",
			url.Values{"csrf": {csrf}, "text": {"hi"}, "back": {"https://evil.example/reviews"}})
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if loc := res.Header.Get("Location"); res.StatusCode != http.StatusSeeOther || !strings.HasPrefix(loc, "/reviews?") {
		t.Fatalf("redirect %d %q", res.StatusCode, loc)
	}
}

func TestReviewsSync(t *testing.T) {
	e, fake, _ := withReviews(t, 10)
	owner := e.owner("boss@example.com")
	_, body := owner.get("/reviews")
	csrf := field(t, body, "csrf")
	at := time.Now()
	fake.Add(reviews.Review{ID: 1, UserAccountID: "u", Text: "Brand new review", Rate: 3, PublishDate: &at})
	code, body := owner.post("/reviews/sync", url.Values{"csrf": {csrf}, "back": {"/reviews?status=all"}})
	if code != http.StatusOK || !strings.Contains(body, "Synced with Bazaar: 1 new.") || !strings.Contains(body, "Brand new review") {
		t.Fatalf("sync: %d\n%s", code, body)
	}
	fake.Fail = &reviews.Error{Kind: reviews.ErrUnauthorized, Status: 401}
	_, body = owner.post("/reviews/sync", url.Values{"csrf": {csrf}})
	if !strings.Contains(body, "Bazaar refused") {
		t.Fatalf("failed sync not shown:\n%s", body)
	}
}

func TestViewerCannotSeeReviews(t *testing.T) {
	e, fake, svc := withReviews(t, 5)
	owner := e.owner("boss@example.com")
	viewer := e.member(owner, "view@example.com", RoleViewer)
	if code, _ := viewer.get("/reviews"); code != http.StatusForbidden {
		t.Fatalf("viewer page: %d", code)
	}
	_, body := viewer.get("/")
	if strings.Contains(body, `href="/reviews"`) {
		t.Fatal("viewer sees the Reviews link")
	}
	csrf := field(t, body, "csrf")
	id := strconv.FormatInt(unanswered(t, svc).ID, 10)
	if code, _ := viewer.post("/reviews/"+id+"/reply", url.Values{"csrf": {csrf}, "text": {"hi"}}); code != http.StatusForbidden {
		t.Fatalf("viewer reply: %d", code)
	}
	if code, _ := viewer.post("/reviews/sync", url.Values{"csrf": {csrf}}); code != http.StatusForbidden {
		t.Fatalf("viewer sync: %d", code)
	}
	if len(fake.Sent) != 0 {
		t.Fatal("a viewer's reply reached Bazaar")
	}
}

func TestReviewQueryRoundTrips(t *testing.T) {
	q := parseReviewQuery(reviewsBack("/reviews?status=answered&r=5&r=1&r=1&v=39&sdk=34&days=90&q=%D8%B3%D9%84%D8%A7%D9%85&u=abc&sort=old"))
	if len(q.Rates) != 2 || q.Status != reviews.StatusAnswered {
		t.Fatalf("parsed %+v", q)
	}
	again := parseReviewQuery(q.values())
	if q.values().Encode() != again.values().Encode() {
		t.Fatalf("%v != %v", q.values(), again.values())
	}
	for _, back := range []string{"https://evil.example/reviews?status=all", "//evil.example/reviews?status=all", "/users?status=all", "javascript:alert(1)", "/reviews/../users?status=all"} {
		if got := reviewsBack(back); len(got) != 0 {
			t.Errorf("reviewsBack(%q) = %v", back, got)
		}
	}
}
