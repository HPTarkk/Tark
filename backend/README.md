# Tark backend

Go + PostgreSQL service behind the Tark app: accounts and sign-in, the
profile, and Cafe Bazaar subscription verification with the signed
entitlement the app checks offline. It is planned to run on ArvanCloud.

The contract with the app is [`api/openapi.yaml`](api/openapi.yaml). Both
sides are written against it.

## Layout

```
cmd/tarkd            the binary: serve, worker, migrate, keygen, pubkeys
internal/app         wires everything together (also used by the e2e tests)
internal/httpapi     routing, middleware, JSON in and out; no business rules
internal/auth        sign-up, login, Google, sessions, password and email flows
internal/profile     GET/PUT profile
internal/billing     Bazaar client, subscription state, signed entitlement, re-check worker
internal/mail        outbox queue, SMTP sender, email templates (English, Persian)
internal/google      Google ID token verification
internal/password    Argon2id hashing with a server pepper
internal/ratelimit   shared fixed-window counters (PostgreSQL)
internal/idempotency safe retries for writes
internal/audit       security event log (no secrets, no raw IPs)
internal/secure      random tokens, keyed hashes, AES-GCM
internal/store       connection pool and embedded migrations
```

It is one binary with separate packages. Billing is the part most likely to
need its own service one day, and it only talks to the rest through the
database and its own package API.

## Running it locally

```sh
# PostgreSQL 14+ with a database called tark
cp .env.development.example .env.development
go run ./cmd/tarkd keygen            # paste the secrets into .env.development
set -a; . ./.env.development; set +a
go run ./cmd/tarkd serve             # migrates, then listens on :8080
```

In development `TARK_MAIL_DRIVER=log` writes emails (with their codes) to the
log instead of sending them. `TARK_BAZAAR_FAKE=true` answers every purchase
token as a 30-day subscription (tokens starting with `invalid` are unknown,
and tokens starting with `down` simulate an outage). Neither setting is
accepted in production.

Tests, including end-to-end tests against a real database (they wipe its
`public` schema):

```sh
TARK_TEST_DATABASE_URL=postgres://tark:tark@localhost:5432/tark_test go test -race -p 1 ./...
```

## Configuration

Everything comes from environment variables. Each secret can also be passed
as a file path in `NAME_FILE`. The service refuses to start with a missing
or malformed secret.

| Variable | Meaning |
|---|---|
| `TARK_ENV` | `production` (default) or `development` |
| `TARK_DATABASE_URL` | PostgreSQL URL. Use `sslmode=verify-full` when the database is not on a private network. |
| `TARK_HTTP_ADDR` | Listen address, default `:8080` |
| `TARK_RUN_WORKERS` | Run the mail, billing and cleanup workers in the API process (default `true`). Several instances are safe. |
| `TARK_TOKEN_KEY`, `TARK_LOOKUP_KEY`, `TARK_DATA_KEY`, `TARK_PASSWORD_PEPPER` | 32-byte secrets from `keygen` |
| `TARK_ENTITLEMENT_KEYS`, `TARK_ENTITLEMENT_ACTIVE_KID` | Ed25519 seeds `kid:seed,…` and the one that signs. `tarkd pubkeys` prints the public halves for the app's `TARK_ENTITLEMENT_KEYS`. |
| `TARK_GOOGLE_CLIENT_IDS` | Comma-separated OAuth client ids accepted as the ID token audience |
| `TARK_GOOGLE_REQUIRE_NONCE` | Default `true`. See open questions. |
| `TARK_LINK_BASE_URL` | Base of email links, default `https://tarkk.ir` |
| `TARK_SMTP_HOST`, `TARK_SMTP_PORT`, `TARK_SMTP_USERNAME`, `TARK_SMTP_PASSWORD`, `TARK_SMTP_SECURITY` | SMTP server. `starttls` (587) or `tls` (465); there is no plaintext mode. |
| `TARK_MAIL_FROM`, `TARK_MAIL_FROM_NAME` | Sender address and name |
| `TARK_SMTP2_HOST`, `TARK_SMTP2_PORT`, `TARK_SMTP2_USERNAME`, `TARK_SMTP2_PASSWORD`, `TARK_SMTP2_SECURITY`, `TARK_SMTP2_FROM` | Optional backup SMTP server, used when the first one fails. Meant for a provider inside Iran. |
| `TARK_BAZAAR_CLIENT_ID`, `TARK_BAZAAR_CLIENT_SECRET`, `TARK_BAZAAR_REFRESH_TOKEN` | Bazaar developer API credentials |
| `TARK_BAZAAR_PACKAGE`, `TARK_BAZAAR_SKUS`, `TARK_BAZAAR_BASE_URL` | Package name, accepted SKUs, API base |
| `TARK_CLIENT_IP_HEADER`, `TARK_TRUSTED_PROXIES` | Where the real client IP is, and which peers may set it (CIDRs). Needed behind ArvanCloud's CDN or load balancer. |
| `TARK_POLICY_GRACE_HOURS`, `TARK_POLICY_REFRESH_DAYS`, `TARK_POLICY_SUSPICIOUS_OFFLINE_HOURS` | Offline policy signed into every entitlement (defaults 72, 5, 72) |
| `TARK_ACCESS_TOKEN_TTL`, `TARK_REFRESH_TOKEN_TTL`, `TARK_SESSION_MAX_LIFETIME` | Defaults 15m, 180 days idle, 2 years |

## How the pieces behave

