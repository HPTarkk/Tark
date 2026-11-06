package admin

import (
	"context"
	"errors"
	"html/template"
	"math"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"

	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
	"github.com/HPTarkk/Tark/backend/internal/reviews"
)

// The Reviews page: Cafe Bazaar reviews of the app, from the copy the
// reviews service keeps (internal/reviews), with replies sent through it.
// Browsing reads only the database; Bazaar is called to sync and to reply,
// both from the server, so the API key never reaches a browser.

var ruleReviewReply = ratelimit.Rule{Name: "admin_review_reply", Max: 40, Window: time.Hour}
var ruleReviewSync = ratelimit.Rule{Name: "admin_review_sync", Max: 12, Window: time.Hour}

// pageStep is how many more reviews "Show more" adds; maxShown caps a page.
const (
	pageStep = 25
	maxShown = 500
)

// Periods offered by the date filter, in days (0: all time).
var reviewPeriods = []int{7, 30, 90, 365, 0}

func init() {
	icons["star"] = `<path d="m12 2.8 2.85 5.78 6.38.93-4.62 4.5 1.09 6.35L12 17.36l-5.7 3 1.09-6.35-4.62-4.5 6.38-.93z"/>`
	icons["like"] = `<path d="M7 10v11M7 10l4-8a3 3 0 0 1 3 3v4h5.5a2 2 0 0 1 2 2.3l-1.4 8A2 2 0 0 1 18.1 21H7"/><path d="M3 10h4v11H3z"/>`
	icons["dislike"] = `<path d="M17 14V3M17 14l-4 8a3 3 0 0 1-3-3v-4H4.5a2 2 0 0 1-2-2.3l1.4-8A2 2 0 0 1 5.9 3H17"/><path d="M21 14h-4V3h4z"/>`
	icons["tag"] = `<path d="M3 12V4a1 1 0 0 1 1-1h8l9 9-9 9z"/><circle cx="7.5" cy="7.5" r="1.5"/>`
	icons["reply"] = `<path d="M9 17 4 12l5-5"/><path d="M20 18v-2a4 4 0 0 0-4-4H4"/>`
	icons["edit"] = `<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>`
	icons["hourglass"] = `<path d="M6 2h12M6 22h12M7 2v4a5 5 0 0 0 10 0V2M7 22v-4a5 5 0 0 1 10 0v4"/>`
	icons["filter"] = `<path d="M3 5h18l-7 8v6l-4 2v-8z"/>`
	icons["sparkle"] = `<path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.6 5.6l2.8 2.8M15.6 15.6l2.8 2.8M5.6 18.4l2.8-2.8M15.6 8.4l2.8-2.8"/>`
	icons["user"] = `<circle cx="12" cy="8" r="4"/><path d="M4 21v-1a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v1"/>`
	// stars draws a rating as five stars, the first n filled. The words for
	// screen readers sit on the element around it.
	funcs["stars"] = func(n int) template.HTML {
		var b strings.Builder
		for i := 1; i <= 5; i++ {
			cls := "st"
			if i <= n {
				cls = "st on"
			}
			b.WriteString(`<svg class="` + cls + `" viewBox="0 0 24 24" aria-hidden="true" focusable="false">` + icons["star"] + `</svg>`)
		}
		return template.HTML(b.String())
	}
	funcs["android"] = androidName
	eventKinds["review.replied"] = eventKind{"reply", "accent"}
	eventKinds["reviews.synced"] = eventKind{"refresh", "info"}
}

// reviewQuery is the page's filter as it reads in the address bar. Every
// link on the page is the current query with one thing changed, so Back,
// reload and a shared link all show the same view.
type reviewQuery struct {
	Status  string
	Rates   []int
	Version int
	SDK     int
	Days    int
	Search  string
	User    string
	Sort    string
	Shown   int
	// StatusSet and SortSet say whether the address chose them; otherwise
	// the page picks (needs-reply first when there are any).
	StatusSet, SortSet bool
}

