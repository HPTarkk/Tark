// Package metrics keeps in-process numbers about how the service is doing:
// requests per route with their latency, calls to Bazaar, emails sent, the
// database connection pool and the Go runtime.
//
// Nothing here is personal: routes are patterns (/v1/users/{id}), never
// paths, and no address, id or email is recorded. The numbers live in
// memory only. The admin panel shows them (the System page), the monitor
// alerts on them, and TARK_METRICS_ADDR can expose them in the Prometheus
// text format on a port that is never published.
package metrics

import (
	"context"
	"fmt"
	"io"
	"math"
	"runtime"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Buckets are the latency histogram bounds in seconds.
var Buckets = []float64{0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

// SlowAfter is when a request counts as slow.
const SlowAfter = 2 * time.Second

// History is how many one-minute snapshots are kept for windowed views.
const History = 60

// Hist is a latency histogram. Counts[i] counts observations at or under
// Buckets[i]; the last entry counts the rest.
type Hist struct {
	Counts [9]int64
	Sum    float64
	N      int64
}

func (h *Hist) observe(d time.Duration) {
	s := d.Seconds()
	i := sort.SearchFloat64s(Buckets, s)
	h.Counts[i]++
	h.Sum += s
	h.N++
}

func (h Hist) sub(o Hist) Hist {
	for i := range h.Counts {
		h.Counts[i] -= o.Counts[i]
	}
	h.Sum -= o.Sum
	h.N -= o.N
	return h
}

// Quantile estimates the q-th quantile (0..1) from the buckets, returning
// the bucket's upper bound. Above the last bound it reports +Inf.
func (h Hist) Quantile(q float64) float64 {
	if h.N == 0 {
		return 0
	}
	rank := int64(math.Ceil(q * float64(h.N)))
	var seen int64
	for i, c := range h.Counts {
		seen += c
		if seen >= rank {
			if i < len(Buckets) {
				return Buckets[i]
			}
			return math.Inf(1)
		}
	}
	return math.Inf(1)
}

// Route is what is known about one method and route pattern.
type Route struct {
	Method, Route string
	// ByClass counts responses by status class: 2xx, 3xx, 4xx, 5xx.
	ByClass [4]int64
	Slow    int64
	Latency Hist
}

func (r Route) Requests() int64 { return r.ByClass[0] + r.ByClass[1] + r.ByClass[2] + r.ByClass[3] }

func (r Route) sub(o Route) Route {
	for i := range r.ByClass {
		r.ByClass[i] -= o.ByClass[i]
	}
	r.Slow -= o.Slow
	r.Latency = r.Latency.sub(o.Latency)
	return r
}

// Calls counts calls to an outside service.
type Calls struct {
	OK, Failed int64
	Latency    Hist
}

func (c Calls) sub(o Calls) Calls {
	return Calls{c.OK - o.OK, c.Failed - o.Failed, c.Latency.sub(o.Latency)}
}

// Pool is the part of pgxpool.Stat the views use.
type Pool struct {
	Acquires, Waited, Canceled int64
	// WaitTime adds up how long successful acquires took.
	WaitTime          time.Duration
	InUse, Total, Max int32
}

// Totals is everything counted since start.
type Totals struct {
	At     time.Time
	Routes map[string]Route
	Bazaar Calls
	Mail   Calls
	Pool   Pool
}

func (t Totals) sub(o Totals) Totals {
	d := Totals{At: t.At, Routes: map[string]Route{}, Bazaar: t.Bazaar.sub(o.Bazaar), Mail: t.Mail.sub(o.Mail), Pool: t.Pool}
	for k, r := range t.Routes {
		d.Routes[k] = r.sub(o.Routes[k])
	}
	d.Pool.Acquires -= o.Pool.Acquires
	d.Pool.Waited -= o.Pool.Waited
	d.Pool.Canceled -= o.Pool.Canceled
	d.Pool.WaitTime -= o.Pool.WaitTime
	return d
}

// All adds every route together.
func (t Totals) All() Route {
	var a Route
	for _, r := range t.Routes {
		for i := range a.ByClass {
			a.ByClass[i] += r.ByClass[i]
		}
		a.Slow += r.Slow
		for i := range a.Latency.Counts {
			a.Latency.Counts[i] += r.Latency.Counts[i]
		}
		a.Latency.Sum += r.Latency.Sum
		a.Latency.N += r.Latency.N
	}
	return a
}

// AvgWait is the mean time an acquire took.
func (p Pool) AvgWait() time.Duration {
	if p.Acquires <= 0 {
		return 0
	}
	return p.WaitTime / time.Duration(p.Acquires)
}

// Sorted lists the routes busiest first.
func (t Totals) Sorted() []Route {
	out := make([]Route, 0, len(t.Routes))
	for _, r := range t.Routes {
		if r.Requests() > 0 {
			out = append(out, r)
		}
	}
	slices.SortFunc(out, func(a, b Route) int {
		if a.Requests() != b.Requests() {
			return int(b.Requests() - a.Requests())
		}
		return strings.Compare(a.Route+a.Method, b.Route+b.Method)
	})
	return out
}

// Registry holds the numbers. The zero value is not usable; call New.
type Registry struct {
	mu      sync.Mutex
	started time.Time
	now     func() time.Time
	pool    *pgxpool.Pool
	cur     Totals
	ring    []Totals // one per minute, oldest first
}

func New(pool *pgxpool.Pool) *Registry {
	return newAt(pool, time.Now)
}

func newAt(pool *pgxpool.Pool, now func() time.Time) *Registry {
	return &Registry{started: now(), now: now, pool: pool, cur: Totals{Routes: map[string]Route{}}}
}

// Started is when the process began counting.
func (r *Registry) Started() time.Time { return r.started }

// ObserveRequest records one HTTP response.
func (r *Registry) ObserveRequest(method, route string, status int, d time.Duration) {
	if r == nil {
		return
	}
	class := status/100 - 2
	if class < 0 {
		class = 0
	}
	if class > 3 {
		class = 3
	}
	k := method + " " + route
	r.mu.Lock()
	defer r.mu.Unlock()
	x := r.cur.Routes[k]
	x.Method, x.Route = method, route
	x.ByClass[class]++
	if d >= SlowAfter {
		x.Slow++
	}
	x.Latency.observe(d)
	r.cur.Routes[k] = x
}

// ObserveBazaar records one call to Bazaar's API.
func (r *Registry) ObserveBazaar(ok bool, d time.Duration) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	observeCall(&r.cur.Bazaar, ok, d)
}

// ObserveMail records one attempt to hand an email to the mail server.
func (r *Registry) ObserveMail(ok bool, d time.Duration) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	observeCall(&r.cur.Mail, ok, d)
}

