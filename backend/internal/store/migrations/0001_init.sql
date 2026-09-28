-- Tark backend schema, first revision.
--
-- Conventions
-- - Secrets are never stored in the clear. High-entropy tokens are stored as
--   HMAC-SHA256 lookup hashes (bytea, 32 bytes). Values that must be read
--   back (Bazaar purchase tokens, queued email bodies) are AES-256-GCM
--   ciphertexts bound to their row.
-- - Emails are stored normalised (trimmed, lower-cased). Uniqueness is
--   enforced by the database, not by a check-then-insert in code.
-- - Times are timestamptz.

CREATE TABLE users (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name              text        NOT NULL,
    -- One of the app's predefined avatars. Null means "not chosen". The
    -- server does not interpret it, so new avatars ship with the app alone.
    avatar_id         text,
    status            text        NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'disabled')),
    -- Bumped on every profile change; exposed as the profile ETag.
    profile_version   bigint      NOT NULL DEFAULT 1,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT users_name_len CHECK (char_length(name) BETWEEN 1 AND 64),
    CONSTRAINT users_avatar_len CHECK (avatar_id IS NULL OR char_length(avatar_id) BETWEEN 1 AND 32)
);

-- Emails live apart from users so that changing an address later is adding
-- a row, verifying it and moving the primary flag, with no schema change.
-- Only verified addresses are ever stored here; an address being verified
-- lives in auth_flows until it is proven.
CREATE TABLE user_emails (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    email        text        NOT NULL,
    is_primary   boolean     NOT NULL DEFAULT false,
    verified_at  timestamptz NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    removed_at   timestamptz,
    CONSTRAINT user_emails_len CHECK (char_length(email) BETWEEN 3 AND 254)
);
-- An address belongs to at most one account at a time.
CREATE UNIQUE INDEX user_emails_email_active ON user_emails (email) WHERE removed_at IS NULL;
-- One primary address per account.
CREATE UNIQUE INDEX user_emails_one_primary ON user_emails (user_id) WHERE is_primary AND removed_at IS NULL;
CREATE INDEX user_emails_user ON user_emails (user_id);

-- Ways to sign in. Google identities are keyed by Google's stable subject
-- id, never by email, because a Google account's email can change.
CREATE TABLE auth_identities (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider          text        NOT NULL CHECK (provider IN ('password', 'google')),
    provider_subject  text,
    password_hash     text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT auth_identities_shape CHECK (
        (provider = 'password' AND password_hash IS NOT NULL AND provider_subject IS NULL) OR
        (provider = 'google'   AND password_hash IS NULL     AND provider_subject IS NOT NULL)
    )
);
CREATE UNIQUE INDEX auth_identities_one_password ON auth_identities (user_id) WHERE provider = 'password';
CREATE UNIQUE INDEX auth_identities_google_subject ON auth_identities (provider_subject) WHERE provider = 'google';
CREATE UNIQUE INDEX auth_identities_one_google ON auth_identities (user_id) WHERE provider = 'google';

-- A signed-in device. Access tokens name the session, and every request
-- checks it is still live, so logging out takes effect immediately.
CREATE TABLE sessions (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at     timestamptz NOT NULL DEFAULT now(),
    last_seen_at   timestamptz NOT NULL DEFAULT now(),
    -- Hard end, however active the session is.
    expires_at     timestamptz NOT NULL,
    revoked_at     timestamptz,
    revoke_reason  text,
    platform       text CHECK (platform IN ('android', 'ios')),
    install_key    text
);
CREATE INDEX sessions_user_live ON sessions (user_id) WHERE revoked_at IS NULL;

