package reviews

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Service keeps bazaar_reviews in step with Bazaar and sends replies.
type Service struct {
	pool *pgxpool.Pool
	api  API
	log  *slog.Logger
	// Every is the time between background syncs.
	every time.Duration
	// ReplyEmail is the default address shown with a reply ("" lets Bazaar
	// use the developer account's own).
	ReplyEmail string
	now        func() time.Time
}

// Settings configure a Service.
type Settings struct {
	Every      time.Duration
	ReplyEmail string
}

func NewService(pool *pgxpool.Pool, api API, set Settings, log *slog.Logger) *Service {
	if set.Every <= 0 {
		set.Every = 15 * time.Minute
	}
	return &Service{pool: pool, api: api, log: log, every: set.Every, ReplyEmail: set.ReplyEmail, now: time.Now}
}

// Every is how often the background sync runs.
func (s *Service) Every() time.Duration { return s.every }

// Limits.
const (
	// MaxReply is the longest reply accepted, in characters. Bazaar does not
	// document one; this is generous for a store reply.
	MaxReply = 2000
	// ResendAfter is how long a reply may wait for Bazaar's approval before
	// the panel lets another be sent in its place: Bazaar never says when it
	// declines one.
	ResendAfter = 7 * 24 * time.Hour
	// maxPages stops a sync that never reaches a last page.
	maxPages = 4000
	// syncLock and replyLock are advisory lock keys (replyLock with the
	// review id), so two servers never sync at once or reply twice.
	syncLock  = 7342119021
	replyLock = 734211
)

var (
	// ErrBusy: another sync is running.
	ErrBusy = errors.New("reviews: a sync is already running")
	// ErrNoReview: the review is not in the copy (or was removed on Bazaar).
	ErrNoReview = errors.New("reviews: no such review")
	// ErrAwaiting: a reply to this review is already waiting for approval.
	ErrAwaiting = errors.New("reviews: a reply is already waiting for Bazaar's approval")
	// ErrEmpty, ErrTooLong and ErrBadEmail refuse a reply before it is sent.
	ErrEmpty    = errors.New("reviews: empty reply")
	ErrTooLong  = errors.New("reviews: reply too long")
	ErrBadEmail = errors.New("reviews: not an email address")
)

// Run syncs shortly after start, then every s.Every(), until ctx ends.
func (s *Service) Run(ctx context.Context) {
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		if _, err := s.Sync(ctx); err != nil && !errors.Is(err, ErrBusy) && ctx.Err() == nil {
			s.log.WarnContext(ctx, "bazaar reviews sync failed", "err", Code(err))
		}
		timer.Reset(s.every)
	}
}

// SyncResult is what one complete sync found.
type SyncResult struct {
	Seen, New, Published, Removed int
}

// Sync walks every page of reviews, stores them, notices replies that Bazaar
// approved, and marks reviews Bazaar no longer lists. Every page is walked
// because edits, like counts and approvals change old reviews too and the API
// has no "changed since". A failed run keeps everything stored so far and
// removes nothing.
func (s *Service) Sync(ctx context.Context) (SyncResult, error) {
	var res SyncResult
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return res, err
	}
	defer conn.Release()
	var got bool
	if err := conn.QueryRow(ctx, "SELECT pg_try_advisory_lock($1)", int64(syncLock)).Scan(&got); err != nil {
		return res, err
	}
	if !got {
		return res, ErrBusy
	}
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", int64(syncLock)) //nolint:errcheck

	if _, err := s.pool.Exec(ctx, `
		INSERT INTO bazaar_review_sync (id, last_started_at) VALUES (1, $1)
		ON CONFLICT (id) DO UPDATE SET last_started_at = $1`, s.now()); err != nil {
		return res, err
	}
	seen := map[int64]bool{}
	cursor := ""
	for pages := 0; ; pages++ {
		if pages >= maxPages {
			err = &Error{Kind: ErrInvalidResponse, Detail: "too many pages"}
			break
		}
		var page Page
		page, err = s.api.List(ctx, cursor)
		if err != nil {
			break
		}
		var n, p int
		if n, p, err = s.store(ctx, page.Reviews); err != nil {
			break
		}
		res.New += n
		res.Published += p
		for _, r := range page.Reviews {
			seen[r.ID] = true
		}
		if page.Next == "" {
			break
		}
		cursor = page.Next
	}
	if err == nil {
		res.Seen = len(seen)
		res.Removed, err = s.markRemoved(ctx, seen)
	}
	s.finish(ctx, res, err)
	return res, err
}

