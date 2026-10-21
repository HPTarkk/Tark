package admin

import "testing"

func TestMeterAndPercent(t *testing.T) {
	for _, c := range []struct {
		n, of int64
		want  int
	}{{0, 20, 0}, {1, 20, 1}, {4, 20, 2}, {20, 20, 10}, {30, 20, 10}, {3, 0, 0}} {
		if got := meter(c.n, c.of); got != c.want {
			t.Errorf("meter(%d, %d) = %d, want %d", c.n, c.of, got, c.want)
		}
	}
	for _, c := range []struct {
		ok, all int64
		want    string
	}{{0, 0, "-"}, {3, 3, "100%"}, {2, 3, "66%"}, {999, 1000, "99%"}} {
		if got := percent(c.ok, c.all); got != c.want {
			t.Errorf("percent(%d, %d) = %q, want %q", c.ok, c.all, got, c.want)
		}
	}
}
