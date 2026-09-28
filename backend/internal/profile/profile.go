// Package profile serves the signed-in person's profile.
//
// Editable today: name and avatar id. Email is read-only here (it changes
// only through the verified email-change flow in auth). New fields are
// added as nullable columns and optional JSON properties, so older apps
// keep working unchanged.
package profile

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/auth"
	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
)

type Profile struct {
	ID            string
	Name          string
	AvatarID      *string
	Email         string
	SignInMethods []string
	Version       int64
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// ETag is the profile version as an HTTP entity tag.
func (p Profile) ETag() string { return `"` + strconv.FormatInt(p.Version, 10) + `"` }

type Service struct {
	pool   *pgxpool.Pool
	limits ratelimit.Limiter
}

func NewService(pool *pgxpool.Pool, limits ratelimit.Limiter) *Service {
	return &Service{pool: pool, limits: limits}
}

var limitProfileWrite = ratelimit.Rule{Name: "profile_write", Max: 30, Window: 10 * time.Minute}

func (s *Service) Get(ctx context.Context, userID string) (Profile, error) {
	var p Profile
	err := s.pool.QueryRow(ctx, `
		SELECT u.id, u.name, u.avatar_id, coalesce(e.email, ''), u.profile_version, u.created_at, u.updated_at,
			coalesce(array(SELECT provider FROM auth_identities WHERE user_id = u.id ORDER BY provider), '{}')
		FROM users u
		LEFT JOIN user_emails e ON e.user_id = u.id AND e.is_primary AND e.removed_at IS NULL
		WHERE u.id = $1 AND u.status = 'active'`, userID).
		Scan(&p.ID, &p.Name, &p.AvatarID, &p.Email, &p.Version, &p.CreatedAt, &p.UpdatedAt, &p.SignInMethods)
	if errors.Is(err, pgx.ErrNoRows) {
		return Profile{}, apperr.Unauthorized("account not found")
	}
	return p, err
}

type Update struct {
	Name     string
	AvatarID *string
	// IfMatch is the ETag the app last saw, or "" to overwrite regardless.
	IfMatch string
}

// Put replaces the editable fields. With If-Match, a stale write (another
// device changed the profile meanwhile) is refused with 412 instead of
// silently undoing that change.
func (s *Service) Put(ctx context.Context, userID string, u Update) (Profile, error) {
	name, err := auth.NormalizeName(u.Name)
	if err != nil {
		return Profile{}, err
	}
	avatar, err := auth.NormalizeAvatar(u.AvatarID)
	if err != nil {
		return Profile{}, err
	}
	if err := s.limits.Hit(ctx, limitProfileWrite, userID); err != nil {
		return Profile{}, err
	}
	var expected *int64
	if u.IfMatch != "" && u.IfMatch != "*" {
		v, err := strconv.ParseInt(trimQuotes(u.IfMatch), 10, 64)
		if err != nil {
			return Profile{}, apperr.BadRequest("invalid_request", "If-Match must be an ETag from GET /profile")
		}
		expected = &v
	}
	// Writing the same values again is a no-op that keeps the version, so a
	// retried PUT does not look like a conflicting edit.
	tag, err := s.pool.Exec(ctx, `
		UPDATE users SET name = $2, avatar_id = $3,
			profile_version = CASE WHEN name = $2 AND avatar_id IS NOT DISTINCT FROM $3 THEN profile_version ELSE profile_version + 1 END,
			updated_at = CASE WHEN name = $2 AND avatar_id IS NOT DISTINCT FROM $3 THEN updated_at ELSE now() END
		WHERE id = $1 AND status = 'active' AND ($4::bigint IS NULL OR profile_version = $4
			OR (name = $2 AND avatar_id IS NOT DISTINCT FROM $3))`,
		userID, name, avatar, expected)
	if err != nil {
		return Profile{}, err
	}
	if tag.RowsAffected() == 0 {
		if expected != nil {
			return Profile{}, apperr.New(http.StatusPreconditionFailed, "profile_changed", "the profile changed on another device; reload it")
		}
		return Profile{}, apperr.Unauthorized("account not found")
	}
	return s.Get(ctx, userID)
}

func trimQuotes(s string) string {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1]
	}
	if len(s) >= 4 && s[:2] == "W/" {
		return trimQuotes(s[2:])
	}
	return s
}
