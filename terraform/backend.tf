# State backend infra. Two-step bootstrap:
#   1. Apply once with the local backend to create the bucket and lock table.
#   2. Uncomment the `backend "s3"` block in versions.tf and run
#      `terraform init -migrate-state` to move state off disk.

variable "state_bucket_name" {
  description = "Globally unique S3 bucket that will hold Terraform state."
  type        = string
}

variable "state_lock_table_name" {
  type    = string
  default = "circleci-reference-pipeline-tfstate-lock"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = var.state_lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
