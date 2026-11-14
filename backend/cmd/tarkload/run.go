package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// A run is open-loop: jobs start at a fixed rate whether or not earlier ones
// have finished, and a job's first request is timed from the moment it was
// due. A closed loop (N workers, each waiting for its answer) slows down
// with the server and so hides exactly the queueing a real overload causes.

type result struct {
	op     string
	status int // 0: no answer at all
	took   time.Duration
}

type runner struct {
	base    string
	client  *http.Client
	users   int
	shareIP int
	results chan result

	mu     sync.Mutex
	tokens map[int]string // refresh tokens that have been rotated
	next   atomic.Int64   // accounts are used in a shuffled order, once each
	order  []int32
}

func runCmd(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	base := fs.String("url", "http://127.0.0.1:8080", "the server to drive; it must trust this machine's X-Forwarded-For")
	users := fs.Int("users", 200000, "accounts that were seeded")
	rates := fs.String("rps", "50,100,200", "app events started per second, one step per value")
	step := fs.Duration("step", 30*time.Second, "length of each step")
	mix := fs.String("mix", "launch=88,login=5,register=2,forgot=1,plans=4", "share of each kind of event")
	workers := fs.Int("workers", 2000, "events in flight at most; more than that are counted as shed")
	shareIP := fs.Int("share-ip", 1, "accounts behind each client address (mobile carriers put many phones behind one)")
	state := fs.String("state", "", "file that remembers rotated refresh tokens between runs (default: none)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if _, err := loadConfig(); err != nil {
		return err
	}
	weights, err := parseMix(*mix)
	if err != nil {
		return err
	}
	var steps []int
	for _, s := range strings.Split(*rates, ",") {
		v, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil || v < 1 {
			return fmt.Errorf("-rps: %q is not a rate", s)
		}
		steps = append(steps, v)
	}

	r := &runner{
		base: strings.TrimRight(*base, "/"), users: *users, shareIP: max(*shareIP, 1),
		results: make(chan result, 1<<16), tokens: map[int]string{},
		client: &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{
			MaxIdleConns: *workers, MaxIdleConnsPerHost: *workers, IdleConnTimeout: 60 * time.Second,
		}},
	}
	if *state != "" {
		if b, err := os.ReadFile(*state); err == nil {
			if err := json.Unmarshal(b, &r.tokens); err != nil {
				return fmt.Errorf("state file: %w", err)
			}
		}
	}
	r.order = make([]int32, *users)
	for i := range r.order {
		r.order[i] = int32(i)
	}
	rand.Shuffle(len(r.order), func(a, b int) { r.order[a], r.order[b] = r.order[b], r.order[a] })

	fmt.Printf("%-9s %-10s %8s %7s %7s %7s %7s %7s %8s %8s %8s %8s\n",
		"events/s", "request", "sent", "2xx", "4xx", "429", "5xx", "failed", "p50 ms", "p95 ms", "p99 ms", "max ms")
	slots := make(chan struct{}, *workers)
	var wg sync.WaitGroup
	for _, rate := range steps {
		var shed atomic.Int64
		collected := make(chan map[string]*opStats, 1)
		stepDone := make(chan struct{})
		go func() { collected <- collect(r.results, stepDone) }()

		stepStart := time.Now()
		interval := time.Second / time.Duration(rate)
		for n := 0; ; n++ {
			due := stepStart.Add(time.Duration(n) * interval)
			if due.Sub(stepStart) >= *step || ctx.Err() != nil {
				break
			}
			time.Sleep(time.Until(due))
			select {
			case slots <- struct{}{}:
			default:
				shed.Add(1)
				continue
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer func() { <-slots }()
				r.event(ctx, pick(weights), due)
			}()
		}
		wg.Wait()
		close(stepDone)
		printStep(rate, time.Since(stepStart), <-collected, shed.Load())
		if ctx.Err() != nil {
			break
		}
	}
	if *state != "" {
		b, _ := json.Marshal(r.tokens)
		if err := os.WriteFile(*state, b, 0o600); err != nil {
			return err
		}
	}
	return nil
}

type weight struct {
	op string
	w  int
}

func parseMix(s string) ([]weight, error) {
	var out []weight
	for _, part := range strings.Split(s, ",") {
		name, value, ok := strings.Cut(strings.TrimSpace(part), "=")
		w, err := strconv.Atoi(value)
		if !ok || err != nil || w < 0 {
			return nil, fmt.Errorf("-mix: %q is not name=weight", part)
		}
		switch name {
		case "launch", "login", "register", "forgot", "plans":
		default:
			return nil, fmt.Errorf("-mix: unknown event %q", name)
		}
		out = append(out, weight{name, w})
	}
	return out, nil
}

func pick(ws []weight) string {
	total := 0
	for _, w := range ws {
		total += w.w
	}
	n := rand.IntN(max(total, 1))
	for _, w := range ws {
		if n < w.w {
			return w.op
		}
		n -= w.w
	}
	return ws[0].op
}

// account hands out the next unused account. Each is used once per run, so
// two events never race on one refresh token; past the end it wraps.
func (r *runner) account() int {
	return int(r.order[int(r.next.Add(1)-1)%len(r.order)])
}

// address is the client address account i calls from. Caddy sets
// X-Forwarded-For in production; here the load generator plays Caddy.
func (r *runner) address(i int) string {
	g := i / r.shareIP
	return fmt.Sprintf("10.%d.%d.%d", g>>16&0xff, g>>8&0xff, g&0xff)
}

