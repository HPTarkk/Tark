package reviews

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/store"
	"github.com/jackc/pgx/v5/pgxpool"
)

func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dbURL := os.Getenv("TARK_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TARK_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := store.Open(ctx, dbURL, 6)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return pool
}

// clock is a settable time shared by the service and the fake.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) { c.mu.Lock(); c.t = c.t.Add(d); c.mu.Unlock() }

func newTestService(t *testing.T, n int) (*Service, *Fake, *clock) {
	t.Helper()
	pool := testPool(t)
	f := NewFake(n)
	f.PageSize = 7
	c := &clock{t: time.Now().UTC()}
	f.now = c.now
	s := NewService(pool, f, Settings{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	s.now = c.now
	return s, f, c
}

func ptr[T any](v T) *T { return &v }

func TestSyncStoresEveryPage(t *testing.T) {
	s, f, _ := newTestService(t, 40)
	ctx := context.Background()
	res, err := s.Sync(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if res.Seen != 40 || res.New != 40 || res.Removed != 0 {
		t.Fatalf("first sync: %+v", res)
	}
	if f.Calls != 6 { // 40 reviews in pages of 7
		t.Fatalf("pages read: %d", f.Calls)
	}
	var n int
	_ = s.pool.QueryRow(ctx, `SELECT count(*) FROM bazaar_reviews`).Scan(&n)
	if n != 40 {
		t.Fatalf("stored %d", n)
	}
	// A second run adds nothing and keeps the rows.
	res, err = s.Sync(ctx)
	if err != nil || res.New != 0 || res.Seen != 40 {
		t.Fatalf("second sync: %+v %v", res, err)
	}
	st, err := s.State(ctx)
	if err != nil || st.LastSuccess == nil || st.Failures != 0 || st.LastSeen != 40 || st.Running(s.now()) {
		t.Fatalf("state: %+v %v", st, err)
	}
}

func TestSyncFollowsEditsRemovalsAndFailures(t *testing.T) {
	s, f, c := newTestService(t, 20)
	ctx := context.Background()
	if _, err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	id := f.reviews[3].ID
	f.Edit(id, "حالا خيلي بهتر شد")
	gone := f.reviews[5].ID
	f.Remove(gone)
	at := c.now().Add(-time.Hour)
	f.Add(Review{ID: 999, UserAccountID: "u-new", Text: "New one", Rate: 2, PublishDate: &at})
	res, err := s.Sync(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if res.New != 1 || res.Removed != 1 || res.Seen != 20 {
		t.Fatalf("sync: %+v", res)
	}
	items, _, err := s.List(ctx, Filter{ID: id})
	if err != nil || len(items) != 1 || items[0].Body != "حالا خيلي بهتر شد" || items[0].IsEdited == nil || !*items[0].IsEdited {
		t.Fatalf("edit: %+v %v", items, err)
	}
	// Search folds Arabic letters and the query alike.
	if items, total, _ := s.List(ctx, Filter{Search: "خیلی  بهتر"}); total != 1 || items[0].ID != id {
		t.Fatalf("search: %d", total)
	}
	if _, total, _ := s.List(ctx, Filter{ID: gone}); total != 0 {
		t.Fatal("removed review still listed")
	}

	// A failed run keeps what is stored and removes nothing.
	f.Fail = &Error{Kind: ErrUnavailable}
	if _, err := s.Sync(ctx); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("got %v", err)
	}
	_, total, _ := s.List(ctx, Filter{})
	if total != 20 {
		t.Fatalf("after a failure: %d", total)
	}
	st, _ := s.State(ctx)
	if st.Failures != 1 || st.LastError != "unavailable" {
		t.Fatalf("state: %+v", st)
	}

	// An empty answer is not taken to mean every review was deleted.
	f.Fail = nil
	f.reviews = nil
	if res, err := s.Sync(ctx); err != nil || res.Removed != 0 {
		t.Fatalf("empty: %+v %v", res, err)
	}
	if _, total, _ := s.List(ctx, Filter{}); total != 20 {
		t.Fatalf("after an empty answer: %d", total)
	}
	if st, _ := s.State(ctx); st.Failures != 0 {
		t.Fatalf("success should reset failures: %+v", st)
	}
}

func TestSyncOneAtATime(t *testing.T) {
	s, _, _ := newTestService(t, 5)
	ctx := context.Background()
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", int64(syncLock)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Sync(ctx); !errors.Is(err, ErrBusy) {
		t.Fatalf("got %v", err)
	}
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_unlock($1)", int64(syncLock)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestReplyFlow(t *testing.T) {
	s, f, c := newTestService(t, 10)
	ctx := context.Background()
	if _, err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	var id int64
	for _, r := range f.reviews {
		if r.Reply == nil {
			id = r.ID
			break
		}
	}
	if id == 0 {
		t.Fatal("no unanswered review in the fake")
	}

	for _, tc := range []struct {
		text, email string
		want        error
	}{
		{"   \r\n ", "", ErrEmpty},
		{strings.Repeat("ب", MaxReply+1), "", ErrTooLong},
		{"hi", "not-an-email", ErrBadEmail},
		{"hi", "a@b.c\r\nBcc: x@y.z", ErrBadEmail},
	} {
		if err := s.Reply(ctx, "", id, tc.text, tc.email); !errors.Is(err, tc.want) {
			t.Fatalf("%q %q: got %v", tc.text, tc.email, err)
		}
	}
	if err := s.Reply(ctx, "", 4242, "hi", ""); !errors.Is(err, ErrNoReview) {
		t.Fatalf("unknown review: %v", err)
	}
	if len(f.Sent) != 0 {
		t.Fatalf("refused replies reached Bazaar: %+v", f.Sent)
	}

	// Bazaar refusing it records nothing.
	f.Fail = &Error{Kind: ErrRefused, Status: 400, Detail: "Too short."}
	if err := s.Reply(ctx, "", id, "hi", ""); !errors.Is(err, ErrRefused) {
		t.Fatalf("got %v", err)
	}
	f.Fail = nil
	if items, _, _ := s.List(ctx, Filter{ID: id}); items[0].Waiting != nil {
		t.Fatal("a refused reply was recorded")
	}

	text := strings.Repeat("ب", MaxReply) // the longest allowed
	if err := s.Reply(ctx, "", id, "  "+text+"\r\n", "support@tarkk.ir"); err != nil {
		t.Fatal(err)
	}
	if len(f.Sent) != 1 || f.Sent[0].Text != text || f.Sent[0].Email != "support@tarkk.ir" {
		t.Fatalf("sent: %+v", f.Sent)
	}
	items, _, _ := s.List(ctx, Filter{ID: id})
	if w := items[0].Waiting; w == nil || w.Body != text || w.Email == nil || *w.Email != "support@tarkk.ir" || w.CanResend(c.now()) {
		t.Fatalf("waiting: %+v", items[0].Waiting)
	}
	if _, n, _ := s.List(ctx, Filter{Status: StatusAwaiting}); n != 1 {
		t.Fatalf("awaiting: %d", n)
	}
	if err := s.Reply(ctx, "", id, "again", ""); !errors.Is(err, ErrAwaiting) {
		t.Fatalf("second reply: %v", err)
	}

	// Bazaar approves it; the next sync shows it public.
	c.add(3 * time.Minute)
	res, err := s.Sync(ctx)
	if err != nil || res.Published != 1 {
		t.Fatalf("sync: %+v %v", res, err)
	}
	items, _, _ = s.List(ctx, Filter{ID: id})
	if items[0].Waiting != nil || items[0].ReplyBody == nil || *items[0].ReplyBody != text {
		t.Fatalf("after approval: %+v", items[0])
	}
	if _, n, _ := s.List(ctx, Filter{Status: StatusAnswered, ID: 0, Search: ""}); n == 0 {
		t.Fatal("answered is empty")
	}
}

func TestReplyMayBeSentAgainAfterAWeek(t *testing.T) {
	s, f, c := newTestService(t, 10)
	ctx := context.Background()
	f.ApproveAfter = 365 * 24 * time.Hour // Bazaar never approves it
	if _, err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	id := f.reviews[0].ID
	if err := s.Reply(ctx, "", id, "first", ""); err != nil {
		t.Fatal(err)
	}
	c.add(ResendAfter - time.Minute)
	if err := s.Reply(ctx, "", id, "second", ""); !errors.Is(err, ErrAwaiting) {
		t.Fatalf("got %v", err)
	}
	c.add(2 * time.Minute)
	if err := s.Reply(ctx, "", id, "second", ""); err != nil {
		t.Fatal(err)
	}
	var n int
	_ = s.pool.QueryRow(ctx, `SELECT count(*) FROM bazaar_review_replies WHERE review_id = $1`, id).Scan(&n)
	items, _, _ := s.List(ctx, Filter{ID: id})
	if n != 1 || items[0].Waiting == nil || items[0].Waiting.Body != "second" {
		t.Fatalf("rows %d, waiting %+v", n, items[0].Waiting)
	}
}

func TestRepliesToOneReviewNeverRace(t *testing.T) {
	s, f, _ := newTestService(t, 5)
	ctx := context.Background()
	if _, err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	id := f.reviews[0].ID
	var wg sync.WaitGroup
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- s.Reply(ctx, "", id, "same time", "")
		}()
	}
	wg.Wait()
	close(errs)
	ok := 0
	for err := range errs {
		switch {
		case err == nil:
			ok++
		case !errors.Is(err, ErrAwaiting):
			t.Fatal(err)
		}
	}
	if ok != 1 || len(f.Sent) != 1 {
		t.Fatalf("%d went through, Bazaar got %d", ok, len(f.Sent))
	}
}

