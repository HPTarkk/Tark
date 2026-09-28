package mail

import (
	"fmt"
	"strings"
)

// SupportEmail is fixed; the app shows the same address.
const SupportEmail = "tarkk.hp@gmail.com"

// Kinds of mail, also stored on outbox rows for monitoring.
const (
	KindRegisterCode     = "register_code"
	KindRegisterExisting = "register_existing"
	KindResetCode        = "reset_code"
	KindEmailChangeCode  = "email_change_code"
	KindEmailChanged     = "email_changed"
	KindPasswordChanged  = "password_changed"
	KindGoogleLinked     = "google_linked"
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

func footer(locale string) string {
	if locale == "fa" {
		return "\n\nاگر شما این درخواست را نداده‌اید، این ایمیل را نادیده بگیرید؛ بدون کد بالا هیچ تغییری در حساب شما انجام نمی‌شود.\nپشتیبانی: " + SupportEmail + "\n— ترک"
	}
	return "\n\nIf you didn't ask for this, you can ignore this email. Nothing changes without the code above.\nSupport: " + SupportEmail + "\n— Tark"
}

func noticeFooter(locale string) string {
	if locale == "fa" {
		return "\n\nاگر این کار را شما انجام نداده‌اید، همین حالا از صفحه ورود «فراموشی رمز» را بزنید و به ما خبر دهید: " + SupportEmail + "\n— ترک"
	}
	return "\n\nIf this wasn't you, reset your password from the sign-in screen right away and let us know: " + SupportEmail + "\n— Tark"
}

func RegisterCode(locale, to string, d CodeMail) Message {
	if locale == "fa" {
		return Message{To: to,
			Subject: fmt.Sprintf("کد تأیید ترک: %s", d.Code),
			Text: fmt.Sprintf("کد تأیید ایمیل شما:\n\n%s\n\nیا روی این پیوند در همان گوشی بزنید تا ترک باز شود و ثبت‌نام کامل شود:\n%s\n\nاین کد تا %d دقیقه معتبر است.",
				d.Code, d.Link, d.Minutes) + footer(locale)}
	}
	return Message{To: to,
		Subject: fmt.Sprintf("Your Tark code: %s", d.Code),
		Text: fmt.Sprintf("Your email verification code:\n\n%s\n\nOr tap this link on the same phone to open Tark and finish signing up:\n%s\n\nThe code works for %d minutes.",
			d.Code, d.Link, d.Minutes) + footer(locale)}
}

// RegisterExisting goes to an address that already has an account when
// someone tries to register it again. The API answers the same way in both
// cases, so this email is how the owner finds out.
func RegisterExisting(locale, to string) Message {
	if locale == "fa" {
		return Message{To: to,
			Subject: "شما از قبل حساب ترک دارید",
			Text:    "کسی (احتمالاً خود شما) خواست با این ایمیل در ترک ثبت‌نام کند، اما این ایمیل از قبل حساب دارد.\n\nبرای ورود، در ترک «ورود» را بزنید. اگر رمز را به خاطر ندارید، در صفحه ورود «فراموشی رمز» را بزنید." + footer(locale)}
	}
	return Message{To: to,
		Subject: "You already have a Tark account",
		Text:    "Someone (probably you) tried to sign up for Tark with this email, but it already has an account.\n\nTo get in, choose \"Sign in\" in Tark. If you don't remember your password, choose \"Forgot password\" on the sign-in screen." + footer(locale)}
}

func ResetCode(locale, to string, d CodeMail) Message {
	if locale == "fa" {
		return Message{To: to,
			Subject: fmt.Sprintf("کد بازیابی رمز ترک: %s", d.Code),
			Text: fmt.Sprintf("کد بازیابی رمز شما:\n\n%s\n\nیا روی این پیوند در همان گوشی بزنید:\n%s\n\nاین کد تا %d دقیقه معتبر است.",
				d.Code, d.Link, d.Minutes) + footer(locale)}
	}
	return Message{To: to,
		Subject: fmt.Sprintf("Your Tark password reset code: %s", d.Code),
		Text: fmt.Sprintf("Your password reset code:\n\n%s\n\nOr tap this link on the same phone:\n%s\n\nThe code works for %d minutes.",
			d.Code, d.Link, d.Minutes) + footer(locale)}
}

func EmailChangeCode(locale, to string, d CodeMail) Message {
	if locale == "fa" {
		return Message{To: to,
			Subject: fmt.Sprintf("کد تأیید ایمیل جدید ترک: %s", d.Code),
			Text: fmt.Sprintf("برای اینکه این ایمیل، ایمیل حساب ترک شما شود، این کد را وارد کنید:\n\n%s\n\nیا روی این پیوند در همان گوشی بزنید:\n%s\n\nاین کد تا %d دقیقه معتبر است.",
				d.Code, d.Link, d.Minutes) + footer(locale)}
	}
	return Message{To: to,
		Subject: fmt.Sprintf("Confirm your new Tark email: %s", d.Code),
		Text: fmt.Sprintf("To make this the email of your Tark account, enter this code:\n\n%s\n\nOr tap this link on the same phone:\n%s\n\nThe code works for %d minutes.",
			d.Code, d.Link, d.Minutes) + footer(locale)}
}

func EmailChanged(locale, to, newMasked string) Message {
	if locale == "fa" {
		return Message{To: to,
			Subject: "ایمیل حساب ترک شما تغییر کرد",
			Text:    fmt.Sprintf("ایمیل حساب ترک شما به %s تغییر کرد. از این پس ایمیل‌های حساب به آن نشانی فرستاده می‌شود.", newMasked) + noticeFooter(locale)}
	}
	return Message{To: to,
		Subject: "Your Tark email was changed",
		Text:    fmt.Sprintf("The email on your Tark account was changed to %s. Account emails now go to that address.", newMasked) + noticeFooter(locale)}
}

func PasswordChanged(locale, to string) Message {
	if locale == "fa" {
		return Message{To: to,
			Subject: "رمز حساب ترک شما تغییر کرد",
			Text:    "رمز حساب ترک شما همین حالا تغییر کرد و از دستگاه‌های دیگر خارج شدید." + noticeFooter(locale)}
	}
	return Message{To: to,
		Subject: "Your Tark password was changed",
		Text:    "Your Tark password was just changed, and your other devices were signed out." + noticeFooter(locale)}
}

func GoogleLinked(locale, to string) Message {
	if locale == "fa" {
		return Message{To: to,
			Subject: "ورود با گوگل به حساب ترک شما اضافه شد",
			Text:    "از این پس می‌توانید با حساب گوگل هم وارد حساب ترک خود شوید. ورود با ایمیل و رمز هم مثل قبل کار می‌کند." + noticeFooter(locale)}
	}
	return Message{To: to,
		Subject: "Google sign-in was added to your Tark account",
		Text:    "You can now also sign in to your Tark account with Google. Signing in with your email and password works as before." + noticeFooter(locale)}
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