// store upserts one page and returns how many reviews were new and how many
// waiting replies Bazaar has now published.
func (s *Service) store(ctx context.Context, page []Review) (added, published int, err error) {
	if len(page) == 0 {
		return 0, 0, nil
	}
	now := s.now()
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		for _, r := range page {
			at, known := now, false
			if r.PublishDate != nil {
				at, known = *r.PublishDate, true
			}
			var replyText, replyEmail *string
			var replyAt *time.Time
			var replyLikes, replyDislikes *int
			if r.Reply != nil {
				replyText, replyEmail, replyAt = &r.Reply.Text, &r.Reply.Email, r.Reply.PublishDate
				replyLikes, replyDislikes = r.Reply.Likes, r.Reply.Dislikes
			}
			var inserted bool
			if err := tx.QueryRow(ctx, `
				INSERT INTO bazaar_reviews (id, user_account_id, rate, body, search_text, published_at, date_known,
					is_edited, likes, dislikes, app_version_code, sdk_version,
					reply_body, reply_email, reply_published_at, reply_likes, reply_dislikes, first_seen_at, synced_at)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $18)
				ON CONFLICT (id) DO UPDATE SET
					user_account_id = EXCLUDED.user_account_id, rate = EXCLUDED.rate, body = EXCLUDED.body,
					search_text = EXCLUDED.search_text,
					-- Without a date from Bazaar the first sighting stays the date.
					published_at = CASE WHEN EXCLUDED.date_known THEN EXCLUDED.published_at ELSE bazaar_reviews.published_at END,
					date_known = EXCLUDED.date_known OR bazaar_reviews.date_known,
					is_edited = EXCLUDED.is_edited, likes = EXCLUDED.likes, dislikes = EXCLUDED.dislikes,
					app_version_code = EXCLUDED.app_version_code, sdk_version = EXCLUDED.sdk_version,
					reply_body = EXCLUDED.reply_body, reply_email = EXCLUDED.reply_email,
					reply_published_at = EXCLUDED.reply_published_at, reply_likes = EXCLUDED.reply_likes,
					reply_dislikes = EXCLUDED.reply_dislikes, synced_at = EXCLUDED.synced_at, removed_at = NULL
				RETURNING (xmax = 0)`,
				r.ID, r.UserAccountID, r.Rate, r.Text, Fold(r.Text), at, known,
				r.IsEdited, r.Likes, r.Dislikes, r.AppVersionCode, r.SDKVersion,
				replyText, replyEmail, replyAt, replyLikes, replyDislikes, now).Scan(&inserted); err != nil {
				return err
			}
			if inserted {
				added++
			}
			if r.Reply == nil {
				continue
			}
			// A waiting reply is published once Bazaar shows a reply that is
			// ours (same words) or not older than ours.
			var id int64
			var body string
			var sent time.Time
			err := tx.QueryRow(ctx, `SELECT id, body, sent_at FROM bazaar_review_replies WHERE review_id = $1 AND state = 'sent'`, r.ID).
				Scan(&id, &body, &sent)
			if errors.Is(err, pgx.ErrNoRows) {
				continue
			}
			if err != nil {
				return err
			}
			same := Fold(body) == Fold(r.Reply.Text)
			newer := r.Reply.PublishDate != nil && !r.Reply.PublishDate.Before(sent.Add(-10*time.Minute))
			if !same && !newer {
				continue
			}
			pubAt := now
			if r.Reply.PublishDate != nil {
				pubAt = *r.Reply.PublishDate
			}
			if _, err := tx.Exec(ctx, `UPDATE bazaar_review_replies SET state = 'published', published_at = $2 WHERE id = $1`, id, pubAt); err != nil {
				return err
			}
			published++
		}
		return nil
	})
	return added, published, err
}

