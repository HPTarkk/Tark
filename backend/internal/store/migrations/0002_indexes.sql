-- Indexes the first revision missed.
--
-- PostgreSQL does not index the referencing side of a foreign key. Deleting a
-- parent row (an account, a session, a refresh token) runs one lookup per
-- referencing table, and without an index each lookup scans the whole table.
-- Measured with 100k refresh tokens: deleting them all took 214 s before this
-- migration and 0.7 s after; deleting one account went from ~45 ms to ~2 ms,
-- and the old cost grew with table size.
--
-- The partial indexes of 0001 (sessions_user_live, the per-provider unique
-- indexes) cannot serve those lookups, because the lookup does not repeat
-- their WHERE clause.

-- Self reference: refresh_tokens.parent_id ... ON DELETE SET NULL. Also serves
-- the refresh retry path ("children of this token").
CREATE INDEX refresh_tokens_parent ON refresh_tokens (parent_id) WHERE parent_id IS NOT NULL;

-- Foreign keys to users that had no full index on user_id.
CREATE INDEX sessions_user ON sessions (user_id);
CREATE INDEX auth_flows_user ON auth_flows (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX google_tickets_user ON google_tickets (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX auth_identities_user ON auth_identities (user_id);
CREATE INDEX subscription_events_purchase ON subscription_events (purchase_id) WHERE purchase_id IS NOT NULL;

-- Columns the periodic sweeper filters on, so it does not scan whole tables
-- every ten minutes.
CREATE INDEX refresh_tokens_expiry ON refresh_tokens (expires_at);
CREATE INDEX sessions_expiry ON sessions (expires_at);
CREATE INDEX sessions_revoked ON sessions (revoked_at) WHERE revoked_at IS NOT NULL;
CREATE INDEX rate_limits_window ON rate_limits (window_start);
CREATE INDEX google_nonces_expiry ON google_nonces (expires_at);
CREATE INDEX google_seen_tokens_expiry ON google_seen_tokens (expires_at);
