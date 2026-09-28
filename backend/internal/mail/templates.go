package mail

import (
	"fmt"
	"strings"
)

// SupportEmail is fixed; the app shows the same address.
const SupportEmail = "tarkk.hp@gmail.com"

// LogoURL is the app icon on the website. Mail clients that block remote
// images show the alt text instead, and nothing in the email depends on it.
const LogoURL = "https://tarkk.ir/logo.png"

// Kinds of mail, also stored on outbox rows for monitoring.
const (
	KindRegisterCode     = "register_code"
	KindRegisterExisting = "register_existing"
	KindResetCode        = "reset_code"
	KindEmailChangeCode  = "email_change_code"
	KindEmailChanged     = "email_changed"
	KindPasswordChanged  = "password_changed"
	KindGoogleLinked     = "google_linked"
	KindAccountDeleted   = "account_deleted"
)

// CodeMail carries a verification code and its matching app link.
type CodeMail struct {
	Code    string
	Link    string
	Minutes int
}

// Locale picks the language of the mail. Anything unknown falls back to
// English.
func Locale(tag string) string {
	if strings.HasPrefix(strings.ToLower(tag), "fa") {
		return "fa"
	}
	return "en"
}

// content is one email before rendering. Every template fills it, and
// render turns it into the plain-text and HTML parts, so both always say
// the same thing.
type content struct {
	Locale    string
	Subject   string
	Preheader string // preview line most inboxes show after the subject
	Heading   string
	Intro     []string
	Code      string
	// The link opens the app on the phone that asked for the code.
	LinkIntro   string // text version: the line before the bare link
	ButtonLabel string
	ButtonURL   string
	ButtonHint  string // HTML version: shown under the button
	Expiry      string
	Outro       []string
	Footer      string
}

func (c content) message(to string) Message {
	return Message{To: to, Subject: c.Subject, Text: c.text(), HTML: c.html()}
}

func (c content) text() string {
	var parts []string
	parts = append(parts, c.Intro...)
	if c.Code != "" {
		parts = append(parts, c.Code)
	}
	if c.ButtonURL != "" {
		parts = append(parts, c.LinkIntro+"\n"+c.ButtonURL)
	}
	if c.Expiry != "" {
		parts = append(parts, c.Expiry)
	}
	parts = append(parts, c.Outro...)
	parts = append(parts, c.Footer+"\n"+support(c.Locale)+"\n"+signature(c.Locale))
	return strings.Join(parts, "\n\n")
}

func support(locale string) string {
	if locale == "fa" {
		return "پشتیبانی: " + SupportEmail
	}
	return "Support: " + SupportEmail
}

func signature(locale string) string {
	if locale == "fa" {
		return "— ترک"
	}
	return "— Tark"
}

func ignoreFooter(locale string) string {
	if locale == "fa" {
		return "اگر شما این درخواست را نداده‌اید، این ایمیل را نادیده بگیرید؛ بدون این کد هیچ تغییری در حساب شما انجام نمی‌شود."
	}
	return "If you didn't ask for this, you can ignore this email. Nothing changes without this code."
}

func noticeFooter(locale string) string {
	if locale == "fa" {
		return "اگر این کار را شما انجام نداده‌اید، همین حالا از صفحه ورود «فراموشی رمز» را بزنید و به ما خبر دهید."
	}
	return "If this wasn't you, reset your password from the sign-in screen right away and let us know."
}

func expiry(locale string, minutes int) string {
	if locale == "fa" {
		return fmt.Sprintf("این کد تا %d دقیقه معتبر است.", minutes)
	}
	return fmt.Sprintf("The code works for %d minutes.", minutes)
}

func buttonHint(locale string) string {
	if locale == "fa" {
		return "دکمه فقط روی گوشی‌ای کار می‌کند که کد را در آن خواسته‌اید. در جای دیگر، کد بالا را در ترک وارد کنید."
	}
	return "The button only works on the phone where you asked for the code. Anywhere else, type the code into Tark."
}

func codeContent(locale string, d CodeMail) content {
	return content{
		Locale:     locale,
		Code:       d.Code,
		ButtonURL:  d.Link,
		ButtonHint: buttonHint(locale),
		Expiry:     expiry(locale, d.Minutes),
		Footer:     ignoreFooter(locale),
	}
}

