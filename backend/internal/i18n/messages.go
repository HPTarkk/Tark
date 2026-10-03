package i18n

import "strings"

// supportEmail must equal mail.SupportEmail (a test checks). Kept here so
// this package stays free of the mail package's dependencies.
const supportEmail = "tarkk.hp@gmail.com"

// text is one message in both languages. {email} and {count} are filled in
// by Message.
type text struct{ en, fa string }

// errorMessages holds the people-facing sentence for every Problem code.
// The wording follows the app's own strings (lib/core/l10n/app_*.arb) so a
// screen reads the same whether it shows the server's message or its own.
// TestEveryCodeHasMessage keeps this in step with the codes the services
// return.
var errorMessages = map[string]text{
	// Generic
	"internal_error": {"Something went wrong on our side. Please try again in a moment.",
		"یه مشکلی سمت ما پیش اومد. چند لحظه دیگه دوباره امتحان کن."},
	"timeout": {"That took too long. Please try again.",
		"زیادی طول کشید. لطفاً دوباره امتحان کن."},
	"not_ready": {"Tark is starting up. Please try again in a moment.",
		"تَرک داره راه می‌افته. چند لحظه دیگه دوباره امتحان کن."},
	"not_found": {"That isn't here.", "این‌جا چیزی پیدا نشد."},
	"method_not_allowed": {"That request isn't supported here.",
		"این درخواست این‌جا پشتیبانی نمی‌شه."},
	"unsupported_media_type": {"That request isn't supported here.",
		"این درخواست این‌جا پشتیبانی نمی‌شه."},
	"body_too_large": {"That's more than we can take in one go. Please send less.",
		"این بیشتر از چیزیه که یه‌جا می‌تونیم بگیریم. لطفاً کمترش کن."},
	"invalid_request": {"Please check what you typed and try again.",
		"یه بار دیگه نوشته‌ات رو ببین و دوباره امتحان کن."},
	"rate_limited": {"That's a lot of tries in a short time. Please wait a little, then try again.",
		"توی مدت کوتاهی خیلی تلاش شد. کمی صبر کن، بعد دوباره امتحان کن."},
	"idempotency_mismatch": {"Something went wrong on our side. Please try again in a moment.",
		"یه مشکلی سمت ما پیش اومد. چند لحظه دیگه دوباره امتحان کن."},
	"request_in_progress": {"We're still working on your last request. Please wait a moment.",
		"هنوز داریم درخواست قبلیت رو انجام می‌دیم. یه لحظه صبر کن."},

	// Sessions
	"unauthorized": {"You've been signed out. Please sign in again.",
		"از حسابت خارج شدی. لطفاً دوباره وارد شو."},
	"session_ended": {"You've been signed out. Please sign in again.",
		"از حسابت خارج شدی. لطفاً دوباره وارد شو."},
	"retry_sign_in": {"Sign-in didn't finish. Please try again.",
		"ورود کامل نشد. دوباره امتحان کن."},
	"account_disabled": {"This account is on hold. Write to us at {email} and we'll sort it out.",
		"این حساب فعلاً متوقف شده. به {email} ایمیل بزن تا درستش کنیم."},
	"reauth_unavailable": {"We can't confirm it's you on this phone. Write to us at {email} and we'll help.",
		"روی این گوشی نمی‌تونیم تأیید کنیم که خودتی. به {email} ایمیل بزن تا کمکت کنیم."},

	// Email and password
	"invalid_credentials": {"That email and password don't match an account.",
		"این ایمیل و رمز با هیچ حسابی جور نیست."},
	"email_already_registered": {"This address already has an account. Sign in instead.",
		"این آدرس از قبل حساب داره. به‌جاش وارد شو."},
	"email_in_use": {"This address already belongs to another account.",
		"این آدرس مال یه حساب دیگه‌ست."},
	"email_unchanged": {"That's already your account's email.",
		"این همین الان ایمیل حسابته."},
	"password_too_short": {"Use 8 characters or more.", "۸ نویسه یا بیشتر بنویس."},
	"password_too_long":  {"Use 128 characters or fewer.", "حداکثر ۱۲۸ نویسه بنویس."},
	"password_too_common": {"That password is easy to guess. Try a longer or less common one.",
		"این رمز راحت حدس زده می‌شه. یه رمز بلندتر یا کمتر رایج امتحان کن."},
	"password_matches_email": {"The password can't be your email address.",
		"رمز نمی‌تونه همون آدرس ایمیلت باشه."},
	"password_invalid": {"That password can't be used. Try another one.",
		"این رمز قابل استفاده نیست. یه رمز دیگه امتحان کن."},
	"password_unchanged": {"That's the current password. Pick a new one.",
		"این همون رمز فعلیه. یه رمز تازه انتخاب کن."},
	"password_not_set": {"This account signs in with Google and has no password yet. Use “Forgot your password?” to add one.",
		"این حساب با گوگل وارد می‌شه و هنوز رمز نداره. برای گذاشتن رمز از «رمزت یادت رفته؟» استفاده کن."},
	"password_changed_concurrently": {"Your password was just changed somewhere else. Please sign in again.",
		"رمزت همین الان یه جای دیگه عوض شد. لطفاً دوباره وارد شو."},

	// Codes and flows
	"code_invalid": {"That code doesn't match.", "این کد جور نیست."},
	"code_locked": {"That's a lot of codes tried. Send a new code to carry on.",
		"کدهای زیادی امتحان شد. برای ادامه یه کد تازه بفرست."},
	"flow_expired": {"This code has run out of time. Start again to get a new one.",
		"زمان این کد تموم شده. از اول شروع کن تا یه کد تازه بگیری."},
	"flow_not_found": {"This code can't be used any more. Please start again.",
		"این کد دیگه قابل استفاده نیست. لطفاً از اول شروع کن."},
	"flow_completed": {"This code can't be used any more. Please start again.",
		"این کد دیگه قابل استفاده نیست. لطفاً از اول شروع کن."},
	"resend_limit": {"That's as many codes as we can send for this one. Please start again.",
		"برای این یکی بیشتر از این نمی‌تونیم کد بفرستیم. لطفاً از اول شروع کن."},
	"ticket_expired": {"That took a while, so it timed out. Please start again.",
		"یه کم طول کشید و زمانش تموم شد. لطفاً دوباره شروع کن."},
	"ticket_locked": {"That took a while, so it timed out. Please start again.",
		"یه کم طول کشید و زمانش تموم شد. لطفاً دوباره شروع کن."},

	// Google
	"google_unavailable": {"Google sign-in isn't available right now. You can use email and password instead.",
		"ورود با گوگل الان در دسترس نیست. می‌تونی با ایمیل و رمز وارد شی."},
	"google_token_invalid": {"Google sign-in didn't finish. Please try again.",
		"ورود با گوگل کامل نشد. دوباره امتحان کن."},
	"google_email_unverified": {"Google hasn't confirmed this Google account's email yet. Confirm it with Google, or use email and password.",
		"گوگل هنوز ایمیل این حساب گوگل رو تأیید نکرده. توی گوگل تأییدش کن، یا با ایمیل و رمز وارد شو."},
	"google_email_unsupported": {"This Google account's email can't be used with Tark. Try another account, or email and password.",
		"ایمیل این حساب گوگل با تَرک قابل استفاده نیست. یه حساب دیگه یا ایمیل و رمز رو امتحان کن."},
	"account_conflict": {"This address is linked to a different Google account. Sign in with that one, or with your password.",
		"این آدرس به یه حساب گوگل دیگه وصله. با همون یکی یا با رمزت وارد شو."},
	"link_required": {"This address already has an account. Enter its password to link Google to it.",
		"این آدرس از قبل حساب داره. رمزش رو بنویس تا گوگل بهش وصل بشه."},
	"name_required": {"Pick a name to finish creating your account.",
		"برای ساختن حسابت یه اسم انتخاب کن."},

	// Profile and account
	"profile_changed": {"Your profile was just changed on another phone. Here's the latest version.",
		"پروفایلت همین الان روی یه گوشی دیگه عوض شد. این آخرین نسخه‌شه."},
	"confirmation_mismatch": {"That isn't the account's email. Type it exactly as shown.",
		"این ایمیل حساب نیست. دقیقاً همونی که نشون داده شده رو بنویس."},
	"subscription_active": {"Your Bazaar subscription is still running. Deleting the account doesn't cancel or refund it.",
		"اشتراک بازارت هنوز فعاله. پاک کردن حساب لغو یا پسش نمی‌ده."},

	// Subscription
	"purchase_invalid": {"Bazaar doesn't recognise this purchase. If you were charged, write to us at {email}.",
		"بازار این خرید رو نمی‌شناسه. اگه پولی ازت کم شده، به {email} ایمیل بزن."},
	"purchase_not_found_yet": {"Bazaar hasn't confirmed this purchase yet. We'll keep checking.",
		"بازار هنوز این خرید رو تأیید نکرده. ما دوباره بررسی می‌کنیم."},
	"purchase_owned_elsewhere": {"This Bazaar purchase is already linked to a different Tark account. Sign in with that account to use it, or write to us and we'll sort it out together.",
		"این خرید بازار قبلاً به یه حساب دیگه‌ی ترک وصل شده. با همون حساب وارد شو، یا بهمون پیام بده تا با هم درستش کنیم."},
	"bazaar_unavailable": {"We couldn't reach Bazaar just now. Please try again in a little while.",
		"الان به بازار نرسیدیم. کمی بعد دوباره امتحان کن."},
}