func parseReviewQuery(q url.Values) reviewQuery {
	rq := reviewQuery{Shown: pageStep}
	switch s := q.Get("status"); s {
	case reviews.StatusNeeds, reviews.StatusAwaiting, reviews.StatusAnswered, reviews.StatusAll:
		rq.Status, rq.StatusSet = s, true
	}
	for _, v := range q["r"] {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 5 && !slices.Contains(rq.Rates, n) {
			rq.Rates = append(rq.Rates, n)
		}
	}
	slices.Sort(rq.Rates)
	if len(rq.Rates) == 5 {
		rq.Rates = nil
	}
	rq.Version = positive(q.Get("v"), 1_000_000_000)
	rq.SDK = positive(q.Get("sdk"), 100)
	if d := positive(q.Get("days"), 3660); slices.Contains(reviewPeriods, d) {
		rq.Days = d
	}
	rq.Search = clipRunes(strings.TrimSpace(q.Get("q")), 100)
	if u := strings.TrimSpace(q.Get("u")); len(u) <= 128 {
		rq.User = u
	}
	switch s := q.Get("sort"); s {
	case reviews.SortNewest, reviews.SortOldest, reviews.SortLowest:
		rq.Sort, rq.SortSet = s, true
	}
	if n := positive(q.Get("n"), maxShown); n > pageStep {
		rq.Shown = (n + pageStep - 1) / pageStep * pageStep
		rq.Shown = min(rq.Shown, maxShown)
	}
	return rq
}

func positive(v string, limit int) int {
	n, err := strconv.Atoi(toASCIIDigits(strings.TrimSpace(v)))
	if err != nil || n < 1 || n > limit {
		return 0
	}
	return n
}

func clipRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// values is the query as it goes in a link: only what differs from the
// defaults, so addresses stay short.
func (rq reviewQuery) values() url.Values {
	v := url.Values{}
	if rq.StatusSet {
		v.Set("status", rq.Status)
	}
	for _, r := range rq.Rates {
		v.Add("r", strconv.Itoa(r))
	}
	if rq.Version > 0 {
		v.Set("v", strconv.Itoa(rq.Version))
	}
	if rq.SDK > 0 {
		v.Set("sdk", strconv.Itoa(rq.SDK))
	}
	if rq.Days > 0 {
		v.Set("days", strconv.Itoa(rq.Days))
	}
	if rq.Search != "" {
		v.Set("q", rq.Search)
	}
	if rq.User != "" {
		v.Set("u", rq.User)
	}
	if rq.SortSet {
		v.Set("sort", rq.Sort)
	}
	return v
}

// url is the page address for this query; a changed filter starts again at
// the first page, so Shown is left out unless keep says otherwise.
func (rq reviewQuery) url(keep bool) string {
	v := rq.values()
	if keep && rq.Shown > pageStep {
		v.Set("n", strconv.Itoa(rq.Shown))
	}
	if len(v) == 0 {
		return "/reviews"
	}
	return "/reviews?" + v.Encode()
}

func (rq reviewQuery) filter(now time.Time) reviews.Filter {
	f := reviews.Filter{Status: rq.Status, Rates: rq.Rates, Version: rq.Version, SDK: rq.SDK, Search: rq.Search,
		User: rq.User, Sort: rq.Sort, Limit: rq.Shown}
	if rq.Days > 0 {
		f.Since = now.Add(-time.Duration(rq.Days) * 24 * time.Hour)
	}
	return f
}

// Filtered says whether anything beyond the status narrows the list.
func (rq reviewQuery) Filtered() bool {
	return len(rq.Rates) > 0 || rq.Version > 0 || rq.SDK > 0 || rq.Days > 0 || rq.Search != "" || rq.User != ""
}

// ---- view -------------------------------------------------------------------

type reviewsView struct {
	Q        reviewQuery
	Stats    reviews.Stats
	State    reviews.State
	Running  bool
	Items    []reviewCard
	Total    int
	Listed   int    // cards shown that match the filter
	More     string // "Show more" link, "" at the end
	MoreN    int    // how many it adds
	Prev     int    // cards shown before "Show more" was pressed, for their entrance
	Tabs     []reviewTab
	Stars    []starBar
	StarMax  int
	Weeks    []weekBar
	WeekMax  int
	Versions []versionRow
	Facets   reviews.Facets
	Periods  []periodOption
	Active   []activeChip
	ClearURL string
	Here     string // this view's address, where forms come back to
	Every    time.Duration
	Email    string // the default reply address
	// Toast is the outcome of a sync or reply that brought the admin here.
	Toast, ToastBad string
	// SentID is the review whose reply just went out; it gets the moment.
	SentID int64
	// Composer is a refused reply, shown again in its card with the words kept.
	Composer *composerState
	Avg30Up  bool
	Avg30Dn  bool
	// ReplyShare is the percent of reviews with a public reply.
	ReplyShare float64
}

