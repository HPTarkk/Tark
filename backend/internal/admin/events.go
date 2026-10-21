package admin

import (
	"bytes"
	"encoding/json"
	"html/template"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/i18n"
)

// The event tables (admin actions, security events, an account's history)
// store a kind like "user.email_revealed" and a JSON object of details. The
// panel shows each kind as a short phrase with an icon and a colour, and the
// details as labelled chips, so nobody has to read codes or JSON. The code
// and the raw JSON stay on hover for anyone matching a page against the
// database or the logs.

// eventKind is how one kind looks: an icon from icons and a tone, one of
// good, bad, warn, info, accent or "" for neutral. Its words are the texts
// "ev.<kind>".
type eventKind struct{ icon, tone string }

var eventKinds = map[string]eventKind{
	// Admin actions (admin_events).
	"user.search":                     {"search", ""},
	"user.viewed":                     {"eye", ""},
	"user.email_revealed":             {"eye", "warn"},
	"user.disabled":                   {"ban", "bad"},
	"user.enabled":                    {"check", "good"},
	"user.signed_out":                 {"signout", "warn"},
	"user.deleted":                    {"trash", "bad"},
	"purchase.rechecked":              {"refresh", "info"},
	"subscription.suspicious_cleared": {"flag", "good"},
	"premium.granted":                 {"gift", "accent"},
	"premium.revoked":                 {"gift", "bad"},
	"mail.retry":                      {"send", "info"},
	"pricing.updated":                 {"pricing", "accent"},
	"admin.created":                   {"plus", "good"},
	"admin.enabled":                   {"check", "good"},
	"admin.disabled":                  {"ban", "bad"},
	"admin.reset":                     {"refresh", "warn"},
	"admin.login":                     {"signin", "good"},
	"admin.logout":                    {"signout", ""},
	"admin.login_failed":              {"alert", "bad"},
	"admin.login_throttled":           {"lock", "bad"},
	"admin.totp_enrolled":             {"phone", "good"},
	"admin.totp_failed":               {"alert", "bad"},
	"admin.totp_throttled":            {"lock", "bad"},
	"admin.password_changed":          {"key", "good"},
	"admin.password_change_failed":    {"key", "bad"},

	// Security events (audit_events, the audit package's kinds).
	"register.started":                 {"plus", "info"},
	"register.existing_email":          {"mail", "warn"},
	"register.completed":               {"check", "good"},
	"login.succeeded":                  {"signin", "good"},
	"login.failed":                     {"alert", "bad"},
	"login.throttled":                  {"lock", "bad"},
	"google.signed_in":                 {"globe", "good"},
	"google.signed_up":                 {"globe", "good"},
	"google.link_required":             {"globe", "warn"},
	"google.linked":                    {"globe", "good"},
	"google.link_failed":               {"globe", "bad"},
	"google.token_rejected":            {"ban", "bad"},
	"flow.code_failed":                 {"alert", "warn"},
	"flow.locked":                      {"lock", "bad"},
	"password.reset_requested":         {"key", "info"},
	"password.reset":                   {"key", "good"},
	"password.changed":                 {"key", "good"},
	"password.change_failed":           {"key", "bad"},
	"email.change_requested":           {"mail", "info"},
	"email.changed":                    {"mail", "good"},
	"session.refresh_reuse":            {"alert", "bad"},
	"session.logged_out":               {"signout", ""},
	"session.logged_out_all":           {"signout", "warn"},
	"account.deleted":                  {"trash", "bad"},
	"account.delete_failed":            {"trash", "warn"},
	"billing.purchase_verified":        {"card", "good"},
	"billing.purchase_owned_elsewhere": {"card", "warn"},
	"billing.purchase_refunded":        {"card", "bad"},
	"billing.purchase_invalid":         {"card", "bad"},

	// Subscription history (subscription_events).
	"verified":                    {"card", "good"},
	"renewed":                     {"refresh", "good"},
	"auto_renew_on":               {"refresh", "info"},
	"auto_renew_off":              {"refresh", ""},
	"refunded":                    {"card", "bad"},
	"suspicious_cleared":          {"flag", "good"},
	"suspicious_cleared_by_admin": {"flag", "good"},
	"premium_granted":             {"gift", "accent"},
	"premium_revoked":             {"gift", "bad"},
}

