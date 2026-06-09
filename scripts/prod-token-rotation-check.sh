#!/usr/bin/env bash
set -euo pipefail

compose_file="${COMPOSE_FILE:-docker-compose.prod.yml}"

for name in HYDRA_API_TOKEN HYDRA_ADMIN_PASSWORD HYDRA_BROWSER_WORKER_TOKEN; do
  if [ -z "${!name:-}" ]; then
    echo "$name is required" >&2
    exit 1
  fi
done

docker compose -f "$compose_file" exec -T app curl -fsS http://127.0.0.1:4000/api/health >/dev/null
docker compose -f "$compose_file" --profile smoke run --rm smoke >/dev/null

old_token_status="$(
  docker compose -f "$compose_file" exec -T app sh -c \
    "curl -s -o /dev/null -w '%{http_code}' -H 'authorization: Bearer old-token' http://127.0.0.1:4000/api/v1/doctor"
)"

if [ "$old_token_status" != "401" ] && [ "$old_token_status" != "403" ]; then
  echo "Unexpected response for stale API token: HTTP $old_token_status" >&2
  exit 1
fi

echo "Token rotation proof passed: app healthy, smoke green, stale token rejected"
