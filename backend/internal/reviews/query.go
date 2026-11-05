package reviews

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Status narrows the list by where a review stands with its answer.
const (
	StatusNeeds    = "needs"    // no public reply and none waiting
	StatusAwaiting = "awaiting" // a reply sent from the panel waits for approval
	StatusAnswered = "answered" // a public reply and none waiting
	StatusAll      = "all"
)

// Sorts.
const (
	SortNewest = "new"
	SortOldest = "old"
	SortLowest = "low" // lowest rating first, then newest
)

// Filter is what the Reviews page asks for. Zero values mean "any".
type Filter struct {
	// ID picks one review, whatever else the filter says.
	ID      int64
	Status  string
	Rates   []int // 1 to 5
	Version int   // app version code
	SDK     int   // Android SDK level
	Since   time.Time
	Search  string
	User    string // a Bazaar user id: everything one person wrote
	Sort    string
	Limit   int
	Offset  int
}

// Item is one review on the page.
type Item struct {
	ID             int64
	UserAccountID  string
	Rate           int
	Body           string
	PublishedAt    time.Time
	DateKnown      bool
	IsEdited       *bool
	Likes          *int
	Dislikes       *int
	AppVersionCode *int
	SDKVersion     *int
	ReplyBody      *string
	ReplyEmail     *string
	ReplyAt        *time.Time
	ReplyLikes     *int
	ReplyDislikes  *int
	// Waiting is a reply sent from the panel that Bazaar has not shown yet.
	Waiting *Waiting
	// UserReviews is how many reviews this Bazaar user has in the copy.
	UserReviews int
}

// Waiting is a reply waiting for Bazaar's approval.
type Waiting struct {
	Body   string
	Email  *string
	SentAt time.Time
	By     string // the admin's name, "" when they were removed
}

// CanResend says whether the waiting reply has waited long enough that
// another may be sent in its place.
func (w *Waiting) CanResend(now time.Time) bool { return now.Sub(w.SentAt) >= ResendAfter }

// where turns a filter into SQL conditions on bazaar_reviews r.
func (f Filter) where() (string, []any) {
	conds := []string{"r.removed_at IS NULL"}
	var args []any
	arg := func(v any) string {
		args = append(args, v)
		return fmt.Sprintf("$%d", len(args))
	}
	if f.ID != 0 {
		return "r.removed_at IS NULL AND r.id = " + arg(f.ID), args
	}
	const waiting = `EXISTS (SELECT 1 FROM bazaar_review_replies w WHERE w.review_id = r.id AND w.state = 'sent')`
	switch f.Status {
	case StatusNeeds:
		conds = append(conds, "r.reply_body IS NULL AND NOT "+waiting)
	case StatusAwaiting:
		conds = append(conds, waiting)
	case StatusAnswered:
		conds = append(conds, "r.reply_body IS NOT NULL AND NOT "+waiting)
	}
	if len(f.Rates) > 0 && len(f.Rates) < 5 {
		conds = append(conds, "r.rate = ANY("+arg(f.Rates)+")")
	}
	if f.Version > 0 {
		conds = append(conds, "r.app_version_code = "+arg(f.Version))
	}
	if f.SDK > 0 {
		conds = append(conds, "r.sdk_version = "+arg(f.SDK))
	}
	if !f.Since.IsZero() {
		conds = append(conds, "r.published_at >= "+arg(f.Since))
	}
	if f.User != "" {
		conds = append(conds, "r.user_account_id = "+arg(f.User))
	}
	for _, term := range strings.Fields(Fold(f.Search)) {
		conds = append(conds, `r.search_text LIKE `+arg("%"+likeEscape(term)+"%")+` ESCAPE '\'`)
	}
	return strings.Join(conds, " AND "), args
}

