output "publish_role_arn" {
  description = "Set this as AWS_ROLE_ARN in the aws-prod-publish CircleCI context."
  value       = aws_iam_role.publish.arn
}

output "ecr_repository_uri" {
  value = aws_ecr_repository.app.repository_url
}

output "release_bucket" {
  value = aws_s3_bucket.releases.bucket
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.circleci.arn
}
