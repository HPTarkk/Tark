// Package audit records security-relevant events: sign-ins, failures,
// resets, token theft, refunds. It never records secrets, codes, tokens or
// raw IP addresses, only what an investigation needs.
package audit

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

type Logger struct {
	db     store.Querier
	hasher *secure.Hasher
	log    *slog.Logger
}

func New(db store.Querier, hasher *secure.Hasher, log *slog.Logger) *Logger {
	return &Logger{db: db, hasher: hasher, log: log}
}

// Event kinds. Kept as constants so dashboards and alerts can rely on them.
const (
	RegisterStarted        = "register.started"
	RegisterExistingEmail  = "register.existing_email"
	RegisterCompleted      = "register.completed"
	LoginSucceeded         = "login.succeeded"
	LoginFailed            = "login.failed"
	LoginThrottled         = "login.throttled"
	GoogleSignedIn         = "google.signed_in"
	GoogleSignedUp         = "google.signed_up"
	GoogleLinkRequired     = "google.link_required"
	GoogleLinked           = "google.linked"
	GoogleLinkFailed       = "google.link_failed"
	GoogleTokenRejected    = "google.token_rejected"
	CodeFailed             = "flow.code_failed"
	FlowLocked             = "flow.locked"
	PasswordResetRequested = "password.reset_requested"
	PasswordReset          = "password.reset"
	PasswordChanged        = "password.changed"
	PasswordChangeFailed   = "password.change_failed"
	EmailChangeRequested   = "email.change_requested"
	EmailChanged           = "email.changed"
	RefreshReuse           = "session.refresh_reuse"
	LoggedOut              = "session.logged_out"
	LoggedOutAll           = "session.logged_out_all"
	AccountDeleted         = "account.deleted"
	AccountDeleteFailed    = "account.delete_failed"
	PurchaseVerified       = "billing.purchase_verified"
	PurchaseOwnedElsewhere = "billing.purchase_owned_elsewhere"
	PurchaseRefunded       = "billing.purchase_refunded"
	PurchaseInvalid        = "billing.purchase_invalid"
)

// Record writes an event. userID may be empty. ip is hashed. details must
// hold only non-sensitive values. Failures are logged, never returned: an
// audit write failing must not fail the request that triggered it.
func (l *Logger) Record(ctx context.Context, kind, userID, ip string, details map[string]any) {
	if details == nil {
		details = map[string]any{}
	}
	var ipHash *string
	if ip != "" {
		h := l.hasher.SumString("audit-ip", ip)
		ipHash = &h
	}
	var uid *string
	if userID != "" {
		uid = &userID
	}
	body, err := json.Marshal(details)
	if err != nil {
		body = []byte("{}")
	}
	if _, err := l.db.Exec(ctx,
		`INSERT INTO audit_events (kind, user_id, ip_hash, details) VALUES ($1, $2, $3, $4)`,
		kind, uid, ipHash, body); err != nil {
		l.log.ErrorContext(ctx, "audit write failed", "kind", kind, "err", err)
	}
	attrs := []any{"event", kind}
	if userID != "" {
		attrs = append(attrs, "user", userID)
	}
	for k, v := range details {
		attrs = append(attrs, k, v)
	}
	l.log.InfoContext(ctx, "audit", attrs...)
}
