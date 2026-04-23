# Setup

One-time bootstrap: connect this repo to CircleCI, then wire AWS so the
publish jobs can assume a role via OIDC. Plan for ~15 minutes.

> **Tip:** prefer the Terraform path in [`terraform/`](terraform/) over the raw
> `aws` CLI commands in sections 3–4 below. Terraform pulls the OIDC
> thumbprint live (so cert rotations don't silently break trust), enables
> SSE + versioning on buckets by default, and `terraform plan` keeps detecting
> drift after the fact. The CLI commands here are kept as a reference for
> what each Terraform resource maps to.

## If your default branch is not `master`

The branch name is pinned in **six places**. Swap every occurrence before you
apply, or the publish jobs either won't fire or will be denied by AWS:

| File / setting | What to change |
| --- | --- |
| [`.circleci/config.yml`](.circleci/config.yml) | `base-revision: master` |
| [`.circleci/continue-config.yml`](.circleci/continue-config.yml) | both `branches: only: master` filters |
| [`terraform/terraform.tfvars`](terraform/terraform.tfvars.example) | set `default_branch = "main"` (overrides the `"master"` default) |
| CircleCI context restriction | §5 below — restrict `aws-prod-publish` to your default branch |
| Trust policy `sub` suffix | §4 below — `refs/heads/<your-branch>` (only if using the CLI path; Terraform reads `var.default_branch`) |
| Example commands in §6 | the `git push` / merge example |

## 1. CircleCI project

1. Sign in at <https://app.circleci.com> and pick the org that owns the GitHub
   account hosting this repo.
1. **Projects → Set up project →** select `circleci-reference-pipeline` →
   **Fastest** → choose your default branch (this repo ships with `master`;
   if yours is `main`, see the "If your default branch is not `master`" box
   above). CircleCI picks up `.circleci/config.yml` automatically.
1. Push any commit; the first build will run the `noop` job (no app files
   changed) or the full pipeline (if app files did). Either is "green".

## 2. Grab your CircleCI org ID

CircleCI's OIDC issuer is per-org. Get the UUID from
**Organization Settings → Overview → Organization ID**. Keep it handy as
`<ORG_UUID>`.

You also need the project's UUID (Project Settings → Overview).
Call it `<PROJECT_UUID>`.

## 3. AWS: create the OIDC provider

Once per AWS account.

```bash
aws iam create-open-id-connect-provider \
  --url "https://oidc.circleci.com/org/<ORG_UUID>" \
  --client-id-list "<ORG_UUID>" \
  --thumbprint-list "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
```

The thumbprint is CircleCI's published OIDC cert thumbprint. AWS does not
strictly enforce it for IAM-managed providers anymore, but the API still
requires the field. If you hit OIDC errors down the road, CircleCI has
rotated the cert — refresh the thumbprint, or (better) migrate to the
Terraform path, which looks it up dynamically via `tls_certificate`.

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

The `vcs-ref/refs/heads/master` suffix on the `sub` claim is the second of
two locks: even if someone managed to use this role's ARN from a feature
branch's pipeline, AWS would refuse the AssumeRole.

```bash
aws iam create-role \
  --role-name circleci-reference-pipeline-publish \
  --assume-role-policy-document file://trust.json
```

Attach a permissions policy that allows ECR push + S3 write to your
release bucket:

```bash
aws iam put-role-policy \
  --role-name circleci-reference-pipeline-publish \
  --policy-name publish \
  --policy-document file://permissions.json
```

Where `permissions.json` is roughly (substitute `<REGION>`, `<AWS_ACCOUNT_ID>`,
and `<RELEASE_BUCKET>` before saving):

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

Create the ECR repo (immutable tags — the publish pipeline tags by commit SHA
only, so re-pushing the same SHA is never silently allowed to overwrite):

```bash
aws ecr create-repository \
  --repository-name circleci-reference-pipeline \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true
```

Create the S3 release bucket and harden it (block public access, encrypt at
rest, enable versioning so an accidental overwrite is recoverable):

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

Add these env vars to it:

| Key | Value |
| --- | --- |
| `AWS_ROLE_ARN` | `arn:aws:iam::<AWS_ACCOUNT_ID>:role/circleci-reference-pipeline-publish` |
| `AWS_REGION` | e.g. `us-east-1` |
| `AWS_ACCOUNT_ID` | your account id |
| `ECR_REPO` | `circleci-reference-pipeline` |
| `RELEASE_BUCKET` | your bucket name |

The OIDC token itself is **not** a context variable — CircleCI injects
`CIRCLE_OIDC_TOKEN_V2` automatically into every job with a context. The
`aws-oidc-login.sh` script exchanges that token for short-lived STS creds.

Then **restrict the context** to the `master` branch:
**Context → Security → Add Restriction → branch `master`**. This is the third
lock — CircleCI will refuse to inject the context's vars into any job not
running on `master`.

### Enable CircleCI Releases (or remove the deploy-marker steps)

The `publish-ecr` and `publish-s3` jobs call `circleci run release plan` /
`circleci run release update` so each publish shows up on the **Deploys**
dashboard. Releases is an org-level feature — enable it under
**Organization Settings → Releases**. If your org can't enable it, strip the
three `circleci run release ...` steps from each publish job in
[`.circleci/continue-config.yml`](.circleci/continue-config.yml); the publish
itself still works without them.

## 6. Push and watch

```bash
git checkout -b ci-bootstrap
git commit --allow-empty -m "trigger pipeline"
git push -u origin ci-bootstrap
```

Open the PR. The pipeline should run lint → test → build-image →
container-integration-test, and skip the publish jobs because the branch
isn't `master`. Merge to `master` and the publish jobs fire.

## Troubleshooting

- **`path-filtering` errors with "could not find base revision".** First-ever
  build on a brand-new branch with no merge base. Push one commit to `master`
  first, or change `base-revision` to `HEAD~1` temporarily — and revert the
  `HEAD~1` workaround once the first real commit is on `master`, or every
  subsequent PR will diff against the wrong base and run the full pipeline.
- **`assume-role-with-web-identity` returns `AccessDenied`.** Almost always
  the `sub` claim string. Print `$CIRCLE_OIDC_TOKEN_V2` decoded
  (`cut -d. -f2 | base64 -d`) and compare against the trust policy.
- **Postgres tests fail with "connection refused".** The sidecar takes a
  beat to come up; `scripts/wait-for-postgres.sh` should cover it. Bump
  `WAIT_ATTEMPTS` if your runner is slow.
- **`publish-ecr` fails with `ImageTagAlreadyExistsException`.** Working as
  designed. The ECR repo is set to `IMMUTABLE`, and the publish pipeline
  tags by commit SHA — so re-running the job for a SHA that's already in ECR
  is refused. Push a new commit; don't re-run. If you genuinely need to
  replace an image for a given SHA, delete it from ECR first and re-run.
- **`circleci run release ...` fails with "unknown command" or a 4xx.**
  Releases isn't enabled on the org, or the job isn't running in CircleCI
  Cloud (the CLI is pre-installed there). See §5 above.
