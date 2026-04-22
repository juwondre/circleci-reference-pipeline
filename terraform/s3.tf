resource "aws_s3_bucket" "releases" {
  bucket = var.release_bucket_name
}

# Block all public access. The publish-s3 job writes via OIDC, no anon reads.
resource "aws_s3_bucket_public_access_block" "releases" {
  bucket                  = aws_s3_bucket.releases.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
