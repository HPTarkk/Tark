# Load testing

`cmd/tarkload` fills a development database with made-up accounts and drives
the API the way the app does. It refuses to run unless `TARK_ENV=development`.
**Never point it at a server that carries real accounts**: seeding needs an
empty database, and a load run is indistinguishable from an attack.

## Running it

```sh
# An empty database and a development environment (see README, "Running it locally").
# The load generator plays the part of Caddy, so the server must trust it:
export TARK_CLIENT_IP_HEADER=X-Forwarded-For TARK_TRUSTED_PROXIES=127.0.0.0/8

go run ./cmd/tarkload seed -users 200000        # about 30 s
go run ./cmd/tarkd serve &
go run ./cmd/tarkload run -rps 100,200,400 -step 30s -state /tmp/tarkload-state.json
```

`run` starts app events at a fixed rate, one step per value of `-rps`, and
prints sent / status / latency per request kind. Events are:

| Event | Requests |
|---|---|
| `launch` | `POST /auth/token/refresh`, `GET /profile`, `GET /subscription`; one in ten also `PUT /profile` |
| `login` | `POST /auth/login` (a full-cost password check) |
| `register` | `POST /auth/register` (a password hash, a flow, an email in the outbox) |
| `forgot` | `POST /auth/password/forgot` |
| `plans` | `GET /subscription/plans` |

`-mix launch=88,login=5,register=2,forgot=1,plans=4` (the default) sets their
shares. Every account calls from its own address; `-share-ip N` puts N accounts
behind each address to see the per-address limits. `-state` remembers rotated
refresh tokens, so a second run does not present tokens the first one used.

The run is open-loop: events start on schedule whether or not the server has
answered earlier ones, and a late start counts as latency. "Events shed" means
more than `-workers` were in flight, which is the server being past its limit.

To imitate a small server, pin the API and PostgreSQL to as many cores as it
has (`taskset -c 0,1 ...`) and the load generator to others.

## Results, November 2026

200,000 accounts, 267,000 sessions, 800,000 refresh tokens, 1,000,000 audit
events (625 MB). API and PostgreSQL 16 with default settings together on 2
cores of a 2.1 GHz Xeon; the load generator on 2 others.

| Load | Requests/s | p50 | p95 | Errors |
|---|---|---|---|---|
| 100 launches/s | 310 | 1.8 ms | 3.9 ms | 0 |
| 300 launches/s | 930 | 1.7 ms | 4.6 ms | 0 |
| 600 launches/s | 1,860 | 2.1 ms | 6.4 ms | 0 |
| 800 launches/s | 2,480 | 14 ms | 330 ms | 0 |
| 1,000 launches/s (past the limit) | 2,730 | 540 ms | 1.3 s | 0, events shed |
| Mix, 200 events/s (14 sign-ins or sign-ups a second) | 570 | 1.7 ms | 8.7 ms | 0 |
| 300 launches/s + 100 sign-ins/s (five times what hashing can do) | 890 | 3.2 ms | launches 25 ms | 2,203 sign-ins answered 503 + Retry-After after 5 s; no launch affected |

Limits: about 850 launches a second (processor, split roughly evenly between
the API and PostgreSQL), and about 20 password checks a second (one hashing
slot, 46 MiB and about 45 ms each). The API process peaked at 243 MB.

What 200,000 accounts need, on generous assumptions (one in five opens the
app on a given day, three times; the busiest hour is ten times the average):
about 14 launches a second at peak. Everyone opening the app within the same
ten minutes is 330 a second.

The production server (2 vCPU, 2 GB) has not been measured and must not be
load-tested while it carries real accounts. Assuming its cores do a third of
the work of the ones above: about 200 launches a second with millisecond
answers and about 7 sign-ins a second, which is fourteen times the modelled
peak.

## What the test changed

- **Password hashing took every processor.** With 4 hashing slots on 2 cores,
  15 sign-ins a second turned a 4 ms token refresh into 2 s for everyone.
  Slots now default to half the processors, and a hash that cannot start
  within 5 s is refused with 503 instead of queueing (`TARK_PASSWORD_HASH_SLOTS`).
- **Used refresh tokens were kept for six months**, one row per app launch:
  about 5.6 GB at this size, most of the database and of every nightly backup.
  They are now dropped 30 days after use (under 1 GB).
- **Rate-limit counters waited for the disk** on almost every request. The
  table is now unlogged.
- **The admin dashboard read every account several times** (1.2 s for the
  sign-up chart). `users (created_at)` is now indexed.

Every query on the request path was already indexed and under 0.2 ms.
