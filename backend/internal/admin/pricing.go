package admin

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/billing"
)

// PriceInputs are the price helper's settings. Prices are in Toman; Bazaar's
// panel takes Rial (Toman × 10), so the page shows both.
type PriceInputs struct {
	BaseMonthly int64
	// Adjustment scales every plan at once, e.g. 1.15 after inflation.
	Adjustment  float64
	Multipliers map[string]float64
	// Prices are rounded up to a multiple of RoundTo, then Ending is taken
	// off: RoundTo 10,000 and Ending 1,000 turn 267,300 into 269,000.
	RoundTo int64
	Ending  int64
}

// PriceRow is one plan's suggestion.
type PriceRow struct {
	Plan       billing.Plan
	Title      string
	Multiplier float64
	Raw        float64
	Toman      int64
	Rial       int64
	PerMonth   int64
	// SavingPct is how much less a month costs than on the 1-month plan's
	// suggested price; 0 for that plan or when there is none.
	SavingPct int
}

// defaultMultiplier is what a plan starts with before anyone sets it: a
// little under the months it covers, so longer plans are a better deal.
func defaultMultiplier(months int) float64 {
	switch {
	case months <= 1:
		return float64(months)
	case months < 12:
		return math.Round(float64(months)*0.9*10) / 10
	default:
		return math.Round(float64(months)*0.75*10) / 10
	}
}

// pricedPlans leaves out the 5-minute test plan: its price is whatever the
// tester set in the panel and has nothing to do with the monthly price.
func pricedPlans(plans []billing.Plan) []billing.Plan {
	out := make([]billing.Plan, 0, len(plans))
	for _, p := range plans {
		if !p.IsTest() {
			out = append(out, p)
		}
	}
	return out
}

func defaultInputs(plans []billing.Plan) PriceInputs {
	in := PriceInputs{Adjustment: 1, RoundTo: 10000, Ending: 1000, Multipliers: map[string]float64{}}
	for _, p := range plans {
		in.Multipliers[p.SKU] = defaultMultiplier(p.Months)
	}
	return in
}

// psychological rounds raw up to a multiple of roundTo, then takes ending
// off, never going below roundTo - ending.
func psychological(raw float64, roundTo, ending int64) int64 {
	if raw <= 0 {
		return 0
	}
	steps := int64(math.Ceil(raw / float64(roundTo)))
	if steps < 1 {
		steps = 1
	}
	return steps*roundTo - ending
}

// SuggestPrices works out every plan's price from the inputs.
func SuggestPrices(in PriceInputs, plans []billing.Plan) []PriceRow {
	plans = pricedPlans(plans)
	rows := make([]PriceRow, 0, len(plans))
	var monthly int64
	for _, p := range plans {
		mult, ok := in.Multipliers[p.SKU]
		if !ok {
			mult = defaultMultiplier(p.Months)
		}
		raw := float64(in.BaseMonthly) * in.Adjustment * mult
		toman := psychological(raw, in.RoundTo, in.Ending)
		row := PriceRow{Plan: p, Title: p.Title("en"), Multiplier: mult, Raw: raw, Toman: toman, Rial: toman * 10,
			PerMonth: int64(math.Round(float64(toman) / float64(p.Months)))}
		if p.Months == 1 {
			monthly = toman
		}
		rows = append(rows, row)
	}
	if monthly > 0 {
		for i := range rows {
			if rows[i].Plan.Months > 1 {
				rows[i].SavingPct = int(math.Round(100 * (1 - float64(rows[i].PerMonth)/float64(monthly))))
			}
		}
	}
	return rows
}

// loadPriceInputs reads the saved settings; saved is false when none exist.
func (s *Server) loadPriceInputs(ctx context.Context) (in PriceInputs, saved bool, err error) {
	in = defaultInputs(s.Plans)
	var raw []byte
	err = s.Pool.QueryRow(ctx, `SELECT base_monthly_toman, adjustment::float8, multipliers, round_to, ending FROM price_helper WHERE id = 1`).
		Scan(&in.BaseMonthly, &in.Adjustment, &raw, &in.RoundTo, &in.Ending)
	if errors.Is(err, pgx.ErrNoRows) {
		return in, false, nil
	}
	if err != nil {
		return in, false, err
	}
	stored := map[string]float64{}
	if err := json.Unmarshal(raw, &stored); err != nil {
		return in, false, err
	}
	for sku, m := range stored {
		in.Multipliers[sku] = m
	}
	return in, true, nil
}

