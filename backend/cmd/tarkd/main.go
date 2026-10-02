// Command tarkd is the Tark backend.
//
//	tarkd serve     run the API (and, unless TARK_RUN_WORKERS=false, the workers)
//	tarkd worker    run only the background workers
//	tarkd migrate   apply database migrations and exit
//	tarkd keygen    print fresh secrets for a new environment
//	tarkd pubkeys   print the entitlement public keys for the app build
//	tarkd healthcheck  exit 0 if the local server answers /healthz (for container HEALTHCHECK)
//	tarkd backup       make a backup now (needs TARK_BACKUP_DIR and TARK_BACKUP_KEY)
//	tarkd backup-list  list the backups in TARK_BACKUP_DIR
//	tarkd backup-verify <name>  decrypt and check a backup without touching the database
//	tarkd backup-cat <name>     write a backup file to stdout (to download it)
//	tarkd restore <name|->      load a backup (a name in TARK_BACKUP_DIR, or - for stdin) into an EMPTY database
//	tarkd alert-test   email a test alert to TARK_ALERT_EMAILS
//	tarkd admin-create <email> <owner|support|viewer> <name>  add an admin panel account and print its one-time password
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/admin"
	"github.com/HPTarkk/Tark/backend/internal/app"
	"github.com/HPTarkk/Tark/backend/internal/audit"
	"github.com/HPTarkk/Tark/backend/internal/auth"
	"github.com/HPTarkk/Tark/backend/internal/backup"
	"github.com/HPTarkk/Tark/backend/internal/billing"
	"github.com/HPTarkk/Tark/backend/internal/config"
	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/ratelimit"
	"github.com/HPTarkk/Tark/backend/internal/secure"
	"github.com/HPTarkk/Tark/backend/internal/store"
)

func main() {
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	logOut := os.Stdout
	if cmd == "backup-cat" {
		logOut = os.Stderr // stdout carries the file
	}
	log := slog.New(slog.NewJSONHandler(logOut, &slog.HandlerOptions{Level: slog.LevelInfo}))
	var err error
	switch cmd {
	case "keygen":
		err = keygen()
	case "healthcheck":
		err = healthcheck()
	case "serve", "worker", "migrate", "pubkeys", "backup", "backup-list", "backup-verify", "backup-cat", "restore", "alert-test", "admin-create":
		err = run(cmd, log)
	default:
		err = fmt.Errorf("unknown command %q", cmd)
	}
	if err != nil {
		log.Error("tarkd failed", "cmd", cmd, "err", err)
		os.Exit(1)
	}
}

