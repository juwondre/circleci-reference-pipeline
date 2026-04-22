#!/usr/bin/env bash
set -euo pipefail

# Wait for Postgres before booting Gunicorn so the first request doesn't 500.
scripts/wait-for-postgres.sh

exec gunicorn \
  --bind 0.0.0.0:8080 \
  --workers "${GUNICORN_WORKERS:-2}" \
  --access-logfile - \
  --error-logfile - \
  'app.main:create_app()'