**Sign-up with email.** `POST /auth/register` always answers 202 with a
`flowId`. A new address gets a 6-digit code and a link
`https://tarkk.ir/v/register#<token>`. An address that already has an
account gets an email saying so and no code. The account only exists once
the code or link is verified, so nobody can pre-register someone else's
address. Verifying signs the app in straight away.

**Deep links.** The app stores the `flowId` in secure storage when a flow
starts, so a link works whether the app was closed, in the background or on
the code screen. The server needs both the `flowId` and the link token, so a
link opened on another phone cannot complete the flow. The person types the
code there instead. The token sits in the URL fragment, which mail scanners
and web servers never see.

**Google.** The server checks the ID token itself (Google's keys, issuer,
audience, expiry, verified email, one-time nonce) and never takes the email
or name from anywhere else. Accounts are keyed by Google's account id. If
the address already has a password account, the answer is `link_required`,
and the accounts are linked once that password is entered.

**Sessions.** Access tokens last 15 minutes and are checked against the
session row on every request, so logging out works immediately. Refresh
tokens rotate on every use. A retry within 60 seconds is allowed; any other
reuse ends the session. Password reset, password change and email change end
the other sessions.

**Brute force and enumeration.** Codes allow 5 wrong tries, then a new code
is needed. Login failures are limited per address and IP and per address.
Every limit key is an HMAC, so the rate-limit table holds no IPs or emails.
Password hashing (Argon2id, OWASP parameters) runs through a bounded pool so
a login flood queues instead of exhausting memory.

**Subscriptions.** A purchase token is bound to one account by a unique
index. Concurrent or repeated submissions are serialised by a row lock and
give the same answer, and the `Idempotency-Key` replays it. A Bazaar outage
never downgrades anyone: the last verified state is signed with
`bazaarChecked: false`. Turning off auto-renew is never suspicious. A refund,
meaning the period cut short or the token revoked (seen twice in a row, so
one odd answer cannot take a subscription away), puts the account in the
conservative mode. One clean paid period afterwards clears it. A worker
re-checks purchases mid-period and around renewal, so refunds are noticed
even if the app is never opened.

**Email.** Requests only queue mail inside their transaction, and a worker
sends it. A retried request cannot send twice, and a slow mail server cannot
slow sign-up. Queued bodies are encrypted and wiped after sending. Each email
has an HTML part in the app's colours (right-to-left for Persian, with a dark
version where the mail app supports it) and a plain-text part with the same
words. If a backup SMTP server is set, a failed send goes to it, and the
failed server is skipped for two minutes so an outage costs one timeout, not
one per email.

**Account deletion.** `POST /account/delete` needs the account's email typed
out, the password (or a fresh Google sign-in), and, while a paid Bazaar period
runs, a separate acknowledgement that deleting does not cancel the Bazaar
subscription. Then the account and everything tied to it are deleted at once,
every session ends, and a confirmation email is sent. Purchases go with it, so
the same Bazaar purchase can be restored in a new account. Security events
stay for their year without the account id.

**Data kept** (relevant to the privacy policy): name, avatar id, email
(current and replaced ones, with dates), password hash, Google account id,
sessions (platform, install public key, created and last-seen time), Bazaar
purchase tokens (encrypted), SKU, dates and state, subscription history, and
security events for one year with IPs stored only as HMACs. Deleting the
account removes all of it except those security events, which lose the
account id. Pending sign-ups,
codes and queued mail expire within a day. Nothing about voice, rooms,
contacts or location reaches this server.

## Deploying on ArvanCloud

- Build the image from this folder (`Dockerfile`, distroless, non-root).
  Docker Hub may not be reachable from inside Iran, so builds may need
  ArvanCloud's registry mirror.
- Use managed PostgreSQL or a private-network database. The app runs
  migrations on start, under an advisory lock.
- Put secrets in the platform's secret store, never in the repo.
- Terminate TLS at ArvanCloud and set `TARK_CLIENT_IP_HEADER` and
  `TARK_TRUSTED_PROXIES` to match its edge. Without them, per-IP limits
  apply to the proxy's address.
- Health checks: `GET /healthz` (process up) and `GET /readyz` (database
  reachable).

## Still open

1. **Bazaar refunds.** Bazaar's subscription API never reports refunds or
   cancellations, and Bazaar has no subscription refunds of its own (a
   cancelled subscription runs to the end of its period). So there is no
   admin refund action. The server only infers a revocation from a period cut
   short, or from a known token no longer being found, in case Bazaar support
   ever revokes one.
2. **Email provider.** Gmail SMTP with an app password on the support
   account is the primary (free, a few hundred emails a day). It still needs
   testing from an ArvanCloud server. A backup provider inside Iran for
   international outages is not chosen yet.
3. **Google nonce.** On by default. It needs the app's Google sign-in library
   to pass a nonce (Credential Manager on Android and GoogleSignIn on iOS
   both can). If the chosen Flutter plugin cannot, set
   `TARK_GOOGLE_REQUIRE_NONCE=false`. Replay of the same ID token is still
   refused either way.
4. **App links.** `https://tarkk.ir/v/*` needs `/.well-known/assetlinks.json`
   (Android signing certificate SHA-256) and
   `/.well-known/apple-app-site-association` (Apple Team ID, once there is an
   iOS app), plus a small fallback page for people who open the link on a
   computer.
5. **ArvanCloud client IP.** The header ArvanCloud puts the visitor's IP in
   and its edge IP ranges are not confirmed yet. Until they are set, per-IP
   limits see the proxy's address.
6. **Deletion outside the app.** Google Play also asks for a web page where
   people can request deletion without the app.
7. **Sign in with Apple.** Not planned until there is an iOS app. Apple's
   rule 4.8 may require it next to Google sign-in then.
