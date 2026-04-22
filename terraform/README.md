# Terraform

Codifies the AWS resources the publish jobs need: the CircleCI OIDC provider,
the publish role + permissions, the ECR repo, and the S3 release bucket. One
`terraform apply` from a fresh account gets you to the same place as the
manual commands in [../SETUP.md](../SETUP.md) — without the click-ops.

## Files

| File | What it owns |
| --- | --- |
| `versions.tf` | Terraform + AWS provider pins |
| `variables.tf` | Inputs (region, CircleCI UUIDs, names) |
| `oidc.tf` | The CircleCI OIDC provider |
| `role.tf` | Publish role, trust policy (pinned to project + branch), permissions |
| `ecr.tf` | The ECR repo |
| `s3.tf` | The release bucket + public-access block |
| `outputs.tf` | Values to plug into the CircleCI context |

## First-time apply

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # fill in your CircleCI UUIDs + a unique bucket name

terraform init
terraform plan
terraform apply
```

Take the four `outputs` and paste them into the `aws-prod-publish` context
in CircleCI (see the main [README](../README.md#what-'s-where)).

## Adopting resources that already exist

If you bootstrapped the AWS side via the CLI (as this project did initially),
import the live resources into state instead of recreating them. Once
imported, `terraform plan` should show **no changes**.

```bash
ORG_ID=893de0ec-5d44-4b58-8cfc-7b4fcb6fda70
ACCOUNT_ID=905418331655
BUCKET=juwondre-cci-reference-releases

terraform import aws_iam_openid_connect_provider.circleci \
  "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.circleci.com/org/${ORG_ID}"

terraform import aws_iam_role.publish \
  circleci-reference-pipeline-publish

terraform import aws_iam_role_policy.publish \
  circleci-reference-pipeline-publish:publish

terraform import aws_ecr_repository.app \
  circleci-reference-pipeline

terraform import aws_s3_bucket.releases "$BUCKET"
terraform import aws_s3_bucket_public_access_block.releases "$BUCKET"
```

## Why these resources are split this way

- **OIDC provider is a singleton per org.** Other CircleCI projects in the
  same org reuse the same provider; only the role + trust policy is
  project-specific.
- **Trust on `sub` claim, not just `aud`.** The `vcs-ref/refs/heads/master`
  suffix is what stops a forked PR's pipeline from ever assuming this role.
- **Permissions use `aws_ecr_repository.app.arn` / `aws_s3_bucket.releases.arn`**,
  not hard-coded ARNs, so renaming the repo or bucket can't accidentally
  drop the lock.
