#!/usr/bin/env bash
# One backup run: pg_dump the prod database, verify the dump is restorable,
# ship it off-host with rclone, prune old copies, ping healthchecks.io.
# Config comes from .env via docker-compose.prod.yml; see docs/OPERATIONS.md
# for setup, restore drill, and how to trigger a run manually.
set -euo pipefail

: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${BACKUP_RCLONE_REMOTE:?BACKUP_RCLONE_REMOTE is required, e.g. offsite:symbio-db-backups}"
POSTGRES_DB="${POSTGRES_DB:-symbio}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
PING_URL="${BACKUP_HEALTHCHECK_URL:-}"

hc_ping() { # $1: "" (success) or "/fail"
  if [ -n "$PING_URL" ]; then
    curl -fsS -m 10 --retry 3 -o /dev/null "${PING_URL}${1}" || true
  fi
}
trap 'hc_ping /fail' ERR

stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
dump="/tmp/symbio-${stamp}.pgdump"
trap 'rm -f "$dump"' EXIT

export PGPASSWORD="$POSTGRES_PASSWORD"
pg_dump --host=db --username=postgres --dbname="$POSTGRES_DB" \
  --format=custom --file="$dump"

# A dump pg_restore can't read is worthless on the day it matters — catch
# truncated/corrupt output now, while the ping can still alert someone.
pg_restore --list "$dump" >/dev/null

rclone copyto "$dump" "${BACKUP_RCLONE_REMOTE}/symbio-${stamp}.pgdump"

# Prune failures fail the whole run on purpose: unbounded growth on the
# remote is also a problem someone should hear about.
rclone delete --min-age "${RETENTION_DAYS}d" "$BACKUP_RCLONE_REMOTE"

hc_ping ""
echo "backup ok: symbio-${stamp}.pgdump ($(du -h "$dump" | cut -f1))"
