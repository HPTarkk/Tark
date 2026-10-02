// Package store opens the PostgreSQL pool and applies migrations.
package store

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

// Open connects and checks the connection. Statement timeouts are set per
// connection so a slow query can never hold a request forever.
func Open(ctx context.Context, url string, maxConns int32) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("store: parse database url: %w", err)
	}
	if maxConns > 0 {
		cfg.MaxConns = maxConns
	}
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.HealthCheckPeriod = 30 * time.Second
	if cfg.ConnConfig.RuntimeParams == nil {
		cfg.ConnConfig.RuntimeParams = map[string]string{}
	}
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "15000"
	cfg.ConnConfig.RuntimeParams["idle_in_transaction_session_timeout"] = "30000"
	cfg.ConnConfig.RuntimeParams["timezone"] = "UTC"

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("store: connect: %w", err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: ping: %w", err)
	}
	return pool, nil
}

// migrationLock is an arbitrary constant for pg_advisory_lock, so two
// instances starting at once do not both migrate.
const migrationLock = 7342119001

// Migrate applies every embedded migration not yet recorded, each in its
// own transaction.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	return migrate(ctx, pool, nil)
}

// MigrateOnly applies the named migrations and no later ones. A restore uses
// it to rebuild the schema a backup was taken with before loading its rows.
// Naming a version this binary does not have is an error.
func MigrateOnly(ctx context.Context, pool *pgxpool.Pool, versions []string) error {
	known := map[string]bool{}
	for _, v := range Versions() {
		known[v] = true
	}
	only := map[string]bool{}
	for _, v := range versions {
		if !known[v] {
			return fmt.Errorf("store: migration %s is not part of this build (the backup is newer than this binary)", v)
		}
		only[v] = true
	}
	return migrate(ctx, pool, only)
}

// Versions lists the embedded migrations in the order they apply.
func Versions() []string {
	names, _ := fs.Glob(migrationFiles, "migrations/*.sql")
	sort.Strings(names)
	out := make([]string, len(names))
	for i, name := range names {
		out[i] = strings.TrimSuffix(strings.TrimPrefix(name, "migrations/"), ".sql")
	}
	return out
}

func migrate(ctx context.Context, pool *pgxpool.Pool, only map[string]bool) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", migrationLock); err != nil {
		return fmt.Errorf("store: migration lock: %w", err)
	}
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", migrationLock) //nolint:errcheck

	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version text PRIMARY KEY,
		applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return fmt.Errorf("store: migrations table: %w", err)
	}

	for _, version := range Versions() {
		if only != nil && !only[version] {
			continue
		}
		name := "migrations/" + version + ".sql"
		var exists bool
		if err := conn.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)", version).Scan(&exists); err != nil {
			return err
		}
		if exists {
			continue
		}
		sql, err := migrationFiles.ReadFile(name)
		if err != nil {
			return err
		}
		err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, string(sql)); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", version)
			return err
		})
		if err != nil {
			return fmt.Errorf("store: migration %s: %w", version, err)
		}
	}
	return nil
}

// IsUniqueViolation reports a unique-constraint failure, optionally on a
// specific constraint or index.
func IsUniqueViolation(err error, constraint string) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23505" {
		return false
	}
	return constraint == "" || pgErr.ConstraintName == constraint
}

// Querier is what pool, connection and transaction have in common.
type Querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}
