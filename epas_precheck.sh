#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

usage() {
  cat <<'USAGE'
EPAS -> PostgreSQL pre-diagnostic helper

Usage:
  ./epas_precheck.sh [options]

Options:
  -h, --host HOST         Database host (default: localhost)
  -p, --port PORT         Database port (default: 5444)
  -d, --dbname DBNAME     Database name (required)
  -U, --user USER         Database user (required)
  -W, --password PASSWORD Database password (or use PGPASSWORD env)
  -s, --schema SCHEMA     Limit object inventory to one schema
  -o, --output DIR        Output directory (default: ./precheck_output_<timestamp>)
  --oracle-checks         Run Oracle-compatibility pattern checks on function bodies
  --connect-timeout SEC   libpq connection timeout seconds (default: 5)

Example:
  ./epas_precheck.sh -h 10.0.0.10 -p 5444 -d appdb -U enterprisedb -o ./precheck
USAGE
}

HOST="localhost"
PORT="5444"
DBNAME=""
DBUSER=""
DBPASSWORD="${PGPASSWORD:-}"
SCHEMA=""
OUTPUT_DIR="precheck_output_$(date +%Y%m%d_%H%M%S)"
ORACLE_CHECKS=0
CONNECT_TIMEOUT="5"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Required command not found: $cmd" >&2
    exit 1
  fi
}

sql_literal() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

line_count() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -l < "$file"
  else
    echo 0
  fi
}

nonempty_line_count() {
  local file="$1"
  if [[ -f "$file" ]]; then
    grep -c . "$file" 2>/dev/null || true
  else
    echo 0
  fi
}

run_sql() {
  local out_file="$1"
  local sql="$2"
  "${PSQL[@]}" -Atqc "$sql" > "$out_file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host) HOST="$2"; shift 2 ;;
    -p|--port) PORT="$2"; shift 2 ;;
    -d|--dbname) DBNAME="$2"; shift 2 ;;
    -U|--user) DBUSER="$2"; shift 2 ;;
    -W|--password) DBPASSWORD="$2"; shift 2 ;;
    -s|--schema) SCHEMA="$2"; shift 2 ;;
    -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
    --oracle-checks) ORACLE_CHECKS=1; shift ;;
    --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    --help|-\?) usage; exit 0 ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DBNAME" || -z "$DBUSER" ]]; then
  echo "[ERROR] --dbname and --user are required." >&2
  usage
  exit 1
fi

require_cmd psql

if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] --port must be numeric." >&2
  exit 1
fi

