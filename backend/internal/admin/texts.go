package admin

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
)

// The panel speaks Persian (the default) and English. The choice lives in a
// cookie set by /lang/{code}; every page and every message is looked up in
// texts. Numbers, dates and codes stay in Latin digits in both languages, so
// prices and ids can be copied as they are.
const (
	langFA = "fa"
	langEN = "en"
	// defaultLang is used until someone picks a language.
	defaultLang = langFA
	langCookie  = "tark_admin_lang"
)

func validLang(l string) bool { return l == langFA || l == langEN }

// langOf reads the language cookie; anything missing or unknown is Persian.
func langOf(r *http.Request) string {
	if c, err := r.Cookie(langCookie); err == nil && validLang(c.Value) {
		return c.Value
	}
	return defaultLang
}

const keyLang ctxKey = 100

func langFrom(ctx context.Context) string {
	if l, ok := ctx.Value(keyLang).(string); ok {
		return l
	}
	return defaultLang
}

// withLang puts the request's language in its context.
func withLang(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), keyLang, langOf(r))))
	})
}

// setLang stores the chosen language for a year and goes back to the page
// the switch was pressed on. The panel sends no Referer, so the page passes
// its own path in next.
func (s *Server) setLang(w http.ResponseWriter, r *http.Request) {
	code := chi.URLParam(r, "code")
	if !validLang(code) {
		http.NotFound(w, r)
		return
	}
	s.setCookie(w, langCookie, code, 365*24*time.Hour)
	http.Redirect(w, r, safeNext(r.URL.Query().Get("next")), http.StatusSeeOther)
}

// safeNext keeps only a path on this site.
func safeNext(next string) string {
	u, err := url.Parse(next)
	if err != nil || u.Scheme != "" || u.Host != "" || !strings.HasPrefix(u.Path, "/") ||
		strings.HasPrefix(next, "//") || strings.Contains(next, "\\") {
		return "/"
	}
	return u.RequestURI()
}

// here is where the language switch comes back to: the page itself, or for
// a form result the nearest page above it that can be opened again
// (/users/{id}/grant goes back to /users/{id}).
func (s *Server) here(r *http.Request) string {
	if r.Method == http.MethodGet {
		return r.URL.RequestURI()
	}
	if r.URL.Path == "/logout" {
		return "/login"
	}
	p := r.URL.Path
	for p != "" && p != "/" {
		if s.router != nil && s.router.Match(chi.NewRouteContext(), http.MethodGet, p) {
			return p
		}
		p = p[:strings.LastIndex(p, "/")]
	}
	return "/"
}

// tr looks a text up and fills in args with fmt.Sprintf. An unknown key comes
// back as itself in brackets, so a gap shows on the page; TestEveryTextKnown
// keeps that from shipping.
func tr(lang, key string, args ...any) string {
	t, ok := texts[key]
	if !ok {
		return "[" + key + "]"
	}
	s := t[0]
	if lang == langFA {
		s = t[1]
	}
	if len(args) > 0 {
		s = fmt.Sprintf(s, args...)
	}
	return s
}

// T translates for the language of the request in ctx.
func T(ctx context.Context, key string, args ...any) string { return tr(langFrom(ctx), key, args...) }

