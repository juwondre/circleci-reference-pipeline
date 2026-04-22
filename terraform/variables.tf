variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "circleci_org_id" {
  description = "CircleCI Organization UUID. Find under Org Settings -> Overview."
  type        = string
}

variable "circleci_project_id" {
  description = "CircleCI Project UUID for circleci-reference-pipeline."
  type        = string
}

variable "default_branch" {
  description = "Branch the publish jobs run on. Pinned in the OIDC trust policy so the role can't be assumed from other refs."
  type        = string
  default     = "master"
}

variable "ecr_repo_name" {
  type    = string
  default = "circleci-reference-pipeline"
}

variable "release_bucket_name" {
  description = "Globally unique S3 bucket for the publish-s3 job."
  type        = string
}

variable "role_name" {
  type    = string
  default = "circleci-reference-pipeline-publish"
}
