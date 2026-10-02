// Package logfile keeps the server's own log on disk for a set number of
// days (30 by default), one file per UTC day, compressed once the day is
// over. Docker's log rotation keeps only the last 50 MB, which a busy day or
// a noisy client can fill in hours; these files let an incident be read
// back weeks later.
//
// The log never holds IP addresses, tokens or request bodies (see the
// access log in httpapi), so keeping it longer does not keep personal data
// longer.
package logfile

import (
	"bufio"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"
)

var nameRE = regexp.MustCompile(`^tark-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(\.gz)?$`)

// Writer appends to today's file. Writing never fails from the caller's
// point of view: a full disk must not stop the server, and the monitor's
// disk alert reports it.
type Writer struct {
	dir  string
	keep int
	now  func() time.Time

	mu   sync.Mutex
	day  string
	f    *os.File
	tidy sync.Mutex
}

// Open creates dir if needed and returns a Writer keeping keepDays days.
func Open(dir string, keepDays int) (*Writer, error) {
	return openAt(dir, keepDays, time.Now)
}

func openAt(dir string, keepDays int, now func() time.Time) (*Writer, error) {
	if keepDays < 1 {
		return nil, errors.New("logfile: keep at least one day")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Writer{dir: dir, keep: keepDays, now: now}, nil
}

func (w *Writer) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	now := w.now()
	day := now.UTC().Format(time.DateOnly)
	if day != w.day || w.f == nil {
		if w.f != nil {
			_ = w.f.Close()
		}
		f, err := os.OpenFile(filepath.Join(w.dir, "tark-"+day+".log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			w.f = nil
			return len(p), nil
		}
		w.f, w.day = f, day
		go w.tidyAt(now)
	}
	_, _ = w.f.Write(p)
	return len(p), nil
}

// Close closes today's file.
func (w *Writer) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return nil
	}
	err := w.f.Close()
	w.f = nil
	return err
}

// Tidy compresses finished days and deletes days past the limit. It runs
// whenever a new day's file is opened.
func (w *Writer) Tidy() { w.tidyAt(w.now()) }

func (w *Writer) tidyAt(now time.Time) {
	w.tidy.Lock()
	defer w.tidy.Unlock()
	today := now.UTC().Format(time.DateOnly)
	oldest := now.UTC().AddDate(0, 0, -(w.keep - 1)).Format(time.DateOnly)
	entries, err := os.ReadDir(w.dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		m := nameRE.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		path := filepath.Join(w.dir, e.Name())
		switch {
		case m[1] < oldest:
			_ = os.Remove(path)
		case m[2] == "" && m[1] < today:
			_ = compress(path)
		}
	}
}

func compress(path string) error {
	in, err := os.Open(path)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := path + ".gz.tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	zw := gzip.NewWriter(out)
	_, err = io.Copy(zw, in)
	if cerr := zw.Close(); err == nil {
		err = cerr
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path+".gz")
	}
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Remove(path)
}

// Day is one day's file.
type Day struct {
	Date  string // YYYY-MM-DD, UTC
	Bytes int64
	name  string
}

// Days lists the kept days, newest first.
func Days(dir string) ([]Day, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	byDate := map[string]Day{}
	for _, e := range entries {
		m := nameRE.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		// While a day is being compressed both files exist; the plain one
		// is complete until it is removed.
		if d, ok := byDate[m[1]]; ok && !strings.HasSuffix(d.name, ".gz") {
			continue
		}
		byDate[m[1]] = Day{Date: m[1], Bytes: info.Size(), name: e.Name()}
	}
	out := make([]Day, 0, len(byDate))
	for _, d := range byDate {
		out = append(out, d)
	}
	slices.SortFunc(out, func(a, b Day) int { return strings.Compare(b.Date, a.Date) })
	return out, nil
}

// OpenDay returns one day's log, uncompressed.
func OpenDay(dir, date string) (io.ReadCloser, error) {
	days, err := Days(dir)
	if err != nil {
		return nil, err
	}
	for _, d := range days {
		if d.Date != date {
			continue
		}
		f, err := os.Open(filepath.Join(dir, d.name))
		if err != nil {
			return nil, err
		}
		if !strings.HasSuffix(d.name, ".gz") {
			return f, nil
		}
		zr, err := gzip.NewReader(f)
		if err != nil {
			f.Close()
			return nil, err
		}
		return readCloser{zr, f}, nil
	}
	return nil, fmt.Errorf("no log kept for %q", date)
}

type readCloser struct {
	io.Reader
	f *os.File
}

func (r readCloser) Close() error { return r.f.Close() }

// Query picks lines out of the kept logs.
type Query struct {
	// Days to search back from today (1 = today only).
	Days int
	// MinLevel is "", "WARN" or "ERROR".
	MinLevel string
	// Text must appear in the line (case-insensitive). Empty matches all.
	Text string
	// Limit is the most lines returned.
	Limit int
}

// Search returns the newest matching lines, newest first, and whether the
// limit cut the result short.
func Search(ctx context.Context, dir string, q Query, now time.Time) ([]string, bool, error) {
	days, err := Days(dir)
	if err != nil {
		return nil, false, err
	}
	from := now.UTC().AddDate(0, 0, -(q.Days - 1)).Format(time.DateOnly)
	text := strings.ToLower(q.Text)
	var out []string
	for _, d := range days {
		if d.Date < from {
			break
		}
		if err := ctx.Err(); err != nil {
			return nil, false, err
		}
		lines, err := matches(dir, d.Date, q.MinLevel, text, q.Limit-len(out)+1)
		if err != nil {
			return nil, false, err
		}
		for i := len(lines) - 1; i >= 0; i-- {
			if len(out) == q.Limit {
				return out, true, nil
			}
			out = append(out, lines[i])
		}
	}
	return out, false, nil
}

// matches returns the last keep matching lines of one day, oldest first.
func matches(dir, date, level, text string, keep int) ([]string, error) {
	r, err := OpenDay(dir, date)
	if err != nil {
		return nil, err
	}
	defer r.Close()
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	var out []string
	for sc.Scan() {
		line := sc.Text()
		if !levelOK(line, level) || (text != "" && !strings.Contains(strings.ToLower(line), text)) {
			continue
		}
		if len(out) == keep {
			out = append(out[:0], out[1:]...)
		}
		out = append(out, line)
	}
	return out, sc.Err()
}

func levelOK(line, min string) bool {
	switch min {
	case "ERROR":
		return strings.Contains(line, `"level":"ERROR"`)
	case "WARN":
		return strings.Contains(line, `"level":"ERROR"`) || strings.Contains(line, `"level":"WARN"`)
	}
	return true
}
