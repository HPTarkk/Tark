// Package mail sends account email through a queue.
//
// Requests never talk to the mail server. They add a message to the
// outbox inside their own database transaction, so a message exists if and
// only if the change that caused it was committed, and a retried request
// cannot send twice. A worker delivers the queue through a Sender.
//
// The provider is still open, so everything provider-specific sits behind
// Sender. The SMTP implementation works with any provider that offers
// authenticated SMTP over TLS.
package mail

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"mime"
	"net"
	"net/mail"
	"net/smtp"
	"strings"
	"time"
)

// Message is one email, already rendered.
type Message struct {
	To      string `json:"-"`
	Subject string `json:"subject"`
	Text    string `json:"text"`
	// HTML is optional. With it the email is multipart/alternative, and
	// clients that cannot show HTML fall back to Text.
	HTML string `json:"html,omitempty"`
}

// Sender delivers a message. An error means "try again later"; the outbox
// decides when to give up.
type Sender interface {
	Send(ctx context.Context, m Message) error
}

// SMTPSender speaks authenticated SMTP, always over TLS: implicit TLS
// (usually port 465) or STARTTLS (usually 587). A server that does not
// offer STARTTLS is refused rather than used in the clear.
type SMTPSender struct {
	Host     string
	Port     int
	Username string
	Password string
	From     string
	FromName string
	Implicit bool
	Timeout  time.Duration
}

func (s *SMTPSender) Send(ctx context.Context, m Message) error {
	raw, err := s.render(m)
	if err != nil {
		return err
	}
	timeout := s.Timeout
	if timeout == 0 {
		timeout = 20 * time.Second
	}
	deadline := time.Now().Add(timeout)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	addr := net.JoinHostPort(s.Host, fmt.Sprint(s.Port))
	tlsConfig := &tls.Config{ServerName: s.Host, MinVersion: tls.VersionTLS12}
	dialer := &net.Dialer{Timeout: time.Until(deadline)}

	var conn net.Conn
	if s.Implicit {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, tlsConfig)
	} else {
		conn, err = dialer.DialContext(ctx, "tcp", addr)
	}
	if err != nil {
		return fmt.Errorf("mail: dial: %w", err)
	}
	_ = conn.SetDeadline(deadline)
	client, err := smtp.NewClient(conn, s.Host)
	if err != nil {
		conn.Close()
		return fmt.Errorf("mail: handshake: %w", err)
	}
	defer client.Close()

	if !s.Implicit {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return errors.New("mail: server does not offer STARTTLS; refusing to send in the clear")
		}
		if err := client.StartTLS(tlsConfig); err != nil {
			return fmt.Errorf("mail: starttls: %w", err)
		}
	}
	if s.Username != "" {
		if err := client.Auth(smtp.PlainAuth("", s.Username, s.Password, s.Host)); err != nil {
			return fmt.Errorf("mail: auth: %w", err)
		}
	}
	if err := client.Mail(s.From); err != nil {
		return fmt.Errorf("mail: from: %w", err)
	}
	if err := client.Rcpt(m.To); err != nil {
		return fmt.Errorf("mail: rcpt: %w", err)
	}
	w, err := client.Data()
	if err != nil {
		return fmt.Errorf("mail: data: %w", err)
	}
	if _, err := w.Write(raw); err != nil {
		return fmt.Errorf("mail: write: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("mail: close data: %w", err)
	}
	// The server has accepted the message once DATA is closed. A failed
	// QUIT after that is not a failed send, and retrying would deliver the
	// email twice.
	_ = client.Quit()
	return nil
}

func (s *SMTPSender) render(m Message) ([]byte, error) {
	for _, v := range []string{m.To, m.Subject, s.From, s.FromName} {
		if strings.ContainsAny(v, "\r\n") {
			return nil, errors.New("mail: header value contains a line break")
		}
	}
	if _, err := mail.ParseAddress(m.To); err != nil {
		return nil, fmt.Errorf("mail: bad recipient: %w", err)
	}
	from := (&mail.Address{Name: s.FromName, Address: s.From}).String()
	domain := s.From[strings.LastIndex(s.From, "@")+1:]
	id := make([]byte, 16)
	_, _ = rand.Read(id)

	var b strings.Builder
	header := func(k, v string) { b.WriteString(k + ": " + v + "\r\n") }
	header("From", from)
	header("To", m.To)
	header("Subject", mime.QEncoding.Encode("utf-8", m.Subject))
	header("Date", time.Now().UTC().Format(time.RFC1123Z))
	header("Message-ID", fmt.Sprintf("<%x@%s>", id, domain))
	header("MIME-Version", "1.0")
	// Transactional mail: ask auto-responders not to reply.
	header("Auto-Submitted", "auto-generated")
	if m.HTML == "" {
		writePart(&b, "text/plain", m.Text)
		return []byte(b.String()), nil
	}
	boundary := fmt.Sprintf("tark-%x", id)
	header("Content-Type", `multipart/alternative; boundary="`+boundary+`"`)
	b.WriteString("\r\n")
	// Plain text first: clients show the last part they can render.
	b.WriteString("--" + boundary + "\r\n")
	writePart(&b, "text/plain", m.Text)
	b.WriteString("--" + boundary + "\r\n")
	writePart(&b, "text/html", m.HTML)
	b.WriteString("--" + boundary + "--\r\n")
	return []byte(b.String()), nil
}

// writePart writes a part's headers and base64 body. Base64 keeps every
// line short and ASCII whatever the content, and cannot collide with the
// boundary.
func writePart(b *strings.Builder, contentType, body string) {
	b.WriteString("Content-Type: " + contentType + "; charset=\"utf-8\"\r\n")
	b.WriteString("Content-Transfer-Encoding: base64\r\n\r\n")
	enc := base64.StdEncoding.EncodeToString([]byte(strings.ReplaceAll(body, "\n", "\r\n")))
	for len(enc) > 76 {
		b.WriteString(enc[:76] + "\r\n")
		enc = enc[76:]
	}
	b.WriteString(enc + "\r\n")
}

// LogSender writes messages to the log instead of sending them. Allowed
// only in development (config enforces it), because the log would then
// hold verification codes.
type LogSender struct {
	Log *slog.Logger
}

func (s *LogSender) Send(ctx context.Context, m Message) error {
	s.Log.WarnContext(ctx, "development mail (not sent)", "to", m.To, "subject", m.Subject, "text", m.Text)
	return nil
}
