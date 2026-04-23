terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Uncomment after running the bootstrap apply that creates the bucket and
  # lock table in backend.tf, then run `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   bucket         = "REPLACE_WITH_state_bucket_name"
  #   key            = "circleci-reference-pipeline/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "circleci-reference-pipeline-tfstate-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}
