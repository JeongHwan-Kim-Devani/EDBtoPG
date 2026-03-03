#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

# EPAS to PostgreSQL migration inspection report generator
# Output:
#  - TSV raw extracts per section
#  - HTML report (includes migration opinion in HTML)

PSQL_BIN="${PSQL_BIN:-psql}"
DBNAME="${PGDATABASE:-}"
DBHOST="${PGHOST:-}"
DBPORT="${PGPORT:-}"
DBUSER="${PGUSER:-}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: ./generate_epas_migration_report.sh [OUT_DIR]

Generate EPAS migration inspection artifacts and HTML opinion report.

Arguments:
  OUT_DIR   Optional output directory path.
            Default: migration_report_YYYYmmdd_HHMMSS

Environment:
  PSQL_BIN  psql executable path (default: psql)
  PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD, ...

Example:
  PGHOST=127.0.0.1 PGPORT=5444 PGDATABASE=edb PGUSER=enterprisedb \
    ./generate_epas_migration_report.sh ./report_$(date +%F)
USAGE
  exit 0
fi

if ! command -v "$PSQL_BIN" >/dev/null 2>&1; then
  echo "[ERROR] psql command not found. Set PSQL_BIN or install psql." >&2
  exit 1
fi

OUT_DIR="${1:-migration_report_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT_DIR"

run_tsv() {
  local outfile="$1"
  shift
  "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -F $'\t' -P footer=off -c "$*" >"$outfile"
}

run_scalar() {
  "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -t -c "$1" | xargs
}

table_exists() {
  local regclass="$1"
  local exists
  exists=$(run_scalar "SELECT to_regclass('$regclass') IS NOT NULL;")
  [[ "$exists" == "t" ]]
}

# -----------------------------
# 1) 파라미터
# -----------------------------
run_tsv "$OUT_DIR/01_parameters.tsv" "
SELECT
    parameter_name,
    default_value,
    current_value,
    CASE
        WHEN parameter_name IN (
            'edb_dynatune', 'edb_dynatune_profile', 'edb_redwood_date',
            'edb_redwood_greatest_least', 'edb_redwood_strings',
            'enable_hints', 'db_dialect'
        ) THEN 'O'
        WHEN default_value <> current_value THEN 'O'
        ELSE ''
    END AS check_required,
    description