// eventTexts are the words for kinds, detail names and detail values. They
// join texts at start-up so tr finds them like any other text.
var eventTexts = map[string][2]string{
	"ev.user.search":                     {"Searched for an account", "جستجوی حساب"},
	"ev.user.viewed":                     {"Opened an account", "دیدن حساب"},
	"ev.user.email_revealed":             {"Revealed an email", "دیدن ایمیل کامل"},
	"ev.user.disabled":                   {"Disabled an account", "غیرفعال‌کردن حساب"},
	"ev.user.enabled":                    {"Enabled an account", "فعال‌کردن حساب"},
	"ev.user.signed_out":                 {"Signed out everywhere", "خارج‌کردن از همه‌ی دستگاه‌ها"},
	"ev.user.deleted":                    {"Deleted an account", "حذف حساب"},
	"ev.purchase.rechecked":              {"Rechecked a purchase", "بررسی دوباره‌ی خرید"},
	"ev.subscription.suspicious_cleared": {"Cleared the suspicious flag", "برداشتن علامت مشکوک"},
	"ev.premium.granted":                 {"Gave premium", "هدیه‌دادن پریمیوم"},
	"ev.premium.revoked":                 {"Took premium back", "پس‌گرفتن پریمیوم"},
	"ev.mail.retry":                      {"Resent stuck emails", "فرستادن دوباره‌ی ایمیل‌ها"},
	"ev.pricing.updated":                 {"Changed prices", "تغییر قیمت‌ها"},
	"ev.admin.created":                   {"Added an admin", "اضافه‌کردن مدیر"},
	"ev.admin.enabled":                   {"Enabled an admin", "فعال‌کردن مدیر"},
	"ev.admin.disabled":                  {"Disabled an admin", "غیرفعال‌کردن مدیر"},
	"ev.admin.reset":                     {"Reset an admin's sign-in", "بازنشانی ورود مدیر"},
	"ev.admin.login":                     {"Signed in", "ورود به پنل"},
	"ev.admin.logout":                    {"Signed out", "خروج از پنل"},
	"ev.admin.login_failed":              {"Failed sign-in", "ورود ناموفق"},
	"ev.admin.login_throttled":           {"Too many sign-ins", "ورود بیش از حد"},
	"ev.admin.totp_enrolled":             {"Set up the authenticator", "راه‌اندازی برنامه‌ی تأیید"},
	"ev.admin.totp_failed":               {"Wrong authenticator code", "کد تأیید اشتباه"},
	"ev.admin.totp_throttled":            {"Too many authenticator codes", "کد تأیید بیش از حد"},
	"ev.admin.password_changed":          {"Changed password", "تغییر رمز"},
	"ev.admin.password_change_failed":    {"Password change failed", "تغییر رمز ناموفق"},

	"ev.register.started":                 {"Sign-up started", "شروع ثبت‌نام"},
	"ev.register.existing_email":          {"Sign-up with a taken email", "ثبت‌نام با ایمیل تکراری"},
	"ev.register.completed":               {"Signed up", "ثبت‌نام کامل شد"},
	"ev.login.succeeded":                  {"Signed in", "ورود"},
	"ev.login.failed":                     {"Failed sign-in", "ورود ناموفق"},
	"ev.login.throttled":                  {"Too many sign-ins", "ورود بیش از حد"},
	"ev.google.signed_in":                 {"Signed in with Google", "ورود با گوگل"},
	"ev.google.signed_up":                 {"Signed up with Google", "ثبت‌نام با گوگل"},
	"ev.google.link_required":             {"Google needs linking", "گوگل باید وصل بشه"},
	"ev.google.linked":                    {"Linked Google", "گوگل وصل شد"},
	"ev.google.link_failed":               {"Google link failed", "وصل‌کردن گوگل ناموفق"},
	"ev.google.token_rejected":            {"Google token refused", "توکن گوگل رد شد"},
	"ev.flow.code_failed":                 {"Wrong email code", "کد ایمیل اشتباه"},
	"ev.flow.locked":                      {"Code locked", "کد قفل شد"},
	"ev.password.reset_requested":         {"Asked to reset password", "درخواست بازیابی رمز"},
	"ev.password.reset":                   {"Reset password", "بازیابی رمز"},
	"ev.password.changed":                 {"Changed password", "تغییر رمز"},
	"ev.password.change_failed":           {"Password change failed", "تغییر رمز ناموفق"},
	"ev.email.change_requested":           {"Asked to change email", "درخواست تغییر ایمیل"},
	"ev.email.changed":                    {"Changed email", "تغییر ایمیل"},
	"ev.session.refresh_reuse":            {"Session token reused", "توکن نشست دوباره استفاده شد"},
	"ev.session.logged_out":               {"Signed out", "خروج"},
	"ev.session.logged_out_all":           {"Signed out everywhere", "خروج از همه‌ی دستگاه‌ها"},
	"ev.account.deleted":                  {"Deleted the account", "حذف حساب"},
	"ev.account.delete_failed":            {"Account deletion failed", "حذف حساب ناموفق"},
	"ev.billing.purchase_verified":        {"Purchase verified", "خرید تأیید شد"},
	"ev.billing.purchase_owned_elsewhere": {"Purchase belongs to another account", "خرید مال حساب دیگه‌ایه"},
	"ev.billing.purchase_refunded":        {"Purchase refunded", "پول خرید برگشت"},
	"ev.billing.purchase_invalid":         {"Invalid purchase", "خرید نامعتبر"},

	"ev.verified":                    {"Purchase verified", "خرید تأیید شد"},
	"ev.renewed":                     {"Renewed", "تمدید شد"},
	"ev.auto_renew_on":               {"Auto-renew turned on", "تمدید خودکار روشن شد"},
	"ev.auto_renew_off":              {"Auto-renew turned off", "تمدید خودکار خاموش شد"},
	"ev.refunded":                    {"Refunded", "پول برگشت"},
	"ev.suspicious_cleared":          {"Suspicious flag lifted", "علامت مشکوک برداشته شد"},
	"ev.suspicious_cleared_by_admin": {"Suspicious flag cleared by an admin", "علامت مشکوک رو مدیر برداشت"},
	"ev.premium_granted":             {"Premium given", "پریمیوم هدیه داده شد"},
	"ev.premium_revoked":             {"Premium taken back", "پریمیوم پس گرفته شد"},

	// Detail names.
	"dk.reason":      {"Reason", "دلیل"},
	"dk.email":       {"Email", "ایمیل"},
	"dk.role":        {"Role", "نقش"},
	"dk.admin":       {"Admin", "مدیر"},
	"dk.by":          {"By", "توسط"},
	"dk.months":      {"Length", "مدت"},
	"dk.until":       {"Until", "تا"},
	"dk.grant":       {"Gift", "هدیه"},
	"dk.emails":      {"Emails", "ایمیل‌ها"},
	"dk.found":       {"Found", "پیدا شد"},
	"dk.known":       {"Has an account", "حساب داره"},
	"dk.purpose":     {"For", "برای"},
	"dk.attempt":     {"Attempt", "تلاش"},
	"dk.via":         {"Via", "با"},
	"dk.method":      {"Method", "روش"},
	"dk.sku":         {"Product", "محصول"},
	"dk.state":       {"State", "وضعیت"},
	"dk.base":        {"Monthly price", "قیمت ماهانه"},
	"dk.adjustment":  {"Overall multiplier", "ضریب کلی"},
	"dk.multipliers": {"Multipliers", "ضریب‌ها"},
	"dk.roundTo":     {"Round to", "گرد کردن به"},
	"dk.ending":      {"Take off", "کم‌کردن"},

	// Detail values.
	"dv.yes":                     {"yes", "بله"},
	"dv.no":                      {"no", "نه"},
	"dv.months":                  {"%v months", "%v ماه"},
	"dv.month":                   {"1 month", "1 ماه"},
	"dv.emails":                  {"%v emails", "%v ایمیل"},
	"dv.toman":                   {"%v Toman", "%v تومان"},
	"dv.attempt":                 {"#%v", "بار %v"},
	"dv.purpose.register":        {"sign-up", "ثبت‌نام"},
	"dv.purpose.password_reset":  {"password reset", "بازیابی رمز"},
	"dv.purpose.email_change":    {"email change", "تغییر ایمیل"},
	"dv.via.link":                {"email link", "لینک ایمیل"},
	"dv.via.code":                {"email code", "کد ایمیل"},
	"dv.method.password":         {"password", "رمز"},
	"dv.by.admin":                {"an admin", "یه مدیر"},
	"dv.reason.token_revoked":    {"Bazaar revoked the purchase", "بازار خرید رو باطل کرد"},
	"dv.reason.period_shortened": {"Bazaar shortened the period", "بازار مدت رو کوتاه کرد"},
}

