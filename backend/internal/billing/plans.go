package billing

import (
	"fmt"
	"regexp"
	"strconv"

	"github.com/HPTarkk/Tark/backend/internal/i18n"
)

// Plan is one subscription product as Bazaar sells it. The length lives in
// the product id (tark_premium_<months>m), so adding a length only means
// creating the product in the Bazaar panel and listing its id in
// TARK_BAZAAR_SKUS; no code or app change.
//
// TestSKU is the one exception: a 5-minute product for trying purchases
// and renewals on a test server. It has no months, only Minutes.
type Plan struct {
	SKU     string
	Months  int
	Minutes int
}

// TestSKU is the Bazaar product that renews every 5 minutes. It is only for
// testing: it is sold or accepted only where TARK_BAZAAR_SKUS lists it, which
// production's default list does not.
const TestSKU = "TEST_SUB"

// testMinutes is TestSKU's period as set in the Bazaar panel.
const testMinutes = 5

var planSKU = regexp.MustCompile(`^tark_premium_([1-9][0-9]?)m$`)

// ParsePlan reads a product id. ok is false for anything that is not one of
// our subscription ids.
func ParsePlan(sku string) (Plan, bool) {
	if sku == TestSKU {
		return Plan{SKU: sku, Minutes: testMinutes}, true
	}
	m := planSKU.FindStringSubmatch(sku)
	if m == nil {
		return Plan{}, false
	}
	months, _ := strconv.Atoi(m[1])
	if months > 36 {
		return Plan{}, false
	}
	return Plan{SKU: sku, Months: months}, true
}

// IsTest reports whether this is the 5-minute test plan.
func (p Plan) IsTest() bool { return p.SKU == TestSKU }

// Days is the period length as the Bazaar panel names it: 30 days a month,
// 365 a year. The test plan is shorter than a day, so 0.
func (p Plan) Days() int {
	if p.IsTest() {
		return 0
	}
	if p.Months%12 == 0 {
		return p.Months / 12 * 365
	}
	return p.Months * 30
}

// Title names the plan for people: "1 month", "3 months", "1 year".
func (p Plan) Title(lang string) string {
	if p.IsTest() {
		if lang == i18n.FA {
			return fmt.Sprintf("تست %s دقیقه‌ای", i18n.Digits(i18n.FA, p.Minutes))
		}
		return fmt.Sprintf("%d-minute test", p.Minutes)
	}
	if p.Months%12 == 0 {
		years := p.Months / 12
		if lang == i18n.FA {
			return fmt.Sprintf("%s ساله", persianCount(years))
		}
		if years == 1 {
			return "1 year"
		}
		return fmt.Sprintf("%d years", years)
	}
	if lang == i18n.FA {
		return fmt.Sprintf("%s ماهه", persianCount(p.Months))
	}
	if p.Months == 1 {
		return "1 month"
	}
	return fmt.Sprintf("%d months", p.Months)
}

// persianCount spells small counts the way a plan name reads ("سه ماهه");
// larger ones use Persian digits.
func persianCount(n int) string {
	words := []string{"", "یک", "دو", "سه", "چهار", "پنج", "شش", "هفت", "هشت", "نه", "ده", "یازده", "دوازده"}
	if n > 0 && n < len(words) {
		return words[n]
	}
	return i18n.Digits(i18n.FA, n)
}

// ParsePlans turns the configured list of product ids into plans, in order,
// refusing anything that is not a plan id or is listed twice.
func ParsePlans(skus []string) ([]Plan, error) {
	seen := map[string]bool{}
	plans := make([]Plan, 0, len(skus))
	for _, sku := range skus {
		p, ok := ParsePlan(sku)
		if !ok {
			return nil, fmt.Errorf("TARK_BAZAAR_SKUS: %q is not a plan id (want tark_premium_<months>m or %s)", sku, TestSKU)
		}
		if seen[sku] {
			return nil, fmt.Errorf("TARK_BAZAAR_SKUS: %q is listed twice", sku)
		}
		seen[sku] = true
		plans = append(plans, p)
	}
	if len(plans) == 0 {
		return nil, fmt.Errorf("TARK_BAZAAR_SKUS: no plans listed")
	}
	return plans, nil
}

// PlanTitle names whatever product an entitlement carries: a plan's length,
// or "Gift from Tark" for premium given from the admin panel. ok is false
// for an empty or unknown id.
func PlanTitle(sku, lang string) (title string, ok bool) {
	if sku == CompSKU {
		if lang == i18n.FA {
			return "هدیه‌ی تَرک", true
		}
		return "Gift from Tark", true
	}
	p, ok := ParsePlan(sku)
	if !ok {
		return "", false
	}
	return p.Title(lang), true
}
