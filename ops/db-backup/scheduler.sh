#!/usr/bin/env bash
# Sleep-until-03:00-UTC loop instead of crond: busybox crond strips the
# container environment, and the whole config for backup.sh lives in env
# vars. A skipped run (host down at backup time) is caught by the
# healthchecks.io dead-man alert, not retried here.
set -euo pipefail

BACKUP_HOUR_UTC="${BACKUP_HOUR_UTC:-3}"

while :; do
  now=$(date -u +%s)
  next=$(date -u -d "today ${BACKUP_HOUR_UTC}:00" +%s)
  if ((next <= now)); then
    next=$(date -u -d "tomorrow ${BACKUP_HOUR_UTC}:00" +%s)
  fi
  echo "next backup at $(date -u -d "@${next}" +%Y-%m-%dT%H:%M:%SZ)"
  sleep $((next - now))
  # A failed run already pinged /fail from backup.sh; keep the loop alive.
  backup.sh || echo "backup failed; will retry tomorrow" >&2
done
