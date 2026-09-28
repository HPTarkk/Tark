package mail

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net/mail"
	"strings"
	"testing"
	"time"
)

func parts(t *testing.T, raw []byte) map[string]string {
	t.Helper()
	msg, err := mail.ReadMessage(strings.NewReader(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	mediaType, params, err := mime.ParseMediaType(msg.Header.Get("Content-Type"))
	if err != nil {
		t.Fatal(err)
	}
	decode := func(r io.Reader) string {
		b, err := io.ReadAll(base64.NewDecoder(base64.StdEncoding, r))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	out := map[string]string{}
	if mediaType != "multipart/alternative" {
		out[mediaType] = decode(msg.Body)
		return out
	}
	mr := multipart.NewReader(msg.Body, params["boundary"])
	for {
		p, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			return out
		}
		if err != nil {
			t.Fatal(err)
		}
		ct, _, _ := mime.ParseMediaType(p.Header.Get("Content-Type"))
		out[ct] = decode(p)
	}
}

var sender = &SMTPSender{From: "no-reply@tarkk.ir", FromName: "Tark"}

func TestRenderMultipart(t *testing.T) {
	m := RegisterCode("en", "a@example.com", CodeMail{Code: "123456", Link: "https://tarkk.ir/v/register#tok_1", Minutes: 15})
	raw, err := sender.render(m)
	if err != nil {
		t.Fatal(err)
	}
	p := parts(t, raw)
	if !strings.Contains(p["text/plain"], "\r\n123456\r\n") || !strings.Contains(p["text/plain"], "https://tarkk.ir/v/register#tok_1") {
		t.Fatalf("text part: %q", p["text/plain"])
	}
	html := p["text/html"]
	for _, want := range []string{`dir="ltr"`, ">123456<", `href="https://tarkk.ir/v/register#tok_1"`, "Finish signing up", LogoURL, "mailto:" + SupportEmail} {
		if !strings.Contains(html, want) {
			t.Fatalf("html part lacks %q", want)
		}
	}
}

func TestRenderPersianIsRightToLeft(t *testing.T) {
	m := ResetCode("fa", "a@example.com", CodeMail{Code: "654321", Link: "https://tarkk.ir/v/reset#t", Minutes: 15})
	if !strings.Contains(m.HTML, `<html lang="fa" dir="rtl">`) || !strings.Contains(m.HTML, "بازیابی رمز") {
		t.Fatal("persian mail is not right-to-left")
	}
	// The code itself stays left-to-right so the digits keep their order.
	if !strings.Contains(m.HTML, `dir="ltr" style="font-family:'SFMono-Regular'`) {
		t.Fatal("code is not left-to-right")
	}
}

func TestHTMLEscapesValues(t *testing.T) {
	m := EmailChanged("en", "a@example.com", `<b onmouseover="x">@evil</b>`)
	if strings.Contains(m.HTML, "<b onmouseover") {
		t.Fatal("value was not escaped")
	}
	if !strings.Contains(m.Text, `<b onmouseover="x">@evil</b>`) {
		t.Fatal("text part should carry the value as is")
	}
}

func TestRenderTextOnly(t *testing.T) {
	raw, err := sender.render(Message{To: "a@example.com", Subject: "Hi", Text: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	if p := parts(t, raw); p["text/plain"] != "hello" || len(p) != 1 {
		t.Fatalf("%v", p)
	}
}

func TestRenderRefusesHeaderInjection(t *testing.T) {
	if _, err := sender.render(Message{To: "a@example.com", Subject: "Hi\r\nBcc: x@example.com", Text: "x"}); err == nil {
		t.Fatal("line break in a header was accepted")
	}
}

type fakeSender struct {
	calls int
	err   error
}

func (f *fakeSender) Send(context.Context, Message) error {
	f.calls++
	return f.err
}

func TestFailover(t *testing.T) {
	primary, backup := &fakeSender{err: errors.New("unreachable")}, &fakeSender{}
	clock := time.Unix(0, 0)
	f := &FailoverSender{
		Senders:  []NamedSender{{"primary", primary}, {"backup", backup}},
		Cooldown: time.Minute,
		now:      func() time.Time { return clock },
	}
	ctx := context.Background()
	if err := f.Send(ctx, Message{}); err != nil {
		t.Fatal(err)
	}
	if primary.calls != 1 || backup.calls != 1 {
		t.Fatalf("calls %d %d", primary.calls, backup.calls)
	}
	// During the cooldown the failed provider is not tried first.
	if err := f.Send(ctx, Message{}); err != nil || primary.calls != 1 || backup.calls != 2 {
		t.Fatalf("cooldown not honoured: %v %d %d", err, primary.calls, backup.calls)
	}
	// After it, the primary is first again.
	clock = clock.Add(2 * time.Minute)
	primary.err = nil
	if err := f.Send(ctx, Message{}); err != nil || primary.calls != 2 || backup.calls != 2 {
		t.Fatalf("primary not retried: %v %d %d", err, primary.calls, backup.calls)
	}
	// Everything down: the error goes back to the outbox, and a provider in
	// its cooldown is still tried as a last resort.
	primary.err, backup.err = errors.New("down"), errors.New("down too")
	if err := f.Send(ctx, Message{}); err == nil || !strings.Contains(err.Error(), "backup: down too") {
		t.Fatalf("want joined error, got %v", err)
	}
	if err := f.Send(ctx, Message{}); err == nil || primary.calls != 4 || backup.calls != 4 {
		t.Fatalf("last resort not tried: %d %d", primary.calls, backup.calls)
	}
}
