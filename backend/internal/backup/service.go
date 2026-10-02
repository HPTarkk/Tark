// Package backup makes encrypted daily backups of the database, checks them,
// and restores them.
//
// The backup is taken by tarkd itself (binary COPY of every table inside one
// snapshot), so the server needs no cron job, no pg_dump and no extra
// container, and the monitor can see when the last good backup is too old.
// Files are encrypted with TARK_BACKUP_KEY, so a copy kept off the server
// (on a laptop, in cloud storage) is useless to whoever finds it.
package backup

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Names are fixed so a file can be fetched by name without letting a caller
// reach anything else on disk.
var nameRE = regexp.MustCompile(`^tark-[0-9]{8}-[0-9]{6}\.tbk$`)

// lockID keeps two instances from backing up at the same time.
const lockID = 7342119002

type Settings struct {
	Dir string
	Key []byte
	// HourUTC is when the daily backup runs.
	HourUTC int
	// KeepDays is how long files stay in Dir.
	KeepDays int
}

type Service struct {
	pool *pgxpool.Pool
	set  Settings
	log  *slog.Logger
	now  func() time.Time
}

func NewService(pool *pgxpool.Pool, set Settings, log *slog.Logger) *Service {
	return &Service{pool: pool, set: set, log: log, now: time.Now}
}

// Result is one finished backup.
type Result struct {
	File    string
	Bytes   int64
	Summary Summary
}

// Run makes the daily backup until ctx ends. It checks every ten minutes
// whether one is due, so a server that was down at the scheduled hour
// catches up when it is back.
func (s *Service) Run(ctx context.Context) {
	t := time.NewTicker(10 * time.Minute)
	defer t.Stop()
	for {
		due, err := s.due(ctx)
		if err != nil {
			s.log.ErrorContext(ctx, "backup schedule check failed", "err", err)
		} else if due {
			if res, err := s.Backup(ctx); err != nil {
				s.log.ErrorContext(ctx, "backup failed", "err", err)
			} else {
				s.log.InfoContext(ctx, "backup written", "file", res.File, "bytes", res.Bytes, "rows", res.Summary.TotalRows())
			}
			if err := s.Prune(); err != nil {
				s.log.ErrorContext(ctx, "backup prune failed", "err", err)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// due reports whether no good backup has been made since the last
// scheduled time. After a failure it waits an hour before trying again, so
// a broken disk does not mean a failed attempt every ten minutes.
func (s *Service) due(ctx context.Context) (bool, error) {
	now := s.now().UTC()
	scheduled := time.Date(now.Year(), now.Month(), now.Day(), s.set.HourUTC, 0, 0, 0, time.UTC)
	if now.Before(scheduled) {
		scheduled = scheduled.Add(-24 * time.Hour)
	}
	var lastOK, lastAny *time.Time
	if err := s.pool.QueryRow(ctx, `
		SELECT max(started_at) FILTER (WHERE ok), max(started_at) FROM backup_runs`).Scan(&lastOK, &lastAny); err != nil {
		return false, err
	}
	if lastOK != nil && !lastOK.Before(scheduled) {
		return false, nil
	}
	if lastAny != nil && now.Sub(*lastAny) < time.Hour {
		return false, nil
	}
	return true, nil
}

// Backup writes one backup now, reads it back to prove it decrypts, and
// records the attempt either way.
func (s *Service) Backup(ctx context.Context) (Result, error) {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return Result{}, err
	}
	defer conn.Release()
	var got bool
	if err := conn.QueryRow(ctx, "SELECT pg_try_advisory_lock($1)", lockID).Scan(&got); err != nil {
		return Result{}, err
	}
	if !got {
		return Result{}, errors.New("backup: another backup is running")
	}
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", lockID) //nolint:errcheck

	var runID int64
	if err := s.pool.QueryRow(ctx, `INSERT INTO backup_runs (started_at) VALUES ($1) RETURNING id`, s.now()).Scan(&runID); err != nil {
		return Result{}, err
	}
	res, err := s.write(ctx)
	if err != nil {
		msg := err.Error()
		if len(msg) > 500 {
			msg = msg[:500]
		}
		if _, dbErr := s.pool.Exec(context.Background(),
			`UPDATE backup_runs SET finished_at = now(), ok = false, error = $2 WHERE id = $1`, runID, msg); dbErr != nil {
			s.log.ErrorContext(ctx, "backup run record failed", "err", dbErr)
		}
		return Result{}, err
	}
	if _, err := s.pool.Exec(ctx, `
		UPDATE backup_runs SET finished_at = now(), ok = true, file = $2, bytes = $3, row_count = $4 WHERE id = $1`,
		runID, res.File, res.Bytes, res.Summary.TotalRows()); err != nil {
		return res, err
	}
	return res, nil
}

func (s *Service) write(ctx context.Context) (Result, error) {
	if s.set.Dir == "" || len(s.set.Key) == 0 {
		return Result{}, errors.New("backup: TARK_BACKUP_DIR and TARK_BACKUP_KEY are not set")
	}
	name := "tark-" + s.now().UTC().Format("20060102-150405") + ".tbk"
	final := filepath.Join(s.set.Dir, name)
	tmp, err := os.CreateTemp(s.set.Dir, ".partial-*")
	if err != nil {
		return Result{}, fmt.Errorf("backup: %w", err)
	}
	defer os.Remove(tmp.Name()) // no-op once renamed
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return Result{}, err
	}
	sum, err := Dump(ctx, s.pool, tmp, s.set.Key)
	if err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return Result{}, err
	}

	// Read it back from disk: a backup that cannot be decrypted is not one.
	f, err := os.Open(tmp.Name())
	if err != nil {
		return Result{}, err
	}
	check, err := Verify(f, s.set.Key)
	f.Close()
	if err != nil {
		return Result{}, fmt.Errorf("backup: the file just written does not verify: %w", err)
	}
	if check.TotalRows() != sum.TotalRows() {
		return Result{}, fmt.Errorf("backup: wrote %d rows but read back %d", sum.TotalRows(), check.TotalRows())
	}
	if err := os.Rename(tmp.Name(), final); err != nil {
		return Result{}, err
	}
	st, err := os.Stat(final)
	if err != nil {
		return Result{}, err
	}
	return Result{File: name, Bytes: st.Size(), Summary: sum}, nil
}

// File is a backup on disk.
type File struct {
	Name    string
	Bytes   int64
	ModTime time.Time
}

// List returns the backups in the directory, newest first.
func List(dir string) ([]File, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []File
	for _, e := range entries {
		if !e.Type().IsRegular() || !nameRE.MatchString(e.Name()) {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, File{Name: e.Name(), Bytes: info.Size(), ModTime: info.ModTime()})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name > out[j].Name })
	return out, nil
}

// Open opens a backup by name. Only names this package writes are accepted.
func Open(dir, name string) (*os.File, error) {
	if !nameRE.MatchString(name) {
		return nil, fmt.Errorf("backup: %q is not a backup file name", name)
	}
	return os.Open(filepath.Join(dir, name))
}

// Prune deletes backups older than KeepDays, but never the newest one.
func (s *Service) Prune() error {
	files, err := List(s.set.Dir)
	if err != nil {
		return err
	}
	cutoff := s.now().Add(-time.Duration(s.set.KeepDays) * 24 * time.Hour)
	var errs []error
	for i, f := range files {
		if i == 0 || !f.ModTime.Before(cutoff) {
			continue
		}
		if err := os.Remove(filepath.Join(s.set.Dir, f.Name)); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
