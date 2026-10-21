package admin

import (
	"net/http"
	"time"
)

// Settings are this admin's own: how the panel looks and reads in this
// browser, their password, and where they are signed in. Theme and language
// live in cookies, so they also apply on the sign-in pages.

const (
	themeCookie = "tark_admin_theme"
	themeSystem = "system"
	themeLight  = "light"
	themeDark   = "dark"
)

// themeOf is the theme picked in this browser: light, dark, or "" to follow
// the system.
func themeOf(r *http.Request) string {
	if c, err := r.Cookie(themeCookie); err == nil && (c.Value == themeLight || c.Value == themeDark) {
		return c.Value
	}
	return ""
}

// prefTTL keeps a display preference for a year, like the language switch.
const prefTTL = 365 * 24 * time.Hour

// savedKinds are the settings a ?saved= confirmation can name.
var savedKinds = map[string]bool{"theme": true, "language": true, "password": true, "sessions": true}

func (s *Server) settings(w http.ResponseWriter, r *http.Request) {
	s.showSettings(w, r, http.StatusOK, "")
}

// showSettings renders the page; pwErr is a refused password change.
func (s *Server) showSettings(w http.ResponseWriter, r *http.Request, status int, pwErr string) {
	ctx := r.Context()
	a, sess := adminFrom(ctx), sessionFrom(ctx)
	// Other live sessions: the same test loadSession applies.
	var others int
	err := s.Pool.QueryRow(ctx, `
		SELECT count(*) FROM admin_sessions
		WHERE admin_id = $1 AND id <> $2 AND stage = 'full' AND expires_at > now() AND last_seen_at > $3`,
		a.ID, sess.id, s.now().Add(-sessionIdle)).Scan(&others)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	theme := themeOf(r)
	if theme == "" {
		theme = themeSystem
	}
	data := map[string]any{
		"ThemeChoice": theme, "Others": others, "Since": sess.createdAt,
		"PasswordError": pwErr, "MinPassword": adminMinPassword,
	}
	if saved := r.URL.Query().Get("saved"); r.Method == http.MethodGet && savedKinds[saved] {
		key := "settings.saved." + saved
		data["Saved"] = T(ctx, key)
		// The page is the same one the change was made on: no entrance replay.
		data["Posted"] = true
	}
	s.render(w, r, status, "settings", data)
}

func (s *Server) saveTheme(w http.ResponseWriter, r *http.Request) {
	switch v := r.PostFormValue("theme"); v {
	case themeLight, themeDark:
		s.setCookie(w, themeCookie, v, prefTTL)
	case themeSystem:
		s.clearCookie(w, themeCookie)
	default:
		http.Error(w, T(r.Context(), "msg.fail"), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/settings?saved=theme", http.StatusSeeOther)
}

func (s *Server) saveLanguage(w http.ResponseWriter, r *http.Request) {
	v := r.PostFormValue("lang")
	if !validLang(v) {
		http.Error(w, T(r.Context(), "msg.fail"), http.StatusBadRequest)
		return
	}
	s.setCookie(w, langCookie, v, prefTTL)
	http.Redirect(w, r, "/settings?saved=language", http.StatusSeeOther)
}

// endOtherSessions signs this admin out of every other browser.
func (s *Server) endOtherSessions(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	a, sess := adminFrom(ctx), sessionFrom(ctx)
	tag, err := s.Pool.Exec(ctx, `DELETE FROM admin_sessions WHERE admin_id = $1 AND id <> $2`, a.ID, sess.id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.record(ctx, a.ID, "admin.sessions_ended", "", ipFrom(ctx), map[string]any{"count": tag.RowsAffected()})
	http.Redirect(w, r, "/settings?saved=sessions#sessions", http.StatusSeeOther)
}
