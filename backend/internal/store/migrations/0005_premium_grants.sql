-- Premium given by hand from the admin panel (testers, goodwill), never a
-- fake Bazaar purchase. Every grant names who gave it and why, ends on its
-- own, and can be revoked; the history stays.
CREATE TABLE premium_grants (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    granted_by  uuid REFERENCES admin_users(id) ON DELETE SET NULL,
    reason      text        NOT NULL,
    starts_at   timestamptz NOT NULL DEFAULT now(),
    ends_at     timestamptz NOT NULL,
    revoked_at  timestamptz,
    revoked_by  uuid REFERENCES admin_users(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT premium_grants_reason_len CHECK (char_length(reason) BETWEEN 3 AND 500),
    CONSTRAINT premium_grants_period CHECK (ends_at > starts_at)
);
CREATE INDEX premium_grants_user ON premium_grants (user_id);
CREATE INDEX premium_grants_granted_by ON premium_grants (granted_by) WHERE granted_by IS NOT NULL;
CREATE INDEX premium_grants_revoked_by ON premium_grants (revoked_by) WHERE revoked_by IS NOT NULL;
