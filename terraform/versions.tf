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

  backend "s3" {
    bucket         = "juwondre-cci-reference-tfstate"
    key            = "circleci-reference-pipeline/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "circleci-reference-pipeline-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