// markRemoved flags reviews a complete sync did not see. An empty answer
// while reviews are stored is not trusted to mean "all removed".
func (s *Service) markRemoved(ctx context.Context, seen map[int64]bool) (int, error) {
	ids := make([]int64, 0, len(seen))
	for id := range seen {
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return 0, nil
	}
	tag, err := s.pool.Exec(ctx, `UPDATE bazaar_reviews SET removed_at = $2 WHERE removed_at IS NULL AND NOT (id = ANY($1))`, ids, s.now())
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

func (s *Service) finish(ctx context.Context, res SyncResult, err error) {
	// The outcome is written even when ctx is ending, so the page never shows
	// a sync that seems to run forever.
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	now := s.now()
	var werr error
	if err == nil {
		_, werr = s.pool.Exec(wctx, `
			UPDATE bazaar_review_sync SET last_finished_at = $1, last_success_at = $1, last_error = NULL, failures = 0,
				last_seen = $2, last_new = $3 WHERE id = 1`, now, res.Seen, res.New)
	} else {
		_, werr = s.pool.Exec(wctx, `
			UPDATE bazaar_review_sync SET last_finished_at = $1, last_error = $2, failures = failures + 1, last_new = $3
			WHERE id = 1`, now, Code(err), res.New)
	}
	if werr != nil {
		s.log.ErrorContext(ctx, "bazaar reviews sync state write failed", "err", werr)
	}
}

// Reply sends text to Bazaar as the reply to a review and records it as
// waiting for approval. Nothing is recorded when Bazaar refuses it. Two
// replies to one review never go out at once, from any server.
func (s *Service) Reply(ctx context.Context, adminID string, reviewID int64, text, email string) error {
	text = strings.TrimSpace(strings.ReplaceAll(text, "\r\n", "\n"))
	email = strings.TrimSpace(email)
	switch n := utf8.RuneCountInString(text); {
	case n == 0:
		return ErrEmpty
	case n > MaxReply:
		return ErrTooLong
	}
	if email != "" && !ValidEmail(email) {
		return ErrBadEmail
	}
	var aid *string
	if adminID != "" {
		aid = &adminID
	}
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1, ($2 % 2147483647)::int)`, replyLock, reviewID); err != nil {
			return err
		}
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM bazaar_reviews WHERE id = $1 AND removed_at IS NULL)`, reviewID).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return ErrNoReview
		}
		var waitingSince time.Time
		err := tx.QueryRow(ctx, `SELECT sent_at FROM bazaar_review_replies WHERE review_id = $1 AND state = 'sent'`, reviewID).Scan(&waitingSince)
		switch {
		case err == nil && s.now().Sub(waitingSince) < ResendAfter:
			return ErrAwaiting
		case err == nil:
			// Waited too long: Bazaar most likely declined it. The new one
			// takes its place.
			if _, err := tx.Exec(ctx, `DELETE FROM bazaar_review_replies WHERE review_id = $1 AND state = 'sent'`, reviewID); err != nil {
				return err
			}
		case !errors.Is(err, pgx.ErrNoRows):
			return err
		}
		callCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		if err := s.api.Reply(callCtx, reviewID, text, email); err != nil {
			return err
		}
		var stored *string
		if email != "" {
			stored = &email
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO bazaar_review_replies (review_id, admin_id, body, email, state, sent_at) VALUES ($1, $2, $3, $4, 'sent', $5)`,
			reviewID, aid, text, stored, s.now())
		if err != nil {
			// Bazaar has the reply but the record failed: say so in the log,
			// with ids only, so nobody sends it twice unknowingly.
			s.log.ErrorContext(ctx, "bazaar reply sent but not recorded", "review", reviewID, "err", err)
		}
		return err
	})
}

// ValidEmail is a plain check: one @, something on each side, no spaces or
// brackets, at most 254 characters.
func ValidEmail(e string) bool {
	if len(e) > 254 || strings.Count(e, "@") != 1 || strings.ContainsAny(e, " <>\"(),;:\\[]\r\n\t") {
		return false
	}
	at := strings.IndexByte(e, '@')
	return at > 0 && at < len(e)-3 && strings.Contains(e[at+1:], ".") && !strings.HasSuffix(e, ".")
}

// folder maps the letters that look alike in Persian and Arabic to one form,
// and the Persian and Arabic digits to Latin ones.
var folder = strings.NewReplacer(
	"ي", "ی", "ى", "ی", "ئ", "ی", "ك", "ک", "ة", "ه", "ۀ", "ه", "أ", "ا", "إ", "ا", "آ", "ا", "ؤ", "و",
	"۰", "0", "۱", "1", "۲", "2", "۳", "3", "۴", "4", "۵", "5", "۶", "6", "۷", "7", "۸", "8", "۹", "9",
	"٠", "0", "١", "1", "٢", "2", "٣", "3", "٤", "4", "٥", "5", "٦", "6", "٧", "7", "٨", "8", "٩", "9",
)

// Fold is the form text is searched in: lower case, Arabic and Persian
// letter variants made one, zero-width joiners, kashida and diacritics
// dropped, runs of spaces made one. A query is folded the same way.
func Fold(s string) string {
	s = folder.Replace(strings.ToLower(s))
	var b strings.Builder
	space := false
	for _, r := range s {
		switch {
		case r == '‌' || r == '‍' || r == 'ـ' || (r >= 'ً' && r <= 'ٟ') || r == 'ٰ':
			continue
		case unicode.IsSpace(r):
			if !space && b.Len() > 0 {
				b.WriteByte(' ')
			}
			space = true
			continue
		}
		space = false
		b.WriteRune(r)
	}
	return strings.TrimSpace(b.String())
}