func observeCall(c *Calls, ok bool, d time.Duration) {
	if ok {
		c.OK++
	} else {
		c.Failed++
	}
	c.Latency.observe(d)
}

// snapshot copies the current totals. Callers hold r.mu.
func (r *Registry) snapshot() Totals {
	t := r.cur
	t.At = r.now()
	t.Routes = make(map[string]Route, len(r.cur.Routes))
	for k, v := range r.cur.Routes {
		t.Routes[k] = v
	}
	if r.pool != nil {
		s := r.pool.Stat()
		t.Pool = Pool{
			Acquires: s.AcquireCount(), Waited: s.EmptyAcquireCount(), Canceled: s.CanceledAcquireCount(),
			WaitTime: s.AcquireDuration(),
			InUse:    s.AcquiredConns(), Total: s.TotalConns(), Max: s.MaxConns(),
		}
	}
	return t
}

// Run stores a snapshot for the windowed views every minute until ctx ends.
func (r *Registry) Run(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			r.Tick()
		}
	}
}

// Tick stores a snapshot for the windowed views.
func (r *Registry) Tick() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ring = append(r.ring, r.snapshot())
	if len(r.ring) > History+1 {
		r.ring = r.ring[len(r.ring)-History-1:]
	}
}

// Now returns the totals since start.
func (r *Registry) Now() Totals {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.snapshot()
}

// Window returns what happened in about the last d: the change since the
// newest snapshot at least d old. Until there is one, it counts from the
// start of the process (every counter, the pool's included, starts there).
// Covered says how long the result actually spans.
func (r *Registry) Window(d time.Duration) (t Totals, covered time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.snapshot()
	base := Totals{At: r.started, Routes: map[string]Route{}}
	for i := len(r.ring) - 1; i >= 0; i-- {
		if now.At.Sub(r.ring[i].At) >= d {
			base = r.ring[i]
			break
		}
	}
	return now.sub(base), now.At.Sub(base.At)
}

