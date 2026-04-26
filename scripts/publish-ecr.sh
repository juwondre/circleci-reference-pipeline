#!/usr/bin/env bash
set -euo pipefail

# Push the loaded image to ECR under its commit SHA. ECR is configured for
# immutable tags, so each publish produces a unique, unambiguous artifact and
# a re-run of a given build can't silently overwrite what's in prod.
: "${AWS_ACCOUNT_ID:?}" "${AWS_REGION:?}" "${ECR_REPO:?}"

local_image="${1:-app:${CIRCLE_SHA1}}"
registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
remote="${registry}/${ECR_REPO}"

# Idempotency: if this SHA is already in ECR, skip the push. Otherwise a
# pipeline rerun (or a CircleCI auto-retry on a transient post-push failure)
# would hit `tag immutable, cannot be overwritten` and fail.
if aws ecr describe-images \
     --region "$AWS_REGION" \
     --repository-name "$ECR_REPO" \
     --image-ids "imageTag=${CIRCLE_SHA1}" \
     >/dev/null 2>&1; then
  echo "skip: ${remote}:${CIRCLE_SHA1} is already in ECR"
  exit 0
fi

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry"

docker tag  "$local_image" "${remote}:${CIRCLE_SHA1}"
docker push "${remote}:${CIRCLE_SHA1}"

echo "pushed ${remote}:${CIRCLE_SHA1}"