type composerState struct {
	ID          int64
	Text, Email string
	Error       string
}

type reviewTab struct {
	Key, URL string
	Count    int
	On       bool
}

type starBar struct {
	Stars, Count, Pct int
	URL               string
	On                bool
	Width             int // 0 to 20, a CSS class (no inline styles)
}

type weekBar struct {
	Start    time.Time
	Count    int
	Low      int
	Average  float64
	Height   int // 0 to 10
	LowShare int // 0 to 10: the part of the bar that is 1-2 stars
}

type versionRow struct {
	Code    int
	Count   int
	Average float64
	Width   int // 0 to 20
	URL     string
	Tone    string
}

type periodOption struct {
	Days int
	On   bool
}

type activeChip struct {
	Label template.HTML
	URL   string
}

type reviewCard struct {
	reviews.Item
	Android   string
	UserShort string
	UserURL   string
	CanReply  bool
	Resend    bool
	Fresh     bool // revealed by "Show more": rises in
	Index     int
	JustSent  bool
	// Pinned: the review just answered, kept in view although the filter
	// (say, "Need a reply") no longer matches it.
	Pinned      bool
	ComposeOpen bool
	Draft       string
	DraftEmail  string
	DraftError  string
}

// androidNames are Android versions by API level.
var androidNames = map[int]string{
	21: "5.0", 22: "5.1", 23: "6", 24: "7", 25: "7.1", 26: "8", 27: "8.1", 28: "9", 29: "10", 30: "11",
	31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16", 37: "17",
}

func androidName(sdk int) string {
	if n, ok := androidNames[sdk]; ok {
		return n
	}
	return "API " + strconv.Itoa(sdk)
}

// ---- handlers ---------------------------------------------------------------

func (s *Server) reviewsPage(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	extra := map[string]any{}
	ctx := r.Context()
	switch {
	case q.Get("sent") != "":
		if id, err := strconv.ParseInt(q.Get("sent"), 10, 64); err == nil {
			extra["SentID"] = id
			extra["Toast"] = T(ctx, "rv.sentToast")
		}
	case q.Get("synced") != "":
		extra["Toast"] = T(ctx, "rv.syncedToast", positive(q.Get("new"), 1_000_000))
	case q.Get("syncerr") != "":
		extra["ToastBad"] = syncErrorText(ctx, q.Get("syncerr"))
	case q.Get("syncing") != "":
		extra["Toast"] = T(ctx, "rv.syncingToast")
	}
	s.showReviews(w, r, http.StatusOK, parseReviewQuery(q), extra)
}

func syncErrorText(ctx context.Context, code string) string {
	switch code {
	case "busy":
		return T(ctx, "rv.err.busy")
	case "unauthorized":
		return T(ctx, "rv.err.unauthorized")
	case "rate_limited":
		return T(ctx, "rv.err.rateLimited")
	}
	return T(ctx, "rv.err.unavailable")
}

