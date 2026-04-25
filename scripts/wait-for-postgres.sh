#!/usr/bin/env bash
set -euo pipefail

# Block until DATABASE_URL is reachable. Used by both the app entrypoint and
# the test job before pytest runs. WAIT_ATTEMPTS overrides the 30s default.
url="${DATABASE_URL:-postgresql+psycopg://app:app@localhost:5432/appdb}"

# Only network-backed databases need a wait. SQLite (or any file-based / in-
# memory backend) has nothing to TCP-ping; skip without erroring so the same
# entrypoint works for App Runner deploys that use sqlite:////tmp/app.db.
case "$url" in
  postgres*|mysql*|mongodb*|redis*) ;;
  *) echo "wait-for-postgres: $url is not a network DB; skipping" ; exit 0 ;;
esac

host_port="$(printf '%s' "$url" | sed -E 's#.*@([^/]+)/.*#\1#')"
host="${host_port%%:*}"
port="${host_port##*:}"

attempts="${WAIT_ATTEMPTS:-30}"
for i in $(seq 1 "$attempts"); do
  if (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
    echo "postgres up at ${host}:${port} (attempt ${i})"
    exit 0
  fi
  sleep 1
done

echo "postgres never came up at ${host}:${port}" >&2
exit 1