// The prefixes of the texts above.
const kindText, keyText, valueText = "ev.", "dk.", "dv."

func init() {
	icons["signin"] = `<path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/><path d="m10 17 5-5-5-5M15 12H3"/>`
	icons["key"] = icons["admins"]
	for k, v := range eventTexts {
		texts[k] = v
	}
}

// eventLabel shows a kind as an icon and a phrase in a tone. A kind the
// panel has no words for keeps its code, so a new kind is never hidden.
func eventLabel(lang, kind string) template.HTML {
	k, ok := eventKinds[kind]
	if !ok {
		return template.HTML(`<code class="kind">` + template.HTMLEscapeString(kind) + `</code>`)
	}
	tone := ""
	if k.tone != "" {
		tone = " t-" + k.tone
	}
	return template.HTML(`<span class="ev` + tone + `" title="` + template.HTMLEscapeString(kind) + `"><span class="ev-i">` +
		string(icon(k.icon)) + `</span><span class="ev-t">` + template.HTMLEscapeString(tr(lang, kindText+kind)) + `</span></span>`)
}

// detailOrder puts the details people look for first; any other key
// follows in alphabetical order.
var detailOrder = []string{"reason", "email", "role", "admin", "by", "months", "until", "sku", "state", "purpose", "via", "method",
	"known", "found", "attempt", "emails", "base", "adjustment", "multipliers", "roundTo", "ending", "grant"}

