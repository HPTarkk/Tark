-- Changes found by load-testing with 200,000 accounts (see LOADTEST.md).

-- The admin dashboard counts sign-ups per day and per period. Without this
-- index each of those counts read every account: the 30-day chart alone
-- took 1.2 s at 200,000 accounts.
CREATE INDEX users_created ON users (created_at);

-- Used refresh tokens are swept 30 days after use (auth.Sweep) instead of
-- staying until they would have expired, six months later. The sweep runs
-- every ten minutes and must not read the whole table to find them.
CREATE INDEX refresh_tokens_used ON refresh_tokens (used_at) WHERE used_at IS NOT NULL;

-- Rate-limit counters are written by almost every request and are worth
-- nothing after a crash: the worst case of losing them is that windows start
-- again. An unlogged table skips the write-ahead log, so counting a request
-- no longer waits for the disk. PostgreSQL empties the table after a crash.
ALTER TABLE rate_limits SET UNLOGGED;
