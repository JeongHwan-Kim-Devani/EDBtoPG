#!/usr/bin/env bash
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

mkdir -p "$OUTPUT_DIR"

export PGPASSWORD="$DBPASSWORD"
PSQL=(psql -X -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$DBUSER" -d "$DBNAME")

echo "[INFO] Output directory: $OUTPUT_DIR"
echo "[INFO] Checking DB connectivity..."
"${PSQL[@]}" -Atqc "select version();" > "$OUTPUT_DIR/version.txt"

schema_filter=""
if [[ -n "$SCHEMA" ]]; then
  schema_filter="AND n.nspname = '$SCHEMA'"
fi

echo "[INFO] Collecting extension inventory..."
"${PSQL[@]}" -Atqc "
SELECT extname || E'\t' || extversion
FROM pg_extension
ORDER BY extname;
" > "$OUTPUT_DIR/extensions.tsv"

echo "[INFO] Collecting schema/object inventory..."
"${PSQL[@]}" -Atqc "
SELECT n.nspname || E'\t' || c.relname || E'\t' || c.relkind
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND c.relkind IN ('r','p','v','m','S','f')
  ${schema_filter}
ORDER BY n.nspname, c.relkind, c.relname;
" > "$OUTPUT_DIR/objects.tsv"

echo "[INFO] Collecting function/procedure inventory..."
"${PSQL[@]}" -Atqc "
SELECT n.nspname || E'\t' || p.proname || E'\t' || l.lanname || E'\t' || p.prokind
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter}
ORDER BY n.nspname, p.proname;
" > "$OUTPUT_DIR/routines.tsv"

echo "[INFO] Collecting role/grant summary..."
"${PSQL[@]}" -Atqc "
SELECT grantee || E'\t' || table_schema || E'\t' || table_name || E'\t' || privilege_type
FROM information_schema.table_privileges
WHERE table_schema NOT IN ('pg_catalog','information_schema')
  ${SCHEMA:+AND table_schema = '$SCHEMA'}
ORDER BY grantee, table_schema, table_name;
" > "$OUTPUT_DIR/table_grants.tsv"

echo "[INFO] Checking for EPAS/EDB specific extensions or names..."
"${PSQL[@]}" -Atqc "
SELECT extname
FROM pg_extension
WHERE extname ILIKE 'edb%'
ORDER BY extname;
" > "$OUTPUT_DIR/edb_extension_hits.txt"

"${PSQL[@]}" -Atqc "
SELECT n.nspname || E'.' || p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND p.proname ILIKE 'edb%'
  ${schema_filter}
ORDER BY 1;
" > "$OUTPUT_DIR/edb_function_name_hits.txt"

if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
  echo "[INFO] Running Oracle-compatibility keyword checks in routine definitions..."
  "${PSQL[@]}" -Atqc "
  SELECT n.nspname || E'.' || p.proname || E'\t' || kw.keyword
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL (
    VALUES ('SYSDATE'), ('SYSTIMESTAMP'), ('ROWNUM'), ('NVL('), ('DECODE('), ('DUAL')
  ) kw(keyword)
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    AND pg_get_functiondef(p.oid) ILIKE '%' || kw.keyword || '%'
    ${schema_filter}
  ORDER BY 1, 2;
  " > "$OUTPUT_DIR/oracle_keyword_hits.tsv"
fi

echo "[INFO] Writing quick summary..."
{
  echo "# EPAS precheck summary"
  echo "- target: ${HOST}:${PORT}/${DBNAME}"
  [[ -n "$SCHEMA" ]] && echo "- schema filter: $SCHEMA" || echo "- schema filter: (none)"
  echo "- generated_at: $(date -Iseconds)"
  echo
  echo "## counts"
  echo "extensions=$(wc -l < \"$OUTPUT_DIR/extensions.tsv\")"
  echo "objects=$(wc -l < \"$OUTPUT_DIR/objects.tsv\")"
  echo "routines=$(wc -l < \"$OUTPUT_DIR/routines.tsv\")"
  echo "table_grants=$(wc -l < \"$OUTPUT_DIR/table_grants.tsv\")"
  echo "edb_extensions=$(grep -c . \"$OUTPUT_DIR/edb_extension_hits.txt\" || true)"
  echo "edb_named_routines=$(grep -c . \"$OUTPUT_DIR/edb_function_name_hits.txt\" || true)"
  if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
    echo "oracle_keyword_hits=$(grep -c . \"$OUTPUT_DIR/oracle_keyword_hits.tsv\" || true)"
  fi
} > "$OUTPUT_DIR/summary.md"

echo "[DONE] Pre-diagnostic data collected. See: $OUTPUT_DIR"