FROM (
    SELECT
        name AS parameter_name,
        CASE name
            WHEN 'timed_statistics' THEN 'off'
            WHEN 'datestyle' THEN 'redwood,show_time'
            WHEN 'edb_redwood_date' THEN 'on'
            WHEN 'edb_redwood_greatest_least' THEN 'on'
            WHEN 'edb_redwood_strings' THEN 'on'
            WHEN 'db_dialect' THEN 'redwood'
            WHEN 'edb_dynatune' THEN '66'
            WHEN 'edb_dynatune_profile' THEN 'oltp'
            WHEN 'data_encryption_key_unwrap_command' THEN ''
            WHEN 'edb_max_resource_groups' THEN '16'
            WHEN 'edb_resource_group' THEN ''
            WHEN 'enable_hints' THEN 'on'
            WHEN 'max_generic_plan_partition_size' THEN '-1'
            ELSE boot_val
        END AS default_value,
        setting AS current_value,
        CASE name
            WHEN 'edb_audit' THEN '[CRITICAL] EDB 전용 감사 기능 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_audit_archiver' THEN '[CRITICAL] EDB 전용 기능 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_early_lock_release' THEN '[CRITICAL] EDB 전용 락 제어 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_max_capture_privileges_policies' THEN '[CRITICAL] EDB 전용 보안 정책 (PostgreSQL에서 사용 불가)'
            WHEN 'qreplace_function' THEN '[CRITICAL] 쿼리를 자동으로 수정하게 조정 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_stmt_level_tx' THEN '[CRITICAL] 트랜잭션 내 오류 발생 시 해당 문장만 롤백 여부 (PostgreSQL에서 사용 불가)'
            WHEN 'data_encryption_key_unwrap_command' THEN '[CRITICAL] EDB 전용 TDE 암호화 제어 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_max_resource_groups' THEN '[CRITICAL] EDB 전용 리소스 제어 한도 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_resource_group' THEN '[CRITICAL] EDB 전용 세션별 리소스 할당 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_redwood_strings' THEN '[WARNING] 빈 문자열과 NULL 처리 방식 변경 (앱 로직 수정 필요)'
            WHEN 'db_dialect' THEN '[WARNING] 오라클 호환 문법 비활성화 (표준 SQL 재작성 필요)'
            WHEN 'datestyle' THEN '[WARNING] 날짜 문자열 파싱 이슈 가능 (ISO 통일 필요)'
            WHEN 'edb_redwood_greatest_least' THEN '[WARNING] GREATEST/LEAST의 NULL 처리 차이 주의'
            WHEN 'edb_redwood_date' THEN '[WARNING] DATE 시간 정보 유실 위험 (TIMESTAMP 권장)'
            WHEN 'edb_dynatune' THEN '[WARNING] 자동 메모리 튜닝 상실 (수동 튜닝 필요)'
            WHEN 'edb_dynatune_profile' THEN '[WARNING] 동적 프로파일링 상실 (work_mem 등 수동 설정 필요)'
            WHEN 'optimizer_mode' THEN '[WARNING] 오라클 방식 실행 계획 무시됨 (재튜닝 필요)'
            WHEN 'default_with_rowids' THEN '[WARNING] ROWID 의존 쿼리 비호환 가능'
            WHEN 'enable_hints' THEN '[WARNING] EDB 힌트 기능 상실 (pg_hint_plan 검토 필요)'
            WHEN 'oracle_home' THEN '[INFO] 오라클 DB 링크 경로 정보'
            WHEN 'extension_control_path' THEN '[INFO] EDB 확장 제어 경로'
            WHEN 'edb_redwood_raw_names' THEN '[INFO] 대문자 객체명 처리 관련'
            WHEN 'timed_statistics' THEN '[INFO] track_io_timing 등으로 대체 가능'
            WHEN 'max_generic_plan_partition_size' THEN '[INFO] EDB 전용 제네릭 플랜 제어'
            ELSE '[UNKNOWN] 기타 파라미터'
        END AS description
    FROM pg_settings
    WHERE name IN (
        'edb_audit', 'edb_audit_archiver', 'oracle_home', 'extension_control_path',
        'default_with_rowids', 'edb_redwood_raw_names', 'edb_stmt_level_tx',
        'optimizer_mode', 'edb_early_lock_release', 'edb_max_capture_privileges_policies',
        'qreplace_function', 'timed_statistics', 'datestyle', 'edb_redwood_date',
        'edb_redwood_greatest_least', 'edb_redwood_strings', 'db_dialect',
        'edb_dynatune', 'edb_dynatune_profile',
        'data_encryption_key_unwrap_command', 'edb_max_resource_groups',
        'edb_resource_group', 'enable_hints', 'max_generic_plan_partition_size'
    )
) s
WHERE
    CASE
        WHEN parameter_name IN ('edb_dynatune','edb_dynatune_profile','edb_redwood_date','edb_redwood_greatest_least','edb_redwood_strings','enable_hints','db_dialect') THEN true
        WHEN default_value <> current_value THEN true
        ELSE false
    END
ORDER BY
    CASE
        WHEN description LIKE '[CRITICAL]%' THEN 1
        WHEN description LIKE '[WARNING]%' THEN 2
        ELSE 3
    END,
    parameter_name;
"

# -----------------------------
# 2) EDB 특화 기능 summary
# -----------------------------
run_tsv "$OUT_DIR/02_summary_packages.tsv" "
SELECT
    object_type,
    schema_name,
    object_name,
    feature
