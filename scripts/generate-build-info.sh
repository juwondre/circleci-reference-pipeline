#!/usr/bin/env bash
set -euo pipefail

# Emits build args to a sourcable file so the Dockerfile build and the S3
# release manifest stay in sync.
out="${1:-build.env}"
sha="${CIRCLE_SHA1:-$(git rev-parse HEAD)}"
short="${sha:0:7}"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
  echo "BUILD_SHA=${sha}"
  echo "BUILD_SHORT=${short}"
  echo "BUILD_TIME=${ts}"
  echo "BUILD_BRANCH=${CIRCLE_BRANCH:-local}"
} > "$out"

cat "$out"
