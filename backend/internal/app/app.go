// Package app wires the services together. cmd/tarkd and the end-to-end
// tests both build the backend through here, so tests run the real wiring.
package app

import (
	"log/slog"
	"net/http"
	"runtime"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/admin"
	"github.com/HPTarkk/Tark/backend/internal/audit"
	"github.com/HPTarkk/Tark/backend/internal/auth"
	"github.com/HPTarkk/Tark/backend/internal/backup"
	"github.com/HPTarkk/Tark/backend/internal/billing"
	"github.com/HPTarkk/Tark/backend/internal/config"
	"github.com/HPTarkk/Tark/backend/internal/google"
	"github.com/HPTarkk/Tark/backend/internal/httpapi"
	"github.com/HPTarkk/Tark/backend/internal/idempotency"
	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/monitor"
	"github.com/HPTarkk/Tark/backend/internal/password"
	"github.com/HPTarkk/Tark/backend/internal/profile"
	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
	"github.com/HPTarkk/Tark/backend/internal/secure"
)

// Options replace parts that talk to the outside world. Zero values use
// the configured real implementations.
type Options struct {
	Sender         mail.Sender
	Bazaar         billing.Bazaar
	PasswordParams *password.Params
	// AuxPool carries audit and rate-limit writes (see config.DBAuxConns). Nil
	// means they share the main pool, which is only safe with a pool larger
	// than the number of concurrent requests.
	AuxPool *pgxpool.Pool
}

type App struct {
	Handler http.Handler
	Outbox  *mail.Outbox
	Billing *billing.Service
	Signer  *billing.Signer
	Monitor *monitor.Monitor
	// Backup is nil when TARK_BACKUP_DIR is not set.
	Backup *backup.Service
	// Admin is the admin panel and its weekly report. Its handler is served
	// only on TARK_ADMIN_ADDR.
	Admin *admin.Server
	// AdminDeps builds admins from the command line (tarkd admin-create).
	AdminDeps admin.Deps
}

func Build(cfg *config.Config, pool *pgxpool.Pool, log *slog.Logger, opts Options) (*App, error) {
	signer, err := billing.NewSigner(cfg.Keys.EntitlementSeeds, cfg.Keys.EntitlementKID)
	if err != nil {
		return nil, err
	}
	lookup, err := secure.NewHasher(cfg.Keys.LookupKey)
	if err != nil {
		return nil, err
	}
	sealer, err := secure.NewSealer(cfg.Keys.DataKey)
	if err != nil {
		return nil, err
	}
	slots := cfg.PasswordHashSlots
	if slots <= 0 {
		slots = runtime.NumCPU()
	}
	params := password.DefaultParams
	if opts.PasswordParams != nil {
		params = *opts.PasswordParams
	}
	pw, err := password.New(cfg.Keys.Pepper, params, slots)
	if err != nil {
		return nil, err
	}

	sender := opts.Sender
	if sender == nil {
		if cfg.Mail.Driver == "log" {
			sender = &mail.LogSender{Log: log}
		} else {
			var senders []mail.NamedSender
			for _, srv := range cfg.Mail.Servers {
				senders = append(senders, mail.NamedSender{Name: srv.Name, Sender: &mail.SMTPSender{
					Host: srv.Host, Port: srv.Port, Username: srv.Username, Password: srv.Password,
					From: srv.From, FromName: cfg.Mail.FromName, Implicit: srv.Security == "tls",
				}})
			}
			sender = &mail.FailoverSender{Senders: senders, Log: log}
		}
	}
	outbox := mail.NewOutbox(pool, sealer, sender, log)

	bz := opts.Bazaar
	if bz == nil {
		if cfg.Bazaar.Fake {
			bz = &billing.FakeBazaar{}
		} else {
			bz = &billing.BazaarHTTP{
				BaseURL: cfg.Bazaar.BaseURL, PackageName: cfg.Bazaar.PackageName,
				ClientID: cfg.Bazaar.ClientID, ClientSecret: cfg.Bazaar.ClientSecret, RefreshToken: cfg.Bazaar.RefreshToken,
			}
		}
	}

	aux := opts.AuxPool
	if aux == nil {
		aux = pool
	}
	limits := ratelimit.NewPG(aux, lookup)
	aud := audit.New(aux, lookup, log)
	gv := google.NewVerifier(cfg.Google.ClientIDs, cfg.Google.JWKSURL, nil)

	authSvc := auth.NewService(pool, lookup, pw, limits, aud, outbox, gv, cfg.Keys.TokenKey, auth.Settings{
		AccessTTL: cfg.AccessTokenTTL, RefreshTTL: cfg.RefreshTokenTTL, SessionMaxLifetime: cfg.SessionMaxLifetime,
		LinkBaseURL: cfg.LinkBaseURL, GoogleRequireNonce: cfg.Google.RequireNonce,
	}, log)
	profileSvc := profile.NewService(pool, limits)
	billingSvc := billing.NewService(pool, bz, signer, sealer, lookup, limits, aud, billing.Policy{
		GraceH: cfg.Policy.GraceHours, RefreshD: cfg.Policy.RefreshDays, SusOfflineH: cfg.Policy.SuspiciousOfflineHrs,
	}, cfg.Bazaar.SKUs, log)

	serverErrors := &monitor.Counter{}
	var bk *backup.Service
	if cfg.Backup.Dir != "" {
		bk = backup.NewService(pool, backup.Settings{
			Dir: cfg.Backup.Dir, Key: cfg.Backup.Key, HourUTC: cfg.Backup.HourUTC, KeepDays: cfg.Backup.KeepDays,
		}, log)
	}
	mon := monitor.New(pool, outbox, serverErrors, monitor.Settings{
		Recipients: cfg.Monitor.AlertEmails, Server: cfg.Monitor.ServerName,
		DiskPath: cfg.Backup.Dir, Backups: bk != nil,
	}, log)

	handler := httpapi.NewHandler(httpapi.Deps{
		Pool: pool, Auth: authSvc, Profile: profileSvc, Billing: billingSvc,
		Idempotency: idempotency.New(pool, sealer, lookup, 24*time.Hour),
		Log:         log, ClientIPHeader: cfg.ClientIPHeader, TrustedProxies: cfg.TrustedProxies, Docs: cfg.DocsEnabled,
		OnServerError: serverErrors.Inc,
	})
	adminDeps := admin.Deps{
		Pool: pool, Passwords: pw, Lookup: lookup, Sealer: sealer, Limits: limits, Mailer: outbox,
		Accounts: authSvc, Billing: billingSvc,
		AlertEmails: cfg.Monitor.AlertEmails, ServerName: cfg.Monitor.ServerName,
		ClientIP: httpapi.ClientIPResolver(cfg.ClientIPHeader, cfg.TrustedProxies),
		Log:      log, Secure: !cfg.Development(),
	}
	adm, err := admin.New(adminDeps)
	if err != nil {
		return nil, err
	}
	return &App{Handler: handler, Outbox: outbox, Billing: billingSvc, Signer: signer, Monitor: mon, Backup: bk,
		Admin: adm, AdminDeps: adminDeps}, nil
}
