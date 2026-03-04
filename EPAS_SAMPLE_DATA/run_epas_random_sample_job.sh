#!/usr/bin/env bash
set -euo pipefail

: "${EPAS_HOST:?EPAS_HOST is required}"
: "${EPAS_PORT:=5444}"
: "${EPAS_DB:?EPAS_DB is required}"
: "${EPAS_USER:?EPAS_USER is required}"
: "${EPAS_PASSWORD:?EPAS_PASSWORD is required}"

TARGET_KB="${TARGET_KB:-1024}"
BATCH_TAG="${BATCH_TAG:-cron_manual_$(date +%Y%m%d%H%M%S)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/epas_random_sample_job.sql"

export PGPASSWORD="${EPAS_PASSWORD}"

psql \
  --host="${EPAS_HOST}" \
  --port="${EPAS_PORT}" \
  --dbname="${EPAS_DB}" \
  --username="${EPAS_USER}" \
  --set=ON_ERROR_STOP=1 \
  --file="${SQL_FILE}"

psql \
  --host="${EPAS_HOST}" \
  --port="${EPAS_PORT}" \
  --dbname="${EPAS_DB}" \
  --username="${EPAS_USER}" \
  --set=ON_ERROR_STOP=1 \
  --command="CALL demo_cron.pr_generate_random_sample(${TARGET_KB}, '${BATCH_TAG}');"

echo "[INFO] demo_cron.pr_generate_random_sample executed. target_kb=${TARGET_KB}, batch_tag=${BATCH_TAG}"