func RegisterCode(locale, to string, d CodeMail) Message {
	c := codeContent(locale, d)
	if locale == "fa" {
		c.Subject = fmt.Sprintf("کد تأیید ترک: %s", d.Code)
		c.Preheader = "برای تکمیل ثبت‌نام، این کد را در ترک وارد کنید."
		c.Heading = "به ترک خوش آمدید"
		c.Intro = []string{"کد تأیید ایمیل شما:"}
		c.LinkIntro = "یا روی این پیوند در همان گوشی بزنید تا ترک باز شود و ثبت‌نام کامل شود:"
		c.ButtonLabel = "تکمیل ثبت‌نام"
	} else {
		c.Subject = fmt.Sprintf("Your Tark code: %s", d.Code)
		c.Preheader = "Enter this code in Tark to finish signing up."
		c.Heading = "Welcome to Tark"
		c.Intro = []string{"Your email verification code:"}
		c.LinkIntro = "Or tap this link on the same phone to open Tark and finish signing up:"
		c.ButtonLabel = "Finish signing up"
	}
	return c.message(to)
}

// RegisterExisting goes to an address that already has an account when
// someone tries to register it again. The API answers the same way in both
// cases, so this email is how the owner finds out.
func RegisterExisting(locale, to string) Message {
	c := content{Locale: locale, Footer: ignoreFooter(locale)}
	if locale == "fa" {
		c.Subject = "شما از قبل حساب ترک دارید"
		c.Preheader = "این ایمیل از قبل حساب ترک دارد."
		c.Heading = "شما از قبل حساب دارید"
		c.Intro = []string{
			"کسی (احتمالاً خود شما) خواست با این ایمیل در ترک ثبت‌نام کند، اما این ایمیل از قبل حساب دارد.",
			"برای ورود، در ترک «ورود» را بزنید. اگر رمز را به خاطر ندارید، در صفحه ورود «فراموشی رمز» را بزنید.",
		}
		c.Footer = "اگر شما این درخواست را نداده‌اید، این ایمیل را نادیده بگیرید؛ حساب شما تغییری نکرده است."
	} else {
		c.Subject = "You already have a Tark account"
		c.Preheader = "This email already has a Tark account."
		c.Heading = "You already have an account"
		c.Intro = []string{
			"Someone (probably you) tried to sign up for Tark with this email, but it already has an account.",
			"To get in, choose \"Sign in\" in Tark. If you don't remember your password, choose \"Forgot password\" on the sign-in screen.",
		}
		c.Footer = "If you didn't ask for this, you can ignore this email. Your account has not changed."
	}
	return c.message(to)
}

func ResetCode(locale, to string, d CodeMail) Message {
	c := codeContent(locale, d)
	if locale == "fa" {
		c.Subject = fmt.Sprintf("کد بازیابی رمز ترک: %s", d.Code)
		c.Preheader = "برای انتخاب رمز تازه، این کد را در ترک وارد کنید."
		c.Heading = "بازیابی رمز"
		c.Intro = []string{"کد بازیابی رمز شما:"}
		c.LinkIntro = "یا روی این پیوند در همان گوشی بزنید:"
		c.ButtonLabel = "انتخاب رمز تازه"
	} else {
		c.Subject = fmt.Sprintf("Your Tark password reset code: %s", d.Code)
		c.Preheader = "Enter this code in Tark to choose a new password."
		c.Heading = "Reset your password"
		c.Intro = []string{"Your password reset code:"}
		c.LinkIntro = "Or tap this link on the same phone:"
		c.ButtonLabel = "Choose a new password"
	}
	return c.message(to)
}

func EmailChangeCode(locale, to string, d CodeMail) Message {
	c := codeContent(locale, d)
	if locale == "fa" {
		c.Subject = fmt.Sprintf("کد تأیید ایمیل جدید ترک: %s", d.Code)
		c.Preheader = "برای تأیید ایمیل جدید، این کد را در ترک وارد کنید."
		c.Heading = "تأیید ایمیل جدید"
		c.Intro = []string{"برای اینکه این ایمیل، ایمیل حساب ترک شما شود، این کد را وارد کنید:"}
		c.LinkIntro = "یا روی این پیوند در همان گوشی بزنید:"
		c.ButtonLabel = "تأیید ایمیل"
	} else {
		c.Subject = fmt.Sprintf("Confirm your new Tark email: %s", d.Code)
		c.Preheader = "Enter this code in Tark to confirm your new email."
		c.Heading = "Confirm your new email"
		c.Intro = []string{"To make this the email of your Tark account, enter this code:"}
		c.LinkIntro = "Or tap this link on the same phone:"
		c.ButtonLabel = "Confirm email"
	}
	return c.message(to)
}

