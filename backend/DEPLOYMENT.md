# Deploying the Tark backend

The backend is one static binary (`tarkd`) in a small Docker image, plus
PostgreSQL. Three ways to run it, from least to most work for you:

| | What | Good for | Files |
|---|---|---|---|
| **A. Local test machine** | PostgreSQL in Docker (or native), API on `localhost:8080` | Development, trying the API, running tests | `setup-backend.ps1`, `docker-compose.dev.yml` |
| **B. One server (VPS)** | Docker Compose: PostgreSQL + API + Caddy (automatic HTTPS) | A first real deployment on any Linux server you can SSH into | `deploy/vps/` |
| **C. ArvanCloud container hosting** | Push the image to a registry; the platform runs it with a managed or private database | The plan in the README | `deploy/arvan/build-and-push.ps1` + the checklist below |

Anything you deploy needs the same four things: the **image**, the **secrets**
(`tarkd keygen`), a **PostgreSQL** database, and **TLS** in front. The scripts
below handle the first three; B handles TLS with Caddy, C leaves it to the
platform.

## A. Local, one command

```powershell
.\backend\setup-backend.ps1
```

It installs/starts what is missing (Go, PostgreSQL), generates secrets into the
git-ignored `backend\.env.development`, builds, migrates, runs the tests and
starts the API. Re-running is safe. Open <http://localhost:8080/docs/> for the
interactive API documentation. Options: `-Database docker|native|external`,
`-SkipTests`, `-NoRun`, `-Reset`, `-HttpPort`, `-DbPort`, `-GoProxy`; see
`Get-Help .\backend\setup-backend.ps1 -Full`.

## B. One server with Docker Compose

**Server:** any Linux machine with Docker Engine + the Compose plugin, ports 80
and 443 open, and a domain whose DNS (A/AAAA record) points at it. Caddy gets
and renews the HTTPS certificate by itself.

**Your machine:** Docker, and the `ssh`/`scp` that ship with Windows 10/11.

```powershell
# 1. First time: build, ship the image, create .env.production with fresh secrets
.\backend\deploy\vps\deploy.ps1 -Server deploy@203.0.113.10 -Init

# 2. Fill in the CHANGE_ME values (domain, SMTP, Bazaar; the Google client id is preset)
ssh deploy@203.0.113.10 nano /opt/tark/.env.production

# 3. Deploy (and every later update)
.\backend\deploy\vps\deploy.ps1 -Server deploy@203.0.113.10

# If an update misbehaves
.\backend\deploy\vps\deploy.ps1 -Server deploy@203.0.113.10 -Rollback
```

Step 1 prints the **public entitlement key**; put it in the app's billing
config. `deploy.ps1 -Init` is safe to repeat: it never overwrites an existing
`.env.production`.

By default the image is copied straight to the server (no registry, so it works
where Docker Hub or other registries are hard to reach). With `-Registry
registry.example.com/team` it is pushed there and the server pulls it. The
server still pulls `postgres` and `caddy` from Docker Hub: set
`TARK_POSTGRES_IMAGE` / `TARK_CADDY_IMAGE` in `.env.production` to mirrors if it
cannot.

**Back up `.env.production`** somewhere private: losing `TARK_DATA_KEY` makes
the stored Bazaar tokens unreadable, and changing `TARK_PASSWORD_PEPPER` locks
every password account out.

**Alerts.** Put the address(es) that should hear about trouble in
`TARK_ALERT_EMAILS` (comma-separated). The server checks itself every minute
and emails when the API returns internal errors, email stops going out,
Bazaar checks fail, sign-in failures spike (a likely attack), the disk passes
80%, or the nightly backup fails or is late. It emails again every 6 hours
while a problem lasts and once more when it clears. Alerts hold counts only,
never personal data. To check that they reach you:

```sh
cd /opt/tark && bash remote.sh alert-test
```

**Server down? The server cannot tell you that itself.** Add one free outside
check that emails you when `https://<your API domain>/readyz` stops answering
(it also fails when the database is down). For example UptimeRobot's free
plan: create an HTTP(s) monitor on that URL with a 5-minute interval and your
email as the alert contact. Monitors abroad sometimes cannot reach servers in
Iran for reasons that have nothing to do with the server (filtering, routing),
so treat one short blip as noise and a lasting one as real.

**Database backups** are automatic. Every night (23:00 UTC, about 02:30 in
Tehran; `TARK_BACKUP_HOUR_UTC` changes it) the API writes an encrypted backup
of the whole database into the `backups` volume, reads it back to prove it
decrypts, and keeps 14 days (`TARK_BACKUP_KEEP_DAYS`). A server that was down
at that hour catches up when it is back. The first deploy with this feature
generates `TARK_BACKUP_KEY` and prints it once: **save it in your password
manager.** Without it no backup can be restored, and losing the server loses
the copy in `.env.production`.

