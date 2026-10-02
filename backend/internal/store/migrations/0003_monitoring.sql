-- Alerts and backups.

-- One row per alert the monitor knows. The row survives restarts, so a
-- firing alert is not announced again every time the server starts, and the
-- "resolved" email goes out exactly once.
CREATE TABLE alert_state (
    key               text PRIMARY KEY,
    firing            boolean     NOT NULL DEFAULT false,
    since             timestamptz,
    last_notified_at  timestamptz,
    -- What the last check saw: counts and thresholds, never personal data.
    detail            text        NOT NULL DEFAULT '',
    updated_at        timestamptz NOT NULL DEFAULT now()
);

-- Every backup attempt, so the monitor can tell when the last good one is
-- too old and the admin panel can list them.
CREATE TABLE backup_runs (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at   timestamptz NOT NULL DEFAULT now(),
    finished_at  timestamptz,
    ok           boolean     NOT NULL DEFAULT false,
    -- File name only, inside the backup directory.
    file         text,
    bytes        bigint,
    row_count    bigint,
    error        text
);
CREATE INDEX backup_runs_started ON backup_runs (started_at DESC);