func TestListFiltersAndStats(t *testing.T) {
	s, f, c := newTestService(t, 0)
	ctx := context.Background()
	now := c.now()
	day := func(n int) *time.Time { t := now.Add(-time.Duration(n) * 24 * time.Hour); return &t }
	replied := &DeveloperReply{Text: "ممنون", PublishDate: day(1)}
	for _, r := range []Review{
		{ID: 1, UserAccountID: "u1", Text: "Crashes on start", Rate: 1, PublishDate: day(2), AppVersionCode: ptr(39), SDKVersion: ptr(34)},
		{ID: 2, UserAccountID: "u1", Text: "Better now 100%", Rate: 4, PublishDate: day(3), AppVersionCode: ptr(39), SDKVersion: ptr(33), Reply: replied},
		{ID: 3, UserAccountID: "u2", Text: "عالي", Rate: 5, PublishDate: day(40), AppVersionCode: ptr(38)},
		{ID: 4, UserAccountID: "u3", Text: "meh_ok", Rate: 3, PublishDate: day(100)},
		{ID: 5, UserAccountID: "u4", Text: "بد", Rate: 2}, // no date: first seen now
	} {
		f.Add(r)
	}
	if _, err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	ids := func(fl Filter) string {
		t.Helper()
		items, total, err := s.List(ctx, fl)
		if err != nil {
			t.Fatal(err)
		}
		var b strings.Builder
		for _, it := range items {
			b.WriteByte(byte('0' + it.ID))
		}
		if total < len(items) {
			t.Fatalf("total %d < %d", total, len(items))
		}
		return b.String()
	}
	for name, tc := range map[string]struct {
		f    Filter
		want string
	}{
		"newest first":    {Filter{}, "51234"},
		"oldest first":    {Filter{Sort: SortOldest}, "43215"},
		"lowest first":    {Filter{Sort: SortLowest}, "15423"},
		"needs a reply":   {Filter{Status: StatusNeeds}, "5134"},
		"answered":        {Filter{Status: StatusAnswered}, "2"},
		"stars":           {Filter{Rates: []int{1, 2}}, "51"},
		"every star":      {Filter{Rates: []int{1, 2, 3, 4, 5}}, "51234"},
		"build":           {Filter{Version: 39}, "12"},
		"android":         {Filter{SDK: 34}, "1"},
		"last 30 days":    {Filter{Since: now.Add(-30 * 24 * time.Hour)}, "512"},
		"one person":      {Filter{User: "u1"}, "12"},
		"search folds":    {Filter{Search: "عالی"}, "3"},
		"search words":    {Filter{Search: "crashes START"}, "1"},
		"like is literal": {Filter{Search: "%"}, "2"},
		"underscore":      {Filter{Search: "_"}, "4"},
		"paging":          {Filter{Limit: 2, Offset: 2}, "23"},
		"one by id":       {Filter{ID: 3, Status: StatusNeeds, Rates: []int{1}}, "3"},
	} {
		if got := ids(tc.f); got != tc.want {
			t.Errorf("%s: got %s, want %s", name, got, tc.want)
		}
	}
	items, _, _ := s.List(ctx, Filter{ID: 1})
	if items[0].UserReviews != 2 {
		t.Fatalf("user reviews: %d", items[0].UserReviews)
	}

	st, err := s.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Total != 5 || st.ByRate != [5]int{1, 1, 1, 1, 1} || st.Average != 3 || st.Needs != 4 || st.Answered != 1 || st.Awaiting != 0 {
		t.Fatalf("stats: %+v", st)
	}
	if st.Last30 != 3 || st.Prev30 != 1 || st.Avg30 < 2.33 || st.Avg30 > 2.34 {
		t.Fatalf("30 days: %+v", st)
	}
	if st.MedianReply != 2*24*time.Hour {
		t.Fatalf("median reply: %v", st.MedianReply)
	}
	if len(st.Weeks) != Weeks {
		t.Fatalf("weeks: %d", len(st.Weeks))
	}
	week := 0
	for _, w := range st.Weeks {
		week += w.Count
	}
	if week != 4 { // all but the one from 100 days ago
		t.Fatalf("weeks hold %d", week)
	}
	if len(st.Versions) != 2 || st.Versions[0].Code != 39 || st.Versions[0].Count != 2 {
		t.Fatalf("versions: %+v", st.Versions)
	}
	if n, _ := s.NeedsReply(ctx); n != 4 {
		t.Fatalf("needs reply: %d", n)
	}
	fc, _ := s.Facets(ctx)
	if len(fc.Versions) != 2 || fc.Versions[0] != 39 || len(fc.SDKs) != 2 {
		t.Fatalf("facets: %+v", fc)
	}
}

func TestFoldAndEmail(t *testing.T) {
	for in, want := range map[string]string{
		"كيك":               "کیک",
		"می‌خواهم":          "میخواهم",
		"۱۲٣ ABC":           "123 abc",
		"  سلام \n\t دنيا ": "سلام دنیا",
		"مـــرسی":           "مرسی",
		"آبِ":               "اب",
	} {
		if got := Fold(in); got != want {
			t.Errorf("Fold(%q) = %q, want %q", in, got, want)
		}
	}
	for e, ok := range map[string]bool{
		"support@tarkk.ir": true, "a.b+c@x.co": true,
		"": false, "x": false, "a@b": false, "a@@b.c": false, "a b@c.de": false, "a@b.c.": false, "<a@b.cd>": false,
	} {
		if ValidEmail(e) != ok {
			t.Errorf("ValidEmail(%q) = %v", e, !ok)
		}
	}
}
