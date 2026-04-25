# Two App Runner services (dev + prod) host the Flask app from the ECR image.
# The pipeline updates each service's image_identifier on deploy; lifecycle
# ignore_changes on source_configuration keeps Terraform from fighting the
# pipeline over what tag is currently running.
#
# Bootstrapped against an `:bootstrap` tag that must already exist in ECR
# before `terraform apply` (one-time `aws ecr put-image` from any master SHA).

# IAM role App Runner assumes to pull images from our private ECR repo.
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
          # SQLite in /tmp keeps cost flat (no RDS). Per-instance and lost on
          # restart — fine for the demo. Production would point at RDS.
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

  # The pipeline (deploy-dev / deploy-prod jobs) owns source_configuration
  # after the first apply. Without ignore_changes, every `terraform apply`
  # would try to roll the service back to :bootstrap.
  lifecycle {
    ignore_changes = [
      source_configuration,
    ]
  }
}
