package metrics

import (
	"math"
	"strings"
	"testing"
	"time"
)

func TestQuantile(t *testing.T) {
	var h Hist
	for range 90 {
		h.observe(30 * time.Millisecond)
	}
	for range 10 {
		h.observe(3 * time.Second)
	}
	if got := h.Quantile(0.5); got != 0.05 {
		t.Fatalf("p50 = %v", got)
	}
	if got := h.Quantile(0.95); got != 5 {
		t.Fatalf("p95 = %v", got)
	}
	h.observe(time.Minute)
	if got := h.Quantile(1); !math.IsInf(got, 1) {
		t.Fatalf("p100 = %v", got)
	}
	if (Hist{}).Quantile(0.5) != 0 {
		t.Fatal("empty histogram")
	}
}

func TestWindowAndClasses(t *testing.T) {
	now := time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC)
	r := newAt(nil, func() time.Time { return now })
	r.ObserveRequest("GET", "/a", 200, 10*time.Millisecond)
	r.ObserveRequest("GET", "/a", 404, 10*time.Millisecond)
	r.ObserveRequest("GET", "/a", 503, 3*time.Second)
	r.ObserveRequest("GET", "/a", 101, time.Millisecond) // counted with 2xx
	now = now.Add(time.Minute)
	r.Tick()
	for range 6 {
		now = now.Add(time.Minute)
		r.ObserveRequest("GET", "/b", 200, time.Millisecond)
		r.Tick()
	}
	r.ObserveBazaar(false, time.Second)
	r.ObserveMail(true, time.Second)

	all := r.Now().Routes["GET /a"]
	if all.ByClass != [4]int64{2, 0, 1, 1} || all.Slow != 1 || all.Requests() != 4 {
		t.Fatalf("route /a: %+v", all)
	}
	w, covered := r.Window(5 * time.Minute)
	if covered != 5*time.Minute {
		t.Fatalf("covered %s", covered)
	}
	if w.Routes["GET /a"].Requests() != 0 || w.Routes["GET /b"].Requests() != 5 {
		t.Fatalf("window: %+v", w.Routes)
	}
	if w.Bazaar.Failed != 1 || w.Mail.OK != 1 {
		t.Fatalf("calls: %+v %+v", w.Bazaar, w.Mail)
	}
	// Longer than the history: counts from the start.
	w, covered = r.Window(time.Hour)
	if covered != 7*time.Minute || w.All().Requests() != 10 {
		t.Fatalf("since start: %s %d", covered, w.All().Requests())
	}
	if s := w.Sorted(); s[0].Route != "/b" {
		t.Fatalf("sorted: %+v", s)
	}
}

func TestHistoryIsBounded(t *testing.T) {
	now := time.Now()
	r := newAt(nil, func() time.Time { return now })
	for range 200 {
		now = now.Add(time.Minute)
		r.Tick()
	}
	if len(r.ring) != History+1 {
		t.Fatalf("ring %d", len(r.ring))
	}
}

func TestWriteText(t *testing.T) {
	r := New(nil)
	r.ObserveRequest("POST", "/v1/auth/login", 200, 30*time.Millisecond)
	r.ObserveMail(false, time.Second)
	var b strings.Builder
	if err := r.WriteText(&b); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`tark_http_requests_total{method="POST",route="/v1/auth/login",code="2xx"} 1`,
		`tark_http_request_seconds_bucket{method="POST",route="/v1/auth/login",le="0.05"} 1`,
		`tark_http_request_seconds_bucket{method="POST",route="/v1/auth/login",le="+Inf"} 1`,
		`tark_mail_calls_total{result="failed"} 1`,
		`tark_mail_call_seconds_count 1`,
		"go_goroutines ",
	} {
		if !strings.Contains(b.String(), want) {
			t.Fatalf("missing %q in\n%s", want, b.String())
		}
	}
}
