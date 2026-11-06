-- Cafe Bazaar reviews of the app, for the admin panel's Reviews page.
--
-- bazaar_reviews is a copy of what Bazaar's reviews API last reported, kept
-- by the sync worker (internal/reviews). The page reads only this copy, so
-- browsing never waits on Bazaar. Fields Bazaar may not send are nullable.

CREATE TABLE bazaar_reviews (
    id                 bigint      PRIMARY KEY,           -- Bazaar's review id
    user_account_id    text        NOT NULL,              -- pseudonymous Bazaar user id
    rate               smallint    NOT NULL CHECK (rate BETWEEN 1 AND 5),
    body               text        NOT NULL,
    -- Lower case, Arabic ي/ك folded to Persian ی/ک, zero-width joiners and
    -- diacritics dropped: what the page's search matches against.
    search_text        text        NOT NULL,
    -- Bazaar's publish_date, or when the review was first seen when Bazaar
    -- does not send one (date_known false).
    published_at       timestamptz NOT NULL,
    date_known         boolean     NOT NULL,
    is_edited          boolean,
    likes              integer,
    dislikes           integer,
    app_version_code   integer,
    sdk_version        integer,
    -- The developer reply Bazaar shows publicly, if any.
    reply_body         text,
    reply_email        text,
    reply_published_at timestamptz,
    reply_likes        integer,
    reply_dislikes     integer,
    first_seen_at      timestamptz NOT NULL DEFAULT now(),
    synced_at          timestamptz NOT NULL DEFAULT now(),
    -- Set when a complete sync no longer lists the review (removed on Bazaar).
    removed_at         timestamptz
);
CREATE INDEX bazaar_reviews_published ON bazaar_reviews (published_at DESC, id DESC) WHERE removed_at IS NULL;
CREATE INDEX bazaar_reviews_unanswered ON bazaar_reviews (rate, published_at DESC) WHERE removed_at IS NULL AND reply_body IS NULL;
CREATE INDEX bazaar_reviews_version ON bazaar_reviews (app_version_code) WHERE removed_at IS NULL;
CREATE INDEX bazaar_reviews_user ON bazaar_reviews (user_account_id);

-- Replies sent from the panel. 'sent' waits for Bazaar's approval; it turns
-- 'published' once the review comes back from Bazaar with a reply that is not
-- older than ours. At most one reply per review waits at a time.
CREATE TABLE bazaar_review_replies (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    review_id     bigint      NOT NULL REFERENCES bazaar_reviews(id) ON DELETE CASCADE,
    admin_id      uuid        REFERENCES admin_users(id) ON DELETE SET NULL,
    body          text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
    email         text,
    state         text        NOT NULL CHECK (state IN ('sent', 'published')),
    sent_at       timestamptz NOT NULL DEFAULT now(),
    published_at  timestamptz
);
CREATE UNIQUE INDEX bazaar_review_replies_waiting ON bazaar_review_replies (review_id) WHERE state = 'sent';
CREATE INDEX bazaar_review_replies_review ON bazaar_review_replies (review_id, sent_at DESC);
CREATE INDEX bazaar_review_replies_admin ON bazaar_review_replies (admin_id) WHERE admin_id IS NOT NULL;

-- One row: how the last syncs went, for the page header, the System page
-- and the monitor.
CREATE TABLE bazaar_review_sync (
    id               smallint    PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    last_started_at  timestamptz,
    last_finished_at timestamptz,
    last_success_at  timestamptz,
    -- A short code of the last failure (unauthorized, rate_limited,
    -- unavailable, refused, invalid_response), never Bazaar's raw text.
    last_error       text,
    failures         integer     NOT NULL DEFAULT 0,  -- consecutive failed runs
    last_seen        integer     NOT NULL DEFAULT 0,  -- reviews listed by the last complete run
    last_new         integer     NOT NULL DEFAULT 0   -- reviews first seen by the last run
);
