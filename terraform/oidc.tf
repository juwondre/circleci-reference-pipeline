data "aws_caller_identity" "current" {}

locals {
  oidc_url    = "https://oidc.circleci.com/org/${var.circleci_org_id}"
  oidc_issuer = "oidc.circleci.com/org/${var.circleci_org_id}"
}

# CircleCI publishes one OIDC issuer per org. Trust on AWS is set up once
# per account, then any number of roles can ride on it.
resource "aws_iam_openid_connect_provider" "circleci" {
  url             = local.oidc_url
  client_id_list  = [var.circleci_org_id]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
}
