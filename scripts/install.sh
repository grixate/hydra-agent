#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

compose_file="${COMPOSE_FILE:-docker-compose.prod.yml}"
env_file="${HYDRA_ENV_FILE:-.env}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

random_hex() {
  openssl rand -hex "$1"
}

random_secret() {
  openssl rand -base64 64 | tr -d '\n'
}

prompt_default() {
  local name="$1"
  local prompt="$2"
  local default="$3"
  local value="${!name:-}"

  if [ -n "$value" ]; then
    printf '%s' "$value"
    return
  fi

  if [ -t 0 ]; then
    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    printf '%s' "$default"
  fi
}

prompt_required() {
  local name="$1"
  local prompt="$2"
  local value="${!name:-}"

  if [ -n "$value" ]; then
    printf '%s' "$value"
    return
  fi

  if [ -t 0 ]; then
    while [ -z "$value" ]; do
      read -r -p "$prompt: " value
    done
    printf '%s' "$value"
  else
    echo "missing required env: $name" >&2
    exit 1
  fi
}

write_env_file() {
  local phx_host="$1"
  local admin_username="$2"
  local admin_password="$3"
  local postgres_password="$4"
  local secret_key_base="$5"
  local api_token="$6"
  local worker_token="$7"

  umask 077
  cat >"$env_file" <<EOF
PHX_HOST=$phx_host
CADDY_ACME_EMAIL=${CADDY_ACME_EMAIL:-}
POSTGRES_PASSWORD=$postgres_password
SECRET_KEY_BASE=$secret_key_base
HYDRA_API_TOKEN=$api_token
HYDRA_ADMIN_USERNAME=$admin_username
HYDRA_ADMIN_PASSWORD=$admin_password
HYDRA_BROWSER_WORKER_TOKEN=$worker_token
HYDRA_BACKUP_CONFIGURED=false
HYDRA_SMOKE_FAIL_ON_WARNING=false
TELEGRAM_BOT_TOKEN=
TELEGRAM_WEBHOOK_SECRET=
EMAIL_ACCESS_TOKEN=
CALENDAR_ACCESS_TOKEN=
NOTION_TOKEN=
YOUTUBE_API_KEY=
X_ACCESS_TOKEN=
LINKEDIN_ACCESS_TOKEN=
EOF
}

need docker
need openssl

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose is required" >&2
  exit 1
fi

created_env=false

if [ ! -f "$env_file" ]; then
  echo "Hydra first install"
  phx_host="$(prompt_required PHX_HOST "Domain for Hydra, for example hydra.example.com")"
  admin_username="$(prompt_default HYDRA_ADMIN_USERNAME "Admin username" "admin")"
  admin_password="${HYDRA_ADMIN_PASSWORD:-$(random_hex 18)}"
  postgres_password="${POSTGRES_PASSWORD:-$(random_hex 24)}"
  secret_key_base="${SECRET_KEY_BASE:-$(random_secret)}"
  api_token="${HYDRA_API_TOKEN:-$(random_hex 32)}"
  worker_token="${HYDRA_BROWSER_WORKER_TOKEN:-$(random_hex 32)}"

  write_env_file \
    "$phx_host" \
    "$admin_username" \
    "$admin_password" \
    "$postgres_password" \
    "$secret_key_base" \
    "$api_token" \
    "$worker_token"

  created_env=true
  echo "Wrote $env_file with generated secrets."
else
  echo "Using existing $env_file."
fi

set -a
# shellcheck disable=SC1090
. "$env_file"
set +a

scripts/prod-env-check.sh
docker compose -f "$compose_file" --profile migrate run --rm migrate
docker compose -f "$compose_file" up -d --build
docker compose -f "$compose_file" --profile smoke run --rm smoke

cat <<EOF

Hydra is running.

Open: https://$PHX_HOST/setup
Admin username: $HYDRA_ADMIN_USERNAME
EOF

if [ "$created_env" = true ]; then
  cat <<EOF
Admin password: $HYDRA_ADMIN_PASSWORD

The password is also stored in $env_file on this server. Keep that file private.
EOF
fi