var uuidish = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// eventDetails shows a details object as one chip per value. An empty
// object shows nothing; anything that is not an object shows as it is.
func eventDetails(lang, raw string) template.HTML {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "{}" || raw == "null" {
		return ""
	}
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.UseNumber()
	var obj map[string]any
	if err := dec.Decode(&obj); err != nil {
		return template.HTML(`<code class="raw">` + template.HTMLEscapeString(raw) + `</code>`)
	}
	if len(obj) == 0 {
		return ""
	}
	rank := map[string]int{}
	for i, k := range detailOrder {
		rank[k] = i + 1
	}
	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		ri, rj := rank[keys[i]], rank[keys[j]]
		if ri == 0 {
			ri = len(detailOrder) + 1
		}
		if rj == 0 {
			rj = len(detailOrder) + 1
		}
		if ri != rj {
			return ri < rj
		}
		return keys[i] < keys[j]
	})
	var b bytes.Buffer
	b.WriteString(`<div class="kvs" title="` + template.HTMLEscapeString(raw) + `">`)
	for _, k := range keys {
		name := k
		if _, ok := texts["dk."+k]; ok {
			name = tr(lang, keyText+k)
		}
		class := "kv"
		if k == "reason" {
			if _, coded := texts["dv.reason."+fmtScalar(obj[k])]; !coded {
				class += " note"
			}
		}
		b.WriteString(`<span class="` + class + `"><span class="k">` + template.HTMLEscapeString(name) + `</span>`)
		b.WriteString(detailValue(lang, k, obj[k]))
		b.WriteString(`</span>`)
	}
	b.WriteString(`</div>`)
	return template.HTML(b.String())
}