// healthcheck asks the server running in this container whether it is alive.
// The image has no shell or curl, so the binary does it itself.
func healthcheck() error {
	addr := os.Getenv("TARK_HTTP_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	client := &http.Client{Timeout: 3 * time.Second}
	res, err := client.Get("http://" + net.JoinHostPort(host, port) + "/healthz")
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode >= 300 {
		return fmt.Errorf("healthz answered %d", res.StatusCode)
	}
	return nil
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
	fmt.Println("# Encrypts database backups. Keep a copy OFF the server: without it no backup can be restored.")
	fmt.Println("TARK_BACKUP_KEY=" + key())
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

	switch cmd {
	case "backup-list", "backup-verify", "backup-cat":
		return backupFiles(cmd, cfg)
	}

	pool, err := store.Open(ctx, cfg.DatabaseURL, cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer pool.Close()
	if cmd == "restore" {
		return restore(ctx, pool, cfg, log)
	}
	auxPool, err := store.Open(ctx, cfg.DatabaseURL, cfg.DBAuxConns)
	if err != nil {
		return err
	}
	defer auxPool.Close()
	if err := store.Migrate(ctx, pool); err != nil {
		return err
	}
	if cmd == "migrate" {
		log.Info("migrations applied")
		return nil
	}

	a, err := app.Build(cfg, pool, log, app.Options{AuxPool: auxPool})
	if err != nil {
		return err
	}

	switch cmd {
	case "backup":
		if a.Backup == nil {
			return errors.New("TARK_BACKUP_DIR is not set")
		}
		res, err := a.Backup.Backup(ctx)
		if err != nil {
			return err
		}
		fmt.Printf("%s  %d bytes  %d rows\n", res.File, res.Bytes, res.Summary.TotalRows())
		return nil
	case "admin-create":
		if len(os.Args) < 5 {
			return errors.New("usage: tarkd admin-create <email> <owner|support|viewer> <name>")
		}
		temp, err := admin.CreateAdmin(ctx, a.AdminDeps, os.Args[2], strings.Join(os.Args[4:], " "), admin.Role(os.Args[3]), "")
		if err != nil {
			return err
		}
		fmt.Println("Admin created. One-time password (shown only now):", temp)
		fmt.Println("At first sign-in they choose their own password and set up an authenticator app.")
		return nil
	case "alert-test":
		if err := a.Monitor.SendTest(ctx); err != nil {
			return err
		}
		fmt.Println("Test alert queued for", strings.Join(cfg.Monitor.AlertEmails, ", "), "- the running server sends it within seconds.")
		return nil
	}

	if cmd == "worker" || cfg.RunWorkers {
		go a.Outbox.Run(ctx)
		go a.Billing.RunWorker(ctx)
		go a.Monitor.Run(ctx)
		if a.Backup != nil {
			go a.Backup.Run(ctx)
		}
		go a.Admin.RunReports(ctx)
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
	errCh := make(chan error, 2)
	go func() {
		log.Info("listening", "addr", cfg.HTTPAddr, "env", cfg.Env)
		errCh <- srv.ListenAndServe()
	}()
	// The admin panel has its own listener, so the public API's address can
	// never reach it, whatever a proxy in front does with Host headers.
	var adminSrv *http.Server
	if cfg.AdminAddr != "" {
		adminSrv = &http.Server{
			Addr:              cfg.AdminAddr,
			Handler:           a.Admin.Handler(),
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       15 * time.Second,
			WriteTimeout:      30 * time.Second,
			IdleTimeout:       90 * time.Second,
			MaxHeaderBytes:    16 << 10,
		}
		go func() {
			log.Info("admin panel listening", "addr", cfg.AdminAddr)
			errCh <- adminSrv.ListenAndServe()
		}()
	}
	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if adminSrv != nil {
		if err := adminSrv.Shutdown(shutdown); err != nil {
			log.Error("admin panel shutdown", "err", err)
		}
	}
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
		if err := audit.Sweep(ctx, pool); err != nil {
			log.Error("audit sweep failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// backupFiles handles the commands that only read backup files.
func backupFiles(cmd string, cfg *config.Config) error {
	dir := cfg.Backup.Dir
	if dir == "" {
		return errors.New("TARK_BACKUP_DIR is not set")
	}
	if cmd == "backup-list" {
		files, err := backup.List(dir)
		if err != nil {
			return err
		}
		for _, f := range files {
			fmt.Printf("%s\t%d\t%s\n", f.Name, f.Bytes, f.ModTime.UTC().Format(time.RFC3339))
		}
		return nil
	}
	if len(os.Args) < 3 {
		return fmt.Errorf("usage: tarkd %s <backup file name>", cmd)
	}
	f, err := backup.Open(dir, os.Args[2])
	if err != nil {
		return err
	}
	defer f.Close()
	if cmd == "backup-cat" {
		_, err := io.Copy(os.Stdout, f)
		return err
	}
	sum, err := backup.Verify(f, cfg.Backup.Key)
	if err != nil {
		return err
	}
	fmt.Printf("OK: taken %s, schema %s, %d rows\n", sum.CreatedAt.Format(time.RFC3339),
		sum.Migrations[len(sum.Migrations)-1], sum.TotalRows())
	return nil
}

// restore loads a backup into an empty database. It runs before migrations,
// so the schema is rebuilt exactly as the backup had it.
func restore(ctx context.Context, pool *pgxpool.Pool, cfg *config.Config, log *slog.Logger) error {
	if len(os.Args) < 3 {
		return errors.New("usage: tarkd restore <backup file name in TARK_BACKUP_DIR | - for stdin>")
	}
	if len(cfg.Backup.Key) == 0 {
		return errors.New("TARK_BACKUP_DIR and TARK_BACKUP_KEY must be set (the key the backup was made with)")
	}
	var in io.Reader = os.Stdin
	if name := os.Args[2]; name != "-" {
		f, err := backup.Open(cfg.Backup.Dir, name)
		if err != nil {
			return err
		}
		defer f.Close()
		in = f
	}
	sum, err := backup.Restore(ctx, pool, in, cfg.Backup.Key)
	if err != nil {
		return err
	}
	log.Info("backup restored", "taken", sum.CreatedAt, "rows", sum.TotalRows())
	return nil
}
