package admin

import (
	"testing"
	"time"
)

func TestJalali(t *testing.T) {
	for _, c := range []struct{ g, j [3]int }{
		{[3]int{2025, 3, 21}, [3]int{1404, 1, 1}},
		{[3]int{2026, 10, 3}, [3]int{1405, 7, 11}},
		{[3]int{2024, 3, 19}, [3]int{1402, 12, 29}},
		{[3]int{2025, 3, 20}, [3]int{1403, 12, 30}}, // 1403 is a leap year
		{[3]int{2000, 1, 1}, [3]int{1378, 10, 11}},
	} {
		y, m, d := jalali(c.g[0], c.g[1], c.g[2])
		if [3]int{y, m, d} != c.j {
			t.Errorf("%v: got %d/%d/%d, want %v", c.g, y, m, d, c.j)
		}
	}
}

func TestFormatWhen(t *testing.T) {
	at := time.Date(2026, 10, 3, 20, 45, 0, 0, time.UTC) // 00:15 next day in Tehran
	if got := formatWhen(langFA, at); got != "⁨12 مهر 1405، 00:15⁩" {
		t.Errorf("fa: %q", got)
	}
	if got := formatWhen(langEN, at); got != "⁨4 Oct 2026, 00:15⁩" {
		t.Errorf("en: %q", got)
	}
}
