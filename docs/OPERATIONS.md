# Operations — backups, monitoring, reboot survival

Production runs on a single self-hosted box at `/home/deployer/symbio`,
deployed by `.github/workflows/deploy-server.yml` (self-hosted runner runs
`docker compose -f docker-compose.prod.yml up -d --build` on push to `main`).
Staging is the Render service in `render.yaml`. This doc covers the KAN-46
hardening: nightly off-host Postgres backups, uptime monitoring, and
surviving a host reboot.

## Database backups

`ops/db-backup/` is a sidecar container in `docker-compose.prod.yml`. Every
night at 03:00 UTC (`BACKUP_HOUR_UTC` to change) it:

1. `pg_dump --format=custom` of the prod database over the compose network,
2. verifies the dump with `pg_restore --list` (a dump that can't be read is
   worse than an alert),
3. ships it off-host with `rclone copyto` to `BACKUP_RCLONE_REMOTE`,
4. prunes remote copies older than `BACKUP_RETENTION_DAYS` (default 30),
5. pings `BACKUP_HEALTHCHECK_URL` on success, `<url>/fail` on any failure.

There is deliberately no on-host copy: the threat model is losing the box
(or its docker volume), and the DB is small enough that restore-from-remote
is fast.

### One-time setup (prod host)

All config lives in `/home/deployer/symbio/.env` (gitignored, survives the
deploy workflow's `git clean -fd`). rclone is configured purely through
`RCLONE_CONFIG_<NAME>_*` env vars — no rclone.conf to mount. Example for an
S3-compatible bucket (Backblaze B2, Cloudflare R2, etc.):

```bash
# .env additions
BACKUP_RCLONE_REMOTE=offsite:symbio-db-backups
BACKUP_HEALTHCHECK_URL=https://hc-ping.com/<uuid>   # from healthchecks.io
# BACKUP_RETENTION_DAYS=30                          # default
# BACKUP_HOUR_UTC=3                                 # default

RCLONE_CONFIG_OFFSITE_TYPE=s3
RCLONE_CONFIG_OFFSITE_PROVIDER=Other     # or: Cloudflare
RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID=...
RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY=...
RCLONE_CONFIG_OFFSITE_ENDPOINT=https://...
```

The remote name in `BACKUP_RCLONE_REMOTE` (before the `:`) must match the
`<NAME>` in the `RCLONE_CONFIG_<NAME>_*` vars, uppercased.

Then create the dead-man check on [healthchecks.io](https://healthchecks.io):
schedule "daily", grace time 6 hours, alert to email. This is what catches
"the backup silently stopped running" — the /fail ping catches "the backup
ran and broke".

### Verify a run without waiting for 03:00

```bash
cd /home/deployer/symbio
docker compose -f docker-compose.prod.yml up -d --build db-backup
docker compose -f docker-compose.prod.yml exec db-backup backup.sh
rclone lsl "$BACKUP_RCLONE_REMOTE"   # or check the bucket in the provider UI
```

### Restore drill (also the actual restore procedure)

Do this once after setup, and after any Postgres major-version bump:

```bash
cd /home/deployer/symbio
# pull the latest dump using the same env the sidecar uses
docker compose -f docker-compose.prod.yml exec db-backup sh -c \
  'rclone copy "$BACKUP_RCLONE_REMOTE/<file>.pgdump" /tmp/'
# restore into a scratch database and sanity-check row counts
docker compose -f docker-compose.prod.yml exec db psql -U postgres \
  -c 'CREATE DATABASE restore_check;'
docker compose -f docker-compose.prod.yml exec db-backup sh -c \
  'pg_restore --host=db --username=postgres --dbname=restore_check /tmp/<file>.pgdump'
docker compose -f docker-compose.prod.yml exec db psql -U postgres -d restore_check \
  -c 'SELECT count(*) FROM nutrition_mealentry;'
docker compose -f docker-compose.prod.yml exec db psql -U postgres \
  -c 'DROP DATABASE restore_check;'
```

For a real disaster (volume lost): bring up `db` empty, restore into the
real database name with `--clean --if-exists`, then start `backend`.

Version-drift note: the sidecar's `pg_dump` major version must match the
`postgres` image in `docker-compose.prod.yml`. When bumping one, bump the
other (`ops/db-backup/Dockerfile`) — a mismatch fails the nightly run loudly
rather than producing dumps.

## Uptime monitoring

`/health/` (`config/urls.py`) is a shallow liveness endpoint — it proves
DNS → TLS → reverse proxy → gunicorn, which covers the realistic outage
modes on a single-box deploy (db-down surfaces as 500s on real endpoints
and in Sentry).

Setup (manual, free tier): [UptimeRobot](https://uptimerobot.com) HTTP(s)
monitor on `https://symbio.drakon4ik.uk/health/`, 5-minute interval,
keyword check for `"status": "ok"`, alert to email. Optionally a second
monitor for staging (`https://fitness-backend-2ux8.onrender.com/health/`)
with alerts off — Render free tier sleeps, so it would only be noise.

## Host reboot survival

`docker-compose.prod.yml` sets `restart: unless-stopped` on every service,
which restarts containers after a reboot **only if** the docker daemon
itself starts. Verify on the host:

```bash
systemctl is-enabled docker            # must be "enabled"
systemctl is-enabled <runner-service>  # actions-runner service, or deploys
                                       # silently stop after a reboot
```

The GitHub Actions runner is the easy one to forget: containers come back
without it, but the next push to `main` never deploys. If it was installed
with `./svc.sh install`, it is a systemd unit named
`actions.runner.<org-repo>.<name>.service`.

After the next planned reboot, confirm: `docker ps` shows `db`, `backend`,
`db-backup`; the UptimeRobot monitor stayed green (or alerted and
recovered); the healthchecks.io check pings the following night.