// detailValue is one value as HTML: known codes in words, numbers and
// prices grouped, dates in the page's calendar, ids shortened, and
// addresses and codes kept left to right.
func detailValue(lang, key string, v any) string {
	esc := template.HTMLEscapeString
	plain := func(s string) string { return `<span class="v">` + esc(s) + `</span>` }
	ltr := func(s, title string) string {
		t := ""
		if title != "" {
			t = ` title="` + esc(title) + `"`
		}
		return `<bdi class="v ltr" dir="ltr"` + t + `>` + esc(s) + `</bdi>`
	}
	switch x := v.(type) {
	case nil:
		return plain("-")
	case bool:
		if x {
			return plain(tr(lang, "dv.yes"))
		}
		return plain(tr(lang, "dv.no"))
	case json.Number:
		n, isInt := x.Int64()
		switch {
		case key == "months" && isInt == nil && n == 1:
			return plain(tr(lang, "dv.month"))
		case key == "months":
			return plain(tr(lang, "dv.months", x.String()))
		case key == "attempt":
			return plain(tr(lang, "dv.attempt", x.String()))
		case (key == "base" || key == "roundTo" || key == "ending") && isInt == nil:
			return plain(tr(lang, "dv.toman", i18n.GroupedDigits(i18n.EN, n)))
		case key == "adjustment":
			return ltr("×"+x.String(), "")
		case isInt == nil:
			return plain(i18n.GroupedDigits(i18n.EN, n))
		}
		return plain(x.String())
	case string:
		switch {
		case key == "role" || key == "state":
			if _, ok := texts[key+"."+x]; ok {
				return `<span class="v chip ` + map[string]string{"role": "role-", "state": "st-"}[key] + esc(x) + `">` + esc(tr(lang, key+"."+x)) + `</span>`
			}
		case key == "until":
			if t, err := time.Parse(time.RFC3339, x); err == nil {
				return plain(formatWhen(lang, t))
			}
		case key == "email" || key == "sku":
			return ltr(x, "")
		case uuidish.MatchString(x):
			return ltr(x[:8], x)
		}
		if _, ok := texts["dv."+key+"."+x]; ok {
			return plain(tr(lang, valueText+key+"."+x))
		}
		return `<bdi class="v">` + esc(x) + `</bdi>`
	case map[string]any:
		// Multipliers read smallest first: 1m ×1, 3m ×2.7, 12m ×9.
		ks := make([]string, 0, len(x))
		for k := range x {
			ks = append(ks, k)
		}
		num := func(k string) float64 { f, _ := strconv.ParseFloat(fmtScalar(x[k]), 64); return f }
		sort.Slice(ks, func(i, j int) bool {
			if a, b := num(ks[i]), num(ks[j]); a != b {
				return a < b
			}
			return ks[i] < ks[j]
		})
		parts := make([]string, 0, len(ks))
		for _, k := range ks {
			parts = append(parts, `<bdi class="ltr" dir="ltr">`+esc(k)+` ×`+esc(fmtScalar(x[k]))+`</bdi>`)
		}
		return `<span class="v list">` + strings.Join(parts, `<span class="sep" aria-hidden="true">·</span>`) + `</span>`
	case []any:
		parts := make([]string, 0, len(x))
		for _, e := range x {
			parts = append(parts, `<bdi>`+esc(fmtScalar(e))+`</bdi>`)
		}
		return `<span class="v list">` + strings.Join(parts, `<span class="sep" aria-hidden="true">·</span>`) + `</span>`
	}
	return plain(fmtScalar(v))
}

func fmtScalar(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case json.Number:
		return x.String()
	case bool:
		return strconv.FormatBool(x)
	}
	b, _ := json.Marshal(v)
	return string(b)
}