func EmailChanged(locale, to, newMasked string) Message {
	c := content{Locale: locale, Footer: noticeFooter(locale)}
	if locale == "fa" {
		// Keep the Latin address in its own direction inside Persian text.
		newMasked = "\u2066" + newMasked + "\u2069"
		c.Subject = "ایمیل حساب ترک شما تغییر کرد"
		c.Preheader = "ایمیل حساب شما به " + newMasked + " تغییر کرد."
		c.Heading = "ایمیل حساب تغییر کرد"
		c.Intro = []string{fmt.Sprintf("ایمیل حساب ترک شما به %s تغییر کرد. از این پس ایمیل‌های حساب به آن نشانی فرستاده می‌شود.", newMasked)}
	} else {
		c.Subject = "Your Tark email was changed"
		c.Preheader = "Your account email is now " + newMasked + "."
		c.Heading = "Your email was changed"
		c.Intro = []string{fmt.Sprintf("The email on your Tark account was changed to %s. Account emails now go to that address.", newMasked)}
	}
	return c.message(to)
}

func PasswordChanged(locale, to string) Message {
	c := content{Locale: locale, Footer: noticeFooter(locale)}
	if locale == "fa" {
		c.Subject = "رمز حساب ترک شما تغییر کرد"
		c.Preheader = "رمز شما تغییر کرد و از دستگاه‌های دیگر خارج شدید."
		c.Heading = "رمز شما تغییر کرد"
		c.Intro = []string{"رمز حساب ترک شما همین حالا تغییر کرد و از دستگاه‌های دیگر خارج شدید."}
	} else {
		c.Subject = "Your Tark password was changed"
		c.Preheader = "Your password was changed and other devices were signed out."
		c.Heading = "Your password was changed"
		c.Intro = []string{"Your Tark password was just changed, and your other devices were signed out."}
	}
	return c.message(to)
}

func GoogleLinked(locale, to string) Message {
	c := content{Locale: locale, Footer: noticeFooter(locale)}
	if locale == "fa" {
		c.Subject = "ورود با گوگل به حساب ترک شما اضافه شد"
		c.Preheader = "از این پس با گوگل هم می‌توانید وارد شوید."
		c.Heading = "ورود با گوگل اضافه شد"
		c.Intro = []string{"از این پس می‌توانید با حساب گوگل هم وارد حساب ترک خود شوید. ورود با ایمیل و رمز هم مثل قبل کار می‌کند."}
	} else {
		c.Subject = "Google sign-in was added to your Tark account"
		c.Preheader = "You can now also sign in with Google."
		c.Heading = "Google sign-in was added"
		c.Intro = []string{"You can now also sign in to your Tark account with Google. Signing in with your email and password works as before."}
	}
	return c.message(to)
}

// AccountDeleted confirms a deletion to the address the account had. It is
// the last thing the server ever sends there.
func AccountDeleted(locale, to string) Message {
	c := content{Locale: locale}
	if locale == "fa" {
		c.Subject = "حساب ترک شما حذف شد"
		c.Preheader = "حساب و داده‌های شما به درخواست خودتان حذف شد."
		c.Heading = "حساب شما حذف شد"
		c.Intro = []string{
			"حساب ترک شما و داده‌های آن به درخواست خودتان حذف شد و از همه دستگاه‌ها خارج شدید.",
			"اشتراک کافه‌بازار در خود بازار مدیریت می‌شود. اگر هنوز آن را لغو نکرده‌اید، از بازار لغو کنید. اگر دوباره حساب بسازید، می‌توانید خریدتان را در حساب تازه بازیابی کنید.",
		}
		c.Footer = "اگر این کار را شما انجام نداده‌اید، همین حالا به ما خبر دهید."
	} else {
		c.Subject = "Your Tark account was deleted"
		c.Preheader = "Your account and its data were deleted at your request."
		c.Heading = "Your account was deleted"
		c.Intro = []string{
			"Your Tark account and its data were deleted at your request, and every device was signed out.",
			"A Cafe Bazaar subscription is managed in Bazaar. If you haven't cancelled it, cancel it there. If you create a new account, you can restore your purchase in it.",
		}
		c.Footer = "If this wasn't you, let us know right away."
	}
	return c.message(to)
}

// MaskEmail shows enough of an address to recognise it without spelling
// it out: "pedram@gmail.com" -> "pe•••@gmail.com".
func MaskEmail(email string) string {
	local, domain, ok := strings.Cut(email, "@")
	if !ok {
		return "•••"
	}
	r := []rune(local)
	keep := 2
	if len(r) <= 2 {
		keep = 1
	}
	return string(r[:keep]) + "•••@" + domain
}