// texts holds {English, Persian} for every key. Persian is casual, like the app.
var texts = map[string][2]string{
	// layout
	"brand":          {"Tarkk admin", "پنل مدیریت تَرک"},
	"lang.other":     {"فارسی", "English"},
	"lang.otherCode": {"fa", "en"},
	"lang.otherName": {"Persian", "انگلیسی"},
	"sep":            {", ", "، "},
	"nav.dashboard":  {"Dashboard", "داشبورد"},
	"nav.system":     {"System", "سیستم"},
	"nav.users":      {"Users", "کاربرها"},
	"nav.security":   {"Security", "امنیت"},
	"nav.mail":       {"Mail", "ایمیل‌ها"},
	"nav.pricing":    {"Pricing", "قیمت‌ها"},
	"nav.backups":    {"Backups", "پشتیبان‌ها"},
	"nav.admins":     {"Admins", "مدیرها"},
	"nav.activity":   {"Activity", "فعالیت‌ها"},
	"nav.logs":       {"Logs", "لاگ‌ها"},
	"nav.account":    {"Account", "حساب من"},
	"signout":        {"Sign out", "خروج"},
	"signout.q":      {"Sign out?", "از پنل خارج می‌شی؟"},
	"signout.x":      {"To come back you'll need your password and a code from your authenticator.", "برای برگشتن، رمزت و یه کد از برنامه‌ی احراز هویت لازمه."},
	"nav.gOverview":  {"Overview", "نمای کلی"},
	"nav.gAccounts":  {"Accounts", "حساب‌ها"},
	"nav.gManage":    {"Manage", "مدیریت"},
	"menu":           {"Menu", "منو"},
	"menuClose":      {"Close menu", "بستن منو"},
	"lead.dashboard": {"Everything at a glance.", "همه‌چیز توی یه نگاه."},
	"lead.system":    {"Health checks, traffic and the server itself.", "سلامت سرویس، ترافیک و خود سرور."},
	"lead.security":  {"Sign-in trouble and account safety.", "مشکلات ورود و امنیت حساب‌ها."},
	"lead.mail":      {"What the server sent and what is still waiting.", "ایمیل‌هایی که سرور فرستاده و اونایی که هنوز توی صفن."},
	"lead.admins":    {"Who can open this panel and what they can do.", "کی می‌تونه این پنل رو باز کنه و چه کارهایی ازش برمیاد."},
	"lead.activity":  {"Everything admins did, newest first.", "هر کاری که مدیرها کردن، جدیدترها اول."},
	"lead.logs":      {"Search the server's log files.", "توی فایل‌های لاگ سرور بگرد."},
	"back":           {"Back", "برگشت"},

	// shared words
	"yes":               {"yes", "بله"},
	"on":                {"on", "روشن"},
	"off":               {"off", "خاموش"},
	"ok":                {"ok", "سالم"},
	"none":              {"None.", "هیچی."},
	"nothing":           {"Nothing.", "چیزی نیست."},
	"never":             {"never", "هیچ‌وقت"},
	"ago.now":           {"just now", "همین الان"},
	"ago.m":             {"%dm ago", "%d دقیقه پیش"},
	"ago.h":             {"%dh ago", "%d ساعت پیش"},
	"ago.d":             {"%dd ago", "%d روز پیش"},
	"last24":            {"Last 24 hours", "24 ساعت اخیر"},
	"role.owner":        {"owner", "مالک"},
	"role.support":      {"support", "پشتیبانی"},
	"role.viewer":       {"viewer", "بیننده"},
	"status.active":     {"active", "فعال"},
	"status.disabled":   {"disabled", "غیرفعال"},
	"state.pending":     {"pending", "در انتظار"},
	"state.active":      {"active", "فعال"},
	"state.expired":     {"expired", "تموم‌شده"},
	"state.refunded":    {"refunded", "پول برگشته"},
	"state.invalid":     {"invalid", "نامعتبر"},
	"label.name":        {"Name", "اسم"},
	"label.email":       {"Email", "ایمیل"},
	"label.role":        {"Role", "نقش"},
	"label.password":    {"Password", "رمز"},
	"label.code":        {"Code", "کد"},
	"label.reason":      {"Reason", "دلیل"},
	"label.months":      {"Months", "ماه"},
	"btn.enable":        {"Enable", "فعال کن"},
	"btn.disable":       {"Disable", "غیرفعال کن"},
	"btn.add":           {"Add", "اضافه کن"},
	"btn.continue":      {"Continue", "ادامه"},
	"btn.search":        {"Search", "جستجو"},
	"btn.save":          {"Save", "ذخیره کن"},
	"btn.cancel":        {"Cancel", "انصراف"},
	"btn.find":          {"Find", "پیدا کن"},
	"btn.revoke":        {"Revoke", "لغو کن"},
	"col.when":          {"When", "زمان"},
	"col.admin":         {"Admin", "مدیر"},
	"col.action":        {"Action", "کار"},
	"col.account":       {"Account", "حساب"},
	"col.details":       {"Details", "جزئیات"},
	"col.name":          {"Name", "اسم"},
	"col.email":         {"Email", "ایمیل"},
	"col.role":          {"Role", "نقش"},
	"col.authenticator": {"Authenticator", "احراز هویت"},
	"col.lastSignin":    {"Last sign-in", "آخرین ورود"},
	"col.started":       {"Started", "شروع"},
	"col.result":        {"Result", "نتیجه"},
	"col.file":          {"File", "فایل"},
	"col.size":          {"Size", "حجم"},
	"col.rows":          {"Rows", "ردیف‌ها"},
	"col.dayUTC":        {"Day (UTC)", "روز (UTC)"},
	"col.sizeDisk":      {"Size on disk", "حجم روی دیسک"},
	"col.kind":          {"Kind", "نوع"},
	"col.sent":          {"Sent", "فرستاده‌شده"},
	"col.dropped":       {"Dropped", "ازدست‌رفته"},
	"col.waiting":       {"Waiting", "در صف"},
	"col.mostTries":     {"Most tries of a waiting one", "بیشترین تلاش برای یکی از صف"},
	"col.plan":          {"Plan", "اشتراک"},
	"col.sku":           {"Product id", "شناسه‌ی محصول"},
	"col.multiplier":    {"Multiplier", "ضریب"},
	"col.exact":         {"Exact", "دقیق"},
	"col.toman":         {"Price (Toman)", "قیمت (تومان)"},
	"col.rial":          {"Type in Bazaar (Rial)", "برای بازار (ریال)"},
	"col.perMonth":      {"Per month", "ماهانه"},
	"col.saves":         {"Saves", "تخفیف"},
	"col.event":         {"Event", "رویداد"},
	"col.count":         {"Count", "تعداد"},
	"col.source":        {"Source", "منبع"},
	"col.route":         {"Route", "مسیر"},
	"col.requests":      {"Requests", "درخواست‌ها"},
	"col.slow":          {"Slow", "کند"},
	"col.typical":       {"Typical", "معمولی"},
	"col.slowest":       {"Slowest 5%", "کندترین 5%"},
	"col.address":       {"Address", "آدرس"},
	"col.primary":       {"Primary", "اصلی"},
	"col.verified":      {"Verified", "تأییدشده"},
	"col.removed":       {"Removed", "حذف‌شده"},
	"col.state":         {"State", "وضعیت"},
	"col.validUntil":    {"Valid until", "معتبر تا"},
	"col.autoRenew":     {"Auto-renew", "تمدید خودکار"},
	"col.refunded":      {"Refunded", "برگشت پول"},
	"col.lastVerified":  {"Last verified", "آخرین بررسی"},
	"col.failedChecks":  {"Failed checks", "بررسی‌های ناموفق"},
	"col.bought":        {"Bought", "خرید"},
	"col.from":          {"From", "از"},
	"col.until":         {"Until", "تا"},
	"col.by":            {"By", "توسط"},
	"col.reason":        {"Reason", "دلیل"},
	"col.platform":      {"Platform", "پلتفرم"},
	"col.signedIn":      {"Signed in", "ورود"},
	"col.lastUsed":      {"Last used", "آخرین استفاده"},
	"col.ended":         {"Ended", "پایان"},

	// activity
	"activity.h": {"Admin activity", "کارهای مدیرها"},

	// admins
	"admins.tempFor":     {"One-time password for", "رمز یک‌بارمصرف برای"},
	"admins.tempNote":    {"It is shown only now. Give it to them privately; at first sign-in they choose their own password and set up their authenticator.", "فقط همین الان نشون داده می‌شه. خصوصی بهش بده؛ بار اول که وارد بشه، رمز خودش رو انتخاب می‌کنه و احراز هویتش رو راه می‌ندازه."},
	"admins.set":         {"set", "فعال"},
	"admins.notYet":      {"not yet", "هنوز نه"},
	"admins.newPw":       {"New password", "رمز جدید"},
	"admins.you":         {"you", "خودت"},
	"admins.addLead":     {"They get a one-time password to sign in with.", "یه رمز یک‌بارمصرف می‌گیره که باهاش وارد بشه."},
	"admins.addH":        {"Add an admin", "اضافه کردن مدیر"},
	"admins.optViewer":   {"viewer: dashboard only", "بیننده: فقط داشبورد"},
	"admins.optSupport":  {"support: dashboard, users, security, mail", "پشتیبانی: داشبورد، کاربرها، امنیت، ایمیل‌ها"},
	"admins.optOwner":    {"owner: everything, manages admins", "مالک: همه‌چیز، مدیرها رو هم مدیریت می‌کنه"},
	"admins.selfDisable": {"You cannot disable yourself.", "نمی‌تونی خودت رو غیرفعال کنی."},
	"admins.selfReset":   {"Change your own password on the Account page.", "رمز خودت رو از صفحه‌ی «حساب من» عوض کن."},
	"admins.badRole":     {"The role must be owner, support or viewer.", "نقش باید مالک، پشتیبانی یا بیننده باشه."},
	"admins.badEmail":    {"That is not an email address.", "این آدرس ایمیل نیست."},
	"admins.badName":     {"The name must be 1 to 64 characters.", "اسم باید بین 1 تا 64 کاراکتر باشه."},
	"admins.exists":      {"An admin with that email already exists.", "یه مدیر با این ایمیل از قبل هست."},

	// backups
	"backups.lead":    {"One encrypted backup a night, kept 14 days on the server. Copy them to your computer with fetch-backups.ps1.", "هر شب یه پشتیبان رمزگذاری‌شده گرفته می‌شه و 14 روز روی سرور می‌مونه. با fetch-backups.ps1 روی کامپیوترت کپی‌شون کن."},
	"backups.ok":      {"ok", "موفق"},
	"backups.failed":  {"failed: %v", "ناموفق: %v"},
	"backups.running": {"running", "در حال اجرا"},
	"backups.none":    {"No backups yet.", "هنوز پشتیبانی نیست."},

	// dashboard
	"dash.alerts":       {"Alerts firing:", "هشدارهای فعال:"},
	"dash.alertsMore":   {"Details are in the alert emails.", "جزئیات توی ایمیل‌های هشدار هست."},
	"dash.accounts":     {"Accounts", "حساب‌ها"},
	"dash.subscribers":  {"Subscribers", "مشترک‌ها"},
	"dash.noPlans":      {"No active plans", "اشتراک فعالی نیست"},
	"dash.delta7":       {"+%v in 7 days", "+%v در 7 روز"},
	"dash.subsSub":      {"%v new in 30 days", "%v خرید تازه در 30 روز"},
	"dash.activeH":      {"Active this week", "فعال در 7 روز"},
	"dash.activeSub":    {"signed-in accounts that used the app", "حساب‌های واردشده‌ای که از برنامه استفاده کردن"},
	"dash.failedH":      {"Failed sign-ins", "ورودهای ناموفق"},
	"dash.failedSub":    {"sign-ins and codes, last 24 hours", "ورود و کد، 24 ساعت اخیر"},
	"dash.seeSystem":    {"Open System", "برو به سیستم"},
	"dash.byPlan":       {"By plan", "به تفکیک اشتراک"},
	"dash.r.new30":      {"New in 30 days", "تازه در 30 روز"},
	"dash.r.email30":    {"Signed up with email (30 days)", "ثبت‌نام با ایمیل (30 روز)"},
	"dash.r.google30":   {"Google only (30 days)", "فقط با گوگل (30 روز)"},
	"dash.r.deleted30":  {"Deleted (30 days)", "حذف‌شده (30 روز)"},
	"dash.r.disabled":   {"Disabled", "غیرفعال"},
	"dash.r.ended30":    {"Ended (30 days)", "تموم‌شده (30 روز)"},
	"dash.r.renewOff":   {"Active with auto-renew off", "فعال با تمدید خودکار خاموش"},
	"dash.r.expiring7":  {"Of those, ending within 7 days", "از اینا، تا 7 روز دیگه تموم می‌شن"},
	"dash.r.refunded30": {"Refunded (30 days)", "برگشت پول (30 روز)"},
	"dash.r.suspicious": {"Flagged suspicious", "علامت مشکوک"},
	"dash.r.grants":     {"Premium given by hand", "نسخه ویژه‌ی دستی"},
	"dash.r.mailSent":   {"Emails sent", "ایمیل فرستاده‌شده"},
	"dash.r.mailFailed": {"Emails dropped", "ایمیل ازدست‌رفته"},
	"dash.r.mailWait":   {"Emails waiting", "ایمیل توی صف"},
	"dash.r.failed":     {"Failed sign-ins and codes", "ورود و کدهای ناموفق"},
	"dash.r.lockouts":   {"Lockouts", "قفل‌شدن‌ها"},
	"dash.r.reuse":      {"Reused refresh tokens", "توکن‌های تکراری"},
	"dash.r.backup":     {"Last good backup", "آخرین پشتیبان موفق"},
	"dash.revenue":      {"Revenue is in the Bazaar developer console.", "درآمد توی پنل توسعه‌دهنده‌ی بازار هست."},
	"dash.backupFailed": {"last attempt failed", "آخرین تلاش ناموفق بود"},
	"dash.perDay":       {"New accounts per day (30 days)", "حساب‌های تازه در هر روز (30 روز)"},

	// sign-in
	"login.title":   {"Sign in", "ورود"},
	"login.lead":    {"Sign in with your admin email and password.", "با ایمیل و رمز مدیریتت وارد شو."},
	"login.expired": {"The form expired. Try again.", "فرم منقضی شد. دوباره امتحان کن."},
	"login.wrong":   {"Wrong email or password.", "ایمیل یا رمز اشتباهه."},
	"login.tooMany": {"Too many attempts. Wait 15 minutes.", "تلاش‌ها زیاد شد. 15 دقیقه صبر کن."},

	// authenticator
	"totp.title":      {"Code", "کد ورود"},
	"totp.enrollH":    {"Set up your authenticator", "احراز هویتت رو راه بنداز"},
	"totp.enrollLead": {"Every sign-in needs a code from an authenticator app (Google Authenticator, Microsoft Authenticator, Aegis, 2FAS…).", "هر بار ورود، یه کد از برنامه‌ی احراز هویت لازمه (Google Authenticator، Microsoft Authenticator، Aegis، 2FAS…)."},
	"totp.step1a":     {"On this phone,", "اگه با همین گوشی اومدی،"},
	"totp.step1link":  {"tap here to add Tarkk admin to your authenticator app", "اینجا بزن تا پنل تَرک به برنامه‌ی احراز هویتت اضافه بشه"},
	"totp.step1b":     {". On a computer, add an account in the app by hand with this key:", ". روی کامپیوتر، توی برنامه دستی یه حساب با این کلید اضافه کن:"},
	"totp.step2":      {"Type the 6-digit code the app shows.", "کد 6 رقمی‌ای که برنامه نشون می‌ده رو بنویس."},
	"totp.enterH":     {"Enter your code", "کدت رو وارد کن"},
	"totp.enterLead":  {"Open your authenticator app and type the 6-digit code for Tarkk admin.", "برنامه‌ی احراز هویتت رو باز کن و کد 6 رقمی پنل تَرک رو بنویس."},
	"totp.signin":     {"Sign in", "ورود"},
	"totp.tooMany":    {"Too many wrong codes. Wait 15 minutes, then sign in again.", "کدهای اشتباه زیاد شد. 15 دقیقه صبر کن، بعد دوباره وارد شو."},
	"totp.wrong":      {"That code is not right. Check the time on your phone and try the newest code.", "این کد درست نیست. ساعت گوشی‌ات رو چک کن و جدیدترین کد رو امتحان کن."},
	"totp.used":       {"That code was already used. Wait for the next one.", "این کد قبلاً استفاده شده. صبر کن کد بعدی بیاد."},

	// logs
	"logs.off":         {"Log files are off on this server (TARK_LOG_DIR is not set).", "فایل‌های لاگ روی این سرور خاموشه (TARK_LOG_DIR تنظیم نشده)."},
	"logs.placeholder": {"Text to find, e.g. backup or a request id", "متن برای جستجو، مثلاً backup یا شناسه‌ی یه درخواست"},
	"logs.all":         {"Everything", "همه"},
	"logs.warn":        {"Warnings and errors", "هشدارها و خطاها"},
	"logs.errors":      {"Errors only", "فقط خطاها"},
	"logs.today":       {"Today", "امروز"},
	"logs.lastDays":    {"Last %v days", "%v روز اخیر"},
	"logs.note":        {"Newest first, at most %v lines.", "جدیدترها اول، حداکثر %v خط."},
	"logs.cut":         {"There are more; narrow the search.", "بیشتر هم هست؛ جستجو رو دقیق‌تر کن."},
	"logs.note2":       {"Times are UTC. The log has no IP addresses or tokens.", "زمان‌ها به وقت UTC هستن. توی لاگ هیچ آدرس IP یا توکنی نیست."},
	"logs.none":        {"Nothing matches.", "چیزی پیدا نشد."},
	"logs.kept":        {"Kept days", "روزهای نگه‌داشته‌شده"},
	"logs.download":    {"Download a whole day on your computer with: bash remote.sh log-day YYYY-MM-DD", "برای گرفتن یه روز کامل روی کامپیوترت: bash remote.sh log-day YYYY-MM-DD"},

	// mail
	"mail.h":     {"Email, last 7 days", "ایمیل‌ها، 7 روز اخیر"},
	"mail.none":  {"No email in 7 days.", "تو 7 روز ایمیلی نبوده."},
	"mail.retry": {"Retry every waiting email now", "همه‌ی ایمیل‌های توی صف رو الان دوباره بفرست"},
	"mail.note":  {"Sent emails are wiped from the database right away; only these counts remain, for 7 days.", "ایمیل‌های فرستاده‌شده همون موقع از پایگاه داده پاک می‌شن؛ فقط همین شمارش‌ها 7 روز می‌مونن."},

	// messages
	"msg.notFoundT":    {"Not found", "پیدا نشد"},
	"msg.notFoundX":    {"There is no such page.", "همچین صفحه‌ای نداریم."},
	"msg.expiredT":     {"Form expired", "فرم منقضی شده"},
	"msg.expiredX":     {"That form was too old or came from somewhere else. Go back, reload and try again.", "این فرم خیلی قدیمی بود یا از جای دیگه‌ای اومده. برگرد، صفحه رو تازه کن و دوباره امتحان کن."},
	"msg.expiredShort": {"Form expired.", "فرم منقضی شده."},
	"msg.role":         {"Your role cannot open this page.", "نقشت اجازه‌ی باز کردن این صفحه رو نمی‌ده."},
	"msg.fail":         {"Something went wrong. It has been logged.", "یه مشکلی پیش اومد. ثبتش کردیم."},
	"msg.noUserT":      {"No such account", "همچین حسابی نیست"},
	"msg.noUserX":      {"It may have been deleted.", "شاید حذف شده باشه."},
	"msg.revealMany":   {"Too many addresses revealed in the last hour.", "تو یک ساعت اخیر آدرس‌های زیادی نشون داده شده."},

	// password
	"pw.choose":       {"Choose your password", "رمزت رو انتخاب کن"},
	"pw.change":       {"Change password", "عوض کردن رمز"},
	"pw.lead":         {"Your current password was set by someone else. Choose your own before continuing.", "رمز فعلی‌ات رو یکی دیگه گذاشته. قبل از ادامه، رمز خودت رو انتخاب کن."},
	"pw.current":      {"Current password", "رمز فعلی"},
	"pw.new":          {"New password (12 or more characters)", "رمز جدید (حداقل 12 کاراکتر)"},
	"pw.again":        {"New password again", "تکرار رمز جدید"},
	"pw.wrongCurrent": {"Your current password is not right.", "رمز فعلی‌ات درست نیست."},
	"pw.mismatch":     {"The two new passwords are different.", "دو تا رمز جدید با هم فرق دارن."},
	"pw.weak":         {"Choose a new password of at least %v characters that is not common and not your email.", "یه رمز جدید با حداقل %v کاراکتر انتخاب کن که رایج نباشه و ایمیلت هم نباشه."},

	// pricing
	"pricing.h":         {"Price helper", "کمک‌حساب قیمت"},
	"pricing.lead":      {"Works out a price for every plan on sale from the monthly price. It only suggests: Bazaar charges whatever you type in its panel, and the app shows Bazaar's price.", "از روی قیمت ماهانه، برای هر اشتراکی که فروشیه قیمت حساب می‌کنه. فقط پیشنهاد می‌ده: بازار همون قیمتی رو می‌گیره که توی پنلش بنویسی و برنامه هم قیمت بازار رو نشون می‌ده."},
	"pricing.empty":     {"Nothing saved yet. Fill in the monthly price to see suggestions.", "هنوز چیزی ذخیره نشده. قیمت ماهانه رو بنویس تا پیشنهادها رو ببینی."},
	"pricing.inputs":    {"Inputs", "ورودی‌ها"},
	"pricing.base":      {"Monthly price, Toman", "قیمت ماهانه، تومان"},
	"pricing.adj":       {"Overall multiplier (raise it when inflation moves, e.g. 1.15)", "ضریب کلی (وقتی تورم بالا رفت زیادش کن، مثلاً 1.15)"},
	"pricing.mult":      {"%v multiplier of the monthly price", "ضریب %v نسبت به قیمت ماهانه"},
	"pricing.round":     {"Round up to a multiple of, Toman", "گرد کردن به بالا، به مضرب این عدد (تومان)"},
	"pricing.ending":    {"Then take off, Toman (1,000 turns 270,000 into 269,000)", "بعد این‌قدر کم کن، تومان (1,000 قیمت 270,000 رو می‌کنه 269,000)"},
	"pricing.save":      {"Save and work out", "ذخیره و حساب کن"},
	"pricing.badBase":   {"The monthly price must be a whole number of Toman between 1,000 and 1,000,000,000.", "قیمت ماهانه باید یه عدد صحیح بین 1,000 تا 1,000,000,000 تومان باشه."},
	"pricing.badAdj":    {"The overall multiplier must be between 0.1 and 100.", "ضریب کلی باید بین 0.1 تا 100 باشه."},
	"pricing.badMult":   {"The multiplier for %v must be between 0.1 and 100.", "ضریب %v باید بین 0.1 تا 100 باشه."},
	"pricing.badRound":  {"Round to must be a whole number of Toman between 1 and 100,000,000.", "عدد گرد کردن باید یه عدد صحیح بین 1 تا 100,000,000 تومان باشه."},
	"pricing.badEnding": {"The ending must be at least 0 and less than Round to.", "عدد کم‌کردن باید حداقل 0 و کمتر از عدد گرد کردن باشه."},
	"pricing.saved":     {"Saved. Type the Rial prices below into the Bazaar panel.", "ذخیره شد. قیمت‌های ریالی پایین رو توی پنل بازار بنویس."},

	// security
	"security.h":      {"Security events", "رویدادهای امنیتی"},
	"security.latest": {"Latest 100 (successful sign-ins left out)", "100 تای آخر (بدون ورودهای موفق)"},
	"security.source": {"\"Source\" is the first characters of a keyed hash of the IP address: equal values mean the same address, the address itself is never stored.", "«منبع» چند کاراکتر اولِ هش کلیددارِ آدرس IP هست: مقدارهای یکسان یعنی همون آدرس، خود آدرس هیچ‌وقت ذخیره نمی‌شه."},

	// system
	"system.checks":     {"Alert checks", "بررسی‌های هشدار"},
	"system.checksNote": {"Checked every minute. Firing alerts are emailed and repeated every 6 hours until they clear.", "هر دقیقه بررسی می‌شه. هشدارهای فعال ایمیل می‌شن و تا وقتی رفع نشدن، هر 6 ساعت تکرار می‌شن."},
	"system.firing":     {"firing since %v", "فعال از %v"},
	"system.noChecks":   {"No checks have run yet. They run where the background workers run.", "هنوز هیچ بررسی‌ای اجرا نشده. جایی اجرا می‌شن که کارهای پس‌زمینه اجرا می‌شن."},
	"system.last5":      {"Last 5 minutes", "5 دقیقه‌ی اخیر"},
	"system.reqs":       {"requests · %v errors (5xx) · %v slow (over 2 s)", "درخواست · %v خطا (5xx) · %v کند (بیش از 2 ثانیه)"},
	"system.typical":    {"Typical %v, slowest 5%% %v", "معمولی %v، کندترین 5%% %v"},
	"system.db":         {"Database connections", "اتصال‌های پایگاه داده"},
	"system.inUse":      {"in use now (%v open)", "الان در حال استفاده (%v باز)"},
	"system.pool":       {"Last 5 minutes: %v taken, average wait %v, %v gave up waiting", "5 دقیقه‌ی اخیر: %v گرفته‌شده، میانگین انتظار %v، %v از انتظار منصرف شدن"},
	"system.outside":    {"Outside services (last hour)", "سرویس‌های بیرونی (یک ساعت اخیر)"},
	"system.bazaar":     {"Bazaar: %v ok, %v failed", "بازار: %v موفق، %v ناموفق"},
	"system.slowest":    {", slowest 5%% %v", "، کندترین 5%% %v"},
	"system.email":      {"Email: %v sent, %v failed tries", "ایمیل: %v فرستاده‌شده، %v تلاش ناموفق"},
	"system.process":    {"Server process", "فرایند سرور"},
	"system.since":      {"Running since %v (%v)", "در حال اجرا از %v (%v)"},
	"system.memory":     {"Memory: %v in use, %v from the system", "حافظه: %v در حال استفاده، %v از سیستم"},
	"system.goroutines": {"%v goroutines", "%v گوروتین"},
	"system.byRoute":    {"Requests by route, last hour", "درخواست‌ها بر اساس مسیر، یک ساعت اخیر"},
	"system.partial":    {"The server started %v, so this covers less than an hour. ", "سرور %v روشن شده، پس این کمتر از یک ساعت رو نشون می‌ده. "},
	"system.buckets":    {"Times are bucket limits: \"≤ 250 ms\" means at most 250 ms.", "زمان‌ها سقف بازه‌ها هستن: «≤ 250 ms» یعنی حداکثر 250 میلی‌ثانیه."},
	"system.noReqs":     {"No requests yet.", "هنوز درخواستی نیست."},

	// one account
	"user.title":       {"Account", "حساب کاربر"},
	"user.account":     {"Account", "حساب"},
	"user.created":     {"created %v", "ساخته‌شده %v"},
	"user.avatar":      {"avatar %v", "آواتار %v"},
	"user.signsIn":     {"signs in with", "ورود با"},
	"user.emailH":      {"Email", "ایمیل"},
	"user.reveal":      {"Show (recorded)", "نشون بده (ثبت می‌شه)"},
	"user.subH":        {"Subscription", "اشتراک"},
	"user.suspicious":  {"Flagged suspicious since %v (a refund before expiry).", "از %v علامت مشکوک خورده (پول قبل از تموم شدن اشتراک برگشته)."},
	"user.recheck":     {"Check with Bazaar now", "الان از بازار بپرس"},
	"user.noPurchases": {"No purchases.", "خریدی نیست."},
	"user.grantsH":     {"Premium given by hand", "نسخه ویژه‌ی دستی"},
	"user.revokedAt":   {"revoked %v", "لغوشده %v"},
	"user.running":     {"running", "فعال"},
	"user.ended":       {"ended", "تموم‌شده"},
	"user.devicesH":    {"Devices", "دستگاه‌ها"},
	"user.historyH":    {"Subscription history", "تاریخچه‌ی اشتراک"},
	"user.actionsH":    {"Actions", "کارها"},
	"user.actionsNote": {"Each action is recorded with your name and the reason.", "هر کار با اسم تو و دلیلش ثبت می‌شه."},
	"user.signoutH":    {"Sign out everywhere", "خروج از همه‌جا"},
	"user.signoutP":    {"Ends every session on every device. They can sign in again.", "ورودش روی همه‌ی دستگاه‌ها تموم می‌شه. می‌تونه دوباره وارد بشه."},
	"user.disableH":    {"Disable account", "غیرفعال کردن حساب"},
	"user.disableP":    {"Signs them out and blocks sign-in (\"contact support\") until enabled again.", "از همه‌جا خارجش می‌کنه و تا دوباره فعال نشه نمی‌تونه وارد بشه («با پشتیبانی تماس بگیر»)."},
	"user.enableH":     {"Enable account", "فعال کردن حساب"},
	"user.grantH":      {"Give premium", "نسخه ویژه بده"},
	"user.grantP":      {"Starts now, ends by itself, never renews. Shows in their subscription history.", "از همین الان شروع می‌شه، خودش تموم می‌شه و هیچ‌وقت تمدید نمی‌شه. توی تاریخچه‌ی اشتراکش دیده می‌شه."},
	"user.grantHint":   {"tester, goodwill after a bug…", "تستر، جبران یه باگ…"},
	"user.revokeH":     {"Revoke premium until %v", "لغو نسخه ویژه تا %v"},
	"user.clearH":      {"Clear suspicious flag", "برداشتن علامت مشکوک"},
	"user.clearP":      {"Only after checking with Bazaar that the refund was a mistake.", "فقط بعد از اینکه با بازار مطمئن شدی برگشت پول اشتباه بوده."},
	"user.clearBtn":    {"Clear flag", "علامت رو بردار"},
	"user.deleteH":     {"Delete account", "حذف حساب"},
	"user.deleteP":     {"Only at the person's own written request. Deletes everything at once and for good; a running Bazaar subscription is not cancelled.", "فقط با درخواست کتبی خود شخص. همه‌چیز همون لحظه و برای همیشه پاک می‌شه؛ اشتراک فعال بازار لغو نمی‌شه."},
	"user.deleteType":  {"Type their email address (%v)", "آدرس ایمیلش رو بنویس (%v)"},
	"user.deleteLang":  {"Confirmation email language", "زبان ایمیل تأیید"},
	"user.langFA":      {"Persian", "فارسی"},
	"user.langEN":      {"English", "انگلیسی"},
	"user.deleteHint":  {"request by email on …", "درخواست با ایمیل در تاریخ …"},
	"user.deleteBtn":   {"Delete for good", "برای همیشه حذف کن"},
	"user.dangerH":     {"Danger zone", "منطقه‌ی خطر"},
	"user.adminH":      {"Admin activity on this account", "کارهای مدیرها روی این حساب"},

	// account actions
	"act.reason":         {"Write a reason (3 to 500 characters); it is recorded with the action.", "یه دلیل بنویس (3 تا 500 کاراکتر)؛ همراه کار ثبت می‌شه."},
	"act.deletedT":       {"Account deleted", "حساب حذف شد"},
	"act.deleted":        {"The account and everything tied to it are gone, and a confirmation email is on its way to the person. A running Bazaar subscription is not cancelled by this; they cancel it in Bazaar.", "حساب و هرچی بهش وصل بود پاک شد و ایمیل تأیید داره براش می‌ره. اشتراک فعال بازار با این لغو نمی‌شه؛ خودش باید توی بازار لغوش کنه."},
	"act.disabled":       {"Account disabled and signed out on every device. Sign-in now answers \"contact support\".", "حساب غیرفعال شد و از همه‌ی دستگاه‌ها خارج شد. حالا موقع ورود «با پشتیبانی تماس بگیر» می‌بینه."},
	"act.enabled":        {"Account enabled. They can sign in again.", "حساب فعال شد. می‌تونه دوباره وارد بشه."},
	"act.signedOut":      {"Signed out on %v device(s).", "از %v دستگاه خارج شد."},
	"act.noAnswer":       {"Bazaar did not answer (or the purchase was checked in the last minute). The stored state is unchanged.", "بازار جواب نداد (یا این خرید تو یک دقیقه‌ی اخیر بررسی شده). وضعیت ذخیره‌شده عوض نشد."},
	"act.rechecked":      {"Checked with Bazaar; the purchase below shows its answer.", "از بازار پرسیده شد؛ خرید پایین جوابش رو نشون می‌ده."},
	"act.notFlagged":     {"The account is not flagged.", "این حساب علامت مشکوک نداره."},
	"act.cleared":        {"Suspicious flag cleared. The app picks it up at its next subscription refresh.", "علامت مشکوک برداشته شد. برنامه دفعه‌ی بعد که اشتراک رو تازه کنه می‌فهمه."},
	"act.months":         {"Choose 1 to 12 months.", "بین 1 تا 12 ماه انتخاب کن."},
	"act.granted":        {"Premium given until %v. The app shows it at its next subscription refresh (opening the subscription screen refreshes it).", "نسخه ویژه تا %v داده شد. برنامه دفعه‌ی بعد که اشتراک رو تازه کنه نشونش می‌ده (باز کردن صفحه‌ی اشتراک تازه‌اش می‌کنه)."},
	"act.alreadyRevoked": {"That grant is already revoked.", "این نسخه ویژه قبلاً لغو شده."},
	"act.revoked":        {"Grant revoked. An app that already holds it keeps premium until its next refresh, at most a few days.", "نسخه ویژه لغو شد. برنامه‌ای که الان داردش تا تازه‌سازی بعدی، حداکثر چند روز، ویژه می‌مونه."},
	"act.confirmEmail":   {"Type the account's email address exactly to confirm the deletion.", "برای تأیید حذف، آدرس ایمیل حساب رو دقیق بنویس."},

	// users
	"users.h":        {"Find an account", "پیدا کردن حساب"},
	"users.lead":     {"Type the person's exact email address or account id. There is no browsing; every search is recorded.", "آدرس ایمیل دقیق یا شناسه‌ی حساب رو بنویس. فهرست کردن نداریم؛ هر جستجو ثبت می‌شه."},
	"users.notFound": {"No account has that address or id.", "هیچ حسابی با این آدرس یا شناسه نیست."},
}
