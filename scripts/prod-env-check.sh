#!/usr/bin/env bash
set -euo pipefail

compose_file="${COMPOSE_FILE:-docker-compose.prod.yml}"

required_env=(
  PHX_HOST
  POSTGRES_PASSWORD
  SECRET_KEY_BASE
  HYDRA_API_TOKEN
  HYDRA_ADMIN_USERNAME
  HYDRA_ADMIN_PASSWORD
  HYDRA_BROWSER_WORKER_TOKEN
)

missing=0

for name in "${required_env[@]}"; do
  if [ -z "${!name:-}" ]; then
    echo "missing required env: $name" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

if [ "${#SECRET_KEY_BASE}" -lt 64 ]; then
  echo "SECRET_KEY_BASE should be at least 64 characters" >&2
  exit 1
fi

if [ "${#HYDRA_API_TOKEN}" -lt 24 ]; then
  echo "HYDRA_API_TOKEN should be at least 24 characters" >&2
  exit 1
fi

if [ "${#HYDRA_ADMIN_PASSWORD}" -lt 16 ]; then
  echo "HYDRA_ADMIN_PASSWORD should be at least 16 characters" >&2
  exit 1
fi

if [ "${#HYDRA_BROWSER_WORKER_TOKEN}" -lt 24 ]; then
  echo "HYDRA_BROWSER_WORKER_TOKEN should be at least 24 characters" >&2
  exit 1
fi

if [ "$HYDRA_API_TOKEN" = "$HYDRA_BROWSER_WORKER_TOKEN" ]; then
  echo "HYDRA_API_TOKEN and HYDRA_BROWSER_WORKER_TOKEN must be different" >&2
  exit 1
fi

if [ "$HYDRA_ADMIN_PASSWORD" = "$HYDRA_API_TOKEN" ] ||
  [ "$HYDRA_ADMIN_PASSWORD" = "$HYDRA_BROWSER_WORKER_TOKEN" ]; then
  echo "HYDRA_ADMIN_PASSWORD must not be reused as an API or worker token" >&2
  exit 1
fi

docker compose -f "$compose_file" --profile migrate --profile smoke config --quiet

echo "Production env shape is valid for $compose_file"