// Field-specific wording for invalid_request, keyed by the JSON field.
var fieldMessages = map[string]text{
	"email":        {"That email address doesn't look complete.", "این آدرس ایمیل کامل به نظر نمی‌رسه."},
	"confirmEmail": {"That email address doesn't look complete.", "این آدرس ایمیل کامل به نظر نمی‌رسه."},
	"newEmail":     {"That email address doesn't look complete.", "این آدرس ایمیل کامل به نظر نمی‌رسه."},
	"name":         {"That name has characters we can't show. Try another one.", "این اسم نویسه‌هایی داره که نمی‌تونیم نشونش بدیم. یه اسم دیگه امتحان کن."},
}

var codeWithAttempts = text{"That code doesn't match. {count} tries left.",
	"این کد جور نیست. {count} بار دیگه می‌تونی امتحان کنی."}

var wrongPassword = text{"That password doesn't match.", "این رمز جور نیست."}

// ErrorMessage is the sentence a person sees for a Problem. extra is the
// Problem's extra fields (field, attemptsLeft) and refines the wording.
// An unknown code gets the generic "something went wrong" text.
func ErrorMessage(lang, code string, extra map[string]any) string {
	t, ok := errorMessages[code]
	if !ok {
		t = errorMessages["internal_error"]
	}
	field, _ := extra["field"].(string)
	switch code {
	case "invalid_request":
		if ft, ok := fieldMessages[field]; ok {
			t = ft
		}
	case "invalid_credentials":
		if field == "currentPassword" {
			t = wrongPassword
		}
	case "code_invalid":
		if left, ok := extra["attemptsLeft"].(int); ok && left > 0 {
			return fill(pick(lang, codeWithAttempts), lang, left)
		}
	}
	return fill(pick(lang, t), lang, 0)
}

// HasErrorMessage reports whether code has its own wording.
func HasErrorMessage(code string) bool {
	_, ok := errorMessages[code]
	return ok
}

func pick(lang string, t text) string {
	if lang == FA {
		return t.fa
	}
	return t.en
}

func fill(s, lang string, count int) string {
	s = strings.ReplaceAll(s, "{email}", supportEmail)
	return strings.ReplaceAll(s, "{count}", Digits(lang, count))
}