-- Rotating refresh tokens. Each use marks the token used and issues a
-- child. Presenting a used token again (outside a short retry window) is
-- treated as theft and ends the whole session.
CREATE TABLE refresh_tokens (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  uuid        NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    token_hash  bytea       NOT NULL UNIQUE,
    parent_id   uuid REFERENCES refresh_tokens(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    used_at     timestamptz,
    -- Replaced by a retry before the app ever received it. Presenting a
    -- burned token can only mean it was intercepted.
    burned_at   timestamptz
);
CREATE INDEX refresh_tokens_session ON refresh_tokens (session_id);

-- Multi-step flows that prove control of an email address: registration,
-- password reset, email change. The flow id is a secret handle held only by
-- the app that started the flow; both the code and the email link must be
-- presented together with it, so a link opened elsewhere cannot complete a
-- flow somebody else started.
CREATE TABLE auth_flows (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    handle_hash       bytea       NOT NULL UNIQUE,
    purpose           text        NOT NULL CHECK (purpose IN ('register', 'password_reset', 'email_change')),
    email             text        NOT NULL,
    -- Set for email_change (the account changing) and for password_reset
    -- when the address belongs to an account. A reset flow for an unknown
    -- address is created too, so the response does not reveal which
    -- addresses exist; it simply can never complete.
    user_id           uuid REFERENCES users(id) ON DELETE CASCADE,
    -- register: the name and password chosen at sign-up, held until the
    -- address is proven.
    name              text,
    password_hash     text,
    locale            text        NOT NULL DEFAULT 'en',
    code_hash         bytea,
    link_hash         bytea,
    attempts          int         NOT NULL DEFAULT 0,
    sends             int         NOT NULL DEFAULT 0,
    last_sent_at      timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    expires_at        timestamptz NOT NULL,
    -- When the code or link was accepted.
    verified_at       timestamptz,
    -- When the flow produced its result (account created, password set,
    -- email changed). A completed flow can never be used again.
    completed_at      timestamptz,
    -- password_reset: after verification, a one-time ticket authorises
    -- choosing the new password.
    ticket_hash       bytea UNIQUE,
    ticket_expires_at timestamptz
);
CREATE INDEX auth_flows_expiry ON auth_flows (expires_at);
CREATE INDEX auth_flows_email ON auth_flows (email, purpose);

-- Short-lived tickets that continue a Google sign-in: linking to an
-- existing password account (after the password is proven) or finishing a
-- new account that still needs a name.
CREATE TABLE google_tickets (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_hash     bytea       NOT NULL UNIQUE,
    purpose         text        NOT NULL CHECK (purpose IN ('link', 'signup')),
    google_subject  text        NOT NULL,
    email           text        NOT NULL,
    suggested_name  text,
    user_id         uuid REFERENCES users(id) ON DELETE CASCADE,
    attempts        int         NOT NULL DEFAULT 0,
    platform        text,
    install_key     text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz NOT NULL,
    used_at         timestamptz
);
CREATE INDEX google_tickets_expiry ON google_tickets (expires_at);

-- Single-use nonces for Google sign-in, and hashes of ID tokens already
-- accepted, so a captured ID token cannot be replayed.
CREATE TABLE google_nonces (
    nonce_hash  bytea PRIMARY KEY,
    expires_at  timestamptz NOT NULL,
    used_at     timestamptz
);
CREATE TABLE google_seen_tokens (
    token_hash  bytea PRIMARY KEY,
    expires_at  timestamptz NOT NULL
);

-- Fixed-window counters keyed by an HMAC of what is limited (IP, email,
-- account), so the table never holds a raw IP address or email.
CREATE TABLE rate_limits (
    key           text PRIMARY KEY,
    window_start  timestamptz NOT NULL,
    hits          int         NOT NULL
);

-- Idempotency records for retryable writes. Only successful responses are
-- kept; the body is encrypted because it can carry a flow handle or a
-- signed entitlement.
CREATE TABLE idempotency_keys (
    scope         text        NOT NULL,
    key           text        NOT NULL,
    request_hash  bytea       NOT NULL,
    state         text        NOT NULL CHECK (state IN ('in_progress', 'done')),
    status        int,
    body          bytea,
    created_at    timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,
    PRIMARY KEY (scope, key)
);
CREATE INDEX idempotency_keys_expiry ON idempotency_keys (expires_at);

-- Outgoing email. A request only enqueues; a worker sends. That way a
-- retried request never sends twice and a slow mail server never slows a
-- request. The body is encrypted and wiped once sent.
CREATE TABLE mail_outbox (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind          text        NOT NULL,
    recipient     bytea       NOT NULL,
    body          bytea,
    attempts      int         NOT NULL DEFAULT 0,
    next_try_at   timestamptz NOT NULL DEFAULT now(),
    -- Past this the message is pointless (its code has expired); drop it.
    discard_after timestamptz NOT NULL,
    sent_at       timestamptz,
    failed_at     timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX mail_outbox_pending ON mail_outbox (next_try_at) WHERE sent_at IS NULL AND failed_at IS NULL;

-- Security-relevant events. Never holds passwords, codes, tokens or raw IP
-- addresses; the IP is an HMAC so repeated abuse from one address can be
-- correlated without storing the address.
CREATE TABLE audit_events (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at          timestamptz NOT NULL DEFAULT now(),
    kind        text        NOT NULL,
    user_id     uuid,
    ip_hash     text,
    details     jsonb       NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX audit_events_user ON audit_events (user_id, at DESC);
CREATE INDEX audit_events_at ON audit_events (at);

-- Cafe Bazaar purchases. A purchase token belongs to exactly one account
-- (unique token_hash). The token itself is kept encrypted because the
-- background re-check needs it.
CREATE TABLE bazaar_purchases (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash         bytea       NOT NULL UNIQUE,
    token_enc          bytea       NOT NULL,
    sku                text        NOT NULL,
    -- active: Bazaar reports a paid period. expired: the period ended
    -- normally. refunded: revoked before its period ended. invalid: Bazaar
    -- never recognised the token.
    state              text        NOT NULL CHECK (state IN ('pending', 'active', 'expired', 'refunded', 'invalid')),
    initiated_at       timestamptz,
    valid_until        timestamptz,
    auto_renewing      boolean     NOT NULL DEFAULT false,
    refunded_at        timestamptz,
    -- Consecutive definitive "not found" answers for a token Bazaar used to
    -- recognise. One is treated as a possible glitch; see billing.
    missing_count      int         NOT NULL DEFAULT 0,
    check_failures     int         NOT NULL DEFAULT 0,
    last_checked_at    timestamptz,
    last_verified_at   timestamptz,
    next_check_at      timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX bazaar_purchases_user ON bazaar_purchases (user_id);
CREATE INDEX bazaar_purchases_due ON bazaar_purchases (next_check_at) WHERE next_check_at IS NOT NULL;

-- Per-account subscription standing that outlives any one purchase.
CREATE TABLE subscription_accounts (
    user_id            uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- Conservative check mode after a refund before expiry. Cleared by the
    -- server after one clean paid period that started after it was set.
    suspicious_since   timestamptz,
    last_verified_at   timestamptz,
    updated_at         timestamptz NOT NULL DEFAULT now()
);

-- History the refund / suspicious logic and support can read.
CREATE TABLE subscription_events (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id      uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    purchase_id  uuid REFERENCES bazaar_purchases(id) ON DELETE SET NULL,
    kind         text        NOT NULL,
    at           timestamptz NOT NULL DEFAULT now(),
    details      jsonb       NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX subscription_events_user ON subscription_events (user_id, at DESC);
