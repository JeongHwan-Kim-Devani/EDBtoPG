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

render_action() {
  local cnt="$1"
  local compat_label="$2"
  local auto_alt="$3"
  local manual_note="$4"

  if [[ "$cnt" -eq 0 ]]; then
    echo "| ${compat_label} | 필요 없음 | 필요 없음 |"
  else
    echo "| 비호환 가능성 높음 | ${auto_alt} | ${manual_note} |"
  fi
}

write_reports() {
  local f_summary="$OUTPUT_DIR/summary.md"
  local f_count="$OUTPUT_DIR/count_summary.tsv"
  local f_guide="$OUTPUT_DIR/migration_guide_report.md"
  local f_plain="$OUTPUT_DIR/migration_summary_report.txt"

  local c_instance c_extensions c_objects c_routines c_grants c_types c_sequences c_edb_ext c_edb_rtn c_epas c_risk c_oracle
  c_instance=$(line_count "$OUTPUT_DIR/instance_settings.tsv")
  c_extensions=$(line_count "$OUTPUT_DIR/extensions.tsv")
  c_objects=$(line_count "$OUTPUT_DIR/objects.tsv")
  c_routines=$(line_count "$OUTPUT_DIR/routines.tsv")
  c_grants=$(line_count "$OUTPUT_DIR/table_grants.tsv")
  c_types=$(line_count "$OUTPUT_DIR/type_hotspots.tsv")
  c_sequences=$(line_count "$OUTPUT_DIR/sequences.tsv")
  c_edb_ext=$(nonempty_line_count "$OUTPUT_DIR/edb_extension_hits.txt")
  c_edb_rtn=$(nonempty_line_count "$OUTPUT_DIR/edb_function_name_hits.txt")
  c_epas=$(nonempty_line_count "$OUTPUT_DIR/epas_feature_hits.tsv")
  c_risk=$(nonempty_line_count "$OUTPUT_DIR/migration_risk_hits.tsv")
  c_oracle=0
  if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
    c_oracle=$(nonempty_line_count "$OUTPUT_DIR/oracle_keyword_hits.tsv")
  fi

  echo "[INFO] Writing count summary..."
  {
    echo "metric\tcount"
    echo -e "instance_settings\t${c_instance}"
    echo -e "extensions\t${c_extensions}"
    echo -e "objects\t${c_objects}"
    echo -e "object_kinds\t$(line_count "$OUTPUT_DIR/object_kind_counts.tsv")"
    echo -e "routines\t${c_routines}"
    echo -e "routine_kinds\t$(line_count "$OUTPUT_DIR/routine_kind_counts.tsv")"
    echo -e "table_grants\t${c_grants}"
    echo -e "type_hotspots\t${c_types}"
    echo -e "sequences\t${c_sequences}"
    echo -e "edb_extensions\t${c_edb_ext}"
    echo -e "edb_named_routines\t${c_edb_rtn}"
    echo -e "epas_feature_hits\t${c_epas}"
    echo -e "migration_risk_hits\t${c_risk}"
    if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
      echo -e "oracle_keyword_hits\t${c_oracle}"
    fi
  } > "$f_count"

  echo "[INFO] Writing quick summary..."
  {
    echo "# EPAS precheck summary"
    echo "- target: ${HOST}:${PORT}/${DBNAME}"
    [[ -n "$SCHEMA" ]] && echo "- schema filter: $SCHEMA" || echo "- schema filter: (none)"
    echo "- generated_at: $(date -Iseconds)"
    echo
    echo "## counts"
    echo "instance_settings=${c_instance}"
    echo "extensions=${c_extensions}"
    echo "objects=${c_objects}"
    echo "routines=${c_routines}"
    echo "table_grants=${c_grants}"
    echo "type_hotspots=${c_types}"
    echo "sequences=${c_sequences}"
    echo "edb_extensions=${c_edb_ext}"
    echo "edb_named_routines=${c_edb_rtn}"
    echo "epas_feature_hits=${c_epas}"
    echo "migration_risk_hits=${c_risk}"
    if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
      echo "oracle_keyword_hits=${c_oracle}"
    fi
    echo
    echo "See also: count_summary.tsv, object_kind_counts.tsv, routine_kind_counts.tsv, migration_guide_report.md, migration_summary_report.txt"
  } > "$f_summary"

  echo "[INFO] Writing migration guide report..."
  {
    echo "# EPAS → PostgreSQL Migration Guide Report"
    echo
    echo "- Target: ${HOST}:${PORT}/${DBNAME}"
    [[ -n "$SCHEMA" ]] && echo "- Schema filter: $SCHEMA" || echo "- Schema filter: (none)"
    echo "- Generated at: $(date -Iseconds)"
    echo
    echo "## 1) Executive summary"
    echo
    echo "| 항목 | 발견 건수 | 평가 |"
    echo "|---|---:|---|"
    echo "| EDB 전용 확장 | ${c_edb_ext} | $([[ "$c_edb_ext" -eq 0 ]] && echo '양호' || echo '호환성 검토 필요') |"
    echo "| EDB 이름 패턴 루틴 | ${c_edb_rtn} | $([[ "$c_edb_rtn" -eq 0 ]] && echo '양호' || echo '재작성 가능성 있음') |"
    echo "| EPAS/Oracle 특화 패턴 히트 | ${c_epas} | $([[ "$c_epas" -eq 0 ]] && echo '양호' || echo '수동 분석 권장') |"
    echo "| 이관 실패 위험 패턴 히트 | ${c_risk} | $([[ "$c_risk" -eq 0 ]] && echo '양호' || echo '사전 치환 강력 권장') |"
    if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
      echo "| Oracle 호환 키워드 히트 | ${c_oracle} | $([[ "$c_oracle" -eq 0 ]] && echo '양호' || echo '재작성 검토 필요') |"
    else
      echo "| Oracle 호환 키워드 히트 | N/A | 검사 미실행 (--oracle-checks 사용 권장) |"
    fi
    echo "| 타입 핫스팟 | ${c_types} | $([[ "$c_types" -eq 0 ]] && echo '양호' || echo '타입 매핑 검토 필요') |"
    echo "| 시퀀스 | ${c_sequences} | $([[ "$c_sequences" -eq 0 ]] && echo '없음' || echo '시퀀스 정합성 점검 필요') |"
    echo
    echo "## 2) 호환성/대체기능/수동수정 가이드"
    echo
    echo "| 점검 영역 | PostgreSQL 호환성 | 대체 기능 가능 여부 | 수동 수정 필요성 | 참고 파일 |"
    echo "|---|---|---|---|---|"
    echo "| EDB 전용 확장(edb%) | $(render_action "$c_edb_ext" "대체로 호환" "유사 확장/표준 SQL로 대체 검토" "확장별 기능 분석 후 스키마/코드 수동 수정 가능성 큼") | edb_extension_hits.txt |"
    echo "| EDB 전용 함수/프로시저 네이밍 | $(render_action "$c_edb_rtn" "대체로 호환" "PL/pgSQL 표준 함수로 치환 가능" "함수 본문 로직 수동 리팩토링 필요 가능") | edb_function_name_hits.txt, routines.tsv |"
    echo "| EPAS/Oracle 특화 함수 패턴(SYS_CONTEXT, AUTHID, NVL 등) | $(render_action "$c_epas" "조건부 호환" "CURRENT_USER, COALESCE, now() 등으로 치환 가능" "패턴별 수동 수정 및 테스트 필요") | epas_feature_hits.tsv |"
    if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
      echo "| Oracle 호환 키워드 사용 | $(render_action "$c_oracle" "대체로 호환" "CASE/COALESCE/표준 SQL로 치환 가능" "복합 비즈니스 로직은 수동 재작성 가능성 높음") | oracle_keyword_hits.tsv |"
    else
      echo "| Oracle 호환 키워드 사용 | 미평가 | --oracle-checks 실행 후 판단 | 실행 후 판단 | oracle_keyword_hits.tsv(옵션) |"
    fi
    echo "| 타입 핫스팟(timestamp/numeric/json/xml) | 조건부 호환 | 타입별 매핑 정책 수립으로 대체 가능 | 애플리케이션 바인딩/정밀도 이슈는 수동 수정 가능 | type_hotspots.tsv |"
    echo "| 시퀀스/자동증가 | 조건부 호환 | identity/sequence setval 전략으로 대체 가능 | cutover 시 시퀀스 동기화 수동 점검 권장 | sequences.tsv |"
    echo
    echo "## 3) 이관 실패 예방 체크리스트"
    echo
    echo "| 자주 실패하는 항목 | 현재 점검 지표 | 권장 선조치 |"
    echo "|---|---|---|"
    echo "| DEFAULT SYSDATE 구문 | migration_risk_hits.tsv 의 SYSDATE_DEFAULT | DDL 변환 전 DEFAULT now()/CURRENT_TIMESTAMP로 치환 |"
    echo "| EDB-SPL 언어 객체 (language edbspl) | migration_risk_hits.tsv 의 EDBSPL_ROUTINE | PL/pgSQL 재작성 후 배포 |"
    echo "| pg_stat_statements 객체 충돌 | migration_risk_hits.tsv 의 PG_STAT_STATEMENTS_OBJECT | 대상 DB의 기존 extension/view/function 사전 정리 |"
    echo "| EPAS 정책/컨텍스트 함수 | migration_risk_hits.tsv 의 POLICY_OR_CONTEXT | PostgreSQL RLS 정책 + CURRENT_USER 기반 함수로 재작성 |"
    echo
    echo "## 4) 덤프 기반 추가 체크리스트 (샘플 기준)"
    echo
    echo "| 항목 | PostgreSQL 호환성 | 대체/권장 방식 | 수동 수정 필요성 |"
    echo "|---|---|---|---|"
    echo "| SYNONYM | 비호환 | VIEW 또는 search_path/SQL 재작성 | 높음 |"
    echo "| PACKAGE | 비호환 | 스키마 + 함수/프로시저 묶음으로 분해 | 높음 |"
    echo "| DBMS_RLS.ADD_POLICY (EDB POLICY) | 부분 호환 | PostgreSQL RLS POLICY로 재구현 | 높음 |"
    echo "| AUTHID DEFINER/CURRENT_USER | 부분 호환 | SECURITY DEFINER/INVOKER 전략 재설계 | 중간~높음 |"
    echo "| SYS_CONTEXT('USERENV','SESSION_USER') | 비호환 | CURRENT_USER/SESSION_USER로 치환 | 중간 |"
    echo "| NVL, SYSDATE | 비호환 | COALESCE, CURRENT_TIMESTAMP/now()로 치환 | 중간 |"
    echo "| CLOB 타입 | 비호환 | text로 매핑 | 중간 |"
    echo
    echo "## 5) 우선순위 액션 플랜"
    echo
    echo "1. **EDB 전용 확장/루틴 우선 정리**: edb_extension_hits.txt, edb_function_name_hits.txt를 기준으로 제거/치환 전략 수립"
    echo "2. **Oracle 패턴 스캔 재실행**: 아직 미실행이면 --oracle-checks 옵션으로 재수집"
    echo "3. **타입/시퀀스 정책 문서화**: type_hotspots.tsv, sequences.tsv 기반으로 표준 매핑표 작성"
    echo "4. **UAT 대상 선정**: 히트가 있는 객체를 우선 테스트 케이스로 지정"
    echo
    echo "## 6) 원본 산출물"
    echo
    echo "- summary.md: 요약"
    echo "- count_summary.tsv: 머신 파싱용 카운트"
    echo "- objects.tsv, object_kind_counts.tsv: 객체 인벤토리"
    echo "- routines.tsv, routine_kind_counts.tsv: 루틴 인벤토리"
    echo "- type_hotspots.tsv, sequences.tsv: 마이그레이션 민감 항목"
    echo "- epas_feature_hits.tsv: EPAS/Oracle 특화 패턴 히트"
    echo "- migration_risk_hits.tsv: 이관 실패 위험 패턴 히트"
    echo "- edb_extension_hits.txt, edb_function_name_hits.txt, oracle_keyword_hits.tsv(옵션): 호환성 리스크 근거"

    echo
    echo "## 7) Migration Summary"
    echo
    echo "총 객체 점검 수: $((c_objects + c_routines))"
    echo "주요 리스크 건수: ${c_risk}"
    echo "- SYSDATE_DEFAULT: $(grep -c $'\tSYSDATE_DEFAULT\t' "$OUTPUT_DIR/migration_risk_hits.tsv" 2>/dev/null || true)"
    echo "- EDBSPL_ROUTINE: $(grep -c $'\tEDBSPL_ROUTINE\t' "$OUTPUT_DIR/migration_risk_hits.tsv" 2>/dev/null || true)"
    echo "- PG_STAT_STATEMENTS_OBJECT: $(grep -c $'\tPG_STAT_STATEMENTS_OBJECT\t' "$OUTPUT_DIR/migration_risk_hits.tsv" 2>/dev/null || true)"
    echo "- POLICY_OR_CONTEXT: $(grep -c $'\tPOLICY_OR_CONTEXT\t' "$OUTPUT_DIR/migration_risk_hits.tsv" 2>/dev/null || true)"
  } > "$f_guide"

  {
    echo "******************** Migration Summary ********************"
    echo "Target: ${HOST}:${PORT}/${DBNAME}"
    [[ -n "$SCHEMA" ]] && echo "Schema filter: $SCHEMA" || echo "Schema filter: (none)"
    echo
    echo "Counts"
    echo "--------------------"
    echo "Objects: ${c_objects}"
    echo "Routines: ${c_routines}"
    echo "Type hotspots: ${c_types}"
    echo "Sequences: ${c_sequences}"
    echo "EPAS feature hits: ${c_epas}"
    echo "Migration risk hits: ${c_risk}"
    [[ "$ORACLE_CHECKS" -eq 1 ]] && echo "Oracle keyword hits: ${c_oracle}"
    echo
    echo "List of migration risk hits"
    echo "======================"
    if [[ -s "$OUTPUT_DIR/migration_risk_hits.tsv" ]]; then
      awk -F '\t' '{print NR ". " $1 " [" $2 "]"}' "$OUTPUT_DIR/migration_risk_hits.tsv"
    else
      echo "No risk hits detected."
    fi
  } > "$f_plain"
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

echo "[INFO] Scanning EPAS/Oracle-specific compatibility patterns..."
run_sql "$OUTPUT_DIR/epas_feature_hits.tsv" "
WITH routine_hits AS (
  SELECT n.nspname || E'.' || p.proname AS object_name,
         'ROUTINE' AS source,
         kw.keyword
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL (
    VALUES ('SYS_CONTEXT('), ('AUTHID'), ('NVL('), ('SYSDATE'), ('SYSTIMESTAMP'), ('DBMS_RLS'), ('DECODE('), ('ROWNUM'), ('DUAL')
  ) kw(keyword)
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
    AND pg_get_functiondef(p.oid) ILIKE '%' || kw.keyword || '%'
),
default_hits AS (
  SELECT n.nspname || E'.' || c.relname || E'.' || a.attname AS object_name,
         'COLUMN_DEFAULT' AS source,
         'SYSDATE' AS keyword
  FROM pg_attrdef d
  JOIN pg_class c ON c.oid = d.adrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
    ${schema_filter}
    AND pg_get_expr(d.adbin, d.adrelid) ILIKE '%sysdate%'
),
type_hits AS (
  SELECT table_schema || E'.' || table_name || E'.' || column_name AS object_name,
         'COLUMN_TYPE' AS source,
         upper(udt_name) AS keyword
  FROM information_schema.columns
  WHERE table_schema NOT IN ('pg_catalog','information_schema')
    ${schema_filter_table}
    AND lower(udt_name) IN ('clob','blob','varchar2','nvarchar2')
)
SELECT object_name || E'\t' || source || E'\t' || keyword
FROM (
  SELECT * FROM routine_hits
  UNION ALL
  SELECT * FROM default_hits
  UNION ALL
  SELECT * FROM type_hits
) t
ORDER BY 1;"

echo "[INFO] Scanning migration failure risk patterns..."
run_sql "$OUTPUT_DIR/migration_risk_hits.tsv" "
WITH sysdate_defaults AS (
  SELECT n.nspname || E'.' || c.relname || E'.' || a.attname AS object_name,
         'SYSDATE_DEFAULT' AS risk_code,
         'DEFAULT uses SYSDATE; convert to now()/CURRENT_TIMESTAMP' AS recommendation
  FROM pg_attrdef d
  JOIN pg_class c ON c.oid = d.adrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
    ${schema_filter}
    AND pg_get_expr(d.adbin, d.adrelid) ILIKE '%sysdate%'
),
edbspl_routines AS (
  SELECT n.nspname || E'.' || p.proname AS object_name,
         'EDBSPL_ROUTINE' AS risk_code,
         'Rewrite to PL/pgSQL before migration' AS recommendation
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
    AND l.lanname = 'edbspl'
),
pgss_objects AS (
  SELECT n.nspname || E'.' || c.relname AS object_name,
         'PG_STAT_STATEMENTS_OBJECT' AS risk_code,
         'Skip migrating extension-managed objects (view/function)' AS recommendation
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
    AND c.relname IN ('pg_stat_statements','pg_stat_statements_info')
  UNION ALL
  SELECT n.nspname || E'.' || p.proname AS object_name,
         'PG_STAT_STATEMENTS_OBJECT' AS risk_code,
         'Skip migrating extension-managed objects (view/function)' AS recommendation
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
    AND p.proname IN ('pg_stat_statements','pg_stat_statements_info','pg_stat_statements_reset')
),
policy_context AS (
  SELECT n.nspname || E'.' || p.proname AS object_name,
         'POLICY_OR_CONTEXT' AS risk_code,
         'Map DBMS_RLS/SYS_CONTEXT semantics to PostgreSQL RLS + CURRENT_USER logic' AS recommendation
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
    AND (
      pg_get_functiondef(p.oid) ILIKE '%dbms_rls%'
      OR pg_get_functiondef(p.oid) ILIKE '%sys_context(%'
    )
)
SELECT object_name || E'\t' || risk_code || E'\t' || recommendation
FROM (
  SELECT * FROM sysdate_defaults
  UNION ALL
  SELECT * FROM edbspl_routines
  UNION ALL
  SELECT * FROM pgss_objects
  UNION ALL
  SELECT * FROM policy_context
) t
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
  ORDER BY 1;"
fi

write_reports

echo "[DONE] Pre-diagnostic data collected. See: $OUTPUT_DIR"
