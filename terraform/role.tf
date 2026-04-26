data "aws_iam_policy_document" "publish_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.circleci.arn]
    }

    # Aud claim is the org UUID. Locks the token to this CircleCI org.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = [var.circleci_org_id]
    }

    # Sub claim encodes project + branch. Pins this role to one project on
    # the default branch only, so a fork or feature-branch pipeline can't
    # assume it even if the role ARN leaks.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_issuer}:sub"
      values = [
        "org/${var.circleci_org_id}/project/${var.circleci_project_id}/user/*/vcs-origin/*/vcs-ref/refs/heads/${var.default_branch}",
      ]
    }
  }
}

resource "aws_iam_role" "publish" {
  name               = var.role_name
  description        = "OIDC role assumed by CircleCI publish jobs (default branch only)."
  assume_role_policy = data.aws_iam_policy_document.publish_trust.json
}

data "aws_iam_policy_document" "publish_permissions" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "S3Release"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:PutObjectAcl"]
    resources = ["${aws_s3_bucket.releases.arn}/releases/*"]
  }

  # App Runner deploy: pipeline calls update-service to roll a new image SHA
  # onto each environment, and describe-service to poll deployment status.
  statement {
    sid    = "AppRunnerDeploy"
    effect = "Allow"
    actions = [
      "apprunner:UpdateService",
      "apprunner:DescribeService",
      "apprunner:StartDeployment",
    ]
    resources = [for s in aws_apprunner_service.app : s.arn]
  }

  # update-service includes the source_configuration's access_role_arn, which
  # AWS treats as a PassRole. Scoped to the App Runner service principals
  # (both the parent and the build sub-service) so this can't be abused to
  # hand the role to anything else.
  statement {
    sid       = "AppRunnerPassECRRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.apprunner_ecr_access.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "apprunner.amazonaws.com",
        "build.apprunner.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "publish" {
  name   = "publish"
  role   = aws_iam_role.publish.id
  policy = data.aws_iam_policy_document.publish_permissions.json
}