func (s *Server) showReviews(w http.ResponseWriter, r *http.Request, status int, rq reviewQuery, extra map[string]any) {
	ctx := r.Context()
	if s.Reviews == nil {
		s.render(w, r, status, "reviews", map[string]any{"Off": true})
		return
	}
	rv := s.Reviews
	st, err := rv.Stats(ctx)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	// A plain visit opens on what needs an answer, worst first, when
	// anything does; otherwise on everything, newest first.
	if !rq.StatusSet {
		rq.Status = reviews.StatusAll
		if st.Needs > 0 {
			rq.Status = reviews.StatusNeeds
		}
	}
	if !rq.SortSet {
		rq.Sort = reviews.SortNewest
		if rq.Status == reviews.StatusNeeds {
			rq.Sort = reviews.SortLowest
		}
	}
	now := rv.Now()
	items, total, err := rv.List(ctx, rq.filter(now))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	facets, err := rv.Facets(ctx)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	state, err := rv.State(ctx)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	v := reviewsView{Q: rq, Stats: st, State: state, Running: state.Running(now), Total: total, Facets: facets,
		Every: rv.Every(), Email: rv.ReplyEmail, Here: rq.url(true)}
	v.build(now)
	sentID, _ := extra["SentID"].(int64)
	comp, _ := extra["Composer"].(*composerState)
	prev := 0
	if n := positive(r.URL.Query().Get("prev"), maxShown); n > 0 && n < rq.Shown {
		prev = n
	}
	v.Prev = prev
	pinned := false
	if sentID != 0 && !slices.ContainsFunc(items, func(it reviews.Item) bool { return it.ID == sentID }) {
		one, _, err := rv.List(ctx, reviews.Filter{ID: sentID, Limit: 1})
		if err != nil {
			s.fail(w, r, err)
			return
		}
		if len(one) == 1 {
			items, pinned = append(one, items...), true
			prev = 0
			v.Prev = 0
		}
	}
	for i, it := range items {
		c := reviewCard{Item: it, Index: i - prev, Fresh: prev > 0 && i >= prev, JustSent: it.ID == sentID, Pinned: pinned && i == 0}
		if it.SDKVersion != nil {
			c.Android = androidName(*it.SDKVersion)
		}
		c.UserShort = shortID(it.UserAccountID)
		if it.UserReviews > 1 && rq.User == "" {
			uq := rq
			uq.User, uq.Status, uq.StatusSet = it.UserAccountID, reviews.StatusAll, true
			c.UserURL = uq.url(false)
		}
		c.CanReply = it.Waiting == nil || it.Waiting.CanResend(now)
		c.Resend = it.Waiting != nil && c.CanReply
		c.DraftEmail = rv.ReplyEmail
		if comp != nil && comp.ID == it.ID {
			c.ComposeOpen, c.Draft, c.DraftEmail, c.DraftError = true, comp.Text, comp.Email, comp.Error
		}
		v.Items = append(v.Items, c)
	}
	if comp != nil && !slices.ContainsFunc(items, func(it reviews.Item) bool { return it.ID == comp.ID }) {
		// The review is no longer in this view: the error still shows.
		v.ToastBad = comp.Error
	}
	listed := len(items)
	if pinned {
		listed--
	}
	v.Listed = listed
	if listed < total && rq.Shown < maxShown {
		next := rq
		next.Shown = min(rq.Shown+pageStep, maxShown)
		v.MoreN = min(pageStep, total-listed)
		mv := next.values()
		mv.Set("n", strconv.Itoa(next.Shown))
		mv.Set("prev", strconv.Itoa(listed))
		v.More = "/reviews?" + mv.Encode() + "#more-" + strconv.Itoa(listed)
	}
	if t, ok := extra["Toast"].(string); ok {
		v.Toast = t
	}
	if t, ok := extra["ToastBad"].(string); ok && v.ToastBad == "" {
		v.ToastBad = t
	}
	v.SentID = sentID
	v.Composer = comp
	s.render(w, r, status, "reviews", map[string]any{"V": v})
}

