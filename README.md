# CircleCI Reference Pipeline

What a real-world CircleCI setup looks like end to end: build a tested
container, scan it, integration-test it, publish to ECR + S3, then deploy
onto two App Runner services with a manual approval before prod. All AWS
access goes through [OIDC](https://circleci.com/docs/openid-connect-tokens/) —
no long-lived keys.

The app under test is a tiny Flask + SQLAlchemy items API. Point is the
pipeline, not the app.

Fork it, change [a few things](#adapting-this-for-your-project), and you've
got the same shape on your project.

- Repo: <https://github.com/juwondre/circleci-reference-pipeline>
- Latest green build: <https://app.circleci.com/pipelines/circleci/HwwMVoew2JQ1sDzMvWGy8s/BLoTBkA3F8xnVJ6PLkdk9W/54/details>
- Live deployed app:
  - dev — <https://mhsfumpeph.us-east-1.awsapprunner.com/healthz>
  - prod — <https://nphmbpqtkp.us-east-1.awsapprunner.com/healthz>

`/healthz` returns `{"build":"<commit-sha>","status":"ok"}` so you can
see what's running. POST to `/items` then GET `/items` round-trips through
SQLAlchemy + SQLite to prove the app actually works.

## How this maps to the brief

| Requirement | Where |
| --- | --- |
| Public VCS, connected to CircleCI | Repo link above; pipeline at [`.circleci/config.yml`](.circleci/config.yml) |
| Custom Docker image built in pipeline | `build-image` job in [`.circleci/continue-config.yml`](.circleci/continue-config.yml) |
| Test results collected | `store_test_results` + coverage in the `test` job |
| Database (Postgres) | SQLAlchemy → Postgres in [`app/db.py`](app/db.py) |
| Sidecar / secondary container | `python-with-postgres` executor (Postgres as a second image) |
| Off-the-shelf DB image | `cimg/postgres:16.2` for tests, `postgres:16-alpine` for integration |
| Conditional work | `circleci/path-filtering` setup workflow — doc-only PRs hit `noop` and exit |
| Shell + non-scripting language | Bash in [`scripts/`](scripts/), plus YAML, HCL, Dockerfile |
| Artifact published to PaaS/IaaS | ECR + S3 (IaaS), then deployed onto App Runner (PaaS) |
| Default branch only | `filters: branches: only: master` on every publish + deploy job |
| Credentials unreachable from non-approved builds | Context restricted to `master` + IAM trust policy pinned to project + branch via OIDC `sub` |
| OIDC | [`scripts/aws-oidc-login.sh`](scripts/aws-oidc-login.sh) trades `CIRCLE_OIDC_TOKEN_V2` for short-lived STS creds |

## What it does

Every push:

1. **Detect what changed.** A [setup workflow](https://circleci.com/docs/dynamic-config/)
   runs [`circleci/path-filtering`](https://circleci.com/developer/orbs/orb/circleci/path-filtering)
   and only continues into the real workflow if app/test/infra files moved.
   Doc-only PR? Single `noop` job, done in seconds.
2. **Lint** with ruff.
3. **Test** with pytest against a real Postgres
   [sidecar](https://circleci.com/docs/using-docker/). JUnit XML + coverage
   go up via [`store_test_results`](https://circleci.com/docs/collect-test-data/),
   so the Tests tab shows per-case history.
4. **Build the image** from the Dockerfile, smoke-test it, save the tar to a
   [workspace](https://circleci.com/docs/workspaces/) for downstream jobs.
5. **In parallel:**
   - **Integration test** — load the saved image, stand it up next to a fresh
     Postgres, exercise the HTTP API.
   - **Security scan** — [Bandit](https://bandit.readthedocs.io/) on the
     Python source, [Trivy](https://trivy.dev/) on the image. HIGH/CRITICAL
     fixable CVEs fail the build. Both gates have to pass before publish.

Master only:

1. **Publish to ECR** — image tagged with the commit SHA. Repo is `IMMUTABLE`,
   so SHA is the source of truth. No `:latest` to keep honest.
2. **Publish to S3** — image tar + JSON manifest under `releases/<sha>/`.
3. **Deploy to dev** — `aws apprunner update-service` rolls the new SHA onto
   the dev [App Runner](https://aws.amazon.com/apprunner/) service. The job
   polls until AWS reports `SUCCEEDED`.
4. **Wait for approval** — `type: approval` job pauses the workflow. A human
   clicks approve in the UI before anything else moves.
5. **Deploy to prod** — same mechanic, prod service.

Every publish + deploy job assumes its AWS role via OIDC. Each one emits
markers that show up on CircleCI's
[Deploys](https://circleci.com/docs/deployment-overview/) dashboard.

## Architecture

```text
┌────────────────────┐
│  setup workflow    │  path-filtering: did app/test/infra change?
└─────────┬──────────┘
          │ run-app-pipeline = true
          ▼
┌────────────────────┐
│ lint  →  test      │  pytest + Postgres sidecar, JUnit XML
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ build-image        │  docker build → smoke test → save tar
└─────────┬──────────┘
          ├────────────────────────┐
          ▼                        ▼
┌────────────────────┐  ┌────────────────────┐
│ container-int-test │  │ security-scan      │
│ load + hit HTTP    │  │ Bandit + Trivy     │
└─────────┬──────────┘  └─────────┬──────────┘
          └────────────┬──────────┘
                       │   filters.branches.only = master
                       ▼
                ┌──────┴──────┐
                ▼             ▼
           publish-ecr   publish-s3    ← OIDC → AWS STS, restricted context
                │
                ▼
       ┌────────────────────┐
       │ deploy-dev         │  aws apprunner update-service + poll
       └─────────┬──────────┘  → live dev URL
                 ▼
       ┌────────────────────┐
       │ approve-prod-deploy│  type: approval (human gate)
       └─────────┬──────────┘
                 ▼
       ┌────────────────────┐
       │ deploy-prod        │  → live prod URL
       └────────────────────┘
```

## Where things live

| Concern | Path |
| --- | --- |
| App | [`app/`](app/) — Flask + SQLAlchemy, two endpoints |
| Tests | [`tests/`](tests/) — pytest, JUnit out |
| Container | [`Dockerfile`](Dockerfile) — slim Python, non-root, healthcheck |
| Shell | [`scripts/`](scripts/) — wait-for-db, smoke, integration, OIDC login, publish, deploy |
| Pipeline (setup) | [`.circleci/config.yml`](.circleci/config.yml) — path-filtering only |
| Pipeline (real) | [`.circleci/continue-config.yml`](.circleci/continue-config.yml) — jobs + workflows |
| AWS infra | [`terraform/`](terraform/) — OIDC provider, publish role, ECR, S3, App Runner, remote state |
| Deploy | [`scripts/deploy-apprunner.sh`](scripts/deploy-apprunner.sh) — `update-service` + poll |
| Bootstrap | [`SETUP.md`](SETUP.md) — CircleCI project, OIDC trust, context vars |

## Why CircleCI

Things this pipeline leans on that you don't get free elsewhere:

- **Setup workflows + `path-filtering` orb.** Gating happens at the workflow
  level, not per-step. A docs-only change never spins up Postgres.
- **Sidecar containers in the docker executor.** Postgres comes up as a second
  image in the same network namespace. Tests just hit `localhost:5432` —
  no `docker run`, no compose, no port wrangling.
- **Workspace persistence.** The image is built once and flowed downstream as
  a tarball. `container-integration-test`, `publish-ecr`, `publish-s3`, and
  the deploys all act on the same bytes.
- **OIDC tokens.** Every publish/deploy job trades `CIRCLE_OIDC_TOKEN_V2` for
  short-lived AWS STS creds. No `AWS_ACCESS_KEY_ID` anywhere.
- **[Context](https://circleci.com/docs/contexts/) restrictions.** The
  `aws-prod-publish` context is locked to the `master` branch in CircleCI.
  If someone added a `publish-ecr` call to a feature branch's config, the
  context wouldn't inject — the job would fail before touching AWS.
- **Defense in depth on credentials.** The IAM trust policy *also* pins on
  the OIDC `sub` claim (project + ref). A leaked role ARN can't be assumed
  from another repo or another branch.
- **Infrastructure as code.** Everything AWS — OIDC provider, publish role,
  trust + permissions, ECR, S3, App Runner — is in [`terraform/`](terraform/).
  `terraform plan` shows zero diff against live, so the code is the source
  of truth. State lives in an encrypted S3 bucket, locked via DynamoDB
  ([`terraform/backend.tf`](terraform/backend.tf)). The OIDC thumbprint is
  pulled live via `tls_certificate` so a CircleCI cert rotation doesn't
  silently break trust.
- **[Deploy markers](https://circleci.com/docs/deployment-overview/).** Every
  publish and deploy job calls `circleci run release plan` before touching
  AWS and `circleci run release update --status=SUCCESS|FAILED` after, so
  every event lands on the Deploys dashboard tagged with the SHA. "What's in
  prod?" is one page, not log spelunking.
- **SAST gate.** Bandit + Trivy run as `security-scan` in parallel with the
  integration test, then both feed into `publish-ecr` / `publish-s3` via
  `requires:`. Findings short-circuit the workflow before anything leaves CI.
- **`type: approval` between dev and prod.** `deploy-dev` runs automatically;
  the workflow then waits on a human clicking approve in the UI before
  `deploy-prod` fires. Zero infra to set up — just a job type.

## Adapting this for your project

Five things to change. Everything else is derived.

**1. Project name.** `circleci-reference-pipeline` is the default for the
ECR repo, IAM publish role, and DynamoDB lock table. On the Terraform path,
override in `terraform/terraform.tfvars`:

```hcl
ecr_repo_name         = "acme-api"
role_name             = "acme-api-publish"
release_bucket_name   = "acme-api-releases"      # globally unique
state_bucket_name     = "acme-api-tfstate"       # globally unique
state_lock_table_name = "acme-api-tfstate-lock"
```

The CircleCI context values then come straight from `terraform output` —
see the mapping in [`terraform/README.md`](terraform/README.md). One thing
`tfvars` *can't* override: the `backend "s3"` block in
[`terraform/versions.tf`](terraform/versions.tf), because Terraform backend
config doesn't take variables. Edit `bucket` and `dynamodb_table` there
manually after the first apply.

CLI path? Substitute your names in `--role-name`, `--repository-name`, and
the ARNs in `permissions.json` (see [`SETUP.md`](SETUP.md)).

**2. Default branch.** Not `master`? Six places to swap — there's a callout
at the top of [`SETUP.md`](SETUP.md) listing them.

**3. AWS region + account.** `aws_region` in tfvars. The account ID gets
read from whatever creds Terraform / the AWS CLI are using; nothing
hard-coded.

**4. CircleCI org + project.** Drop the UUIDs from §2 of [`SETUP.md`](SETUP.md)
into `circleci_org_id` and `circleci_project_id`.

**5. This README.** Update the repo + build links at the top to point at
your fork.

## Running locally

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt

# Postgres on :5432. Test-only credentials on a throwaway container —
# don't reuse for production.
docker run -d --rm --name pg -p 5432:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=appdb \
  postgres:16-alpine

pytest

# Build + smoke + integration test the image the same way CI does.
docker build -t app:dev .
./scripts/smoke-test.sh app:dev
./scripts/integration-test.sh app:dev
```

## Future work

- **Build with BuildKit + push from the build job.** Today it's save → load →
  push, costing a workspace round-trip. Pushing straight to ECR from
  `build-image` would be faster, but couples that job to AWS creds — which
  we deliberately scoped to master-only jobs. Current shape keeps the
  boundary clean.
- **Real database.** App Runner instances use SQLite at `/tmp/app.db` — fine
  for the demo, ephemeral on restart. Production would point `DATABASE_URL`
  at RDS or Aurora Serverless v2; the app already reads it from env, so the
  swap is config-only.
- **Image signing (cosign + Sigstore).** Layer it on after `publish-ecr`;
  App Runner deploys could verify before pulling.
- **One-click Deploy + Rollback in the CircleCI UI.** Now that there are
  downstream consumers (the App Runner services), the **Deploy Pipeline**
  and **Rollback Pipeline** toggles under *Project Settings → Deploy
  Settings* become useful — single-click promote/revert from the Deploys
  dashboard. Today the same effect needs a push or revert on master.
- **SaaS SAST.** Bandit + Trivy run locally and emit text artifacts. Snyk or
  Semgrep would add a dashboard, trends, PR inline comments. One-line orb
  swap (`snyk/snyk` or `semgrep/semgrep`) plus a context-injected token.
- **dgoss for container tests.** [`scripts/smoke-test.sh`](scripts/smoke-test.sh)
  hand-rolls assertions to keep deps minimal. dgoss would let you write the
  same checks in YAML.
- **Bigger machine class.** Defaults are fine here; bumping the
  [resource class](https://circleci.com/docs/resource-class-overview/) starts
  mattering once the image grows or the test suite parallelizes.
- **Test parallelism.** `circleci tests split` becomes useful past ~30s of
  pytest. Not yet.
- **Tighter orb pins.** `@3.0.0` / `@5.4.1` are fine for now; pin to exact
  patches in your fork if you want bit-for-bit reproducibility.

See [`SETUP.md`](SETUP.md) for the one-time bootstrap.

## Further reading

- [Dynamic config / setup workflows](https://circleci.com/docs/dynamic-config/)
- [`circleci/path-filtering` orb](https://circleci.com/developer/orbs/orb/circleci/path-filtering)
- [Using Docker (sidecar / secondary containers)](https://circleci.com/docs/using-docker/)
- [OpenID Connect tokens](https://circleci.com/docs/openid-connect-tokens/)
- [Using contexts](https://circleci.com/docs/contexts/)
- [Collect test data](https://circleci.com/docs/collect-test-data/)
- [Using workspaces](https://circleci.com/docs/workspaces/)
- [Deployment overview](https://circleci.com/docs/deployment-overview/)
- [`circleci/aws-cli` orb](https://circleci.com/developer/orbs/orb/circleci/aws-cli)
- [Resource class overview](https://circleci.com/docs/resource-class-overview/)
- [Configuration reference](https://circleci.com/docs/configuration-reference/)
