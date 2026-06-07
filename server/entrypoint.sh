#!/bin/sh
# Container entrypoint: optionally bootstrap a superuser from env vars, then
# serve. `superuser upsert` is idempotent — it creates the account on a fresh
# pb_data and updates the password on subsequent boots, so the credentials in
# the environment are always the source of truth. Leave the vars unset to manage
# superusers manually (the installer UI at /_/ or the CLI).
set -e

if [ -n "$PB_SUPERUSER_EMAIL" ] && [ -n "$PB_SUPERUSER_PASSWORD" ]; then
  echo "entrypoint: ensuring superuser '$PB_SUPERUSER_EMAIL' (password min 8 chars)…"
  /pb/pocketbase superuser upsert "$PB_SUPERUSER_EMAIL" "$PB_SUPERUSER_PASSWORD"
fi

# `exec` so PocketBase becomes PID 1 and receives signals (graceful shutdown).
# "$@" carries the CMD args (the serve invocation) from the Dockerfile.
exec "$@"
