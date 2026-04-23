output "publish_role_arn" {
  description = "AWS_ROLE_ARN for the aws-prod-publish CircleCI context."
  value       = aws_iam_role.publish.arn
}

output "aws_region" {
  description = "AWS_REGION for the aws-prod-publish CircleCI context."
  value       = var.aws_region
}

output "aws_account_id" {
  description = "AWS_ACCOUNT_ID for the aws-prod-publish CircleCI context."
  value       = data.aws_caller_identity.current.account_id
}

output "ecr_repo_name" {
  description = "ECR_REPO for the aws-prod-publish CircleCI context (the repo name, not the full URI)."
  value       = aws_ecr_repository.app.name
}

output "release_bucket" {
  description = "RELEASE_BUCKET for the aws-prod-publish CircleCI context."
  value       = aws_s3_bucket.releases.bucket
}

output "ecr_repository_uri" {
  description = "Full ECR URI (registry/repo). Useful for `docker pull` references."
  value       = aws_ecr_repository.app.repository_url
}

output "oidc_provider_arn" {
  description = "ARN of the CircleCI OIDC provider in this account."
  value       = aws_iam_openid_connect_provider.circleci.arn
}
