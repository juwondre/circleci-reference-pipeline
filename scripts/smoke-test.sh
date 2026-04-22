#!/usr/bin/env bash
set -euo pipefail

# Structural smoke test of the freshly built image. Catches things unit tests
# can't see: missing files, wrong user, broken entrypoint shebang.
image="${1:?usage: smoke-test.sh <image>}"

run() {
  docker run --rm --entrypoint sh "$image" -c "$1"
}

echo "→ python is on PATH"
run 'command -v python >/dev/null'

echo "→ runs as non-root"
uid="$(run 'id -u')"
[ "$uid" != "0" ] || { echo "image must not run as root (uid=$uid)" >&2; exit 1; }

echo "→ app package is importable"
run 'python -c "import app.main"'

echo "→ entrypoint is executable"
run 'test -x scripts/entrypoint.sh'

echo "→ gunicorn binary is present"
run 'command -v gunicorn >/dev/null'

echo "smoke test passed for $image"
