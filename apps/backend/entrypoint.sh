#!/usr/bin/env bash
set -e

# Run migrations
python manage.py migrate --noinput

# SimpleJWT never deletes token_blacklist rows on its own: OutstandingToken
# grows by one row per login forever, and password change/reset blacklists a
# user's whole (ever-longer) list. Neither deploy target has a scheduler for
# `manage.py flushexpiredtokens` (Render free tier has no cron; the compose
# host runs no crond), so flush here — at boot and then daily in-process.
# Failures only log: a stale-row backlog must never block serving traffic,
# but that also makes a broken command silent — test_token_flush.py pins
# both the command and this wiring.
flush_tokens() {
  python manage.py flushexpiredtokens \
    || echo "flushexpiredtokens failed; retrying in 24h" >&2
}
flush_tokens
(while :; do
  sleep 86400
  flush_tokens
done) &

# Start gunicorn, binding to Render's $PORT (default to 8000 locally if PORT unset)
exec gunicorn config.wsgi:application \
  --bind 0.0.0.0:${PORT:-8000} \
  --workers 3 \
  --timeout 60