// build fills everything derived from the numbers and the query.
func (v *reviewsView) build(now time.Time) {
	rq, st := v.Q, v.Stats
	tab := func(key string, count int) reviewTab {
		q := rq
		q.Status, q.StatusSet = key, true
		return reviewTab{Key: key, URL: q.url(false), Count: count, On: rq.Status == key}
	}
	v.Tabs = []reviewTab{
		tab(reviews.StatusNeeds, st.Needs), tab(reviews.StatusAwaiting, st.Awaiting),
		tab(reviews.StatusAnswered, max(st.Total-st.Needs-st.Awaiting, 0)), tab(reviews.StatusAll, st.Total),
	}
	for i := range 5 {
		v.StarMax = max(v.StarMax, st.ByRate[i])
	}
	for stars := 5; stars >= 1; stars-- {
		n := st.ByRate[stars-1]
		b := starBar{Stars: stars, Count: n, On: slices.Contains(rq.Rates, stars)}
		if st.Total > 0 {
			b.Pct = int(math.Round(float64(n) * 100 / float64(st.Total)))
		}
		if v.StarMax > 0 {
			b.Width = int(math.Round(float64(n) * 20 / float64(v.StarMax)))
		}
		q := rq
		if b.On {
			q.Rates = slices.DeleteFunc(slices.Clone(rq.Rates), func(x int) bool { return x == stars })
		} else {
			q.Rates = append(slices.Clone(rq.Rates), stars)
			slices.Sort(q.Rates)
		}
		b.URL = q.url(false)
		v.Stars = append(v.Stars, b)
	}
	for _, w := range st.Weeks {
		v.WeekMax = max(v.WeekMax, w.Count)
	}
	for _, w := range st.Weeks {
		b := weekBar{Start: w.Start, Count: w.Count, Low: w.Low, Average: w.Average}
		if v.WeekMax > 0 && w.Count > 0 {
			b.Height = max(1, int(math.Round(float64(w.Count)*10/float64(v.WeekMax))))
			b.LowShare = int(math.Round(float64(w.Low) * 10 / float64(w.Count)))
		}
		v.Weeks = append(v.Weeks, b)
	}
	for _, ver := range st.Versions {
		q := rq
		q.Version = ver.Code
		row := versionRow{Code: ver.Code, Count: ver.Count, Average: ver.Average, URL: q.url(false),
			Width: int(math.Round(ver.Average * 4))}
		switch {
		case ver.Average >= 4:
			row.Tone = "good"
		case ver.Average < 3:
			row.Tone = "bad"
		default:
			row.Tone = "warn"
		}
		v.Versions = append(v.Versions, row)
	}
	for _, d := range reviewPeriods {
		v.Periods = append(v.Periods, periodOption{Days: d, On: rq.Days == d})
	}
	if st.Total > 0 {
		v.ReplyShare = float64(st.Answered) * 100 / float64(st.Total)
	}
	if st.Last30 > 0 && st.Prev30 > 0 {
		v.Avg30Up = st.Avg30-st.AvgPrev30 >= 0.05
		v.Avg30Dn = st.AvgPrev30-st.Avg30 >= 0.05
	}
	clear := rq
	clear.Rates, clear.Version, clear.SDK, clear.Days, clear.Search, clear.User = nil, 0, 0, 0, "", ""
	v.ClearURL = clear.url(false)
}

// shortID is the first block of a Bazaar user id, enough to tell people
// apart on one page.
func shortID(id string) string {
	if i := strings.IndexByte(id, '-'); i > 0 && i <= 12 {
		return id[:i]
	}
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// replyToReview sends a reply. The form posts back here from the page with
// the view it came from, which the result returns to.
func (s *Server) replyToReview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	a := adminFrom(ctx)
	if s.Reviews == nil {
		http.NotFound(w, r)
		return
	}
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, r)
		return
	}
	back := reviewsBack(r.PostFormValue("back"))
	rq := parseReviewQuery(back)
	text := r.PostFormValue("text")
	email := strings.TrimSpace(r.PostFormValue("email"))
	refuse := func(status int, msg string) {
		s.showReviews(w, r, status, rq, map[string]any{"Composer": &composerState{ID: id, Text: text, Email: email, Error: msg}})
	}
	if utf8.RuneCountInString(text) > reviews.MaxReply+200 || len(email) > 254 {
		refuse(http.StatusBadRequest, T(ctx, "rv.err.tooLong", reviews.MaxReply))
		return
	}
	if err := s.Limits.Hit(ctx, ruleReviewReply, a.ID); err != nil {
		refuse(http.StatusTooManyRequests, T(ctx, "rv.err.tooMany"))
		return
	}
	err = s.Reviews.Reply(ctx, a.ID, id, text, email)
	switch {
	case err == nil:
	case errors.Is(err, reviews.ErrEmpty):
		refuse(http.StatusBadRequest, T(ctx, "rv.err.empty"))
		return
	case errors.Is(err, reviews.ErrTooLong):
		refuse(http.StatusBadRequest, T(ctx, "rv.err.tooLong", reviews.MaxReply))
		return
	case errors.Is(err, reviews.ErrBadEmail):
		refuse(http.StatusBadRequest, T(ctx, "rv.err.email"))
		return
	case errors.Is(err, reviews.ErrAwaiting):
		refuse(http.StatusConflict, T(ctx, "rv.err.awaiting"))
		return
	case errors.Is(err, reviews.ErrNoReview), errors.Is(err, reviews.ErrNotFound):
		refuse(http.StatusNotFound, T(ctx, "rv.err.gone"))
		return
	case errors.Is(err, reviews.ErrUnauthorized):
		refuse(http.StatusBadGateway, T(ctx, "rv.err.unauthorized"))
		return
	case errors.Is(err, reviews.ErrRateLimited):
		refuse(http.StatusBadGateway, T(ctx, "rv.err.rateLimited"))
		return
	case errors.Is(err, reviews.ErrRefused):
		msg := T(ctx, "rv.err.refused")
		var e *reviews.Error
		if errors.As(err, &e) && e.Detail != "" {
			msg = T(ctx, "rv.err.refusedWhy", e.Detail)
		}
		refuse(http.StatusBadGateway, msg)
		return
	case errors.As(err, new(*reviews.Error)):
		refuse(http.StatusBadGateway, T(ctx, "rv.err.unavailable"))
		return
	default:
		s.fail(w, r, err)
		return
	}
	s.record(ctx, a.ID, "review.replied", "", ipFrom(ctx), map[string]any{
		"review": strconv.FormatInt(id, 10), "chars": utf8.RuneCountInString(strings.TrimSpace(text)),
	})
	v := rq.values()
	if rq.Shown > pageStep {
		v.Set("n", strconv.Itoa(rq.Shown))
	}
	v.Set("sent", strconv.FormatInt(id, 10))
	http.Redirect(w, r, "/reviews?"+v.Encode()+"#review-"+strconv.FormatInt(id, 10), http.StatusSeeOther)
}