A backup that only lives on the server dies with the server, so copy them to
your computer regularly (by hand, or daily from Windows Task Scheduler; see the
script's help):

```powershell
.\backend\deploy\vps\fetch-backups.ps1 -Server deploy@203.0.113.10
```

On the server: `bash remote.sh backups` lists them and `bash remote.sh
backup-now` makes one immediately.

**Restoring** (onto a new server, or to test a backup). Restore only goes into
an **empty** database and refuses one that has tables, so it can never
overwrite live data.

1. Deploy as usual with `-Init`, then put the old server's `.env.production`
   values in place: at least `TARK_BACKUP_KEY` and `TARK_DATA_KEY`,
   `TARK_LOOKUP_KEY`, `TARK_TOKEN_KEY`, `TARK_PASSWORD_PEPPER` and
   `TARK_ENTITLEMENT_KEYS`/`TARK_ENTITLEMENT_ACTIVE_KID`. Without the old data
   key the stored Bazaar tokens are unreadable; without the old pepper no
   password works.
2. Start only the database: `docker compose --env-file .env.production -f
   docker-compose.prod.yml up -d db`.
3. Copy the backup file to the server and load it:
   ```sh
   cd /opt/tark
   docker compose --env-file .env.production -f docker-compose.prod.yml run --rm -T --no-deps api restore - < tark-YYYYMMDD-HHMMSS.tbk
   ```
4. Deploy normally. The API applies any newer migrations on start.

**Behind the ArvanCloud CDN instead of facing the internet?** See the comment in
`deploy/vps/Caddyfile` and the "Deploying on ArvanCloud" section of the README:
both Caddy and `TARK_TRUSTED_PROXIES` must know the CDN's address ranges, or
per-IP limits see the CDN instead of the caller.

## C. ArvanCloud container hosting

I do not have the panel's current screens or your registry details, so this is
a checklist of **what must be true**, not click-by-click steps; use ArvanCloud's
own documentation for where each setting lives.

1. **Image.** Build and push:
   ```powershell
   .\backend\deploy\arvan\build-and-push.ps1 -Registry <registry-host/namespace> -Username <user>
   ```
   If the build cannot reach Docker Hub from Iran, build on a machine that can,
   or through ArvanCloud's registry mirror.
2. **Database.** A managed PostgreSQL 14+ (or one on the private network). Use
   `sslmode=require` or `verify-full`; the server **refuses to start in
   production with a plaintext connection to a public-looking host**. If the
   database is on a private network but has a public-looking hostname, set
   `TARK_DATABASE_ALLOW_PLAINTEXT=true`. Migrations run on start, under an
   advisory lock, so several instances starting together are fine.
3. **Secrets** (the platform's secret store, never the repo). Generate once:
   `docker run --rm <image> keygen`. Required: `TARK_DATABASE_URL`,
   `TARK_TOKEN_KEY`, `TARK_LOOKUP_KEY`, `TARK_DATA_KEY`, `TARK_PASSWORD_PEPPER`,
   `TARK_ENTITLEMENT_KEYS`, `TARK_ENTITLEMENT_ACTIVE_KID`,
   `TARK_GOOGLE_CLIENT_IDS`, SMTP (`TARK_SMTP_*`, `TARK_MAIL_FROM`) and Bazaar
   (`TARK_BAZAAR_*`) credentials. Each can also be a file path (`NAME_FILE`).
   `TARK_ENV` must be `production` (the default).
4. **Client IP.** `TARK_CLIENT_IP_HEADER=ar-real-ip` and `TARK_TRUSTED_PROXIES`
   with ArvanCloud's edge ranges plus any load balancer in between (full list in
   the README). Without this every per-IP limit applies to the proxy.
5. **Port and health checks.** The container listens on `8080`. Liveness:
   `GET /healthz`; readiness: `GET /readyz` (checks the database). The image
   also has a built-in Docker `HEALTHCHECK`.
6. **Scaling.** Several replicas are safe (workers use row locks). Mind the
   database's connection limit: each replica opens up to `TARK_DB_MAX_CONNS`
   (default 20) **plus** `TARK_DB_AUX_CONNS` (default 5), so
   `replicas x 25 <= max_connections`, or lower those two.
7. **Docs.** `/docs` is off in production. To publish the interactive docs set
   `TARK_DOCS_ENABLED=true`; they are served from the binary and call the same
   host they were opened on.

## D. Automating it later (not set up)

A GitHub Actions workflow could build the image on every merge to `main` and
run `build-and-push.ps1`'s steps (`docker build`, `docker push`) with the
registry password in a repository secret, then SSH to the server and run
`remote.sh up <image>`. Not added, because it needs your decisions on the
registry, the server's SSH key and who may deploy. The existing
`.github/workflows/backend.yml` already tests the code, checks dependencies
for known vulnerabilities and verifies that the image builds.

## What is and is not verified

Verified by running them: the Go build and tests (against real PostgreSQL),
`setup-backend.ps1` end to end (in PowerShell 7 on Linux, against an external
PostgreSQL), `remote.sh` (with a stand-in for `docker`), the dry-run output of
both deploy scripts, and both compose files (`docker compose config`).

**Not** verified, because there was no Windows machine, Docker image pulls or
server in the environment they were written in: the Windows PowerShell 5.1
behaviour (the scripts avoid PowerShell 7-only syntax and work around the known
5.1 pitfalls), `winget` installs of Go and PostgreSQL, `docker compose up` of
the production stack, Caddy obtaining a certificate, and anything on
ArvanCloud's platform. Treat the first run of each as a rehearsal.