func (s *Server) pricing(w http.ResponseWriter, r *http.Request) {
	in, saved, err := s.loadPriceInputs(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.showPricing(w, r, http.StatusOK, in, saved, "", "")
}

func (s *Server) showPricing(w http.ResponseWriter, r *http.Request, status int, in PriceInputs, saved bool, notice, errText string) {
	data := map[string]any{"In": in, "Saved": saved, "Notice": notice, "Error": errText, "Plans": pricedPlans(s.Plans)}
	if in.BaseMonthly > 0 {
		data["Rows"] = SuggestPrices(in, s.Plans)
	}
	s.render(w, r, status, "pricing", data)
}

// parseAmount reads a whole number typed with or without separators
// ("99,000", "99٬000", "۹۹۰۰۰").
func parseAmount(v string) (int64, error) {
	v = toASCIIDigits(strings.TrimSpace(v))
	v = strings.NewReplacer(",", "", "٬", "", " ", "", "_", "").Replace(v)
	return strconv.ParseInt(v, 10, 64)
}

func parseFactor(v string) (float64, error) {
	v = toASCIIDigits(strings.TrimSpace(v))
	v = strings.ReplaceAll(v, "٫", ".")
	return strconv.ParseFloat(v, 64)
}

func toASCIIDigits(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= '۰' && r <= '۹':
			b.WriteRune('0' + (r - '۰'))
		case r >= '٠' && r <= '٩':
			b.WriteRune('0' + (r - '٠'))
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func (s *Server) savePricing(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	in := PriceInputs{Multipliers: map[string]float64{}}
	bad := func(msg string) {
		s.showPricing(w, r, http.StatusBadRequest, in, false, "", msg)
	}
	var err error
	if in.BaseMonthly, err = parseAmount(r.PostFormValue("base")); err != nil || in.BaseMonthly < 1000 || in.BaseMonthly > 1_000_000_000 {
		bad(T(ctx, "pricing.badBase"))
		return
	}
	if in.Adjustment, err = parseFactor(r.PostFormValue("adjustment")); err != nil || in.Adjustment < 0.1 || in.Adjustment > 100 {
		bad(T(ctx, "pricing.badAdj"))
		return
	}
	for _, p := range pricedPlans(s.Plans) {
		m, err := parseFactor(r.PostFormValue("mult_" + p.SKU))
		if err != nil || m < 0.1 || m > 100 {
			bad(T(ctx, "pricing.badMult", p.Title(langFrom(ctx))))
			return
		}
		in.Multipliers[p.SKU] = math.Round(m*10000) / 10000
	}
	if in.RoundTo, err = parseAmount(r.PostFormValue("round_to")); err != nil || in.RoundTo < 1 || in.RoundTo > 100_000_000 {
		bad(T(ctx, "pricing.badRound"))
		return
	}
	if in.Ending, err = parseAmount(r.PostFormValue("ending")); err != nil || in.Ending < 0 || in.Ending >= in.RoundTo {
		bad(T(ctx, "pricing.badEnding"))
		return
	}
	in.Adjustment = math.Round(in.Adjustment*10000) / 10000

	// Keep multipliers of plans no longer on sale, so putting one back on
	// sale brings its old number back.
	old, _, err := s.loadPriceInputs(ctx)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	stored := map[string]float64{}
	for sku, m := range old.Multipliers {
		stored[sku] = m
	}
	for sku, m := range in.Multipliers {
		stored[sku] = m
	}
	raw, _ := json.Marshal(stored)
	a := adminFrom(ctx)
	if _, err := s.Pool.Exec(ctx, `
		INSERT INTO price_helper (id, base_monthly_toman, adjustment, multipliers, round_to, ending, updated_by, updated_at)
		VALUES (1, $1, $2, $3, $4, $5, $6, now())
		ON CONFLICT (id) DO UPDATE SET base_monthly_toman = EXCLUDED.base_monthly_toman, adjustment = EXCLUDED.adjustment,
			multipliers = EXCLUDED.multipliers, round_to = EXCLUDED.round_to, ending = EXCLUDED.ending,
			updated_by = EXCLUDED.updated_by, updated_at = now()`,
		in.BaseMonthly, in.Adjustment, raw, in.RoundTo, in.Ending, a.ID); err != nil {
		s.fail(w, r, err)
		return
	}
	s.record(ctx, a.ID, "pricing.updated", "", ipFrom(ctx), map[string]any{
		"base": in.BaseMonthly, "adjustment": in.Adjustment, "multipliers": in.Multipliers, "roundTo": in.RoundTo, "ending": in.Ending,
	})
	s.showPricing(w, r, http.StatusOK, in, true, T(ctx, "pricing.saved"), "")
}