FROM (
    SELECT
        'FUNCTION/PROCEDURE' AS object_type,
        n.nspname AS schema_name,
        p.proname AS object_name,
        m[1] AS feature
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid,
    LATERAL regexp_matches(lower(p.prosrc), '(\\m(?:dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\\.[a-z0-9_]+|htf\\.[a-z0-9_]+)\\M)', 'g') AS m
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND n.nspname NOT LIKE 'dbms_%'
      AND n.nspname NOT LIKE 'utl_%'

    UNION ALL

    SELECT
        'VIEW' AS object_type,
        v.schemaname AS schema_name,
        v.viewname AS object_name,
        m[1] AS feature
    FROM pg_views v,
    LATERAL regexp_matches(lower(v.definition), '(\\m(?:dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\\.[a-z0-9_]+|htf\\.[a-z0-9_]+)\\M)', 'g') AS m
    WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND v.schemaname NOT LIKE 'dbms_%'
      AND v.schemaname NOT LIKE 'utl_%'
) x
ORDER BY object_type, schema_name, object_name;
"

run_tsv "$OUT_DIR/02_summary_synonyms.tsv" "
SELECT ns.nspname AS synonym_schema, s.synname, s.synobjschema, s.synobjname, COALESCE(s.synlink,'') AS synlink
FROM pg_catalog.pg_synonym s
JOIN pg_namespace ns ON ns.oid = s.synnamespace
ORDER BY ns.nspname, s.synname;
" || true

run_tsv "$OUT_DIR/02_summary_policies.tsv" "
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
ORDER BY schemaname, tablename, policyname;
"

# -----------------------------
# 3) 디테일 (user created)
# -----------------------------
run_tsv "$OUT_DIR/03_detail_keywords.tsv" "
SELECT
    object_type,
    schema_name,
    object_name,
    detected_keyword
FROM (
    SELECT
        'FUNCTION/PROCEDURE' AS object_type,
        n.nspname AS schema_name,
        p.proname AS object_name,
        m[1] AS detected_keyword
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid,
    LATERAL regexp_matches(lower(p.prosrc), '(\\m(?:blob|clob|varchar2|nvarchar2|bfile|raw|greatest|least|sysdate|systimestamp|rownum|rowid|level|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|listagg|wm_concat|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|pragma|sqlcode|sqlerrm|raise_application_error|numtodsinterval|numtoyminterval|sys_extract_utc|tz_offset|dbtimezone|sessiontimezone|lnnvl|nanvl|ratio_to_report|substrb|instrb|lengthb)\\M|\\m(?:user_[a-z0-9_]+|all_[a-z0-9_]+|dba_[a-z0-9_]+|v\\\$[a-z0-9_]+)\\M)', 'g') AS m
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')

    UNION ALL

    SELECT
        'VIEW' AS object_type,
        v.schemaname AS schema_name,
        v.viewname AS object_name,
        m[1] AS detected_keyword
    FROM pg_views v,
    LATERAL regexp_matches(lower(v.definition), '(\\m(?:blob|clob|varchar2|nvarchar2|bfile|raw|greatest|least|sysdate|systimestamp|rownum|rowid|level|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|listagg|wm_concat|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|pragma|sqlcode|sqlerrm|raise_application_error|numtodsinterval|numtoyminterval|sys_extract_utc|tz_offset|dbtimezone|sessiontimezone|lnnvl|nanvl|ratio_to_report|substrb|instrb|lengthb)\\M|\\m(?:user_[a-z0-9_]+|all_[a-z0-9_]+|dba_[a-z0-9_]+|v\\\$[a-z0-9_]+)\\M)', 'g') AS m
    WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
) z
ORDER BY object_type, schema_name, object_name;
"

run_tsv "$OUT_DIR/03_detail_datatypes_objects.tsv" "
SELECT
    object_type,
    schema_name,
    object_name,
    detected_datatype
FROM (
    SELECT
        'FUNCTION/PROCEDURE' AS object_type,
        n.nspname AS schema_name,
        p.proname AS object_name,
        m[1] AS detected_datatype
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid,
    LATERAL regexp_matches(lower(p.prosrc), '(\\m(?:blob|clob|varchar2|nvarchar2|bfile|raw)\\M)', 'g') AS m
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')

    UNION ALL

    SELECT
        'VIEW' AS object_type,
        v.schemaname AS schema_name,
        v.viewname AS object_name,
        m[1] AS detected_datatype
    FROM pg_views v,
    LATERAL regexp_matches(lower(v.definition), '(\\m(?:blob|clob|varchar2|nvarchar2|bfile|raw)\\M)', 'g') AS m
    WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
) z
ORDER BY object_type, schema_name, object_name;
"

