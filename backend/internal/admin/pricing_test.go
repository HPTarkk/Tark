package admin

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/HPTarkk/Tark/backend/internal/billing"
)

func testPlans() []billing.Plan {
	plans, err := billing.ParsePlans([]string{"tark_premium_1m", "tark_premium_3m", "tark_premium_6m", "tark_premium_12m"})
	if err != nil {
		panic(err)
	}
	return plans
}

func TestPsychological(t *testing.T) {
	cases := []struct {
		raw             float64
		roundTo, ending int64
		want            int64
	}{
		{267300, 10000, 1000, 269000},
		{99000, 10000, 1000, 99000},
		{100000, 10000, 1000, 99000},
		{100001, 10000, 1000, 109000},
		{5000, 10000, 1000, 9000},
		{123456, 1000, 0, 124000},
		{0, 10000, 1000, 0},
	}
	for _, c := range cases {
		if got := psychological(c.raw, c.roundTo, c.ending); got != c.want {
			t.Errorf("psychological(%v, %d, %d) = %d, want %d", c.raw, c.roundTo, c.ending, got, c.want)
		}
	}
}

func TestSuggestPrices(t *testing.T) {
	in := PriceInputs{BaseMonthly: 99000, Adjustment: 1, RoundTo: 10000, Ending: 1000,
		Multipliers: map[string]float64{"tark_premium_1m": 1, "tark_premium_3m": 2.7, "tark_premium_6m": 5, "tark_premium_12m": 9}}
	rows := SuggestPrices(in, testPlans())
	want := []int64{99000, 269000, 499000, 899000}
	for i, r := range rows {
		if r.Toman != want[i] || r.Rial != want[i]*10 {
			t.Errorf("%s: %d Toman %d Rial, want %d", r.Plan.SKU, r.Toman, r.Rial, want[i])
		}
	}
	if rows[0].SavingPct != 0 || rows[1].SavingPct != 9 || rows[3].SavingPct != 24 {
		t.Errorf("savings %d %d %d", rows[0].SavingPct, rows[1].SavingPct, rows[3].SavingPct)
	}

	in.Adjustment = 1.2 // inflation: everything moves together
	if got := SuggestPrices(in, testPlans())[0].Toman; got != 119000 {
		t.Errorf("adjusted monthly %d", got)
	}
}

func TestParseAmount(t *testing.T) {
	for in, want := range map[string]int64{"99,000": 99000, "۹۹٬۰۰۰": 99000, " 1 000 ": 1000, "250000": 250000} {
		if got, err := parseAmount(in); err != nil || got != want {
			t.Errorf("parseAmount(%q) = %d %v", in, got, err)
		}
	}
	if got, err := parseFactor("۲٫۷"); err != nil || got != 2.7 {
		t.Errorf("parseFactor = %v %v", got, err)
	}
}

func TestPricingPage(t *testing.T) {
	e := setup(t)
	b := e.owner("boss@example.com")
	code, body := b.get("/pricing")
	if code != http.StatusOK || !strings.Contains(body, "Nothing saved yet") || !strings.Contains(body, `name="mult_tark_premium_3m"`) {
		t.Fatalf("empty page: %d", code)
	}
	form := url.Values{"csrf": {field(t, body, "csrf")}, "base": {"99,000"}, "adjustment": {"1"},
		"mult_tark_premium_1m": {"1"}, "mult_tark_premium_3m": {"2.7"}, "mult_tark_premium_6m": {"5"}, "mult_tark_premium_12m": {"9"},
		"round_to": {"10,000"}, "ending": {"1,000"}}
	bad := url.Values{}
	for k, v := range form {
		bad[k] = v
	}
	bad.Set("ending", "10000")
	if code, _ := b.post("/pricing", bad); code != http.StatusBadRequest {
		t.Fatalf("ending >= round_to: %d", code)
	}
	code, body = b.post("/pricing", form)
	if code != http.StatusOK || !strings.Contains(body, "<code>2,690,000</code>") || !strings.Contains(body, "<strong>899,000</strong>") {
		t.Fatalf("save: %d %s", code, body)
	}
	// Saved: a fresh load shows the same numbers.
	_, body = b.get("/pricing")
	if !strings.Contains(body, `value="2.7"`) || !strings.Contains(body, "<strong>269,000</strong>") {
		t.Fatal("not saved")
	}
	var n int
	if err := e.deps.Pool.QueryRow(context.Background(), `SELECT count(*) FROM admin_events WHERE kind = 'pricing.updated'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("events %d %v", n, err)
	}
}
