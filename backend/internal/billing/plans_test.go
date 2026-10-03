package billing

import "testing"

func TestParsePlan(t *testing.T) {
	cases := map[string]int{"tark_premium_1m": 1, "tark_premium_3m": 3, "tark_premium_12m": 12, "tark_premium_24m": 24}
	for sku, months := range cases {
		p, ok := ParsePlan(sku)
		if !ok || p.Months != months {
			t.Errorf("ParsePlan(%q) = %v %v", sku, p, ok)
		}
	}
	for _, bad := range []string{"", "comp", "tark_premium_0m", "tark_premium_01m", "tark_premium_37m",
		"tark_premium_1y", "tark_premium_1m ", "TARK_PREMIUM_1M", "x_tark_premium_1m"} {
		if _, ok := ParsePlan(bad); ok {
			t.Errorf("ParsePlan(%q) accepted", bad)
		}
	}
}

func TestPlanDaysAndTitles(t *testing.T) {
	cases := []struct {
		months int
		days   int
		en, fa string
	}{
		{1, 30, "1 month", "یک ماهه"},
		{3, 90, "3 months", "سه ماهه"},
		{6, 180, "6 months", "شش ماهه"},
		{12, 365, "1 year", "یک ساله"},
		{24, 730, "2 years", "دو ساله"},
	}
	for _, c := range cases {
		p := Plan{Months: c.months}
		if p.Days() != c.days || p.Title("en") != c.en || p.Title("fa") != c.fa {
			t.Errorf("%d months: %d %q %q", c.months, p.Days(), p.Title("en"), p.Title("fa"))
		}
	}
	if title, ok := PlanTitle(CompSKU, "en"); !ok || title != "Gift from Tark" {
		t.Errorf("comp title %q", title)
	}
	if _, ok := PlanTitle("", "en"); ok {
		t.Error("empty sku has a title")
	}
}

func TestTestPlan(t *testing.T) {
	p, ok := ParsePlan(TestSKU)
	if !ok || !p.IsTest() || p.Months != 0 || p.Minutes != 5 || p.Days() != 0 {
		t.Fatalf("%+v %v", p, ok)
	}
	if p.Title("en") != "5-minute test" || p.Title("fa") != "تست ۵ دقیقه‌ای" {
		t.Errorf("%q %q", p.Title("en"), p.Title("fa"))
	}
	if title, ok := PlanTitle(TestSKU, "en"); !ok || title != "5-minute test" {
		t.Errorf("PlanTitle %q %v", title, ok)
	}
	for _, bad := range []string{"test_sub", "TEST_SUB ", "TEST_SUB2"} {
		if _, ok := ParsePlan(bad); ok {
			t.Errorf("ParsePlan(%q) accepted", bad)
		}
	}
	if plans, err := ParsePlans([]string{"tark_premium_1m", TestSKU}); err != nil || len(plans) != 2 {
		t.Errorf("%v %v", plans, err)
	}
}

func TestParsePlans(t *testing.T) {
	if _, err := ParsePlans([]string{"tark_premium_1m", "tark_premium_1m"}); err == nil {
		t.Error("duplicate accepted")
	}
	if _, err := ParsePlans([]string{"tark_premium_6m", "nope"}); err == nil {
		t.Error("bad id accepted")
	}
	if _, err := ParsePlans(nil); err == nil {
		t.Error("empty list accepted")
	}
	plans, err := ParsePlans([]string{"tark_premium_12m", "tark_premium_1m"})
	if err != nil || plans[0].Months != 12 || plans[1].Months != 1 {
		t.Errorf("%v %v", plans, err)
	}
}
