package password

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

var testParams = Params{MemoryKiB: 8 * 1024, Iterations: 1, Parallelism: 1}

func newHasher(t *testing.T) *Hasher {
	t.Helper()
	h, err := New([]byte(strings.Repeat("p", 32)), testParams, 2)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func TestHashAndVerify(t *testing.T) {
	h := newHasher(t)
	ctx := context.Background()
	enc, err := h.Hash(ctx, "correct horse battery")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(enc, "$argon2id$v=19$m=8192,t=1,p=1$") {
		t.Fatalf("unexpected encoding %q", enc)
	}
	if rehash, err := h.Verify(ctx, "correct horse battery", enc); err != nil || rehash {
		t.Fatalf("verify = %v, rehash %v", err, rehash)
	}
	if _, err := h.Verify(ctx, "wrong horse battery", enc); !errors.Is(err, ErrMismatch) {
		t.Fatalf("wrong password: %v", err)
	}
	// Same pepper, stronger params: old hash still verifies but wants a rehash.
	stronger, _ := New([]byte(strings.Repeat("p", 32)), Params{MemoryKiB: 9 * 1024, Iterations: 1, Parallelism: 1}, 1)
	if rehash, err := stronger.Verify(ctx, "correct horse battery", enc); err != nil || !rehash {
		t.Fatalf("expected rehash, got %v %v", rehash, err)
	}
	// A different pepper cannot verify: a DB dump alone is not enough.
	other, _ := New([]byte(strings.Repeat("q", 32)), testParams, 1)
	if _, err := other.Verify(ctx, "correct horse battery", enc); !errors.Is(err, ErrMismatch) {
		t.Fatalf("other pepper verified: %v", err)
	}
}

func TestNormalisationMatchesEquivalentInput(t *testing.T) {
	h := newHasher(t)
	ctx := context.Background()
	enc, _ := h.Hash(ctx, "ｐａｓｓｗｏｒｄ-long") // full-width letters
	if _, err := h.Verify(ctx, "password-long", enc); err != nil {
		t.Fatalf("NFKC-equivalent password did not verify: %v", err)
	}
}

func TestRejectsTamperedParams(t *testing.T) {
	h := newHasher(t)
	if _, err := h.Verify(context.Background(), "x", "$argon2id$v=19$m=99999999,t=1,p=1$c2FsdHNhbHQ$a2V5a2V5a2V5a2V5a2V5"); !errors.Is(err, ErrFormat) {
		t.Fatalf("expected ErrFormat, got %v", err)
	}
}

func TestProblem(t *testing.T) {
	cases := map[string]string{
		"short":                  "password_too_short",
		"password":               "password_too_common",
		"aaaaaaaaaa":             "password_too_common",
		"pedram@gmail.com":       "password_matches_email",
		"pedramxx":               "password_matches_email",
		strings.Repeat("a", 129): "password_too_long",
		"good passphrase 42":     "",
		"رمز عبور خوب من":        "",
		"with\x00null char":      "password_invalid",
	}
	for pw, want := range cases {
		email := "pedram@gmail.com"
		if pw == "pedramxx" {
			email = "pedramxx@example.com"
		}
		if got := Problem(pw, email); got != want {
			t.Errorf("Problem(%q) = %q, want %q", pw, got, want)
		}
	}
}

// A hash that cannot get a slot in time is refused rather than queued for as
// long as the request lives, and the dummy check reports it the same way, so
// a busy server answers known and unknown addresses alike.
func TestBusyHasherRefusesInsteadOfQueueing(t *testing.T) {
	h, err := New([]byte(strings.Repeat("p", 32)), testParams, 1)
	if err != nil {
		t.Fatal(err)
	}
	hash, err := h.Hash(context.Background(), "correct horse battery")
	if err != nil {
		t.Fatal(err)
	}
	h.maxWait = 20 * time.Millisecond
	h.slots <- struct{}{} // the only slot is taken

	if _, err := h.Verify(context.Background(), "correct horse battery", hash); !errors.Is(err, ErrBusy) {
		t.Fatalf("Verify with no free slot: got %v, want ErrBusy", err)
	}
	if err := h.VerifyDummy(context.Background(), "anything at all"); !errors.Is(err, ErrBusy) {
		t.Fatalf("VerifyDummy with no free slot: got %v, want ErrBusy", err)
	}
	if !errors.Is(ErrBusy, context.DeadlineExceeded) {
		t.Fatal("ErrBusy must read as a timeout, which the API answers with 503 and Retry-After")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := h.Hash(ctx, "correct horse battery"); !errors.Is(err, context.Canceled) {
		t.Fatalf("Hash with a cancelled request: got %v, want context.Canceled", err)
	}

	<-h.slots // free again: everything works as before
	if _, err := h.Verify(context.Background(), "correct horse battery", hash); err != nil {
		t.Fatal(err)
	}
	if err := h.VerifyDummy(context.Background(), "anything at all"); err != nil {
		t.Fatalf("VerifyDummy of a wrong password is not an error: %v", err)
	}
}
