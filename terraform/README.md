# Terraform

Codifies every AWS resource the publish + deploy jobs touch: the CircleCI
OIDC provider, publish role + permissions, ECR repo, S3 release bucket, two
App Runner services (dev + prod) plus the IAM role they use to pull from
ECR, and the state backend itself (state bucket + DynamoDB lock table).
Same end state as the manual commands in [../SETUP.md](../SETUP.md), without
the click-ops.

Bootstrap is two steps because the backend resources have to exist before
Terraform can store its own state in them. See
[First-time apply](#first-time-apply).

## Files

| File | What it owns |
| --- | --- |
| `versions.tf` | Terraform + provider pins, `backend "s3"` block |
| `variables.tf` | Inputs (region, CircleCI UUIDs, names) |
| `backend.tf` | State bucket (SSE + versioning) and DynamoDB lock table |
| `oidc.tf` | CircleCI OIDC provider, thumbprint pulled via `tls_certificate` |
| `role.tf` | Publish role, trust policy (project + branch), publish + App Runner deploy permissions |
| `ecr.tf` | ECR repo (`IMMUTABLE` tags) |
| `s3.tf` | Release bucket (SSE + versioning + public-access block) |
| `apprunner.tf` | App Runner services (dev + prod) and the IAM role they assume to pull from ECR |
| `outputs.tf` | Values for the CircleCI context |

## First-time apply

> **Already bootstrapped via CLI in [../SETUP.md](../SETUP.md)?** Skip to
> [Adopting resources that already exist](#adopting-resources-that-already-exist)
> first. Run `terraform init`, then the imports there, *then* come back here
> for apply + migrate-state. Otherwise apply fails with `EntityAlreadyExists`
> on the role, OIDC provider, ECR repo, and bucket.

The state backend has a chicken-and-egg problem: the bucket and lock table
in [`backend.tf`](backend.tf) are what the `backend "s3"` block in
[`versions.tf`](versions.tf) needs. Two steps:

> Don't uncomment the `backend "s3"` block before the first apply.
> `terraform init` will try to read state from a bucket that doesn't exist
> yet and fail with an opaque S3 error. Apply once first, *then* uncomment.

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # CircleCI UUIDs, release + state bucket names

# Step 1 — apply with the default local backend. Creates the state bucket,
# lock table, and the rest of the publish infra.
terraform init
terraform apply

# Step 2 — uncomment the backend block in versions.tf (set bucket =
# state_bucket_name), then migrate state off disk into the bucket you
# just created.
terraform init -migrate-state
```

After step 2, `terraform.tfstate` on disk becomes a stub. Real state lives
encrypted in S3, locked via DynamoDB.

> **App Runner services need an `:bootstrap` ECR tag before they can come
> up healthy.** [`apprunner.tf`](apprunner.tf) points the dev/prod services
> at `${ecr_repo_url}:bootstrap`. After your pipeline has pushed at least
> one image SHA to ECR, retag it as `:bootstrap` so the App Runner apply
> succeeds:
>
> ```bash
> # Pick any tag already in ECR (e.g. an earlier master SHA).
> manifest=$(aws ecr batch-get-image \
>   --repository-name "$ecr_repo_name" \
>   --image-ids imageTag=<some-existing-sha> \
>   --query 'images[0].imageManifest' --output text)
> aws ecr put-image \
>   --repository-name "$ecr_repo_name" \
>   --image-tag bootstrap \
>   --image-manifest "$manifest"
> ```
>
> Skip this and the services land in `CREATE_FAILED` because they can't
> pull `:bootstrap`. After the first apply, the pipeline takes over —
> every master merge updates each service's `image_identifier` to the
> new SHA.

Plug the outputs into the `aws-prod-publish` context in CircleCI (see
[Where things live](../README.md#where-things-live) in the main README for
how the context fits in). 1:1 mapping:

| CircleCI context env var | Terraform output |
| --- | --- |
| `AWS_ROLE_ARN` | `publish_role_arn` |
| `AWS_REGION` | `aws_region` |
| `AWS_ACCOUNT_ID` | `aws_account_id` |
| `ECR_REPO` | `ecr_repo_name` |
| `RELEASE_BUCKET` | `release_bucket` |
| `APPRUNNER_SERVICE_DEV_ARN` | `apprunner_service_dev_arn` |
| `APPRUNNER_SERVICE_PROD_ARN` | `apprunner_service_prod_arn` |
| `APPRUNNER_ECR_ACCESS_ROLE_ARN` | `apprunner_ecr_access_role_arn` |

`ecr_repository_uri`, `oidc_provider_arn`, `apprunner_service_dev_url`, and
`apprunner_service_prod_url` are also published for reference (the URLs are
handy for `curl /healthz` after a deploy) but don't go in the context.

## Adopting resources that already exist

Bootstrapped via the CLI in [`../SETUP.md`](../SETUP.md)? Import the live
resources into state instead of recreating them. After the imports run,
`terraform plan` should show no changes.

Replace placeholders with your values. `ROLE_NAME` and `REPO_NAME` must
match the literal strings you passed to `--role-name` and
`--repository-name`; the defaults in `variables.tf` match what
[`../SETUP.md`](../SETUP.md) uses.

```bash
ORG_ID=<YOUR_CIRCLECI_ORG_UUID>
ACCOUNT_ID=<YOUR_AWS_ACCOUNT_ID>
BUCKET=<YOUR_RELEASE_BUCKET>
ROLE_NAME=circleci-reference-pipeline-publish   # match --role-name
REPO_NAME=circleci-reference-pipeline           # match --repository-name

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

The state bucket and lock table in [`backend.tf`](backend.tf) get created by
Terraform itself during the first apply, so they don't need importing —
unless you already built them by hand:

```bash
STATE_BUCKET=<YOUR_STATE_BUCKET>
LOCK_TABLE=<YOUR_LOCK_TABLE_NAME>  # default: circleci-reference-pipeline-tfstate-lock

terraform import aws_s3_bucket.tfstate "$STATE_BUCKET"
terraform import aws_s3_bucket_public_access_block.tfstate "$STATE_BUCKET"
terraform import aws_s3_bucket_server_side_encryption_configuration.tfstate "$STATE_BUCKET"
terraform import aws_s3_bucket_versioning.tfstate "$STATE_BUCKET"
terraform import aws_dynamodb_table.tfstate_lock "$LOCK_TABLE"
```

## Why it's split this way

- **OIDC provider is a singleton per org.** Other CircleCI projects in the
  same org reuse it; only the role + trust policy is project-specific.
- **Thumbprint pulled live.** `data "tls_certificate"` in `oidc.tf` reads
  CircleCI's current cert at plan time. A cert rotation gets picked up on
  the next apply instead of silently breaking trust.
- **Trust on `sub`, not just `aud`.** The `vcs-ref/refs/heads/master`
  suffix is what stops a forked PR's pipeline from assuming this role.
- **Permissions reference `aws_ecr_repository.app.arn` and
  `aws_s3_bucket.releases.arn`**, not hard-coded ARNs. Renaming the repo
  or bucket can't accidentally drop the lock.
- **ECR is `IMMUTABLE`.** Pipeline tags by SHA only; no `:latest` to keep
  honest. Immutable tags are a stable reference for rollbacks and signed
  images.
- **Release + state buckets both have SSE + versioning.** Encryption at
  rest for the "someone gets a read" case; versioning for the "bad publish
  overwrites a good one" case.
- **`lifecycle.ignore_changes = [source_configuration]` on App Runner.**
  Without it, every apply would try to roll the running services back to
  `:bootstrap` and undo whatever SHA the pipeline last deployed. The
  pipeline (`deploy-dev` / `deploy-prod`) owns the running version;
  Terraform owns everything else about the service.