func likeEscape(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

// List returns one page of reviews and how many match in all.
func (s *Service) List(ctx context.Context, f Filter) ([]Item, int, error) {
	where, args := f.where()
	var total int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM bazaar_reviews r WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	order := "r.published_at DESC, r.id DESC"
	switch f.Sort {
	case SortOldest:
		order = "r.published_at, r.id"
	case SortLowest:
		order = "r.rate, r.published_at DESC, r.id DESC"
	}
	limit := f.Limit
	if limit <= 0 || limit > 500 {
		limit = 25
	}
	args = append(args, limit, max(f.Offset, 0))
	rows, err := s.pool.Query(ctx, fmt.Sprintf(`
		SELECT r.id, r.user_account_id, r.rate, r.body, r.published_at, r.date_known, r.is_edited, r.likes, r.dislikes,
			r.app_version_code, r.sdk_version, r.reply_body, r.reply_email, r.reply_published_at, r.reply_likes, r.reply_dislikes,
			w.body, w.email, w.sent_at, a.name,
			(SELECT count(*) FROM bazaar_reviews u WHERE u.user_account_id = r.user_account_id AND u.removed_at IS NULL)
		FROM bazaar_reviews r
		LEFT JOIN bazaar_review_replies w ON w.review_id = r.id AND w.state = 'sent'
		LEFT JOIN admin_users a ON a.id = w.admin_id
		WHERE %s ORDER BY %s LIMIT $%d OFFSET $%d`, where, order, len(args)-1, len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Item, error) {
		var it Item
		var wBody, wBy *string
		var wEmail *string
		var wSent *time.Time
		err := row.Scan(&it.ID, &it.UserAccountID, &it.Rate, &it.Body, &it.PublishedAt, &it.DateKnown, &it.IsEdited, &it.Likes, &it.Dislikes,
			&it.AppVersionCode, &it.SDKVersion, &it.ReplyBody, &it.ReplyEmail, &it.ReplyAt, &it.ReplyLikes, &it.ReplyDislikes,
			&wBody, &wEmail, &wSent, &wBy, &it.UserReviews)
		if wBody != nil && wSent != nil {
			it.Waiting = &Waiting{Body: *wBody, Email: wEmail, SentAt: *wSent}
			if wBy != nil {
				it.Waiting.By = *wBy
			}
		}
		return it, err
	})
	return items, total, err
}

// Stats are the numbers at the top of the Reviews page, all from the copy.
type Stats struct {
	Total     int
	Average   float64 // 0 with no reviews
	Last30    int
	Prev30    int
	Avg30     float64 // 0 when Last30 is 0
	AvgPrev30 float64
	Needs     int
	Awaiting  int
	Answered  int
	// ByRate[i] is how many reviews gave i+1 stars.
	ByRate [5]int
	// MedianReply is the median time from a review to its public reply,
	// over the last 90 days; 0 when nothing to measure.
	MedianReply time.Duration
	Weeks       []Week
	Versions    []Version
}

// Week is one bar of the trend: reviews written that week.
type Week struct {
	Start   time.Time
	Count   int
	Average float64
	// Low is how many gave 1 or 2 stars.
	Low int
}

// Version is how one app build is rated.
type Version struct {
	Code    int
	Count   int
	Average float64
}

// Weeks is how many weeks the trend shows.
const Weeks = 12

func (s *Service) Stats(ctx context.Context) (Stats, error) {
	var st Stats
	now := s.now()
	err := s.pool.QueryRow(ctx, `
		SELECT count(*),
			coalesce(avg(rate), 0)::float8,
			count(*) FILTER (WHERE published_at >= $1),
			count(*) FILTER (WHERE published_at >= $2 AND published_at < $1),
			coalesce(avg(rate) FILTER (WHERE published_at >= $1), 0)::float8,
			coalesce(avg(rate) FILTER (WHERE published_at >= $2 AND published_at < $1), 0)::float8,
			count(*) FILTER (WHERE reply_body IS NULL AND NOT EXISTS (SELECT 1 FROM bazaar_review_replies w WHERE w.review_id = r.id AND w.state = 'sent')),
			count(*) FILTER (WHERE EXISTS (SELECT 1 FROM bazaar_review_replies w WHERE w.review_id = r.id AND w.state = 'sent')),
			count(*) FILTER (WHERE reply_body IS NOT NULL),
			count(*) FILTER (WHERE rate = 1), count(*) FILTER (WHERE rate = 2), count(*) FILTER (WHERE rate = 3),
			count(*) FILTER (WHERE rate = 4), count(*) FILTER (WHERE rate = 5)
		FROM bazaar_reviews r WHERE removed_at IS NULL`,
		now.Add(-30*24*time.Hour), now.Add(-60*24*time.Hour)).Scan(
		&st.Total, &st.Average, &st.Last30, &st.Prev30, &st.Avg30, &st.AvgPrev30, &st.Needs, &st.Awaiting, &st.Answered,
		&st.ByRate[0], &st.ByRate[1], &st.ByRate[2], &st.ByRate[3], &st.ByRate[4])
	if err != nil {
		return st, err
	}
	var medianSec float64
	if err := s.pool.QueryRow(ctx, `
		SELECT coalesce(extract(epoch FROM percentile_cont(0.5) WITHIN GROUP (ORDER BY reply_published_at - published_at)), 0)::float8
		FROM bazaar_reviews WHERE removed_at IS NULL AND date_known AND reply_published_at > published_at AND published_at >= $1`,
		now.Add(-90*24*time.Hour)).Scan(&medianSec); err != nil {
		return st, err
	}
	st.MedianReply = time.Duration(medianSec * float64(time.Second))

	// Weeks in Tehran time, starting on Saturday as the Persian week does.
	rows, err := s.pool.Query(ctx, `
		WITH weeks AS (
			SELECT generate_series(0, $2 - 1) AS i
		), bounds AS (
			SELECT i, (date_trunc('day', ($1::timestamptz AT TIME ZONE 'Asia/Tehran'))
				- ((extract(dow FROM ($1::timestamptz AT TIME ZONE 'Asia/Tehran'))::int + 1) % 7) * interval '1 day'
				- ($2 - 1 - i) * interval '7 days') AT TIME ZONE 'Asia/Tehran' AS start
			FROM weeks
		)
		SELECT b.start, count(r.id), coalesce(avg(r.rate), 0)::float8, count(r.id) FILTER (WHERE r.rate <= 2)
		FROM bounds b
		LEFT JOIN bazaar_reviews r ON r.removed_at IS NULL AND r.published_at >= b.start AND r.published_at < b.start + interval '7 days'
		GROUP BY b.i, b.start ORDER BY b.i`, now, Weeks)
	if err != nil {
		return st, err
	}
	st.Weeks, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Week, error) {
		var w Week
		return w, row.Scan(&w.Start, &w.Count, &w.Average, &w.Low)
	})
	if err != nil {
		return st, err
	}
	rows, err = s.pool.Query(ctx, `
		SELECT app_version_code, count(*), avg(rate)::float8 FROM bazaar_reviews
		WHERE removed_at IS NULL AND app_version_code IS NOT NULL
		GROUP BY app_version_code ORDER BY app_version_code DESC LIMIT 6`)
	if err != nil {
		return st, err
	}
	st.Versions, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Version, error) {
		var v Version
		return v, row.Scan(&v.Code, &v.Count, &v.Average)
	})
	return st, err
}

