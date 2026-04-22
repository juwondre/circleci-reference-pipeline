# CircleCI Reference Pipeline

A small, opinionated reference for what a "production-shaped" CircleCI pipeline
looks like end-to-end: build a tested container, prove it works, then publish
it to AWS using short-lived OIDC credentials — never a static key.

The app under test is a Flask + SQLAlchemy items API talking to Postgres. It
is intentionally tiny so the pipeline is what you read, not the app.

- VCS: <https://github.com/juwondre/circleci-reference-pipeline>
- Latest passing build: <https://app.circleci.com/pipelines/circleci/HwwMVoew2JQ1sDzMvWGy8s/BLoTBkA3F8xnVJ6PLkdk9W/14/details>

## What it does

On every push:

1. **Detect what changed.** A setup workflow runs `circleci/path-filtering` and
   continues into the real workflow only if app/test/infra files moved. A
   docs-only PR runs a single `noop` job and finishes in seconds.
2. **Lint** with ruff.
3. **Test** with pytest against a real Postgres sidecar container. JUnit XML
   and coverage are uploaded so CircleCI's UI shows per-test history.
4. **Build a custom image** from the repo's Dockerfile, run a structural
   smoke test against it, then save it as a workspace artifact.
5. **Integration test** the saved image: load it, stand it up next to a fresh
   Postgres, and exercise the HTTP API.

Only on merge to `master`:

1. **Publish to ECR** — image tagged with the commit SHA and `latest`.
1. **Publish to S3** — the image tar plus a JSON manifest under `releases/<sha>/`.

Both publish jobs assume an AWS role via OIDC. No long-lived keys live in the
project.

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
          ▼
┌────────────────────┐
│ container-int-test │  load tar, run image + postgres, hit API
└─────────┬──────────┘
          │   filters.branches.only = master
          ▼
   ┌──────┴──────┐
   ▼             ▼
publish-ecr   publish-s3   ← OIDC → AWS STS, restricted context
```

## Component map

| Concern | Where it lives |
| --- | --- |
| App (Python) | [`app/`](app/) — Flask + SQLAlchemy, two endpoints |
| Tests (JUnit) | [`tests/`](tests/) — pytest, `--junitxml=test-results/pytest.xml` |
| Container | [`Dockerfile`](Dockerfile) — slim Python, non-root, healthcheck |
| Shell glue | [`scripts/`](scripts/) — wait-for-db, smoke, integration, AWS OIDC, publish |
| Pipeline (setup) | [`.circleci/config.yml`](.circleci/config.yml) — path-filtering only |
| Pipeline (real) | [`.circleci/continue-config.yml`](.circleci/continue-config.yml) — jobs + workflows |
| AWS infra (IaC) | [`terraform/`](terraform/) — OIDC provider, publish role, ECR, S3 as code |
| Bootstrap | [`SETUP.md`](SETUP.md) — CircleCI project + AWS OIDC trust policy |

## Why CircleCI

A few things this pipeline leans on that you don't get for free elsewhere:

- **Setup workflows + path-filtering orb.** Conditional execution at the
  _workflow_ level, not the step level. A docs-only change never even spins
  up Postgres.
- **Sidecar containers in the docker executor.** Postgres comes up as a
  secondary container in the same network namespace, so tests just hit
  `localhost:5432`. No `docker run`, no `docker compose`, no port juggling.
- **Workspace persistence.** The image is built once and flowed through three
  downstream jobs as a tarball, so `container-integration-test`,
  `publish-ecr`, and `publish-s3` all act on the same bytes.
- **OIDC tokens (`CIRCLE_OIDC_TOKEN_V2`).** Every publish job exchanges a
  short-lived token for AWS STS credentials. No `AWS_ACCESS_KEY_ID` is stored
  anywhere.
- **Context restrictions.** The `aws-prod-publish` context is restricted to
  the `master` branch in CircleCI. Even if someone added a `publish-ecr` call
  to a feature branch's config, the context would refuse to inject — the job
  would fail before it could touch AWS.
- **Two-layer credential isolation.** Belt and suspenders: the IAM trust
  policy _also_ pins on the OIDC `sub` claim, which encodes project + ref.
  A leaked role ARN can't be assumed from another repo or another branch.
- **Infrastructure as code.** Everything on the AWS side — OIDC provider,
  publish role, trust + permissions policies, ECR repo, S3 bucket — lives
  under [`terraform/`](terraform/). `terraform plan` against the live
  account shows zero diffs, so the codified version is the source of truth.
- **Deploy markers.** Both `publish-ecr` and `publish-s3` call
  `circleci run release plan` before they touch AWS and
  `circleci run release update --status=SUCCESS|FAILED` after, so each
  publish shows up in the **Deploys** dashboard tagged with the SHA.
  An SRE looking for "what version is in prod right now?" gets a single
  pane, no log spelunking required.

## Running locally

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt

# Tests need Postgres on :5432
docker run -d --rm --name pg -p 5432:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=appdb \
  postgres:16-alpine

pytest

# Build + smoke + integration test the image the same way CI does
docker build -t app:dev .
./scripts/smoke-test.sh app:dev
./scripts/integration-test.sh app:dev
```

## Future optimizations and trade-offs

- **Build with BuildKit + push from the build job.** Today we save → load →
  push, which costs an extra workspace round-trip. Pushing straight to ECR
  from `build-image` would be faster but couples the build job to AWS
  credentials, which we deliberately scoped to `master`-only jobs. The current
  shape keeps that boundary clean.
- **Manual approval before publish.** Drop in a `type: approval` job between
  `container-integration-test` and the publish jobs if you want a human
  before bytes leave CI.
- **Image signing (cosign + Sigstore).** Easy to layer on after `publish-ecr`;
  consumers can then verify images by SHA before deploy.
- **dgoss for container tests.** [`scripts/smoke-test.sh`](scripts/smoke-test.sh)
  hand-rolls the assertions to keep dependencies minimal. dgoss would give
  you declarative YAML and is a one-line swap.
- **Larger machine class for builds.** The default executor is fine here; a
  larger resource class would matter once the image grows or the test suite
  parallelizes.
- **Parallel test splits.** `circleci tests split` would matter once pytest
  takes more than ~30s. Not worth it at this size.
- **Pin orb versions tighter than `@3.0.0` / `@5.1.1`.** If you want fully
  reproducible runs, pin to exact patch versions in your fork.

See [`SETUP.md`](SETUP.md) for the one-time CircleCI + AWS OIDC bootstrap.
