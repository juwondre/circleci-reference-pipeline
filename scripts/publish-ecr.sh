#!/usr/bin/env bash
set -euo pipefail

# Push the loaded image to ECR under its commit SHA. ECR is configured for
# immutable tags, so each publish produces a unique, unambiguous artifact and
# a re-run of a given build can't silently overwrite what's in prod.
: "${AWS_ACCOUNT_ID:?}" "${AWS_REGION:?}" "${ECR_REPO:?}"

local_image="${1:-app:${CIRCLE_SHA1}}"
registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
remote="${registry}/${ECR_REPO}"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry"

docker tag  "$local_image" "${remote}:${CIRCLE_SHA1}"
docker push "${remote}:${CIRCLE_SHA1}"

echo "pushed ${remote}:${CIRCLE_SHA1}"
