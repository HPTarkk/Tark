package admin

import (
	"fmt"
	"time"
	_ "time/tzdata" // the server may have no zone files
)

// Times show in Tehran time, where the panel's people are: the Persian
// calendar on Persian pages, "3 Oct 2026" on English ones.
var tehran = func() *time.Location {
	if l, err := time.LoadLocation("Asia/Tehran"); err == nil {
		return l
	}
	return time.FixedZone("IRST", 3*3600+1800)
}()

var persianMonths = [12]string{"فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور", "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"}

// jalali converts a Gregorian date to the Persian (Solar Hijri) calendar.
func jalali(gy, gm, gd int) (jy, jm, jd int) {
	gdm := [12]int{0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334}
	gy2 := gy
	if gm > 2 {
		gy2 = gy + 1
	}
	days := 355666 + 365*gy + (gy2+3)/4 - (gy2+99)/100 + (gy2+399)/400 + gd + gdm[gm-1]
	jy = -1595 + 33*(days/12053)
	days %= 12053
	jy += 4 * (days / 1461)
	days %= 1461
	if days > 365 {
		jy += (days - 1) / 365
		days = (days - 1) % 365
	}
	if days < 186 {
		return jy, 1 + days/31, 1 + days%31
	}
	return jy, 7 + (days-186)/30, 1 + (days-186)%30
}

// formatDate is a day: "11 مهر 1405" or "3 Oct 2026".
func formatDate(lang string, t time.Time) string {
	t = t.In(tehran)
	if lang == langFA {
		y, m, d := jalali(t.Year(), int(t.Month()), t.Day())
		return fmt.Sprintf("%d %s %d", d, persianMonths[m-1], y)
	}
	return t.Format("2 Jan 2006")
}

// formatWhen is a day and a time, isolated so its parts keep their order
// inside Persian text.
func formatWhen(lang string, t time.Time) string {
	sep := ", "
	if lang == langFA {
		sep = "، "
	}
	return "⁨" + formatDate(lang, t) + sep + t.In(tehran).Format("15:04") + "⁩"
}

// formatDay is the short chart label: "11 مهر" or "3 Oct".
func formatDay(lang string, t time.Time) string {
	t = t.In(tehran)
	if lang == langFA {
		_, m, d := jalali(t.Year(), int(t.Month()), t.Day())
		return fmt.Sprintf("%d %s", d, persianMonths[m-1])
	}
	return t.Format("2 Jan")
}
