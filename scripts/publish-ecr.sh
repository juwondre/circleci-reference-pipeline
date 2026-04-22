#!/usr/bin/env bash
set -euo pipefail

# Push the loaded image to ECR under both the SHA and `latest`. Run only on
# main, with creds from the restricted publish context.
: "${AWS_ACCOUNT_ID:?}" "${AWS_REGION:?}" "${ECR_REPO:?}"

local_image="${1:-app:${CIRCLE_SHA1}}"
registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
remote="${registry}/${ECR_REPO}"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry"

docker tag  "$local_image" "${remote}:${CIRCLE_SHA1}"
docker tag  "$local_image" "${remote}:latest"
docker push "${remote}:${CIRCLE_SHA1}"
docker push "${remote}:latest"

echo "pushed ${remote}:${CIRCLE_SHA1}"
