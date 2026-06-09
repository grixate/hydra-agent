#!/usr/bin/env bash
set -euo pipefail

base_url="${HYDRA_BASE_URL:-${1:-}}"
token="${HYDRA_API_TOKEN:-}"
workspace_id="${HYDRA_SMOKE_WORKSPACE_ID:-${2:-}}"
fail_on_warning="${HYDRA_SMOKE_FAIL_ON_WARNING:-false}"

if [ -z "$base_url" ]; then
  echo "HYDRA_BASE_URL or a base URL argument is required" >&2
  exit 64
fi

if [ -z "$token" ]; then
  echo "HYDRA_API_TOKEN is required" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fetch_doctor() {
  local path="$1"
  local output="$2"

  curl -fsS \
    -H "authorization: Bearer $token" \
    -H "accept: application/json" \
    "$base_url$path" >"$output"
}

assert_status() {
  local label="$1"
  local file="$2"

  local status
  status="$(json_status "$file")"

  if [ "$status" = "error" ]; then
    echo "$label doctor reported errors" >&2
    cat "$file" >&2
    exit 1
  fi

  if [ "$status" = "warning" ] && [ "$fail_on_warning" = "true" ]; then
    echo "$label doctor reported warnings" >&2
    cat "$file" >&2
    exit 1
  fi

  echo "$label doctor status: $status"
}

json_status() {
  local file="$1"

  if command -v jq >/dev/null 2>&1; then
    jq -r '.data.status' "$file"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    FILE="$file" python3 - <<'PY'
import json
import os

with open(os.environ["FILE"], encoding="utf-8") as handle:
    print(json.load(handle)["data"]["status"])
PY
    return
  fi

  if command -v node >/dev/null 2>&1; then
    FILE="$file" node -e "const fs=require('node:fs'); const data=JSON.parse(fs.readFileSync(process.env.FILE, 'utf8')); console.log(data.data.status)"
    return
  fi

  echo "No JSON parser found; install jq, python3, or node" >&2
  exit 1
}

global_report="$tmp_dir/global.json"
fetch_doctor "/api/v1/doctor" "$global_report"
assert_status "global" "$global_report"

if [ -n "$workspace_id" ]; then
  workspace_report="$tmp_dir/workspace.json"
  fetch_doctor "/api/v1/workspaces/$workspace_id/doctor" "$workspace_report"
  assert_status "workspace $workspace_id" "$workspace_report"
fi
