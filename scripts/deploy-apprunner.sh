#!/usr/bin/env bash
set -euo pipefail

# Roll the just-published image SHA onto an App Runner service and block
# until the deploy reaches a terminal state. Called by deploy-dev /
# deploy-prod jobs. Required env (from the aws-prod-publish context):
#   AWS_ACCOUNT_ID, AWS_REGION, ECR_REPO
#   APPRUNNER_ECR_ACCESS_ROLE_ARN
#   APPRUNNER_SERVICE_DEV_ARN  (when invoked with "dev")
#   APPRUNNER_SERVICE_PROD_ARN (when invoked with "prod")

env="${1:?usage: deploy-apprunner.sh <dev|prod>}"
case "$env" in
  dev)  : "${APPRUNNER_SERVICE_DEV_ARN:?}";  arn="$APPRUNNER_SERVICE_DEV_ARN" ;;
  prod) : "${APPRUNNER_SERVICE_PROD_ARN:?}"; arn="$APPRUNNER_SERVICE_PROD_ARN" ;;
  *)    echo "env must be dev or prod" >&2; exit 1 ;;
esac

: "${AWS_ACCOUNT_ID:?}" "${AWS_REGION:?}" "${ECR_REPO:?}"
: "${APPRUNNER_ECR_ACCESS_ROLE_ARN:?}"

new_image="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${CIRCLE_SHA1}"

# update-service requires the full source_configuration block, including the
# auth role and runtime env vars. Anything omitted gets reset to defaults.
# Built with a heredoc to avoid a jq dependency (cimg/python doesn't ship it).
# Safe because $new_image, $sha, $role come from AWS-controlled identifiers
# that can't contain quotes/backslashes that would break JSON.
source_config=$(cat <<JSON
{
  "AuthenticationConfiguration": { "AccessRoleArn": "$APPRUNNER_ECR_ACCESS_ROLE_ARN" },
  "AutoDeploymentsEnabled": false,
  "ImageRepository": {
    "ImageIdentifier": "$new_image",
    "ImageRepositoryType": "ECR",
    "ImageConfiguration": {
      "Port": "8080",
      "RuntimeEnvironmentVariables": {
        "DATABASE_URL": "sqlite:////tmp/app.db",
        "BUILD_SHA": "$CIRCLE_SHA1"
      }
    }
  }
}
JSON
)

echo "→ Updating $env service to image $new_image"
op_id=$(aws apprunner update-service \
  --service-arn "$arn" \
  --source-configuration "$source_config" \
  --query 'OperationId' --output text)
echo "  OperationId: $op_id"

# Poll the operation until terminal. App Runner deploys typically take 2-4
# minutes; we time out at 12 minutes (60 polls x 12s). Note we DON'T
# suppress AWS CLI stderr — a permission/network error here used to mask
# itself as PENDING and burn the entire timeout silently.
echo "→ Waiting for deploy..."
for i in $(seq 1 60); do
  op_status=$(aws apprunner list-operations --service-arn "$arn" \
    --query "OperationSummaryList[?Id=='$op_id'] | [0].Status" \
    --output text)
  case "$op_status" in
    SUCCEEDED)
      echo "✓ $env deploy SUCCEEDED (poll $i)"
      exit 0 ;;
    FAILED|ROLLBACK_FAILED|ROLLBACK_SUCCEEDED)
      echo "✗ $env deploy ended in $op_status" >&2
      exit 1 ;;
    PENDING|IN_PROGRESS|None|"")
      [ $((i % 5)) -eq 0 ] && echo "  $env: $op_status (poll $i)"
      ;;
    *)
      echo "  $env: unexpected status '$op_status' (poll $i)"
      ;;
  esac
  sleep 12
done

echo "✗ $env deploy did not reach a terminal state within 12 minutes" >&2
exit 1
