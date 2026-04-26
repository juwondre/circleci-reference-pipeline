# Setup

One-time bootstrap. Connect the repo to CircleCI, wire AWS so the publish
and deploy jobs can assume a role via OIDC. Plan ~15 minutes.

> Prefer the Terraform path in [`terraform/`](terraform/) over the raw `aws`
> CLI commands in §3–§4 below. Terraform pulls the OIDC thumbprint live (so
> a CircleCI cert rotation doesn't silently break trust), enables SSE +
> versioning on buckets by default, and `terraform plan` keeps detecting
> drift after the fact. The CLI commands here exist as a reference for what
> each Terraform resource maps to.

## If your default branch isn't `master`

The branch name is pinned in **six places**. Swap every one before applying,
or the publish jobs either won't fire or will be denied by AWS:

| File / setting | Change |
| --- | --- |
| [`.circleci/config.yml`](.circleci/config.yml) | `base-revision: master` |
| [`.circleci/continue-config.yml`](.circleci/continue-config.yml) | both `branches: only: master` filters |
| [`terraform/terraform.tfvars`](terraform/terraform.tfvars.example) | `default_branch = "main"` (overrides `"master"`) |
| CircleCI context restriction | §5 below — restrict `aws-prod-publish` to your branch |
| Trust policy `sub` suffix | §4 below — `refs/heads/<your-branch>` (CLI path only; Terraform reads `var.default_branch`) |
| §6 example commands | the `git push` / merge example |

## 1. CircleCI project

1. Sign in at <https://app.circleci.com> and pick the org that owns the
   GitHub account hosting this repo.
2. **Projects → Set up project →** select `circleci-reference-pipeline` →
   **Fastest** → choose your default branch (this repo ships with `master`;
   if yours is `main`, see the box above). CircleCI picks up
   `.circleci/config.yml` automatically.
3. Push any commit. The first build either runs `noop` (if no app files
   changed) or the full pipeline (if they did). Either is green.

## 2. Grab CircleCI org + project IDs

CircleCI's OIDC issuer is per-org. Grab the org UUID from
**Organization Settings → Overview → Organization ID**. Call it `<ORG_UUID>`.

Project UUID is at **Project Settings → Overview**. Call it `<PROJECT_UUID>`.

## 3. AWS: create the OIDC provider

Once per AWS account.

```bash
aws iam create-open-id-connect-provider \
  --url "https://oidc.circleci.com/org/<ORG_UUID>" \
  --client-id-list "<ORG_UUID>" \
  --thumbprint-list "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
```

The thumbprint is CircleCI's published OIDC cert thumbprint. AWS no longer
strictly enforces it for IAM-managed providers, but the API still requires
the field. If you hit OIDC errors months later, CircleCI rotated the cert —
refresh the thumbprint, or migrate to the Terraform path which looks it up
live via `tls_certificate`.

## 4. AWS: create the publish role

Save this trust policy as `trust.json` (substitute your `<ORG_UUID>`,
`<PROJECT_UUID>`, and `<AWS_ACCOUNT_ID>`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/oidc.circleci.com/org/<ORG_UUID>"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.circleci.com/org/<ORG_UUID>:aud": "<ORG_UUID>"
      },
      "StringLike": {
        "oidc.circleci.com/org/<ORG_UUID>:sub": "org/<ORG_UUID>/project/<PROJECT_UUID>/user/*/vcs-origin/*/vcs-ref/refs/heads/master"
      }
    }
  }]
}
```

The `vcs-ref/refs/heads/master` suffix on `sub` is the second of two locks.
Even if someone got hold of the role's ARN and used it from a feature
branch's pipeline, AWS would refuse the AssumeRole.

```bash
aws iam create-role \
  --role-name circleci-reference-pipeline-publish \
  --assume-role-policy-document file://trust.json
```

Attach a permissions policy for ECR push + S3 write to the release bucket:

```bash
aws iam put-role-policy \
  --role-name circleci-reference-pipeline-publish \
  --policy-name publish \
  --policy-document file://permissions.json
```

`permissions.json` is roughly (substitute `<REGION>`, `<AWS_ACCOUNT_ID>`,
and `<RELEASE_BUCKET>` first):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "ECRPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "arn:aws:ecr:<REGION>:<AWS_ACCOUNT_ID>:repository/circleci-reference-pipeline"
    },
    {
      "Sid": "S3Release",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": "arn:aws:s3:::<RELEASE_BUCKET>/releases/*"
    }
  ]
}
```

