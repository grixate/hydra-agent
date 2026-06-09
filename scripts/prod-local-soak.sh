#!/usr/bin/env bash
set -euo pipefail

compose_file="${COMPOSE_FILE:-docker-compose.prod.yml}"
iterations="${HYDRA_SOAK_ITERATIONS:-60}"
sleep_seconds="${HYDRA_SOAK_SLEEP_SECONDS:-1}"
fail_on_warning="${HYDRA_SMOKE_FAIL_ON_WARNING:-true}"

export HYDRA_SMOKE_FAIL_ON_WARNING="$fail_on_warning"
export HYDRA_BACKUP_CONFIGURED="${HYDRA_BACKUP_CONFIGURED:-true}"

cleanup() {
  docker compose -f "$compose_file" --profile migrate --profile smoke down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

scripts/prod-env-check.sh

docker compose -f "$compose_file" --profile migrate --profile smoke build browser-worker app migrate smoke
docker compose -f "$compose_file" up -d postgres browser-worker
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

unauthorized_status="$(
  docker compose -f "$compose_file" exec -T browser-worker node - <<'NODE'
fetch("http://127.0.0.1:4100/actions", {
  method: "POST",
  headers: {"content-type": "application/json"},
  body: JSON.stringify({action: "extract", input: {selector: "body"}, context: {}})
}).then((response) => {
  console.log(response.status);
}).catch(() => {
  console.log("0");
});
NODE
)"

if [ "$unauthorized_status" != "401" ]; then
  echo "Browser worker accepted unauthenticated action request; got HTTP $unauthorized_status" >&2
  exit 1
fi

for i in $(seq 1 "$iterations"); do
  docker compose -f "$compose_file" exec -T app curl -fsS http://127.0.0.1:4000/api/health >/dev/null

  if [ "$((i % 10))" -eq 0 ]; then
    docker compose -f "$compose_file" --profile smoke run --rm smoke >/dev/null
    echo "soak iteration $i/$iterations passed"
  fi

  sleep "$sleep_seconds"
done

echo "Local production soak passed: $iterations health checks plus periodic smoke checks"
