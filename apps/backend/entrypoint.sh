#!/usr/bin/env bash
set -e

# Run migrations
python manage.py migrate --noinput

# Start gunicorn, binding to Render's $PORT (default to 8000 locally if PORT unset)
exec gunicorn config.wsgi:application \
  --bind 0.0.0.0:${PORT:-8000} \
  --workers 3 \
  --timeout 60
