// Command tarkd is the Tark backend.
//
//	tarkd serve     run the API (and, unless TARK_RUN_WORKERS=false, the workers)
//	tarkd worker    run only the background workers
//	tarkd migrate   apply database migrations and exit
//	tarkd keygen    print fresh secrets for a new environment
//	tarkd pubkeys   print the entitlement public keys for the app build
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/app"
	"github.com/HPTarkk/Tark/backend/internal/auth"
	"github.com/HPTarkk/Tark/backend/internal/billing"
	"github.com/HPTarkk/Tark/backend/internal/config"
	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	var err error
	switch cmd {
	case "keygen":
		err = keygen()
	case "serve", "worker", "migrate", "pubkeys":
		err = run(cmd, log)
	default:
		err = fmt.Errorf("unknown command %q", cmd)
	}
	if err != nil {
		log.Error("tarkd failed", "cmd", cmd, "err", err)
		os.Exit(1)
	}
}

func keygen() error {
	key := func() string {
		b := make([]byte, secure.KeySize)
		if _, err := rand.Read(b); err != nil {
			panic(err)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return err
	}
	kid := "k" + time.Now().UTC().Format("20060102")
	pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	fmt.Println("# Server secrets. Store them in the platform's secret store, never in git.")
	fmt.Println("TARK_TOKEN_KEY=" + key())
	fmt.Println("TARK_LOOKUP_KEY=" + key())
	fmt.Println("TARK_DATA_KEY=" + key())
	fmt.Println("TARK_PASSWORD_PEPPER=" + key())
	fmt.Println("TARK_ENTITLEMENT_KEYS=" + kid + ":" + base64.RawURLEncoding.EncodeToString(seed))
	fmt.Println("TARK_ENTITLEMENT_ACTIVE_KID=" + kid)
	fmt.Println()
	fmt.Println("# Public half for the app build (billing.json). Safe to publish.")
	fmt.Println(`"TARK_ENTITLEMENT_KEYS": "` + kid + ":" + base64.RawURLEncoding.EncodeToString(pub) + `"`)
	return nil
}

func run(cmd string, log *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	signer, err := billing.NewSigner(cfg.Keys.EntitlementSeeds, cfg.Keys.EntitlementKID)
	if err != nil {
		return err
	}
	if cmd == "pubkeys" {
		keys := signer.PublicKeys()
		kids := make([]string, 0, len(keys))
		for kid := range keys {
			kids = append(kids, kid)
		}
		sort.Strings(kids)
		parts := make([]string, 0, len(kids))
		for _, kid := range kids {
			parts = append(parts, kid+":"+keys[kid])
		}
		fmt.Println(strings.Join(parts, ","))
		return nil
	}

	pool, err := store.Open(ctx, cfg.DatabaseURL, cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := store.Migrate(ctx, pool); err != nil {
		return err
	}
	if cmd == "migrate" {
		log.Info("migrations applied")
		return nil
	}

	a, err := app.Build(cfg, pool, log, app.Options{})
	if err != nil {
		return err
	}

	if cmd == "worker" || cfg.RunWorkers {
		go a.Outbox.Run(ctx)
		go a.Billing.RunWorker(ctx)
		go sweeper(ctx, pool, log)
	}
	if cmd == "worker" {
		<-ctx.Done()
		return nil
	}

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           a.Handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	errCh := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", cfg.HTTPAddr, "env", cfg.Env)
		errCh <- srv.ListenAndServe()
	}()
	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return srv.Shutdown(shutdown)
}

// sweeper removes expired rows every ten minutes.
func sweeper(ctx context.Context, pool *pgxpool.Pool, log *slog.Logger) {
	t := time.NewTicker(10 * time.Minute)
	defer t.Stop()
	for {
		if err := auth.Sweep(ctx, pool); err != nil {
			log.Error("auth sweep failed", "err", err)
		}
		if err := ratelimit.Sweep(ctx, pool, 24*time.Hour); err != nil {
			log.Error("rate limit sweep failed", "err", err)
		}
		if err := mail.Sweep(ctx, pool, 7*24*time.Hour); err != nil {
			log.Error("mail sweep failed", "err", err)
		}
		// Security events are kept for a year, then dropped.
		if _, err := pool.Exec(ctx, `DELETE FROM audit_events WHERE at < now() - interval '365 days'`); err != nil {
			log.Error("audit sweep failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
