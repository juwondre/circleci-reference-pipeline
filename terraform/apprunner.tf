# Dev + prod services for the Flask app. Pipeline owns the image SHA via
# update-service; we ignore_changes on source_configuration so apply doesn't
# revert the running version. Needs an `:bootstrap` tag in ECR before first
# apply or the services land in CREATE_FAILED.

# IAM role App Runner assumes to pull from ECR.
resource "aws_iam_role" "apprunner_ecr_access" {
  name = "${var.role_name}-apprunner-ecr"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "build.apprunner.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "apprunner_ecr" {
  role       = aws_iam_role.apprunner_ecr_access.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
}

locals {
  apprunner_envs = toset(["dev", "prod"])
}

resource "aws_apprunner_service" "app" {
  for_each = local.apprunner_envs

  service_name = "${var.ecr_repo_name}-${each.key}"

  source_configuration {
    authentication_configuration {
      access_role_arn = aws_iam_role.apprunner_ecr_access.arn
    }
    image_repository {
      image_identifier      = "${aws_ecr_repository.app.repository_url}:bootstrap"
      image_repository_type = "ECR"
      image_configuration {
        port = "8080"
        runtime_environment_variables = {
          # SQLite in /tmp. Ephemeral on restart, fine for a demo;
          # production would point DATABASE_URL at RDS.
          DATABASE_URL = "sqlite:////tmp/app.db"
          BUILD_SHA    = "bootstrap"
        }
      }
    }
    auto_deployments_enabled = false
  }

  # 0.25 vCPU + 0.5 GB — smallest config to keep cost ~$11/mo per service.
  instance_configuration {
    cpu    = "256"
    memory = "512"
  }

  health_check_configuration {
    protocol            = "HTTP"
    path                = "/healthz"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 1
    unhealthy_threshold = 3
  }

  # Pipeline (deploy-dev / deploy-prod) owns source_configuration after
  # first apply. Without ignore_changes, every apply would roll the service
  # back to :bootstrap.
  lifecycle {
    ignore_changes = [
      source_configuration,
    ]
  }
}