// reviewsBack reads the view a form came from: a query string of this page
// only, never an address elsewhere.
func reviewsBack(raw string) url.Values {
	u, err := url.Parse(safeNext(raw))
	if err != nil || u.Path != "/reviews" {
		return url.Values{}
	}
	return u.Query()
}

// syncReviews runs a sync now and comes back to the view with how it went.
func (s *Server) syncReviews(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	a := adminFrom(ctx)
	if s.Reviews == nil {
		http.NotFound(w, r)
		return
	}
	v := parseReviewQuery(reviewsBack(r.PostFormValue("back"))).values()
	if err := s.Limits.Hit(ctx, ruleReviewSync, a.ID); err != nil {
		v.Set("syncerr", "rate_limited")
		http.Redirect(w, r, "/reviews?"+v.Encode(), http.StatusSeeOther)
		return
	}
	// The admin listener answers within 30 s, so the page waits up to 20 s
	// and a longer sync carries on by itself; the page then says it runs.
	type outcome struct {
		res reviews.SyncResult
		err error
	}
	done := make(chan outcome, 1)
	bg, ip := context.WithoutCancel(ctx), ipFrom(ctx)
	go func() {
		sctx, cancel := context.WithTimeout(bg, 10*time.Minute)
		defer cancel()
		res, err := s.Reviews.Sync(sctx)
		switch {
		case err == nil:
			s.record(bg, a.ID, "reviews.synced", "", ip, map[string]any{"new": res.New, "seen": res.Seen})
		case !errors.Is(err, reviews.ErrBusy):
			s.record(bg, a.ID, "reviews.synced", "", ip, map[string]any{"error": reviews.Code(err)})
		}
		done <- outcome{res, err}
	}()
	wait := time.NewTimer(s.syncWait)
	defer wait.Stop()
	select {
	case o := <-done:
		switch {
		case o.err == nil:
			v.Set("synced", "1")
			v.Set("new", strconv.Itoa(o.res.New))
		case errors.Is(o.err, reviews.ErrBusy):
			v.Set("syncerr", "busy")
		default:
			v.Set("syncerr", reviews.Code(o.err))
		}
	case <-wait.C:
		v.Set("syncing", "1")
	}
	http.Redirect(w, r, "/reviews?"+v.Encode(), http.StatusSeeOther)
}

// reviewsBadge is the number on the menu's Reviews item: reviews with no
// answer, for admins who can answer them. Any trouble just hides it.
func (s *Server) reviewsBadge(ctx context.Context) int {
	a := adminFrom(ctx)
	if s.Reviews == nil || a == nil || !a.Role.atLeast(RoleSupport) {
		return 0
	}
	n, err := s.Reviews.NeedsReply(ctx)
	if err != nil {
		return 0
	}
	return n
}