func (r *runner) event(ctx context.Context, op string, due time.Time) {
	i := r.account()
	switch op {
	case "launch":
		r.launch(ctx, i, due)
	case "login":
		for !hasPassword(i) {
			i = r.account()
		}
		r.call(ctx, due, "login", i, http.MethodPost, "/v1/auth/login",
			map[string]any{"email": seedEmail(i), "password": seedPassword}, "", nil)
	case "register":
		r.call(ctx, due, "register", i, http.MethodPost, "/v1/auth/register", map[string]any{
			"email": fmt.Sprintf("new%d-%d@%s", i, rand.Uint64(), emailDomain), "password": seedPassword, "name": "New person", "locale": "fa"}, "", nil)
	case "forgot":
		r.call(ctx, due, "forgot", i, http.MethodPost, "/v1/auth/password/forgot",
			map[string]any{"email": seedEmail(i), "locale": "fa"}, "", nil)
	case "plans":
		r.call(ctx, due, "plans", i, http.MethodGet, "/v1/subscription/plans", nil, "", nil)
	}
}

// launch is what the app does when it is opened after a while: trade the
// refresh token for a new pair, load the profile, check the subscription.
// One launch in ten also saves the profile.
func (r *runner) launch(ctx context.Context, i int, due time.Time) {
	r.mu.Lock()
	refresh, ok := r.tokens[i]
	r.mu.Unlock()
	if !ok {
		refresh = seedRefreshToken(i)
	}
	var tokens struct {
		AccessToken  string `json:"accessToken"`
		RefreshToken string `json:"refreshToken"`
	}
	if r.call(ctx, due, "refresh", i, http.MethodPost, "/v1/auth/token/refresh", map[string]any{"refreshToken": refresh}, "", &tokens) != http.StatusOK {
		return
	}
	r.mu.Lock()
	r.tokens[i] = tokens.RefreshToken
	r.mu.Unlock()
	var profile struct {
		Name string `json:"name"`
	}
	r.call(ctx, time.Time{}, "profile", i, http.MethodGet, "/v1/profile", nil, tokens.AccessToken, &profile)
	r.call(ctx, time.Time{}, "subscription", i, http.MethodGet, "/v1/subscription", nil, tokens.AccessToken, nil)
	if i%10 == 0 && profile.Name != "" {
		r.call(ctx, time.Time{}, "profile-save", i, http.MethodPut, "/v1/profile",
			map[string]any{"name": fmt.Sprintf("Load user %d.%d", i, rand.IntN(1000))}, tokens.AccessToken, nil)
	}
}

// call sends one request and records it. due is when it should have started
// (zero: now). It returns the status, 0 when there was no answer.
func (r *runner) call(ctx context.Context, due time.Time, op string, i int, method, path string, body any, access string, out any) int {
	if due.IsZero() {
		due = time.Now()
	}
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, r.base+path, reader)
	if err != nil {
		return 0
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("X-Forwarded-For", r.address(i))
	req.Header.Set("X-Tark-Platform", "android")
	req.Header.Set("X-Tark-Install-Key", seedInstallKey(i))
	req.Header.Set("Accept-Language", "fa")
	if access != "" {
		req.Header.Set("Authorization", "Bearer "+access)
	}
	status := 0
	res, err := r.client.Do(req)
	if err == nil {
		status = res.StatusCode
		b, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if out != nil && status/100 == 2 {
			_ = json.Unmarshal(b, out)
		}
	} else if errors.Is(err, context.Canceled) {
		return 0
	}
	r.results <- result{op: op, status: status, took: time.Since(due)}
	return status
}

type opStats struct {
	ok, client, limited, server, failed int
	took                                []time.Duration
}

func collect(in <-chan result, done <-chan struct{}) map[string]*opStats {
	stats := map[string]*opStats{}
	add := func(res result) {
		s := stats[res.op]
		if s == nil {
			s = &opStats{}
			stats[res.op] = s
		}
		switch {
		case res.status == 0:
			s.failed++
		case res.status == http.StatusTooManyRequests:
			s.limited++
		case res.status >= 500:
			s.server++
		case res.status >= 400:
			s.client++
		default:
			s.ok++
		}
		s.took = append(s.took, res.took)
	}
	for {
		select {
		case res := <-in:
			add(res)
		case <-done:
			for {
				select {
				case res := <-in:
					add(res)
				default:
					return stats
				}
			}
		}
	}
}

func printStep(rate int, elapsed time.Duration, stats map[string]*opStats, shed int64) {
	names := make([]string, 0, len(stats))
	for name := range stats {
		names = append(names, name)
	}
	sort.Strings(names)
	all := &opStats{}
	row := func(label, name string, s *opStats) {
		sort.Slice(s.took, func(a, b int) bool { return s.took[a] < s.took[b] })
		q := func(p float64) float64 {
			if len(s.took) == 0 {
				return 0
			}
			return float64(s.took[min(int(p*float64(len(s.took))), len(s.took)-1)].Microseconds()) / 1000
		}
		fmt.Printf("%-9s %-10s %8d %7d %7d %7d %7d %7d %8.1f %8.1f %8.1f %8.1f\n", label, name, len(s.took),
			s.ok, s.client, s.limited, s.server, s.failed, q(0.50), q(0.95), q(0.99), q(1))
	}
	for _, name := range names {
		s := stats[name]
		all.ok, all.client, all.limited, all.server, all.failed = all.ok+s.ok, all.client+s.client, all.limited+s.limited, all.server+s.server, all.failed+s.failed
		all.took = append(all.took, s.took...)
		row("", name, s)
	}
	row(strconv.Itoa(rate), "ALL", all)
	fmt.Printf("%-9s %.0f requests/s answered over %s", "", float64(len(all.took))/elapsed.Seconds(), elapsed.Round(time.Second))
	if shed > 0 {
		fmt.Printf("; %d events shed (more than -workers were in flight: the server is past its limit)", shed)
	}
	fmt.Println()
}