if [[ ! "$CONNECT_TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] --connect-timeout must be numeric." >&2
  exit 1
fi

if [[ -n "$SCHEMA" && ! "$SCHEMA" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "[ERROR] --schema must be an unquoted schema identifier (letters, numbers, underscore)." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

export PGPASSWORD="$DBPASSWORD"
export PGCONNECT_TIMEOUT="$CONNECT_TIMEOUT"
PSQL=(psql -X -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$DBUSER" -d "$DBNAME")

echo "[INFO] Output directory: $OUTPUT_DIR"
echo "[INFO] Checking DB connectivity..."
if ! run_sql "$OUTPUT_DIR/version.txt" "select version();"; then
  echo "[ERROR] Connection failed. Check host/port/db/user/password and role existence." >&2
  echo "[HINT] Example check: psql -h '$HOST' -p '$PORT' -U '$DBUSER' -d '$DBNAME' -c 'select current_user, current_database();'" >&2
  exit 1
fi

schema_filter=""
schema_filter_table=""
if [[ -n "$SCHEMA" ]]; then
  schema_sql=$(sql_literal "$SCHEMA")
  schema_filter="AND n.nspname = ${schema_sql}"
  schema_filter_table="AND table_schema = ${schema_sql}"
fi

echo "[INFO] Collecting instance settings (encoding/collation/timezone)..."
run_sql "$OUTPUT_DIR/instance_settings.tsv" "
SELECT name || E'\\t' || setting
FROM pg_settings
WHERE name IN ('server_encoding','lc_collate','lc_ctype','TimeZone')
ORDER BY name;"

echo "[INFO] Collecting extension inventory..."
run_sql "$OUTPUT_DIR/extensions.tsv" "
SELECT extname || E'\\t' || extversion
FROM pg_extension
ORDER BY extname;"

echo "[INFO] Collecting schema/object inventory..."
run_sql "$OUTPUT_DIR/objects.tsv" "
SELECT n.nspname || E'\\t' || c.relname || E'\\t' || c.relkind
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND c.relkind IN ('r','p','v','m','S','f')
  ${schema_filter}
ORDER BY n.nspname, c.relkind, c.relname;"

echo "[INFO] Collecting object kind counts..."
run_sql "$OUTPUT_DIR/object_kind_counts.tsv" "
SELECT relkind || E'\\t' || count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND c.relkind IN ('r','p','v','m','S','f')
  ${schema_filter}
GROUP BY relkind
ORDER BY relkind;"

echo "[INFO] Collecting function/procedure inventory..."
run_sql "$OUTPUT_DIR/routines.tsv" "
SELECT n.nspname || E'\\t' || p.proname || E'\\t' || l.lanname || E'\\t' || p.prokind
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter}
ORDER BY n.nspname, p.proname;"

echo "[INFO] Collecting routine kind counts..."
run_sql "$OUTPUT_DIR/routine_kind_counts.tsv" "
SELECT prokind || E'\\t' || count(*)
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter}
GROUP BY prokind
ORDER BY prokind;"

echo "[INFO] Collecting role/grant summary..."
run_sql "$OUTPUT_DIR/table_grants.tsv" "
SELECT grantee || E'\\t' || table_schema || E'\\t' || table_name || E'\\t' || privilege_type
FROM information_schema.table_privileges
WHERE table_schema NOT IN ('pg_catalog','information_schema')
  ${schema_filter_table}
ORDER BY grantee, table_schema, table_name;"

echo "[INFO] Collecting data type hotspot inventory..."
run_sql "$OUTPUT_DIR/type_hotspots.tsv" "
SELECT table_schema || E'\\t' || table_name || E'\\t' || column_name || E'\\t' || data_type || E'\\t' || COALESCE(udt_name,'')
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog','information_schema')
  ${schema_filter_table}
  AND (
    data_type IN ('timestamp with time zone','timestamp without time zone','time with time zone','time without time zone','numeric')
    OR udt_name IN ('xml','json','jsonb')
  )
ORDER BY table_schema, table_name, ordinal_position;"

echo "[INFO] Checking sequence alignment risks..."
run_sql "$OUTPUT_DIR/sequences.tsv" "
SELECT n.nspname || E'\\t' || c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'S'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter}
ORDER BY n.nspname, c.relname;"

echo "[INFO] Checking for EPAS/EDB specific extensions or names..."
run_sql "$OUTPUT_DIR/edb_extension_hits.txt" "
SELECT extname
FROM pg_extension
WHERE extname ILIKE 'edb%'
ORDER BY extname;"

run_sql "$OUTPUT_DIR/edb_function_name_hits.txt" "
SELECT n.nspname || E'.' || p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND p.proname ILIKE 'edb%'
  ${schema_filter}
ORDER BY 1;"

if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
  echo "[INFO] Running Oracle-compatibility keyword checks in routine definitions..."
  run_sql "$OUTPUT_DIR/oracle_keyword_hits.tsv" "
  SELECT n.nspname || E'.' || p.proname || E'\\t' || kw.keyword
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL (
    VALUES ('SYSDATE'), ('SYSTIMESTAMP'), ('ROWNUM'), ('NVL('), ('DECODE('), ('DUAL')
  ) kw(keyword)
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    AND pg_get_functiondef(p.oid) ILIKE '%' || kw.keyword || '%'
    ${schema_filter}
  ORDER BY 1, 2;"
fi

echo "[INFO] Writing count summary..."
{
  echo "metric\tcount"
  echo -e "instance_settings\t$(line_count "$OUTPUT_DIR/instance_settings.tsv")"
  echo -e "extensions\t$(line_count "$OUTPUT_DIR/extensions.tsv")"
  echo -e "objects\t$(line_count "$OUTPUT_DIR/objects.tsv")"
  echo -e "object_kinds\t$(line_count "$OUTPUT_DIR/object_kind_counts.tsv")"
  echo -e "routines\t$(line_count "$OUTPUT_DIR/routines.tsv")"
  echo -e "routine_kinds\t$(line_count "$OUTPUT_DIR/routine_kind_counts.tsv")"
  echo -e "table_grants\t$(line_count "$OUTPUT_DIR/table_grants.tsv")"
  echo -e "type_hotspots\t$(line_count "$OUTPUT_DIR/type_hotspots.tsv")"
  echo -e "sequences\t$(line_count "$OUTPUT_DIR/sequences.tsv")"
  echo -e "edb_extensions\t$(nonempty_line_count "$OUTPUT_DIR/edb_extension_hits.txt")"
  echo -e "edb_named_routines\t$(nonempty_line_count "$OUTPUT_DIR/edb_function_name_hits.txt")"
  if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
    echo -e "oracle_keyword_hits\t$(nonempty_line_count "$OUTPUT_DIR/oracle_keyword_hits.tsv")"
  fi
} > "$OUTPUT_DIR/count_summary.tsv"

echo "[INFO] Writing quick summary..."
{
  echo "# EPAS precheck summary"
  echo "- target: ${HOST}:${PORT}/${DBNAME}"
  [[ -n "$SCHEMA" ]] && echo "- schema filter: $SCHEMA" || echo "- schema filter: (none)"
  echo "- generated_at: $(date -Iseconds)"
  echo
  echo "## counts"
  echo "instance_settings=$(line_count "$OUTPUT_DIR/instance_settings.tsv")"
  echo "extensions=$(line_count "$OUTPUT_DIR/extensions.tsv")"
  echo "objects=$(line_count "$OUTPUT_DIR/objects.tsv")"
  echo "routines=$(line_count "$OUTPUT_DIR/routines.tsv")"
  echo "table_grants=$(line_count "$OUTPUT_DIR/table_grants.tsv")"
  echo "type_hotspots=$(line_count "$OUTPUT_DIR/type_hotspots.tsv")"
  echo "sequences=$(line_count "$OUTPUT_DIR/sequences.tsv")"
  echo "edb_extensions=$(nonempty_line_count "$OUTPUT_DIR/edb_extension_hits.txt")"
  echo "edb_named_routines=$(nonempty_line_count "$OUTPUT_DIR/edb_function_name_hits.txt")"
  if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
    echo "oracle_keyword_hits=$(nonempty_line_count "$OUTPUT_DIR/oracle_keyword_hits.tsv")"
  fi
  echo
  echo "See also: count_summary.tsv, object_kind_counts.tsv, routine_kind_counts.tsv"
} > "$OUTPUT_DIR/summary.md"

echo "[DONE] Pre-diagnostic data collected. See: $OUTPUT_DIR"