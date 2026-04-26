#!/usr/bin/env bash
set -euo pipefail

# Bundle the image tar + a JSON manifest under the commit SHA. One known
# location per release.
: "${AWS_REGION:?}" "${RELEASE_BUCKET:?}"

image_tar="${1:?usage: publish-s3.sh <image-tar>}"
prefix="releases/${CIRCLE_SHA1}"

cat > manifest.json <<JSON
{
  "sha":        "${CIRCLE_SHA1}",
  "branch":     "${CIRCLE_BRANCH:-unknown}",
  "build_url":  "${CIRCLE_BUILD_URL:-unknown}",
  "built_at":   "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "image_tar":  "$(basename "$image_tar")",
  "image_size": $(wc -c < "$image_tar")
}
JSON

aws s3 cp "$image_tar"   "s3://${RELEASE_BUCKET}/${prefix}/$(basename "$image_tar")"
aws s3 cp manifest.json  "s3://${RELEASE_BUCKET}/${prefix}/manifest.json"

echo "published s3://${RELEASE_BUCKET}/${prefix}/"
