#!/usr/bin/env bash
#
# run_local.sh — run the whole app locally, no AWS, with one command.
#
#   ./scripts/run_local.sh up      # build + start (app on http://127.0.0.1:8000)
#   ./scripts/run_local.sh down     # stop + remove everything
#   ./scripts/run_local.sh logs     # follow the app's logs
#
# This is the no-install equivalent of `docker compose up` (see
# docker-compose.yml): same two containers, but driven by plain `docker` so it
# works even without the Compose plugin. It stands in for the AWS stack on your
# laptop — the "app" container is the same image Fargate runs; the "db" container
# is a local Postgres playing the role of RDS. The only thing swapped is where
# the DB password comes from (DATABASE_URL here vs. Secrets Manager in AWS).

set -euo pipefail

NET=us-net
DB=us-db
APP=us-app
IMAGE=url-shortener:local
PORT=8000
DB_USER=appuser
DB_PASS=localpw
DB_NAME=urlshortener

# Repo paths, resolved relative to this script so it works from any directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

down() {
  docker rm -f "$APP" "$DB" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}

up() {
  down # start from a clean slate (idempotent)
  docker network create "$NET" >/dev/null

  echo "Starting Postgres…"
  docker run -d --name "$DB" --network "$NET" \
    -e POSTGRES_USER="$DB_USER" \
    -e POSTGRES_PASSWORD="$DB_PASS" \
    -e POSTGRES_DB="$DB_NAME" \
    postgres:16-alpine >/dev/null
  local ready=false
  for _ in $(seq 1 30); do
    if docker exec "$DB" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  $ready || {
    echo "Postgres did not become ready in time." >&2
    exit 1
  }

  echo "Building app image… (first run takes ~1 min)"
  docker build -t "$IMAGE" "$ROOT/app" >/dev/null

  echo "Starting app…"
  docker run -d --name "$APP" --network "$NET" \
    -e DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB:5432/$DB_NAME" \
    -p "127.0.0.1:$PORT:$PORT" \
    "$IMAGE" >/dev/null
  local healthy=false
  for _ in $(seq 1 30); do
    if curl -fs "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
      healthy=true
      break
    fi
    sleep 1
  done
  $healthy || {
    echo "App did not become healthy in time. Check: docker logs $APP" >&2
    exit 1
  }

  echo
  echo "  URL shortener is up →  http://127.0.0.1:$PORT"
  echo "  Stop it with        →  ./scripts/run_local.sh down"
}

case "${1:-up}" in
up) up ;;
down)
  down
  echo "Stopped and removed local containers + network."
  ;;
logs) docker logs -f "$APP" ;;
*)
  echo "usage: $0 [up|down|logs]" >&2
  exit 1
  ;;
esac
