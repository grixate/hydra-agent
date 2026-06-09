#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 path/to/backup.sql" >&2
  exit 64
fi

backup="$1"
compose_file="${COMPOSE_FILE:-docker-compose.prod.yml}"
project="hydra_restore_smoke_$(date -u +%Y%m%d%H%M%S)"

if [ ! -s "$backup" ]; then
  echo "Backup file does not exist or is empty: $backup" >&2
  exit 66
fi

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$project}"
export HYDRA_SMOKE_FAIL_ON_WARNING="${HYDRA_SMOKE_FAIL_ON_WARNING:-true}"
export HYDRA_BACKUP_CONFIGURED="${HYDRA_BACKUP_CONFIGURED:-true}"

cleanup() {
  docker compose -f "$compose_file" --profile migrate --profile smoke down -v --remove-orphans
}
trap cleanup EXIT

wait_for_postgres() {
  for attempt in {1..30}; do
    if docker compose -f "$compose_file" exec -T postgres pg_isready -U hydra -d hydra_agent >/dev/null 2>&1; then
      return 0
    fi

    if [ "$attempt" = "30" ]; then
      docker compose -f "$compose_file" logs postgres
      echo "Postgres did not become ready for restore smoke" >&2
      return 1
    fi

    sleep 2
  done
}

wait_for_browser_worker() {
  for attempt in {1..30}; do
    if docker compose -f "$compose_file" exec -T browser-worker node -e "fetch('http://127.0.0.1:4100/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))" >/dev/null 2>&1; then
      return 0
    fi

    if [ "$attempt" = "30" ]; then
      docker compose -f "$compose_file" logs browser-worker
      echo "Browser worker did not become ready for restore smoke" >&2
      return 1
    fi

    sleep 2
  done
}

docker compose -f "$compose_file" up -d postgres browser-worker
wait_for_postgres
wait_for_browser_worker

docker compose -f "$compose_file" exec -T postgres \
  sh -c "dropdb -U hydra --if-exists hydra_agent && createdb -U hydra hydra_agent"

docker compose -f "$compose_file" exec -T postgres \
  psql -U hydra -d hydra_agent <"$backup"

docker compose -f "$compose_file" --profile migrate run --rm migrate
docker compose -f "$compose_file" up -d app

for attempt in {1..30}; do
  if docker compose -f "$compose_file" exec -T app curl -fsS http://127.0.0.1:4000/api/health >/dev/null; then
    break
  fi

  if [ "$attempt" = "30" ]; then
    docker compose -f "$compose_file" logs app
    exit 1
  fi

  sleep 2
done

docker compose -f "$compose_file" --profile smoke run --rm smoke

echo "Restore smoke passed for $backup using Compose project $COMPOSE_PROJECT_NAME"
