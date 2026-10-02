-- The admin panel. Admins are not app accounts: a stolen app account can
-- never become an admin, and an admin is never a user of the app.

CREATE TABLE admin_users (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email                 text        NOT NULL UNIQUE,
    name                  text        NOT NULL,
    -- owner: everything, manages admins. support: looks users up and (later)
    -- acts on them. viewer: dashboard only.
    role                  text        NOT NULL CHECK (role IN ('owner', 'support', 'viewer')),
    password_hash         text        NOT NULL,
    -- Set for a password someone else chose (a new admin, a reset). The admin
    -- must pick their own before doing anything else.
    must_change_password  boolean     NOT NULL DEFAULT true,
    -- TOTP secret, encrypted with TARK_DATA_KEY. Null until enrolled; no page
    -- but enrolment is reachable without it.
    totp_secret           bytea,
    -- Last accepted TOTP time step, so a code cannot be used twice.
    totp_last_step        bigint      NOT NULL DEFAULT 0,
    disabled_at           timestamptz,
    created_by            uuid REFERENCES admin_users(id) ON DELETE SET NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    last_login_at         timestamptz,
    CONSTRAINT admin_users_name_len CHECK (char_length(name) BETWEEN 1 AND 64)
);
CREATE INDEX admin_users_created_by ON admin_users (created_by) WHERE created_by IS NOT NULL;

-- A browser signed in to the panel. stage 'password' has passed the
-- password and still owes a TOTP code; only 'full' reaches any page.
CREATE TABLE admin_sessions (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash    bytea       NOT NULL UNIQUE,
    admin_id      uuid        NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    stage         text        NOT NULL CHECK (stage IN ('password', 'full')),
    csrf          text        NOT NULL,
    -- A TOTP secret being enrolled, encrypted; moved to admin_users once a
    -- code from it is proven.
    pending_totp  bytea,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,
    ip_hash       text
);
CREATE INDEX admin_sessions_admin ON admin_sessions (admin_id);
CREATE INDEX admin_sessions_expiry ON admin_sessions (expires_at);

-- Everything admins do, including every sign-in and every look at a full
-- email address. Kept longer than audit_events: it is the record of who
-- touched what.
CREATE TABLE admin_events (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at           timestamptz NOT NULL DEFAULT now(),
    admin_id     uuid REFERENCES admin_users(id) ON DELETE SET NULL,
    kind         text        NOT NULL,
    -- The app user acted on, if any. Cleared when that account is deleted.
    target_user  uuid,
    ip_hash      text,
    details      jsonb       NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX admin_events_admin ON admin_events (admin_id) WHERE admin_id IS NOT NULL;
CREATE INDEX admin_events_target ON admin_events (target_user) WHERE target_user IS NOT NULL;
CREATE INDEX admin_events_at ON admin_events (at DESC);

-- Last run of scheduled jobs such as the weekly summary email.
CREATE TABLE job_runs (
    name         text PRIMARY KEY,
    last_run_at  timestamptz NOT NULL
);