run_tsv "$OUT_DIR/03_detail_datatypes_tables.tsv" "
SELECT
    table_schema AS schema_name,
    table_name,
    column_name,
    COALESCE(domain_name, udt_name) AS current_datatype
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
  AND (
      udt_name IN ('blob', 'clob', 'varchar2', 'nvarchar2', 'bfile', 'raw')
      OR domain_name IN ('blob', 'clob', 'varchar2', 'nvarchar2', 'bfile', 'raw')
  )
ORDER BY schema_name, table_name, column_name;
"

run_tsv "$OUT_DIR/03_detail_expr_keywords.tsv" "
SELECT
    object_type,
    schema_name,
    table_name,
    target_name,
    expression,
    detected_keyword
FROM (
    SELECT
        'DEFAULT VALUE' AS object_type,
        n.nspname AS schema_name,
        c.relname AS table_name,
        a.attname AS target_name,
        pg_get_expr(d.adbin, d.adrelid) AS expression,
        substring(lower(pg_get_expr(d.adbin, d.adrelid)) from '\\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|user_[a-z0-9_]+)\\M') AS detected_keyword
    FROM pg_attrdef d
    JOIN pg_attribute a ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    JOIN pg_class c ON d.adrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND pg_get_expr(d.adbin, d.adrelid) ~* '\\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|user_[a-z0-9_]+)\\M'

    UNION ALL

    SELECT
        'CHECK CONSTRAINT' AS object_type,
        n.nspname AS schema_name,
        c.relname AS table_name,
        con.conname AS target_name,
        pg_get_expr(con.conbin, con.conrelid) AS expression,
        substring(lower(pg_get_expr(con.conbin, con.conrelid)) from '\\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|user_[a-z0-9_]+)\\M') AS detected_keyword
    FROM pg_constraint con
    JOIN pg_class c ON con.conrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE con.contype = 'c'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND pg_get_expr(con.conbin, con.conrelid) ~* '\\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|user_[a-z0-9_]+)\\M'

    UNION ALL

    SELECT
        'INDEX EXPRESSION' AS object_type,
        n.nspname AS schema_name,
        c.relname AS table_name,
        i.relname AS target_name,
        pg_get_expr(idx.indexprs, idx.indrelid) AS expression,
        substring(lower(pg_get_expr(idx.indexprs, idx.indrelid)) from '\\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|user_[a-z0-9_]+)\\M') AS detected_keyword
    FROM pg_index idx
    JOIN pg_class c ON idx.indrelid = c.oid
    JOIN pg_class i ON idx.indexrelid = i.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE idx.indexprs IS NOT NULL
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND pg_get_expr(idx.indexprs, idx.indrelid) ~* '\\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|user_[a-z0-9_]+)\\M'
) z
ORDER BY object_type, schema_name, table_name;
"

# -----------------------------
# 4) 폴리시 디테일 (user created)
# -----------------------------
if table_exists "pg_catalog.edb_profile"; then
  run_tsv "$OUT_DIR/04_policy_edb_profile.tsv" "
  SELECT *
  FROM pg_catalog.edb_profile
  WHERE prfname <> 'default'
  ORDER BY prfname;
  "
else
  : >"$OUT_DIR/04_policy_edb_profile.tsv"
fi

if table_exists "pg_catalog.edb_resource_group"; then
  run_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv" "
  SELECT * FROM pg_catalog.edb_resource_group ORDER BY rgrpname;
  "
else
  : >"$OUT_DIR/04_policy_edb_resource_group.tsv"
fi

if table_exists "pg_catalog.edb_dblink"; then
  run_tsv "$OUT_DIR/04_policy_edb_dblink.tsv" "
  SELECT lnkname, lnkowner, lnktype, lnkispublic, lnkuser, lnkconnstr, oid
  FROM pg_catalog.edb_dblink
  ORDER BY lnkname;
  "
else
  : >"$OUT_DIR/04_policy_edb_dblink.tsv"
fi