// Runtime is a few numbers about the Go process.
type Runtime struct {
	Goroutines int
	HeapBytes  uint64
	SysBytes   uint64
	GCs        uint32
}

func ReadRuntime() Runtime {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return Runtime{Goroutines: runtime.NumGoroutine(), HeapBytes: m.HeapAlloc, SysBytes: m.Sys, GCs: m.NumGC}
}

// WriteText writes everything in the Prometheus text exposition format.
func (r *Registry) WriteText(w io.Writer) error {
	t := r.Now()
	var b strings.Builder
	b.WriteString("# TYPE tark_http_requests_total counter\n")
	routes := t.Sorted()
	slices.SortFunc(routes, func(a, b Route) int { return strings.Compare(a.Route+a.Method, b.Route+b.Method) })
	classes := []string{"2xx", "3xx", "4xx", "5xx"}
	for _, x := range routes {
		for i, c := range x.ByClass {
			if c > 0 {
				fmt.Fprintf(&b, "tark_http_requests_total{method=%q,route=%q,code=%q} %d\n", x.Method, x.Route, classes[i], c)
			}
		}
	}
	b.WriteString("# TYPE tark_http_request_seconds histogram\n")
	for _, x := range routes {
		writeHist(&b, "tark_http_request_seconds", fmt.Sprintf("method=%q,route=%q", x.Method, x.Route), x.Latency)
	}
	for _, c := range []struct {
		name string
		c    Calls
	}{{"bazaar", t.Bazaar}, {"mail", t.Mail}} {
		fmt.Fprintf(&b, "# TYPE tark_%s_calls_total counter\n", c.name)
		fmt.Fprintf(&b, "tark_%s_calls_total{result=\"ok\"} %d\ntark_%s_calls_total{result=\"failed\"} %d\n", c.name, c.c.OK, c.name, c.c.Failed)
		fmt.Fprintf(&b, "# TYPE tark_%s_call_seconds histogram\n", c.name)
		writeHist(&b, "tark_"+c.name+"_call_seconds", "", c.c.Latency)
	}
	p := t.Pool
	fmt.Fprintf(&b, "# TYPE tark_db_acquires_total counter\ntark_db_acquires_total %d\n", p.Acquires)
	fmt.Fprintf(&b, "# TYPE tark_db_acquires_waited_total counter\ntark_db_acquires_waited_total %d\n", p.Waited)
	fmt.Fprintf(&b, "# TYPE tark_db_acquires_canceled_total counter\ntark_db_acquires_canceled_total %d\n", p.Canceled)
	fmt.Fprintf(&b, "# TYPE tark_db_connections gauge\ntark_db_connections{state=\"in_use\"} %d\ntark_db_connections{state=\"open\"} %d\ntark_db_connections{state=\"max\"} %d\n",
		p.InUse, p.Total, p.Max)
	rt := ReadRuntime()
	fmt.Fprintf(&b, "# TYPE go_goroutines gauge\ngo_goroutines %d\n", rt.Goroutines)
	fmt.Fprintf(&b, "# TYPE go_memstats_heap_alloc_bytes gauge\ngo_memstats_heap_alloc_bytes %d\n", rt.HeapBytes)
	fmt.Fprintf(&b, "# TYPE go_memstats_sys_bytes gauge\ngo_memstats_sys_bytes %d\n", rt.SysBytes)
	fmt.Fprintf(&b, "# TYPE process_start_time_seconds gauge\nprocess_start_time_seconds %d\n", r.started.Unix())
	_, err := io.WriteString(w, b.String())
	return err
}

func writeHist(b *strings.Builder, name, labels string, h Hist) {
	sep := ""
	if labels != "" {
		sep = ","
	}
	var cum int64
	for i, le := range Buckets {
		cum += h.Counts[i]
		fmt.Fprintf(b, "%s_bucket{%s%sle=\"%g\"} %d\n", name, labels, sep, le, cum)
	}
	fmt.Fprintf(b, "%s_bucket{%s%sle=\"+Inf\"} %d\n", name, labels, sep, h.N)
	if labels != "" {
		fmt.Fprintf(b, "%s_sum{%s} %g\n%s_count{%s} %d\n", name, labels, h.Sum, name, labels, h.N)
	} else {
		fmt.Fprintf(b, "%s_sum %g\n%s_count %d\n", name, h.Sum, name, h.N)
	}
}
