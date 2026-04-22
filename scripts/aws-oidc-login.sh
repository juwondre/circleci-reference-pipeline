#!/usr/bin/env bash
set -euo pipefail

# Trades the CircleCI OIDC token for short-lived AWS creds. No long-lived
# keys ever touch the runner.
: "${AWS_ROLE_ARN:?set AWS_ROLE_ARN in the restricted context}"
: "${AWS_REGION:?set AWS_REGION in the restricted context}"
: "${CIRCLE_OIDC_TOKEN_V2:?CircleCI did not inject an OIDC token; check job context}"

creds="$(aws sts assume-role-with-web-identity \
  --role-arn "$AWS_ROLE_ARN" \
  --role-session-name "circleci-${CIRCLE_WORKFLOW_ID:-local}" \
  --web-identity-token "$CIRCLE_OIDC_TOKEN_V2" \
  --duration-seconds 1800 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)"

read -r ak sk st <<<"$creds"
{
  echo "export AWS_ACCESS_KEY_ID=$ak"
  echo "export AWS_SECRET_ACCESS_KEY=$sk"
  echo "export AWS_SESSION_TOKEN=$st"
  echo "export AWS_REGION=$AWS_REGION"
  echo "export AWS_DEFAULT_REGION=$AWS_REGION"
} >> "$BASH_ENV"

echo "assumed $AWS_ROLE_ARN for 30m"
