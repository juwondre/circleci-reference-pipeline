# Terraform

Codifies the AWS resources the publish jobs need: the CircleCI OIDC provider,
the publish role + permissions, the ECR repo, the S3 release bucket, and the
state backend itself (state bucket + DynamoDB lock table). Reaches the same
end state as the manual commands in [../SETUP.md](../SETUP.md), without the
click-ops. Bootstrap is two steps (see [First-time apply](#first-time-apply)
below) because the backend resources have to exist before Terraform can store
its own state in them.

## Files

| File | What it owns |
| --- | --- |
| `versions.tf` | Terraform + provider pins, `backend "s3"` block |
| `variables.tf` | Inputs (region, CircleCI UUIDs, names) |
| `backend.tf` | State bucket (SSE + versioning) and DynamoDB lock table |
| `oidc.tf` | CircleCI OIDC provider, thumbprint pulled via `tls_certificate` |
| `role.tf` | Publish role, trust policy (pinned to project + branch), permissions |
| `ecr.tf` | ECR repo (`IMMUTABLE` tags) |
| `s3.tf` | Release bucket (SSE + versioning + public-access block) |
| `outputs.tf` | Values to plug into the CircleCI context |

## First-time apply

> **Already bootstrapped AWS via the CLI in [../SETUP.md](../SETUP.md)?**
> Skip to [Adopting resources that already exist](#adopting-resources-that-already-exist)
> first. Run `terraform init`, then the `terraform import` commands there,
> **then** come back here for the apply + migrate-state steps. Otherwise
> `terraform apply` will fail with `EntityAlreadyExists` on the role, OIDC
> provider, ECR repo, and bucket.

The state backend has a chicken-and-egg problem: the bucket and lock table in
[`backend.tf`](backend.tf) are what the `backend "s3"` block in
[`versions.tf`](versions.tf) needs. Bootstrap is two steps:

> **Do not uncomment the `backend "s3"` block before the first apply.**
> `terraform init` will try to read state from a bucket that doesn't exist
> yet and fail with an opaque S3 error. Run step 1 first, then uncomment.

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # fill in CircleCI UUIDs, release + state bucket names

# Step 1 — apply once with the default local backend. Creates the state
# bucket, the lock table, and the rest of the publish infra.
terraform init
terraform apply

# Step 2 — uncomment the `backend "s3"` block in versions.tf (set the
# `bucket` field to your state_bucket_name value), then migrate state off
# disk into the bucket you just created.
terraform init -migrate-state
```

After step 2, `terraform.tfstate` on disk becomes a stub; the real state lives
encrypted in S3, and concurrent applies are locked via DynamoDB.

Plug the outputs into the `aws-prod-publish` context in CircleCI (see the
**Component map** in the [main README](../README.md#component-map) for how the
context fits into the pipeline). The mapping is 1:1:

| CircleCI context env var | Terraform output |
| --- | --- |
| `AWS_ROLE_ARN` | `publish_role_arn` |
| `AWS_REGION` | `aws_region` |
| `AWS_ACCOUNT_ID` | `aws_account_id` |
| `ECR_REPO` | `ecr_repo_name` |
| `RELEASE_BUCKET` | `release_bucket` |

`ecr_repository_uri` and `oidc_provider_arn` are also published for reference
but don't go into the context.

## Adopting resources that already exist

If you bootstrapped the AWS side via the CLI in [`../SETUP.md`](../SETUP.md),
import the live resources into state instead of recreating them. Once
imported, `terraform plan` should show **no changes**.

Replace the placeholders with your own values before running. The `ROLE_NAME`
and `REPO_NAME` below must match the literal strings you passed to
`--role-name` and `--repository-name` during the CLI bootstrap (the defaults
in `variables.tf` match what [`../SETUP.md`](../SETUP.md) uses):

```bash
ORG_ID=<YOUR_CIRCLECI_ORG_UUID>
ACCOUNT_ID=<YOUR_AWS_ACCOUNT_ID>
BUCKET=<YOUR_RELEASE_BUCKET>
ROLE_NAME=circleci-reference-pipeline-publish   # whatever you passed to --role-name
REPO_NAME=circleci-reference-pipeline           # whatever you passed to --repository-name

terraform import aws_iam_openid_connect_provider.circleci \
  "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.circleci.com/org/${ORG_ID}"

terraform import aws_iam_role.publish "$ROLE_NAME"

terraform import aws_iam_role_policy.publish "${ROLE_NAME}:publish"

terraform import aws_ecr_repository.app "$REPO_NAME"

terraform import aws_s3_bucket.releases "$BUCKET"
terraform import aws_s3_bucket_public_access_block.releases "$BUCKET"
terraform import aws_s3_bucket_server_side_encryption_configuration.releases "$BUCKET"
terraform import aws_s3_bucket_versioning.releases "$BUCKET"
```

The state bucket and DynamoDB lock table in [`backend.tf`](backend.tf) are
created by Terraform itself during the first-time apply, so they don't need
importing — unless you already created them by hand, in which case:

```bash
STATE_BUCKET=<YOUR_STATE_BUCKET>
LOCK_TABLE=<YOUR_LOCK_TABLE_NAME>  # default: circleci-reference-pipeline-tfstate-lock

terraform import aws_s3_bucket.tfstate "$STATE_BUCKET"
terraform import aws_s3_bucket_public_access_block.tfstate "$STATE_BUCKET"
terraform import aws_s3_bucket_server_side_encryption_configuration.tfstate "$STATE_BUCKET"
terraform import aws_s3_bucket_versioning.tfstate "$STATE_BUCKET"
terraform import aws_dynamodb_table.tfstate_lock "$LOCK_TABLE"
```

## Why these resources are split this way

- **OIDC provider is a singleton per org.** Other CircleCI projects in the
  same org reuse the same provider; only the role + trust policy is
  project-specific.
- **Thumbprint is pulled live.** `data "tls_certificate"` in `oidc.tf` reads
  the current CircleCI cert at plan time, so a cert rotation is picked up on
  the next apply instead of causing a silent trust break.
- **Trust on `sub` claim, not just `aud`.** The `vcs-ref/refs/heads/master`
  suffix is what stops a forked PR's pipeline from ever assuming this role.
- **Permissions use `aws_ecr_repository.app.arn` / `aws_s3_bucket.releases.arn`**,
  not hard-coded ARNs, so renaming the repo or bucket can't accidentally
  drop the lock.
- **ECR tags are `IMMUTABLE`.** The publish pipeline tags images by commit
  SHA only; there is no moving `:latest`. An immutable tag is a stable
  reference for rollbacks and signed-image verification.
- **Release bucket and state bucket both have SSE + versioning.** Encryption
  at rest covers the "what if someone gets a read on the bucket" case;
  versioning covers the "what if a bad publish overwrites a good one" case.
