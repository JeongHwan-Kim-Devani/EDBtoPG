#!/usr/bin/env bash
set -euo pipefail

: "${EPAS_HOST:?EPAS_HOST is required}"
: "${EPAS_PORT:=5444}"
: "${EPAS_DB:?EPAS_DB is required}"
: "${EPAS_USER:?EPAS_USER is required}"
: "${EPAS_PASSWORD:?EPAS_PASSWORD is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/insert_sample_data.sql"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql command not found. Please install PostgreSQL client tools first." >&2
  exit 1
fi

export PGPASSWORD="${EPAS_PASSWORD}"

echo "[INFO] Connecting to ${EPAS_HOST}:${EPAS_PORT}/${EPAS_DB} as ${EPAS_USER}"
psql \
  --host="${EPAS_HOST}" \
  --port="${EPAS_PORT}" \
  --dbname="${EPAS_DB}" \
  --username="${EPAS_USER}" \
  --set=ON_ERROR_STOP=1 \
  --file="${SQL_FILE}"

echo "[INFO] Sample data inserted successfully."