# -----------------------------
# 5) 소견 HTML 생성
# -----------------------------
line_count() {
  local f="$1"
  local n
  if [[ ! -s "$f" ]]; then
    echo 0
    return
  fi

  n=$(wc -l <"$f")
  # psql output includes header row by default when at least one line exists.
  # For report counts we return data-row count (excluding header).
  if (( n > 0 )); then
    echo $((n-1))
  else
    echo 0
  fi
}

param_cnt=$(line_count "$OUT_DIR/01_parameters.tsv")
pkg_cnt=$(line_count "$OUT_DIR/02_summary_packages.tsv")
syn_cnt=$(line_count "$OUT_DIR/02_summary_synonyms.tsv")
rls_cnt=$(line_count "$OUT_DIR/02_summary_policies.tsv")
kw_cnt=$(line_count "$OUT_DIR/03_detail_keywords.tsv")
dtype_obj_cnt=$(line_count "$OUT_DIR/03_detail_datatypes_objects.tsv")
dtype_tbl_cnt=$(line_count "$OUT_DIR/03_detail_datatypes_tables.tsv")
expr_cnt=$(line_count "$OUT_DIR/03_detail_expr_keywords.tsv")
profile_cnt=$(line_count "$OUT_DIR/04_policy_edb_profile.tsv")
rg_cnt=$(line_count "$OUT_DIR/04_policy_edb_resource_group.tsv")
dblink_cnt=$(line_count "$OUT_DIR/04_policy_edb_dblink.tsv")

default_li_if_empty() {
  local s="$1"
  if [[ -z "${s//[[:space:]]/}" ]]; then
    echo "<li>검출 없음</li>"
  else
    printf "%s" "$s"
  fi
}

param_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li><code>%s</code>: 기본값 <code>%s</code>, 현재값 <code>%s</code> (%s)</li>\n",$1,$2,$3,$5}''' "$OUT_DIR/01_parameters.tsv")
param_detail_html=$(default_li_if_empty "$param_detail_html")

pkg_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li><code>%s.%s</code> (%s) 에서 <code>%s</code> 검출</li>\n",$2,$3,$1,$4}''' "$OUT_DIR/02_summary_packages.tsv")
pkg_detail_html=$(default_li_if_empty "$pkg_detail_html")

syn_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li><code>%s.%s</code> → <code>%s.%s</code></li>\n",$1,$2,$3,$4}''' "$OUT_DIR/02_summary_synonyms.tsv")
syn_detail_html=$(default_li_if_empty "$syn_detail_html")

rls_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li><code>%s.%s</code> - policy <code>%s</code> (cmd: %s)</li>\n",$1,$2,$3,$6}''' "$OUT_DIR/02_summary_policies.tsv")
rls_detail_html=$(default_li_if_empty "$rls_detail_html")

kw_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li><code>%s.%s</code> (%s): <code>%s</code></li>\n",$2,$3,$1,$4}''' "$OUT_DIR/03_detail_keywords.tsv")
kw_detail_html=$(default_li_if_empty "$kw_detail_html")

dtype_obj_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li><code>%s.%s</code> (%s): <code>%s</code></li>\n",$2,$3,$1,$4}''' "$OUT_DIR/03_detail_datatypes_objects.tsv")
dtype_obj_detail_html=$(default_li_if_empty "$dtype_obj_detail_html")

dtype_tbl_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li><code>%s.%s.%s</code>: <code>%s</code></li>\n",$1,$2,$3,$4}''' "$OUT_DIR/03_detail_datatypes_tables.tsv")
dtype_tbl_detail_html=$(default_li_if_empty "$dtype_tbl_detail_html")

expr_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li><code>%s.%s</code> (%s): <code>%s</code> 검출</li>\n",$2,$3,$1,$6}''' "$OUT_DIR/03_detail_expr_keywords.tsv")
expr_detail_html=$(default_li_if_empty "$expr_detail_html")

profile_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li>Profile: <code>%s</code></li>\n",$2}''' "$OUT_DIR/04_policy_edb_profile.tsv")
profile_detail_html=$(default_li_if_empty "$profile_detail_html")

