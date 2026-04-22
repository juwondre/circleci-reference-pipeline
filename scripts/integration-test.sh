#!/usr/bin/env bash
set -euo pipefail

# Stand the built image up next to a real postgres and exercise the HTTP API.
# This is what proves the artifact actually works end-to-end before we publish
# to ECR or S3.
image="${1:?usage: integration-test.sh <image>}"
net="cci-it-$$"
db="cci-it-db-$$"
app="cci-it-app-$$"

cleanup() {
  docker rm -f "$app" "$db" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$net" >/dev/null

docker run -d --name "$db" --network "$net" \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=appdb \
  postgres:16-alpine >/dev/null

docker run -d --name "$app" --network "$net" \
  -e DATABASE_URL="postgresql+psycopg://app:app@${db}:5432/appdb" \
  -p 8080:8080 \
  "$image" >/dev/null

# Poll the container's healthcheck instead of guessing a sleep duration.
for i in $(seq 1 30); do
  status="$(docker inspect -f '{{.State.Health.Status}}' "$app" 2>/dev/null || echo starting)"
  [ "$status" = "healthy" ] && break
  sleep 2
done
[ "$status" = "healthy" ] || { docker logs "$app"; echo "app never became healthy" >&2; exit 1; }

echo "→ POST /items"
curl -fsS -XPOST -H 'content-type: application/json' \
  -d '{"name":"smoke-widget"}' http://127.0.0.1:8080/items

echo "→ GET /items returns the row we just wrote"
got="$(curl -fsS http://127.0.0.1:8080/items | grep -c smoke-widget || true)"
[ "$got" -ge 1 ] || { echo "round trip failed"; exit 1; }

echo "integration test passed"
