package admin

import (
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HPTarkk/Tark/backend/internal/logfile"
	"github.com/HPTarkk/Tark/backend/internal/metrics"
)

type alertRow struct {
	Key      string
	Firing   bool
	Since    *time.Time
	Detail   string
	Notified *time.Time
	Updated  time.Time
}

// system shows how the service is doing right now: every alert check with
// its last reading, requests per route, Bazaar and mail calls, database
// connections and the Go process. Numbers only, so every role sees it.
func (s *Server) system(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Pool.Query(r.Context(), `
		SELECT key, firing, since, detail, last_notified_at, updated_at FROM alert_state ORDER BY firing DESC, key`)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	alerts, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (alertRow, error) {
		var a alertRow
		return a, row.Scan(&a.Key, &a.Firing, &a.Since, &a.Detail, &a.Notified, &a.Updated)
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	data := map[string]any{"Alerts": alerts}
	if s.Metrics != nil {
		hour, covered := s.Metrics.Window(time.Hour)
		five, _ := s.Metrics.Window(5 * time.Minute)
		data["M"] = map[string]any{
			"Started": s.Metrics.Started(),
			"Covered": covered.Round(time.Minute),
			"Hour":    hour,
			"HourAll": hour.All(),
			"Five":    five.All(),
			"Pool":    five.Pool,
			"Now":     s.Metrics.Now().Pool,
			"Runtime": metrics.ReadRuntime(),
		}
	}
	s.render(w, r, http.StatusOK, "system", data)
}

// The logs page shows at most this many lines per search.
const logLines = 200

// logs searches the kept log files. Owner only: an error message can carry
// an email address.
func (s *Server) logs(w http.ResponseWriter, r *http.Request) {
	if s.LogDir == "" {
		s.render(w, r, http.StatusOK, "logs", map[string]any{"Off": true})
		return
	}
	q := r.URL.Query()
	days, _ := strconv.Atoi(q.Get("days"))
	days = max(1, min(days, 30))
	level := q.Get("level")
	if level != "" && level != "WARN" && level != "ERROR" {
		level = ""
	}
	text := q.Get("q")
	if len([]rune(text)) > 200 {
		text = string([]rune(text)[:200])
	}
	lines, cut, err := logfile.Search(r.Context(), s.LogDir, logfile.Query{Days: days, MinLevel: level, Text: text, Limit: logLines}, s.now())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	kept, err := logfile.Days(s.LogDir)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.render(w, r, http.StatusOK, "logs", map[string]any{
		"Lines": lines, "Cut": cut, "Kept": kept, "Days": days, "Level": level, "Q": text, "Max": logLines,
	})
}

// latency formats a bucket bound in seconds.
func latency(sec float64) string {
	switch {
	case math.IsInf(sec, 1):
		return "> 10 s"
	case sec == 0:
		return "-"
	case sec < 1:
		return "≤ " + strconv.Itoa(int(sec*1000)) + " ms"
	}
	return "≤ " + strconv.FormatFloat(sec, 'f', -1, 64) + " s"
}
