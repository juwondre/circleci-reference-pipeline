# Setup

One-time bootstrap: connect this repo to CircleCI, then wire AWS so the
publish jobs can assume a role via OIDC. Plan for ~15 minutes.

## 1. CircleCI project

1. Sign in at <https://app.circleci.com> and pick the org that owns the GitHub
   account hosting this repo.
1. **Projects → Set up project →** select `circleci-reference-pipeline` →
   **Fastest** → choose the `master` branch. CircleCI picks up
   `.circleci/config.yml` automatically.
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
requires the field.

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

Where `permissions.json` is roughly:

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

Create the ECR repo and the S3 bucket if they do not exist:

```bash
aws ecr create-repository --repository-name circleci-reference-pipeline
aws s3 mb s3://<RELEASE_BUCKET>
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

Then **restrict the context** to the `master` branch:
**Context → Security → Add Restriction → branch `master`**. This is the third
lock — CircleCI will refuse to inject the context's vars into any job not
running on `master`.

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
  first, or change `base-revision` to `HEAD~1` temporarily.
- **`assume-role-with-web-identity` returns `AccessDenied`.** Almost always
  the `sub` claim string. Print `$CIRCLE_OIDC_TOKEN_V2` decoded
  (`cut -d. -f2 | base64 -d`) and compare against the trust policy.
- **Postgres tests fail with "connection refused".** The sidecar takes a
  beat to come up; `scripts/wait-for-postgres.sh` should cover it. Bump
  `WAIT_ATTEMPTS` if your runner is slow.
