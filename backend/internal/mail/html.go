package mail

import (
	"bytes"
	"html/template"
)

// The HTML part follows what mail clients actually support: tables for
// layout, inline styles, no scripts, no web fonts required and no remote
// content besides the logo. The colours are the app's: dark header, warm
// paper card, amber accent. Clients that honour prefers-color-scheme get a
// dark version; the rest show the light one. html/template escapes every
// value, so nothing in a message can inject markup.
var layout = template.Must(template.New("mail").Parse(`<!doctype html>
<html lang="{{.Lang}}" dir="{{.Dir}}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>{{.C.Subject}}</title>
<style>
  body { margin: 0; padding: 0; }
  a { color: #B26B00; }
  @media (max-width: 600px) {
    .t-card { padding: 28px 22px !important; }
    .t-code { font-size: 30px !important; letter-spacing: 6px !important; }
  }
  @media (prefers-color-scheme: dark) {
    .t-bg { background: #0B0E11 !important; }
    .t-card { background: #13171C !important; border-color: #2D343D !important; }
    .t-h { color: #E9EDF1 !important; }
    .t-p { color: #C4CBD3 !important; }
    .t-muted { color: #8B939D !important; }
    .t-codebox { background: #1A2027 !important; border-color: #D9661F !important; }
    .t-code { color: #F5853F !important; }
    .t-rule { border-color: #2D343D !important; }
    .t-head { border: 1px solid #2D343D !important; border-bottom: 0 !important; }
    a { color: #F5853F !important; }
    a.t-btn { color: #0B0E11 !important; }
    a.t-foot { color: #8B939D !important; }
  }
</style>
</head>
<body class="t-bg" style="margin:0;padding:0;background:#F6F1E7;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">{{.C.Preheader}}</div>
<table role="presentation" class="t-bg" width="100%" cellspacing="0" cellpadding="0" border="0" style="background:#F6F1E7;">
<tr><td align="center" style="padding:32px 12px;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width:520px;">
    <tr><td class="t-head" style="background:#0B0E11;border-radius:20px 20px 0 0;padding:22px 28px;" dir="{{.Dir}}">
      <table role="presentation" cellspacing="0" cellpadding="0" border="0"><tr>
        <td style="vertical-align:middle;"><img src="{{.Logo}}" width="40" height="40" alt="" style="display:block;border:0;border-radius:10px;"></td>
        <td style="vertical-align:middle;padding:0 12px;font-family:{{.Font}};font-size:22px;font-weight:700;color:#F5853F;letter-spacing:0.5px;">{{.Brand}}</td>
      </tr></table>
    </td></tr>
    <tr><td class="t-card" style="background:#FFFDF7;border:1px solid #E0D5BD;border-top:0;border-radius:0 0 20px 20px;padding:36px 32px;font-family:{{.Font}};text-align:{{.Align}};" dir="{{.Dir}}">
      <h1 class="t-h" style="margin:0 0 18px;font-size:24px;line-height:1.35;font-weight:700;color:#0B0E11;">{{.C.Heading}}</h1>
      {{range .C.Intro}}<p class="t-p" style="margin:0 0 14px;font-size:16px;line-height:1.7;color:#2D343D;">{{.}}</p>
      {{end}}
      {{- if .C.Code}}
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:10px 0 22px;">
        <tr><td class="t-codebox" align="center" style="background:#FBEEDF;border:1px solid #F5853F;border-radius:14px;padding:18px 12px;">
          <div class="t-code" dir="ltr" style="font-family:'SFMono-Regular',Menlo,Consolas,'Courier New',monospace;font-size:36px;line-height:1.2;font-weight:700;letter-spacing:10px;padding-left:10px;color:#0B0E11;">{{.C.Code}}</div>
        </td></tr>
      </table>
      {{- end}}
      {{- if .C.ButtonURL}}
      <table role="presentation" cellspacing="0" cellpadding="0" border="0" align="center" style="margin:4px auto 12px;">
        <tr><td align="center" bgcolor="#F5853F" style="border-radius:12px;">
          <a class="t-btn" href="{{.C.ButtonURL}}" target="_blank" style="display:inline-block;padding:14px 30px;font-family:{{.Font}};font-size:16px;font-weight:700;color:#0B0E11;text-decoration:none;border-radius:12px;">{{.C.ButtonLabel}}</a>
        </td></tr>
      </table>
      <p class="t-muted" style="margin:0 0 18px;font-size:13px;line-height:1.6;color:#6B737D;text-align:center;">{{.C.ButtonHint}}</p>
      {{- end}}
      {{- if .C.Expiry}}
      <p class="t-p" style="margin:0 0 14px;font-size:15px;line-height:1.7;color:#2D343D;">{{.C.Expiry}}</p>
      {{- end}}
      {{range .C.Outro}}<p class="t-p" style="margin:0 0 14px;font-size:16px;line-height:1.7;color:#2D343D;">{{.}}</p>
      {{end}}
      <hr class="t-rule" style="border:0;border-top:1px solid #E0D5BD;margin:26px 0 18px;">
      <p class="t-muted" style="margin:0 0 8px;font-size:13px;line-height:1.7;color:#6B737D;">{{.C.Footer}}</p>
      <p class="t-muted" style="margin:0;font-size:13px;line-height:1.7;color:#6B737D;">{{.SupportLabel}} <a href="mailto:{{.Support}}" style="color:#B26B00;">{{.Support}}</a></p>
    </td></tr>
    <tr><td align="center" class="t-muted" style="padding:18px 12px 0;font-family:{{.Font}};font-size:12px;color:#8B939D;">{{.Brand}} · <a class="t-foot" href="https://tarkk.ir" style="color:#8B939D;text-decoration:none;">tarkk.ir</a></td></tr>
  </table>
</td></tr>
</table>
</body>
</html>
`))

type layoutData struct {
	C            content
	Lang, Dir    string
	Align        string
	Font         template.CSS
	Brand        string
	Logo         string
	Support      string
	SupportLabel string
}

func (c content) html() string {
	d := layoutData{
		C: c, Lang: "en", Dir: "ltr", Align: "left",
		Font:  template.CSS(`-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif`),
		Brand: "Tark", Logo: LogoURL, Support: SupportEmail, SupportLabel: "Support:",
	}
	if c.Locale == "fa" {
		d.Lang, d.Dir, d.Align = "fa", "rtl", "right"
		d.Font = template.CSS(`Vazirmatn,Tahoma,'Segoe UI',Arial,sans-serif`)
		d.Brand, d.SupportLabel = "ترک", "پشتیبانی:"
	}
	var b bytes.Buffer
	if err := layout.Execute(&b, d); err != nil {
		// The template and its data are fixed; this cannot fail at run time
		// without failing every test first. Fall back to text-only mail.
		return ""
	}
	return b.String()
}