rg_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li>Resource Group: <code>%s</code> (CPU limit: %s)</li>\n",$4,$2}''' "$OUT_DIR/04_policy_edb_resource_group.tsv")
rg_detail_html=$(default_li_if_empty "$rg_detail_html")

dblink_detail_html=$(awk -F $'	' '''NR==1{next} {for(i=1;i<=NF;i++){gsub("&","\\&amp;",$i);gsub("<","\\&lt;",$i);gsub(">","\\&gt;",$i)} printf "<li>DBLINK <code>%s</code> (user: %s, conn: <code>%s</code>)</li>\n",$1,$5,$6}''' "$OUT_DIR/04_policy_edb_dblink.tsv")
dblink_detail_html=$(default_li_if_empty "$dblink_detail_html")

cat >"$OUT_DIR/05_opinion.html" <<HTML
<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <title>EPAS 이관 점검 리포트</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 24px; }
    h1, h2, h3 { color: #1f2937; }
    table { border-collapse: collapse; width: 100%; margin: 12px 0; }
    th, td { border: 1px solid #d1d5db; padding: 8px; text-align: left; vertical-align: top; }
    th { background: #f3f4f6; }
    .ok { color: #065f46; font-weight: 600; }
    .warn { color: #92400e; font-weight: 600; }
    .crit { color: #991b1b; font-weight: 700; }
    .group-title { background: #eef2ff; font-weight: 700; }
    code { background: #f3f4f6; padding: 2px 4px; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>이관 리포트 (EPAS → PostgreSQL)</h1>
  <h2>요약</h2>
  <table>
    <tr><th>항목</th><th>검출 건수</th><th>가벼운 설명</th></tr>
    <tr class="group-title"><td colspan="3">1. 파라미터</td></tr>
    <tr><td>1. 파라미터(점검 대상)</td><td>${param_cnt}</td><td>핵심 호환 파라미터 + 기본값 대비 변경값 점검</td></tr>

    <tr class="group-title"><td colspan="3">2. EDB(Oracle) 특화기능 Summary</td></tr>
    <tr><td>2. EDB 특화 기능(패키지/프로시저/함수/뷰)</td><td>${pkg_cnt}</td><td>DBMS/UTL/OWA/HTP/HTF 계열 사용 흔적</td></tr>
    <tr><td>2. 시노님</td><td>${syn_cnt}</td><td>synonym → 실제 객체 매핑 현황</td></tr>
    <tr><td>2. 정책(RLS)</td><td>${rls_cnt}</td><td>RLS 정책 존재 여부와 대상 테이블</td></tr>

    <tr class="group-title"><td colspan="3">3. 디테일 (user created)</td></tr>
    <tr><td>3. 오라클 키워드/함수</td><td>${kw_cnt}</td><td>객체 정의에서 Oracle 키워드/함수 의존 흔적</td></tr>
    <tr><td>3. 오라클 데이터타입(함수/프로시저/뷰)</td><td>${dtype_obj_cnt}</td><td>코드/뷰 내부 Oracle 데이터타입 사용</td></tr>
    <tr><td>3. 오라클 데이터타입(테이블)</td><td>${dtype_tbl_cnt}</td><td>테이블 컬럼 datatype 의존</td></tr>
    <tr><td>3. 기본값/제약조건/인덱스 표현식</td><td>${expr_cnt}</td><td>표현식 내 Oracle 함수 사용</td></tr>

    <tr class="group-title"><td colspan="3">4. 폴리시 디테일 (user created)</td></tr>
    <tr><td>4. 프로파일(Non-default)</td><td>${profile_cnt}</td><td>default 이외 profile 존재 여부</td></tr>
    <tr><td>4. 리소스 그룹</td><td>${rg_cnt}</td><td>리소스 그룹 설정 현황</td></tr>
    <tr><td>4. DBLINK</td><td>${dblink_cnt}</td><td>DBLINK 정의 현황</td></tr>
  </table>

  <h2>검출 건수 상세 (무엇이 검출되었는지)</h2>

  <h3>1. 파라미터 (${param_cnt}건)</h3>
  <ul>
    ${param_detail_html}
  </ul>

  <h3>2. EDB 특화기능 Summary</h3>
  <p><strong>패키지/프로시저/함수/뷰 (${pkg_cnt}건)</strong></p>
  <ul>${pkg_detail_html}</ul>
  <p><strong>시노님 (${syn_cnt}건)</strong></p>
  <ul>${syn_detail_html}</ul>
  <p><strong>정책(RLS) (${rls_cnt}건)</strong></p>
  <ul>${rls_detail_html}</ul>

  <h3>3. 디테일 (user created)</h3>
  <p><strong>오라클 키워드/함수 (${kw_cnt}건)</strong></p>
  <ul>${kw_detail_html}</ul>
  <p><strong>오라클 데이터타입(함수/프로시저/뷰) (${dtype_obj_cnt}건)</strong></p>
  <ul>${dtype_obj_detail_html}</ul>
  <p><strong>오라클 데이터타입(테이블) (${dtype_tbl_cnt}건)</strong></p>
  <ul>${dtype_tbl_detail_html}</ul>
  <p><strong>기본값/제약조건/인덱스 표현식 (${expr_cnt}건)</strong></p>
  <ul>${expr_detail_html}</ul>

  <h3>4. 폴리시 디테일 (user created)</h3>
  <p><strong>프로파일(Non-default) (${profile_cnt}건)</strong></p>
  <ul>${profile_detail_html}</ul>
  <p><strong>리소스 그룹 (${rg_cnt}건)</strong></p>
  <ul>${rg_detail_html}</ul>
  <p><strong>DBLINK (${dblink_cnt}건)</strong></p>
  <ul>${dblink_detail_html}</ul>

  <h2>5. 소견</h2>
  <ul>
    <li><span class="crit">대체 불가(수동 수정 필요)</span>: CRITICAL 파라미터/EDB 고유 보안·리소스 제어 기능은 PostgreSQL 기본 기능으로 1:1 대체가 어렵습니다. 애플리케이션 및 운영 절차 변경이 필요합니다.</li>
    <li><span class="warn">조건부 대체 가능</span>: WARNING 항목(문자열 NULL 처리, 날짜/문법 호환, 힌트, 옵티마이저 관련)은 SQL 재작성과 성능 재튜닝을 통해 대체할 수 있습니다.</li>
    <li><span class="ok">대체 가능</span>: INFO 항목 다수는 PostgreSQL 확장(예: <code>orafce</code>, <code>oracle_fdw</code>, <code>pg_hint_plan</code>) 또는 표준 기능 전환으로 대체 가능합니다.</li>
    <li>검출 건수가 0인 항목은 현재 사용 흔적이 없거나, 카탈로그 권한/버전에 따라 조회되지 않을 수 있습니다. 운영 계정 권한으로 재검증을 권장합니다.</li>
  </ul>

  <h2>산출물 파일</h2>
  <p>같은 디렉터리의 <code>01_*.tsv</code> ~ <code>04_*.tsv</code> 파일을 근거 데이터로 사용하세요.</p>
</body>
</html>
HTML

cat >"$OUT_DIR/REPORT_INDEX.txt" <<TXT
[EPAS Migration Inspection Report]
Output directory : $OUT_DIR
Connection hints : host=${DBHOST:-N/A}, port=${DBPORT:-N/A}, db=${DBNAME:-N/A}, user=${DBUSER:-N/A}

1) Parameters                 : 01_parameters.tsv
2) EDB Summary                : 02_summary_packages.tsv, 02_summary_synonyms.tsv, 02_summary_policies.tsv
3) User-created Detail        : 03_detail_keywords.tsv, 03_detail_datatypes_objects.tsv, 03_detail_datatypes_tables.tsv, 03_detail_expr_keywords.tsv
4) Policy Detail              : 04_policy_edb_profile.tsv, 04_policy_edb_resource_group.tsv, 04_policy_edb_dblink.tsv
5) Opinion (HTML)             : 05_opinion.html

Note: Summary counts in HTML exclude TSV header rows.
TXT

echo "[DONE] Report generated at: $OUT_DIR"
echo "       Open HTML: $OUT_DIR/05_opinion.html"
