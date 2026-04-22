#!/usr/bin/env bash
set -euo pipefail

# Wait for Postgres before booting Gunicorn so the first request doesn't 500.
scripts/wait-for-postgres.sh

# Bootstrap schema once, before gunicorn forks. Doing it inside create_app()
# means every worker races on CREATE TABLE and the loser hits UniqueViolation.
python -c "from app.db import Base, engine; from app import models; Base.metadata.create_all(bind=engine)"

exec gunicorn \
  --bind 0.0.0.0:8080 \
  --workers "${GUNICORN_WORKERS:-2}" \
  --access-logfile - \
  --error-logfile - \
  'app.main:create_app()'