// Facets are the values the version and Android filters offer: only those
// that some review has.
type Facets struct {
	Versions []int
	SDKs     []int
}

func (s *Service) Facets(ctx context.Context) (Facets, error) {
	var f Facets
	rows, err := s.pool.Query(ctx, `SELECT DISTINCT app_version_code FROM bazaar_reviews WHERE removed_at IS NULL AND app_version_code IS NOT NULL ORDER BY 1 DESC LIMIT 60`)
	if err != nil {
		return f, err
	}
	if f.Versions, err = pgx.CollectRows(rows, pgx.RowTo[int]); err != nil {
		return f, err
	}
	rows, err = s.pool.Query(ctx, `SELECT DISTINCT sdk_version FROM bazaar_reviews WHERE removed_at IS NULL AND sdk_version IS NOT NULL ORDER BY 1 DESC LIMIT 60`)
	if err != nil {
		return f, err
	}
	f.SDKs, err = pgx.CollectRows(rows, pgx.RowTo[int])
	return f, err
}

// NeedsReply counts reviews with no reply at all, for the menu badge.
func (s *Service) NeedsReply(ctx context.Context) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `
		SELECT count(*) FROM bazaar_reviews r WHERE removed_at IS NULL AND reply_body IS NULL
		AND NOT EXISTS (SELECT 1 FROM bazaar_review_replies w WHERE w.review_id = r.id AND w.state = 'sent')`).Scan(&n)
	return n, err
}

// State is how syncing has gone.
type State struct {
	LastStarted, LastFinished, LastSuccess *time.Time
	LastError                              string
	Failures, LastSeen, LastNew            int
}

// Running says whether a sync started and has not finished (or was cut off
// in the last 10 minutes).
func (st State) Running(now time.Time) bool {
	return st.LastStarted != nil && (st.LastFinished == nil || st.LastFinished.Before(*st.LastStarted)) &&
		now.Sub(*st.LastStarted) < 10*time.Minute
}

func (s *Service) State(ctx context.Context) (State, error) {
	var st State
	var code *string
	err := s.pool.QueryRow(ctx, `
		SELECT last_started_at, last_finished_at, last_success_at, last_error, failures, last_seen, last_new
		FROM bazaar_review_sync WHERE id = 1`).Scan(&st.LastStarted, &st.LastFinished, &st.LastSuccess, &code, &st.Failures, &st.LastSeen, &st.LastNew)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, nil
	}
	if code != nil {
		st.LastError = *code
	}
	return st, err
}

// Now is the service's clock, so pages agree with it.
func (s *Service) Now() time.Time { return s.now() }
