package logfile

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

func TestRotateCompressPrune(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 10, 1, 23, 59, 0, 0, time.UTC)
	// A day past the limit and a stray file that must be left alone.
	old := filepath.Join(dir, "tark-2026-08-01.log.gz")
	stray := filepath.Join(dir, "notes.txt")
	for _, p := range []string{old, stray} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	w, err := openAt(dir, 30, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	w.Write([]byte(`{"level":"INFO","msg":"first day"}` + "\n"))
	now = now.Add(2 * time.Minute)
	w.Write([]byte(`{"level":"ERROR","msg":"second day"}` + "\n"))
	w.Close()
	w.Tidy() // the goroutine may still be running; this one waits for it

	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("day past the limit was kept")
	}
	if _, err := os.Stat(stray); err != nil {
		t.Fatal("stray file removed")
	}
	if _, err := os.Stat(filepath.Join(dir, "tark-2026-10-01.log")); !os.IsNotExist(err) {
		t.Fatal("finished day not compressed")
	}
	days, err := Days(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := []string{days[0].Date, days[1].Date}; !slices.Equal(got, []string{"2026-10-02", "2026-10-01"}) || len(days) != 2 {
		t.Fatalf("days: %+v", days)
	}
	r, err := OpenDay(dir, "2026-10-01")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r)
	r.Close()
	if string(b) != `{"level":"INFO","msg":"first day"}`+"\n" {
		t.Fatalf("compressed day reads %q", b)
	}
	if info, _ := os.Stat(filepath.Join(dir, "tark-2026-10-02.log")); info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode())
	}
	if _, err := OpenDay(dir, "../etc/passwd"); err == nil {
		t.Fatal("opened a path outside the kept days")
	}
}

func TestSearch(t *testing.T) {
	dir := t.TempDir()
	write := func(day, s string) {
		if err := os.WriteFile(filepath.Join(dir, "tark-"+day+".log"), []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("2026-10-01", `{"level":"ERROR","msg":"a"}`+"\n"+`{"level":"INFO","msg":"b"}`+"\n")
	write("2026-10-02", `{"level":"WARN","msg":"c"}`+"\n"+`{"level":"INFO","msg":"Backup written"}`+"\n")
	now := time.Date(2026, 10, 2, 8, 0, 0, 0, time.UTC)
	ctx := context.Background()

	got, cut, err := Search(ctx, dir, Query{Days: 2, Limit: 10}, now)
	if err != nil || cut || len(got) != 4 || got[0] != `{"level":"INFO","msg":"Backup written"}` || got[3] != `{"level":"ERROR","msg":"a"}` {
		t.Fatalf("all: %q %v %v", got, cut, err)
	}
	got, _, _ = Search(ctx, dir, Query{Days: 1, Limit: 10}, now)
	if len(got) != 2 {
		t.Fatalf("today only: %q", got)
	}
	got, _, _ = Search(ctx, dir, Query{Days: 2, MinLevel: "WARN", Limit: 10}, now)
	if !slices.Equal(got, []string{`{"level":"WARN","msg":"c"}`, `{"level":"ERROR","msg":"a"}`}) {
		t.Fatalf("warn: %q", got)
	}
	got, _, _ = Search(ctx, dir, Query{Days: 2, MinLevel: "ERROR", Limit: 10}, now)
	if len(got) != 1 {
		t.Fatalf("error: %q", got)
	}
	got, _, _ = Search(ctx, dir, Query{Days: 2, Text: "backup", Limit: 10}, now)
	if len(got) != 1 {
		t.Fatalf("text: %q", got)
	}
	got, cut, _ = Search(ctx, dir, Query{Days: 2, Limit: 3}, now)
	if !cut || len(got) != 3 || got[2] != `{"level":"INFO","msg":"b"}` {
		t.Fatalf("limit: %q %v", got, cut)
	}
}
