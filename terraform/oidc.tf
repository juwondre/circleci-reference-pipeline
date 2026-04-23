data "aws_caller_identity" "current" {}

locals {
  oidc_url    = "https://oidc.circleci.com/org/${var.circleci_org_id}"
  oidc_issuer = "oidc.circleci.com/org/${var.circleci_org_id}"
}

# Pull the live cert chain so the thumbprint tracks CircleCI rotations instead
# of silently going stale.
data "tls_certificate" "circleci" {
  url = local.oidc_url
}

# CircleCI publishes one OIDC issuer per org. Trust on AWS is set up once
# per account, then any number of roles can ride on it.
resource "aws_iam_openid_connect_provider" "circleci" {
  url             = local.oidc_url
  client_id_list  = [var.circleci_org_id]
  thumbprint_list = [data.tls_certificate.circleci.certificates[0].sha1_fingerprint]
}
