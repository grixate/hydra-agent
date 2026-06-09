#!/usr/bin/env bash
set -euo pipefail

compose_file="${COMPOSE_FILE:-docker-compose.prod.yml}"
output="${1:-backups/hydra-agent-$(date -u +%Y%m%dT%H%M%SZ).sql}"

mkdir -p "$(dirname "$output")"
umask 077

docker compose -f "$compose_file" exec -T postgres \
  pg_dump -U hydra -d hydra_agent --clean --if-exists >"$output"

bytes="$(wc -c <"$output" | tr -d ' ')"

if [ "$bytes" = "0" ]; then
  echo "Backup failed: $output is empty" >&2
  exit 1
fi

echo "Wrote $output ($bytes bytes)"