Create the ECR repo as `IMMUTABLE` so re-pushing the same SHA can't silently
overwrite what's in prod:

```bash
aws ecr create-repository \
  --repository-name circleci-reference-pipeline \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true
```

Create the release bucket and harden it (block public access, encrypt at
rest, enable versioning):

```bash
aws s3 mb s3://<RELEASE_BUCKET> --region <REGION>

aws s3api put-public-access-block \
  --bucket <RELEASE_BUCKET> \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption \
  --bucket <RELEASE_BUCKET> \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-bucket-versioning \
  --bucket <RELEASE_BUCKET> \
  --versioning-configuration Status=Enabled
```

## 5. CircleCI context

**Organization Settings → Contexts → Create Context** named `aws-prod-publish`.

Add these env vars:

| Key | Value |
| --- | --- |
| `AWS_ROLE_ARN` | `arn:aws:iam::<AWS_ACCOUNT_ID>:role/circleci-reference-pipeline-publish` |
| `AWS_REGION` | e.g. `us-east-1` |
| `AWS_ACCOUNT_ID` | your account id |
| `ECR_REPO` | `circleci-reference-pipeline` |
| `RELEASE_BUCKET` | your bucket name |
| `APPRUNNER_SERVICE_DEV_ARN` | `terraform output -raw apprunner_service_dev_arn` |
| `APPRUNNER_SERVICE_PROD_ARN` | `terraform output -raw apprunner_service_prod_arn` |
| `APPRUNNER_ECR_ACCESS_ROLE_ARN` | `terraform output -raw apprunner_ecr_access_role_arn` |

The first five drive `publish-ecr` and `publish-s3`. The three `APPRUNNER_*`
vars drive `deploy-dev` and `deploy-prod` — the deploy script reads them to
roll the new image SHA onto each App Runner service. The mapping table in
[`terraform/README.md`](terraform/README.md) shows which terraform output
maps to which env var.

The OIDC token isn't a context variable — CircleCI injects
`CIRCLE_OIDC_TOKEN_V2` automatically into any job with a context.
[`scripts/aws-oidc-login.sh`](scripts/aws-oidc-login.sh) trades it for
short-lived STS creds.

Restrict the context to `master`:
**Context → Security → Add Restriction → branch `master`**. CircleCI then
refuses to inject the context's vars into any job that isn't running on
`master`.

### Enable CircleCI Releases (or strip the marker steps)

`publish-ecr`, `publish-s3`, `deploy-dev`, and `deploy-prod` all call
`circleci run release plan` / `circleci run release update` so each event
lands on the **Deploys** dashboard. Releases is an org-level feature —
enable at **Organization Settings → Releases**. If your org can't, strip
the three `circleci run release ...` steps from each publish/deploy job in
[`.circleci/continue-config.yml`](.circleci/continue-config.yml). The publish
and deploy work fine without them; you just lose the dashboard view.

## 6. Push and watch

```bash
git checkout -b ci-bootstrap
git commit --allow-empty -m "trigger pipeline"
git push -u origin ci-bootstrap
```

Open the PR. Pipeline runs lint → test → build-image →
[container-integration-test, security-scan]. Publish + deploy jobs are
skipped because the branch isn't `master`. Merge to `master` and they fire.

## Troubleshooting

- **`path-filtering` errors with "could not find base revision".** First-ever
  build on a new branch with no merge base. Push one commit to `master`
  first, or change `base-revision` to `HEAD~1` temporarily — and revert that
  workaround once master has a real commit, or every subsequent PR will diff
  against the wrong base and run the full pipeline.
- **`assume-role-with-web-identity` returns `AccessDenied`.** Almost always
  the `sub` claim. Print `$CIRCLE_OIDC_TOKEN_V2` decoded
  (`cut -d. -f2 | base64 -d`) and compare against the trust policy.
- **Postgres tests fail with "connection refused".** Sidecar takes a beat to
  come up; `scripts/wait-for-postgres.sh` covers it. Bump `WAIT_ATTEMPTS`
  if your runner is slow.
- **`publish-ecr` fails with `ImageTagAlreadyExistsException`.** Working as
  designed. ECR is `IMMUTABLE` and the pipeline tags by SHA, so re-pushing
  a SHA that's already up gets refused. Push a new commit. If you really
  need to replace an image for a given SHA, delete it from ECR first.
- **`circleci run release ...` fails with "unknown command" or a 4xx.**
  Releases isn't enabled on the org, or the job isn't running in CircleCI
  Cloud (the CLI is pre-installed there). See §5.
