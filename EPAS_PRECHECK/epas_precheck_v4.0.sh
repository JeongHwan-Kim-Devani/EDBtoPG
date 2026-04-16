#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
if shopt -oq posix 2>/dev/null; then
  exec bash "$0" "$@"
fi
set -euo pipefail

usage(){ cat <<'USAGE'
EPAS -> PostgreSQL pre-diagnostic helper
Usage: ./epas_precheck_v4.0.sh [options]
Options:
  -h, --host HOST
  -p, --port PORT
  -d, --dbname DBNAME   (required)
  -U, --user USER       (required)
  -W, --password PASS
  -o, --output DIR      Output directory (required)
  -c, --compress TYPE   tar | gz
  --connect-timeout SEC
  --help
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

PSQL_BIN="${PSQL_BIN:-psql}"
HOST="${PGHOST:-localhost}"; PORT="${PGPORT:-5444}"
DBNAME="${PGDATABASE:-}"; DBUSER="${PGUSER:-}"; DBPASSWORD="${PGPASSWORD:-}"
OUT_DIR=""; CONNECT_TIMEOUT=5; CLEANUP_TEMP=0; COMPRESS=""; EMBEDDED_SQL_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    -h|--host) HOST="$2"; shift 2 ;;
    -p|--port) PORT="$2"; shift 2 ;;
    -d|--dbname) DBNAME="$2"; shift 2 ;;
    -U|--user) DBUSER="$2"; shift 2 ;;
    -W|--password) DBPASSWORD="$2"; shift 2 ;;
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    -c|--compress) COMPRESS="$2"; shift 2 ;;
    --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    -s|--schema|--oracle-checks) shift; [[ "$1" != -* ]] && shift || true ;;
    --) shift; break ;;
    -*) echo "[ERROR] Unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

[[ -n "$DBNAME" && -n "$DBUSER" ]] || { echo "[ERROR] --dbname and --user are required." >&2; exit 1; }
if [[ -z "$OUT_DIR" ]]; then
  echo "[ERROR] --output (-o) is required." >&2
  usage
  exit 1
fi

if [[ -n "$COMPRESS" && "$COMPRESS" != "tar" && "$COMPRESS" != "gz" ]]; then
  echo "[ERROR] --compress must be one of: tar, gz" >&2
  exit 1
fi
command -v "$PSQL_BIN" >/dev/null 2>&1 || { echo "[ERROR] psql not found" >&2; exit 1; }

export PGHOST="$HOST" PGPORT="$PORT" PGDATABASE="$DBNAME" PGUSER="$DBUSER" PGCONNECT_TIMEOUT="$CONNECT_TIMEOUT"
[[ -n "$DBPASSWORD" ]] && export PGPASSWORD="$DBPASSWORD"

mkdir -p "$OUT_DIR"
DBNAME_SAFE="$(printf '%s' "$DBNAME" | tr -cs '[:alnum:]_.-' '_')"
HTML_BASENAME="${DBNAME_SAFE}.html"; HTML_PATH="$OUT_DIR/$HTML_BASENAME"
SOURCE_HTML_BASENAME="${DBNAME_SAFE}_source.html"; SOURCE_HTML_PATH="$OUT_DIR/$SOURCE_HTML_BASENAME"
SOURCE_DIR_BASENAME="${DBNAME_SAFE}_sources"; SOURCE_DIR_PATH="$OUT_DIR/$SOURCE_DIR_BASENAME"
export SOURCE_HTML_BASENAME SOURCE_DIR_BASENAME HTML_BASENAME

write_embedded_sql(){
  EMBEDDED_SQL_FILE="$OUT_DIR/.embedded_epas_precheck_$$.sql"
  cat > "$EMBEDDED_SQL_FILE" <<'__EMBEDDED_SQL__'
-- == SECTION 1-1: Parameters ==
--@@ sec_1_1_parameters
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
            WHEN 'edb_audit' THEN 'EDB audit option (not supported in PostgreSQL)'
            WHEN 'edb_audit_archiver' THEN 'EDB audit archiver option (not supported in PostgreSQL)'
            WHEN 'edb_early_lock_release' THEN 'EDB lock behavior option (not supported in PostgreSQL)'
            WHEN 'edb_max_capture_privileges_policies' THEN 'EDB privilege capture policy option (not supported in PostgreSQL)'
            WHEN 'qreplace_function' THEN 'Query replacement function option (not supported in PostgreSQL)'
            WHEN 'edb_stmt_level_tx' THEN 'Statement-level transaction behavior option (not supported in PostgreSQL)'
            WHEN 'data_encryption_key_unwrap_command' THEN 'EDB TDE unwrap command option (not supported in PostgreSQL)'
            WHEN 'edb_max_resource_groups' THEN 'EDB max resource groups option (not supported in PostgreSQL)'
            WHEN 'edb_resource_group' THEN 'EDB session resource group option (not supported in PostgreSQL)'
            WHEN 'edb_redwood_strings' THEN 'String and NULL behavior difference may require review'
            WHEN 'db_dialect' THEN 'Oracle-compatible dialect mode may affect SQL behavior'
            WHEN 'datestyle' THEN 'Date parsing behavior may differ; ISO normalization recommended'
            WHEN 'edb_redwood_greatest_least' THEN 'GREATEST/LEAST NULL behavior can differ'
            WHEN 'edb_redwood_date' THEN 'DATE/TIMESTAMP behavior difference may exist'
            WHEN 'edb_dynatune' THEN 'Automatic memory tuning profile differs from PostgreSQL defaults'
            WHEN 'edb_dynatune_profile' THEN 'Dynamic tuning profile may require manual adjustment'
            WHEN 'optimizer_mode' THEN 'Optimizer mode setting may require migration review'
            WHEN 'default_with_rowids' THEN 'ROWID-dependent SQL may require rewrite'
            WHEN 'enable_hints' THEN 'Hint feature dependency may require pg_hint_plan review'
            WHEN 'oracle_home' THEN 'Oracle DB link related path information'
            WHEN 'extension_control_path' THEN 'EDB extension control path setting'
            WHEN 'edb_redwood_raw_names' THEN 'Quoted/case-sensitive object naming behavior'
            WHEN 'timed_statistics' THEN 'May map to track_io_timing behavior'
            WHEN 'max_generic_plan_partition_size' THEN 'EDB generic plan partition option'
            ELSE '[UNKNOWN] Other parameter'
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
        WHEN parameter_name IN ('edb_audit','edb_audit_archiver','edb_early_lock_release','edb_max_capture_privileges_policies','qreplace_function','edb_stmt_level_tx','data_encryption_key_unwrap_command','edb_max_resource_groups','edb_resource_group') THEN 1
        WHEN parameter_name IN ('edb_redwood_strings','db_dialect','datestyle','edb_redwood_greatest_least','edb_redwood_date','edb_dynatune','edb_dynatune_profile','optimizer_mode','default_with_rowids','enable_hints') THEN 2
        ELSE 3
    END,
    parameter_name;

-- == SECTION 2-1: Compatibility Objects (Package usage) ==
--@@ sec_2_1_packages_summary
SELECT
    object_type,
    schema_name,
    object_name,
    feature
FROM (
    SELECT
        CASE WHEN p.prokind='p' THEN 'P' ELSE 'F' END AS object_type,
        n.nspname AS schema_name,
        p.proname AS object_name,
        m[1] AS feature
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid,
    LATERAL regexp_matches(lower(p.prosrc), '(\m(?:dbms_crypto(?:\.[a-z0-9_]+)?|dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\.[a-z0-9_]+|htf\.[a-z0-9_]+)\M)', 'g') AS m
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
      AND n.nspname NOT LIKE 'dbms_%'
      AND n.nspname NOT LIKE 'utl_%'
      AND NOT (
        lower(p.proname) ~ '^(htf|htp|xmltype)'
        AND COALESCE(p.prosrc, '') !~* 'USER_CREATED'
        AND (
          n.nspname IN ('htf', 'htp', 'xmltype')
          OR p.prosrc LIKE '$__EDBwrapped__$$PROTOCOL2$%'
          OR lower(pg_catalog.pg_get_userbyid(p.proowner)) = 'enterprisedb'
          OR EXISTS (
            SELECT 1
            FROM pg_depend d2
            JOIN pg_extension e2 ON e2.oid = d2.refobjid
            WHERE d2.classid = 'pg_proc'::regclass
              AND d2.objid = p.oid
              AND d2.deptype = 'e'
          )
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_depend d
        JOIN pg_extension e ON e.oid = d.refobjid
        WHERE d.classid = 'pg_proc'::regclass
          AND d.objid = p.oid
          AND d.deptype = 'e'
      )
    UNION ALL
    SELECT
        'V' AS object_type,
        v.schemaname AS schema_name,
        v.viewname AS object_name,
        m[1] AS feature
    FROM pg_views v,
    LATERAL regexp_matches(lower(v.definition), '(\m(?:dbms_crypto(?:\.[a-z0-9_]+)?|dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\.[a-z0-9_]+|htf\.[a-z0-9_]+)\M)', 'g') AS m
    WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
      AND v.schemaname NOT LIKE 'dbms_%'
      AND v.schemaname NOT LIKE 'utl_%'
) x
ORDER BY schema_name, CASE object_type WHEN 'P' THEN 1 WHEN 'F' THEN 2 WHEN 'V' THEN 3 ELSE 9 END, object_name;

-- == SECTION 2-4: Synonyms ==
--@@ sec_2_4_synonyms
SELECT ns.nspname AS synonym_schema, s.synname, s.synobjschema, s.synobjname, COALESCE(s.synlink,'') AS synlink
FROM pg_catalog.pg_synonym s
JOIN pg_namespace ns ON ns.oid = s.synnamespace
ORDER BY ns.nspname, s.synname;

-- == SECTION 3-1: RLS (pg_policies) ==
--@@ sec_3_1_policies_pg
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
ORDER BY schemaname, tablename, policyname;


-- == SECTION 3-1: RLS (sys.all_policies) ==
--@@ sec_3_1_policies_dbms
SELECT object_owner, schema_name, object_name, policy_group, policy_name, pf_owner, package, function
FROM sys.all_policies
ORDER BY schema_name, object_name, policy_name;

-- == SECTION 3-2: Redaction ==
--@@ sec_3_2_redaction
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    p.rdname AS policy_name,
    a.attname AS column_name,
    pg_get_expr(rc.rdfuncexpr, rc.rdrelid) AS mask_function
FROM edb_redaction_policy p
JOIN edb_redaction_column rc ON p.oid = rc.rdpolicyid
JOIN pg_class c ON p.rdrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
JOIN pg_attribute a ON rc.rdrelid = a.attrelid AND rc.rdattnum = a.attnum
ORDER BY schema_name, table_name, policy_name;

-- == SECTION 2-1: Compatibility Objects (Keyword/lang detection) ==
--@@ sec_2_1_keywords
SELECT object_type, schema_name, object_name, detected_keyword
FROM (
    SELECT CASE WHEN p.prokind='p' THEN 'P' ELSE 'F' END AS object_type, n.nspname AS schema_name, p.proname AS object_name,
           m[1] AS detected_keyword
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid,
    LATERAL regexp_matches(lower(p.prosrc), '(\m(?:dbms_crypto(?:\.[a-z0-9_]+)?|clob|bfile|raw|greatest|least|sysdate|systimestamp|rownum|rowid|level|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|listagg|wm_concat|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|pragma|sqlcode|sqlerrm|raise_application_error|numtodsinterval|numtoyminterval|sys_extract_utc|tz_offset|dbtimezone|sessiontimezone|lnnvl|nanvl|ratio_to_report|substrb|instrb|lengthb)\M)', 'g') AS m
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
      AND NOT (
        lower(p.proname) ~ '^(htf|htp|xmltype)'
        AND COALESCE(p.prosrc, '') !~* 'USER_CREATED'
        AND (
          n.nspname IN ('htf', 'htp', 'xmltype')
          OR p.prosrc LIKE '$__EDBwrapped__$$PROTOCOL2$%'
          OR lower(pg_catalog.pg_get_userbyid(p.proowner)) = 'enterprisedb'
          OR EXISTS (
            SELECT 1
            FROM pg_depend d2
            JOIN pg_extension e2 ON e2.oid = d2.refobjid
            WHERE d2.classid = 'pg_proc'::regclass
              AND d2.objid = p.oid
              AND d2.deptype = 'e'
          )
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_depend d
        JOIN pg_extension e ON e.oid = d.refobjid
        WHERE d.classid = 'pg_proc'::regclass
          AND d.objid = p.oid
          AND d.deptype = 'e'
      )
    UNION ALL
    SELECT CASE WHEN p.prokind='p' THEN 'P' ELSE 'F' END AS object_type,
           n.nspname AS schema_name,
           p.proname AS object_name,
           lower(l.lanname) AS detected_keyword
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    JOIN pg_language l ON l.oid = p.prolang
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
      AND n.nspname NOT LIKE 'dbms_%'
      AND n.nspname NOT LIKE 'utl_%'
      AND p.proname !~* '^((dbms|utl|owa|htp|htf)(_|\.)|aq\$)'
      AND NOT (
        lower(p.proname) ~ '^(htf|htp|xmltype)'
        AND COALESCE(p.prosrc, '') !~* 'USER_CREATED'
        AND (
          n.nspname IN ('htf', 'htp', 'xmltype')
          OR p.prosrc LIKE '$__EDBwrapped__$$PROTOCOL2$%'
          OR lower(pg_catalog.pg_get_userbyid(p.proowner)) = 'enterprisedb'
          OR EXISTS (
            SELECT 1
            FROM pg_depend d2
            JOIN pg_extension e2 ON e2.oid = d2.refobjid
            WHERE d2.classid = 'pg_proc'::regclass
              AND d2.objid = p.oid
              AND d2.deptype = 'e'
          )
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_depend d
        JOIN pg_extension e ON e.oid = d.refobjid
        WHERE d.classid = 'pg_proc'::regclass
          AND d.objid = p.oid
          AND d.deptype = 'e'
      )
      AND lower(l.lanname) IN ('edbspl')
    UNION ALL
    SELECT 'V' AS object_type, v.schemaname AS schema_name, v.viewname AS object_name,
           m[1] AS detected_keyword
    FROM pg_views v,
    LATERAL regexp_matches(lower(v.definition), '(\m(?:dbms_crypto(?:\.[a-z0-9_]+)?|clob|bfile|raw|greatest|least|sysdate|systimestamp|rownum|rowid|level|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|listagg|wm_concat|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|pragma|sqlcode|sqlerrm|raise_application_error|numtodsinterval|numtoyminterval|sys_extract_utc|tz_offset|dbtimezone|sessiontimezone|lnnvl|nanvl|ratio_to_report|substrb|instrb|lengthb)\M)', 'g') AS m
    WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
) z
ORDER BY schema_name, CASE object_type WHEN 'P' THEN 1 WHEN 'F' THEN 2 WHEN 'V' THEN 3 ELSE 9 END, object_name;

-- == SECTION 2-2: Datatypes (objects) ==
--@@ sec_2_2_datatypes_objects
SELECT object_type, schema_name, object_name, detected_datatype
FROM (
    SELECT CASE WHEN p.prokind='p' THEN 'P' ELSE 'F' END AS object_type, n.nspname AS schema_name, p.proname AS object_name,
           m[1] AS detected_datatype
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid,
    LATERAL regexp_matches(lower(p.prosrc), '(\m(?:clob|bfile|raw)\M)', 'g') AS m
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
    UNION ALL
    SELECT 'V' AS object_type, v.schemaname AS schema_name, v.viewname AS object_name,
           m[1] AS detected_datatype
    FROM pg_views v,
    LATERAL regexp_matches(lower(v.definition), '(\m(?:clob|bfile|raw)\M)', 'g') AS m
    WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
) z
ORDER BY schema_name, CASE object_type WHEN 'P' THEN 1 WHEN 'F' THEN 2 WHEN 'V' THEN 3 ELSE 9 END, object_name;

-- == SECTION 2-2: Datatypes (tables/columns) ==
--@@ sec_2_2_datatypes_tables
SELECT
  table_schema AS schema_name,
  table_name,
  string_agg(column_name, ', ' ORDER BY column_name) AS merged_columns,
  string_agg(DISTINCT COALESCE(domain_name, udt_name), ', ' ORDER BY COALESCE(domain_name, udt_name)) AS current_datatype
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
  AND (udt_name IN ('clob', 'bfile', 'raw')
       OR domain_name IN ('clob', 'bfile', 'raw'))
GROUP BY table_schema, table_name
ORDER BY schema_name, table_name;

-- == SECTION 2-3: Expressions ==
--@@ sec_2_3_expr_keywords
SELECT object_type, schema_name, table_name, target_name, detected_keyword
FROM (
    SELECT 'DEFAULT VALUE' AS object_type, n.nspname AS schema_name, c.relname AS table_name, a.attname AS target_name,
           substring(lower(pg_get_expr(d.adbin, d.adrelid)) from '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M') AS detected_keyword
    FROM pg_attrdef d
    JOIN pg_attribute a ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    JOIN pg_class c ON d.adrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
      AND pg_get_expr(d.adbin, d.adrelid) ~* '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M'
    UNION ALL
    SELECT 'CHECK CONSTRAINT' AS object_type, n.nspname AS schema_name, c.relname AS table_name, con.conname AS target_name,
           substring(lower(pg_get_expr(con.conbin, con.conrelid)) from '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M') AS detected_keyword
    FROM pg_constraint con
    JOIN pg_class c ON con.conrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE con.contype = 'c'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
      AND pg_get_expr(con.conbin, con.conrelid) ~* '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M'
    UNION ALL
    SELECT 'INDEX EXPRESSION' AS object_type, n.nspname AS schema_name, c.relname AS table_name, i.relname AS target_name,
           substring(lower(pg_get_expr(idx.indexprs, idx.indrelid)) from '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M') AS detected_keyword
    FROM pg_index idx
    JOIN pg_class c ON idx.indrelid = c.oid
    JOIN pg_class i ON idx.indexrelid = i.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE idx.indexprs IS NOT NULL
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
      AND pg_get_expr(idx.indexprs, idx.indrelid) ~* '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M'
) z
ORDER BY schema_name, table_name, target_name, object_type;

-- == SECTION 3-3: Profiles (pg_catalog) ==
--@@ sec_3_3_profiles
WITH prof AS (
  SELECT p.*
  FROM pg_catalog.edb_profile p
  WHERE p.prfname <> 'default'
), prof_with_users AS (
  SELECT
    pf.*,
    COALESCE((
      SELECT string_agg(r.rolname, ', ' ORDER BY r.rolname)
      FROM pg_roles r
      WHERE lower(COALESCE(to_jsonb(r)->>'rolprofile','')) = lower(pf.prfname)
         OR lower(COALESCE(to_jsonb(r)->>'edb_profile','')) = lower(pf.prfname)
         OR EXISTS (
           SELECT 1
           FROM unnest(COALESCE(r.rolconfig, ARRAY[]::text[])) cfg
           WHERE regexp_replace(lower(cfg), '["''\s]', '', 'g') = 'edb_profile=' || lower(pf.prfname)
         )
    ), '') AS applied_users
  FROM prof pf
), profile_rows AS (
  SELECT
    p.prfname AS profile_name,
    p.applied_users,
    x.resource_name,
    x.resource_type,
    x.limit_value,
    'YES'::text AS common_value
  FROM prof_with_users p
  CROSS JOIN LATERAL (
    VALUES
      ('FAILED_LOGIN_ATTEMPTS', 'PASSWORD', COALESCE(p.prffailedloginattempts::text, 'DEFAULT')),
      ('PASSWORD_ALLOW_HASHED', 'PASSWORD', CASE WHEN p.prfpasswordallowhashed = -1 THEN 'DEFAULT' ELSE p.prfpasswordallowhashed::text END),
      ('PASSWORD_GRACE_TIME', 'PASSWORD', CASE WHEN p.prfpasswordgracetime = -1 THEN 'DEFAULT' WHEN p.prfpasswordgracetime = -2 THEN 'UNLIMITED' ELSE p.prfpasswordgracetime::text END),
      ('PASSWORD_LIFE_TIME', 'PASSWORD', CASE WHEN p.prfpasswordlifetime = -1 THEN 'DEFAULT' WHEN p.prfpasswordlifetime = -2 THEN 'UNLIMITED' ELSE p.prfpasswordlifetime::text END),
      ('PASSWORD_LOCK_TIME', 'PASSWORD', CASE WHEN p.prfpasswordlocktime = -1 THEN 'DEFAULT' WHEN p.prfpasswordlocktime = -2 THEN 'UNLIMITED' ELSE p.prfpasswordlocktime::text END),
      ('PASSWORD_REUSE_MAX', 'PASSWORD', CASE WHEN p.prfpasswordreusemax = -1 THEN 'DEFAULT' WHEN p.prfpasswordreusemax = -2 THEN 'UNLIMITED' ELSE p.prfpasswordreusemax::text END),
      ('PASSWORD_REUSE_TIME', 'PASSWORD', CASE WHEN p.prfpasswordreusetime = -1 THEN 'DEFAULT' WHEN p.prfpasswordreusetime = -2 THEN 'UNLIMITED' ELSE p.prfpasswordreusetime::text END),
      ('PASSWORD_VERIFY_FUNCTION', 'PASSWORD', COALESCE(NULLIF(p.prfpasswordverifyfunc::regprocedure::text, ''), p.prfpasswordverifyfunc::text, 'DEFAULT'))
  ) AS x(resource_name, resource_type, limit_value)
)
SELECT
  profile_name,
  regexp_replace(
    'PROFILE           | RESOURCE_NAME               | RESOURCE_TYPE | LIMIT                    | COMMON' || E'\n' ||
    '--------------------------------------------------------------------------------------------------------' || E'\n' ||
    string_agg(
      rpad(profile_name, 17, ' ') || ' | ' ||
      rpad(resource_name, 27, ' ') || ' | ' ||
      rpad(resource_type, 13, ' ') || ' | ' ||
      rpad(COALESCE(limit_value, 'DEFAULT'), 24, ' ') || ' | ' ||
      COALESCE(common_value, '-'),
      E'\n' ORDER BY resource_name
    ) || E'\n\n' ||
    'APPLIED USERS: ' || CASE WHEN applied_users = '' THEN '(not applied)' ELSE applied_users END,
    E'[\r\n]+', E'\\n', 'g'
  ) AS profile_detail,
  applied_users
FROM profile_rows
GROUP BY profile_name, applied_users
ORDER BY profile_name;
-- == SECTION 3-3: Profiles (sys.dba_profiles) ==
--@@ sec_3_3_profiles_dba
WITH prof_users AS (
  SELECT
    p.profile AS profile_name,
    COALESCE((
      SELECT string_agg(r.rolname, ', ' ORDER BY r.rolname)
      FROM pg_roles r
      WHERE lower(COALESCE(to_jsonb(r)->>'rolprofile','')) = lower(p.profile)
         OR lower(COALESCE(to_jsonb(r)->>'edb_profile','')) = lower(p.profile)
         OR EXISTS (
           SELECT 1
           FROM unnest(COALESCE(r.rolconfig, ARRAY[]::text[])) cfg
           WHERE regexp_replace(lower(cfg), '["''\s]', '', 'g') = 'edb_profile=' || lower(p.profile)
         )
    ), '') AS applied_users
  FROM (
    SELECT DISTINCT profile
    FROM sys.dba_profiles
    WHERE upper(profile) <> 'DEFAULT'
  ) p
), prof_detail AS (
  SELECT
    p.profile AS profile_name,
    string_agg(
      rpad(COALESCE(p.profile::text, '-'), 17, ' ') || ' | ' ||
      rpad(COALESCE(p.resource_name::text, '-'), 27, ' ') || ' | ' ||
      rpad(COALESCE(p.resource_type::text, '-'), 13, ' ') || ' | ' ||
      rpad(COALESCE(p.limit::text, '-'), 24, ' ') || ' | ' ||
      COALESCE(p.common::text, '-'),
      E'\n' ORDER BY p.resource_type, p.resource_name
    ) AS body_lines
  FROM sys.dba_profiles p
  WHERE upper(p.profile) <> 'DEFAULT'
  GROUP BY p.profile
)
SELECT
  d.profile_name,
  regexp_replace(
    'PROFILE           | RESOURCE_NAME               | RESOURCE_TYPE | LIMIT                    | COMMON' || E'\n' ||
    '--------------------------------------------------------------------------------------------------------' || E'\n' ||
    COALESCE(d.body_lines, '(none)') || E'\n\n' ||
    'APPLIED USERS: ' || CASE WHEN u.applied_users = '' THEN '(not applied)' ELSE u.applied_users END,
    E'[\r\n]+', E'\\n', 'g'
  ) AS profile_detail,
  u.applied_users
FROM prof_detail d
LEFT JOIN prof_users u ON u.profile_name = d.profile_name
ORDER BY d.profile_name;

-- == SECTION 3-4: Resource Groups ==
--@@ sec_3_4_resource_groups
SELECT
  rg.rgrpname AS resource_group_name,
  COALESCE(
    to_jsonb(rg)->>'cpurate',
    to_jsonb(rg)->>'rgrpcpurate',
    to_jsonb(rg)->>'cpulimit',
    to_jsonb(rg)->>'rgrpcpulimit',
    to_jsonb(rg)->>'cpu_rate',
    to_jsonb(rg)->>'rgrp_cpu_rate',
    (SELECT j.value FROM jsonb_each_text(to_jsonb(rg)) j WHERE lower(j.key) LIKE '%cpu%' AND lower(j.key) NOT LIKE '%dirty%' LIMIT 1),
    ''
  ) AS cpurate,
  COALESCE(
    to_jsonb(rg)->>'dirtyratelimit',
    to_jsonb(rg)->>'rgrpdirtyratelimit',
    to_jsonb(rg)->>'dirty_rate_limit',
    to_jsonb(rg)->>'rgrp_dirty_rate_limit',
    (SELECT j.value FROM jsonb_each_text(to_jsonb(rg)) j WHERE lower(j.key) LIKE '%dirty%' LIMIT 1),
    ''
  ) AS dirtyratelimit,
  COALESCE((
    SELECT string_agg(r.rolname, ', ' ORDER BY r.rolname)
    FROM pg_roles r
    WHERE EXISTS (
      SELECT 1
      FROM unnest(COALESCE(r.rolconfig, ARRAY[]::text[])) cfg
      WHERE regexp_replace(lower(cfg), '["''\s]', '', 'g') = 'edb_resource_group=' || lower(rg.rgrpname)
    )
  ), '') AS applied_users
FROM pg_catalog.edb_resource_group rg
ORDER BY rg.rgrpname;

-- == SECTION 4-1: DBLink ==
--@@ sec_4_1_dblink
SELECT lnkname, lnkowner, lnktype, lnkispublic, lnkuser, lnkconnstr, oid
FROM pg_catalog.edb_dblink
ORDER BY lnkname;


-- == SOURCE COMPONENT: package/view source dump ==
--@@ raw_2_1_packages
SELECT CASE WHEN p.prokind='p' THEN 'P' ELSE 'F' END AS object_type,
       n.nspname AS schema_name,
       p.proname AS object_name,
       regexp_replace(
         'Schema: ' || n.nspname || E'\n' ||
         'Name: ' || p.proname || E'\n' ||
         'Result data type: ' || pg_catalog.pg_get_function_result(p.oid) || E'\n' ||
         'Argument data types: ' || COALESCE(pg_catalog.pg_get_function_arguments(p.oid), '') || E'\n' ||
         'Type: ' || CASE p.prokind WHEN 'p' THEN 'proc' WHEN 'a' THEN 'agg' WHEN 'w' THEN 'window' ELSE 'func' END || E'\n' ||
         'Volatility: ' || CASE p.provolatile WHEN 'i' THEN 'immutable' WHEN 's' THEN 'stable' WHEN 'v' THEN 'volatile' ELSE p.provolatile::text END || E'\n' ||
         'Parallel: ' || CASE p.proparallel WHEN 'r' THEN 'restricted' WHEN 's' THEN 'safe' WHEN 'u' THEN 'unsafe' ELSE p.proparallel::text END || E'\n' ||
         'Owner: ' || pg_catalog.pg_get_userbyid(p.proowner) || E'\n' ||
         'Security: ' || CASE WHEN p.prosecdef THEN 'definer' ELSE 'invoker' END || E'\n' ||
         'Language: ' || l.lanname || E'\n' ||
         -- Replaced at runtime by version-branch logic in bash.
         'Source code:' || E'\n' || __FUNC_SOURCE_EXPR__,
         E'[\r\n]+', E'\\n', 'g'
       ) AS source_text
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
LEFT JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
  AND n.nspname NOT LIKE 'dbms_%'
  AND n.nspname NOT LIKE 'utl_%'
  AND p.proname !~* '^((dbms|utl|owa|htp|htf)(_|\.)|aq\$)'
  AND NOT (
    lower(p.proname) ~ '^(htf|htp|xmltype)'
    AND COALESCE(p.prosrc, '') !~* 'USER_CREATED'
    AND (
      n.nspname IN ('htf', 'htp', 'xmltype')
      OR p.prosrc LIKE '$__EDBwrapped__$$PROTOCOL2$%'
      OR lower(pg_catalog.pg_get_userbyid(p.proowner)) = 'enterprisedb'
      OR EXISTS (
        SELECT 1
        FROM pg_depend d2
        JOIN pg_extension e2 ON e2.oid = d2.refobjid
        WHERE d2.classid = 'pg_proc'::regclass
          AND d2.objid = p.oid
          AND d2.deptype = 'e'
      )
    )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_depend d
    JOIN pg_extension e ON e.oid = d.refobjid
    WHERE d.classid = 'pg_proc'::regclass
      AND d.objid = p.oid
      AND d.deptype = 'e'
  )
UNION ALL
SELECT 'V' AS object_type,
       v.schemaname AS schema_name,
       v.viewname AS object_name,
       regexp_replace(
         'Schema: ' || v.schemaname || E'\n' ||
         'Name: ' || v.viewname || E'\n' ||
         'Type: view' || E'\n' ||
         'Source code:' || E'\n' || v.definition,
         E'[\r\n]+', E'\\n', 'g'
       ) AS source_text
FROM pg_views v
WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
  AND v.schemaname NOT LIKE 'dbms_%'
  AND v.schemaname NOT LIKE 'utl_%';
-- == SOURCE COMPONENT: keyword object source dump ==
--@@ raw_2_1_keywords
SELECT CASE WHEN p.prokind='p' THEN 'P' ELSE 'F' END AS object_type,
       n.nspname AS schema_name,
       p.proname AS object_name,
       regexp_replace(
         'Schema: ' || n.nspname || E'\n' ||
         'Name: ' || p.proname || E'\n' ||
         'Result data type: ' || pg_catalog.pg_get_function_result(p.oid) || E'\n' ||
         'Argument data types: ' || COALESCE(pg_catalog.pg_get_function_arguments(p.oid), '') || E'\n' ||
         'Type: ' || CASE p.prokind WHEN 'p' THEN 'proc' WHEN 'a' THEN 'agg' WHEN 'w' THEN 'window' ELSE 'func' END || E'\n' ||
         'Volatility: ' || CASE p.provolatile WHEN 'i' THEN 'immutable' WHEN 's' THEN 'stable' WHEN 'v' THEN 'volatile' ELSE p.provolatile::text END || E'\n' ||
         'Parallel: ' || CASE p.proparallel WHEN 'r' THEN 'restricted' WHEN 's' THEN 'safe' WHEN 'u' THEN 'unsafe' ELSE p.proparallel::text END || E'\n' ||
         'Owner: ' || pg_catalog.pg_get_userbyid(p.proowner) || E'\n' ||
         'Security: ' || CASE WHEN p.prosecdef THEN 'definer' ELSE 'invoker' END || E'\n' ||
         'Language: ' || l.lanname || E'\n' ||
         -- Replaced at runtime by version-branch logic in bash.
         'Source code:' || E'\n' || __FUNC_SOURCE_EXPR__,
         E'[\r\n]+', E'\\n', 'g'
       ) AS source_text
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
LEFT JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
  AND n.nspname NOT LIKE 'dbms_%'
  AND n.nspname NOT LIKE 'utl_%'
  AND p.proname !~* '^((dbms|utl|owa|htp|htf)(_|\.)|aq\$)'
  AND NOT (
    lower(p.proname) ~ '^(htf|htp|xmltype)'
    AND COALESCE(p.prosrc, '') !~* 'USER_CREATED'
    AND (
      n.nspname IN ('htf', 'htp', 'xmltype')
      OR p.prosrc LIKE '$__EDBwrapped__$$PROTOCOL2$%'
      OR lower(pg_catalog.pg_get_userbyid(p.proowner)) = 'enterprisedb'
      OR EXISTS (
        SELECT 1
        FROM pg_depend d2
        JOIN pg_extension e2 ON e2.oid = d2.refobjid
        WHERE d2.classid = 'pg_proc'::regclass
          AND d2.objid = p.oid
          AND d2.deptype = 'e'
      )
    )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_depend d
    JOIN pg_extension e ON e.oid = d.refobjid
    WHERE d.classid = 'pg_proc'::regclass
      AND d.objid = p.oid
      AND d.deptype = 'e'
  )
UNION ALL
SELECT 'V' AS object_type,
       v.schemaname AS schema_name,
       v.viewname AS object_name,
       regexp_replace(
         'Schema: ' || v.schemaname || E'\n' ||
         'Name: ' || v.viewname || E'\n' ||
         'Type: view' || E'\n' ||
         'Source code:' || E'\n' || v.definition,
         E'[\r\n]+', E'\\n', 'g'
       ) AS source_text
FROM pg_views v
WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
  AND v.schemaname NOT LIKE 'dbms_%'
  AND v.schemaname NOT LIKE 'utl_%';
-- == SOURCE COMPONENT: expression source dump ==
--@@ raw_2_3_expr
SELECT 'DEFAULT VALUE' AS object_type, n.nspname AS schema_name, c.relname AS table_name, a.attname AS target_name,
       regexp_replace(pg_get_expr(d.adbin, d.adrelid), E'[\r\n]+', E'\\n', 'g') AS expression
FROM pg_attrdef d
JOIN pg_attribute a ON d.adrelid = a.attrelid AND d.adnum = a.attnum
JOIN pg_class c ON d.adrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
UNION ALL
SELECT 'CHECK CONSTRAINT' AS object_type, n.nspname AS schema_name, c.relname AS table_name, con.conname AS target_name,
       regexp_replace(
         '[Detected Columns] ' || COALESCE((
           SELECT string_agg(a.attname, ', ' ORDER BY a.attnum)
           FROM unnest(con.conkey) AS ck(attnum)
           JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ck.attnum
         ), '(expression-based/unknown)') || E'\n' || pg_get_expr(con.conbin, con.conrelid),
         E'[\r\n]+', E'\\n', 'g'
       ) AS expression
FROM pg_constraint con
JOIN pg_class c ON con.conrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE con.contype = 'c' AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
UNION ALL
SELECT 'INDEX EXPRESSION' AS object_type, n.nspname AS schema_name, c.relname AS table_name, i.relname AS target_name,
       regexp_replace(pg_get_expr(idx.indexprs, idx.indrelid), E'[\r\n]+', E'\\n', 'g') AS expression
FROM pg_index idx
JOIN pg_class c ON idx.indrelid = c.oid
JOIN pg_class i ON idx.indexrelid = i.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE idx.indexprs IS NOT NULL AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype');

-- == SOURCE COMPONENT: table column catalog dump ==
--@@ raw_tables_columns
SELECT table_schema, table_name, column_name,
       COALESCE(domain_name, udt_name) AS column_type,
       is_nullable,
       COALESCE(column_default, '') AS column_default
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
ORDER BY table_schema, table_name, ordinal_position;


-- == SOURCE COMPONENT: table object source dump ==
--@@ raw_tables_objects
WITH tbl AS (
  SELECT c.oid, n.nspname AS schema_name, c.relname AS table_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r','p')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb', 'htf', 'htp', 'xmltype')
), cols AS (
  SELECT t.oid,
         string_agg(
           format('  %s | %s | %s | %s',
             a.attname,
             pg_catalog.format_type(a.atttypid, a.atttypmod),
             CASE WHEN a.attnotnull THEN 'not null' ELSE '' END,
             COALESCE((SELECT pg_catalog.pg_get_expr(d.adbin, d.adrelid, true)
                       FROM pg_catalog.pg_attrdef d
                       WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum), '')
           ), E'\n' ORDER BY a.attnum
         ) AS val
  FROM tbl t
  JOIN pg_attribute a ON a.attrelid = t.oid
  WHERE a.attnum > 0 AND NOT a.attisdropped
  GROUP BY t.oid
), idx AS (
  SELECT t.oid,
         string_agg(
           format('  %s', pg_catalog.pg_get_indexdef(i.indexrelid, 0, true)), E'\n' ORDER BY c2.relname
         ) AS val
  FROM tbl t
  JOIN pg_index i ON i.indrelid = t.oid
  JOIN pg_class c2 ON c2.oid = i.indexrelid
  GROUP BY t.oid
), fk AS (
  SELECT t.oid,
         string_agg(
           format('  %s %s', con.conname, pg_catalog.pg_get_constraintdef(con.oid, true)), E'\n' ORDER BY con.conname
         ) AS val
  FROM tbl t
  JOIN pg_constraint con ON con.conrelid = t.oid
  WHERE con.contype = 'f'
  GROUP BY t.oid
), pol AS (
  SELECT t.oid,
         string_agg(
           format('  %s (%s)', pol.polname,
             CASE pol.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT' WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE pol.polcmd::text END
           ), E'\n' ORDER BY pol.polname
         ) AS val
  FROM tbl t
  JOIN pg_policy pol ON pol.polrelid = t.oid
  GROUP BY t.oid
)
SELECT t.schema_name, t.table_name,
       regexp_replace(
         format('Table "%s.%s"\n\nColumns:\n%s\n\nIndexes:\n%s\n\nForeign-key constraints:\n%s\n\nPolicies:\n%s',
           t.schema_name,
           t.table_name,
           COALESCE(cols.val, '  (none)'),
           COALESCE(idx.val, '  (none)'),
           COALESCE(fk.val, '  (none)'),
           COALESCE(pol.val, '  (none)')
         ),
         E'[\r\n]+', E'\\n', 'g'
       ) AS source_text
FROM tbl t
LEFT JOIN cols ON cols.oid = t.oid
LEFT JOIN idx ON idx.oid = t.oid
LEFT JOIN fk ON fk.oid = t.oid
LEFT JOIN pol ON pol.oid = t.oid
ORDER BY t.schema_name, t.table_name;
__EMBEDDED_SQL__
}

cleanup_embedded_sql(){
  [[ -z "${EMBEDDED_SQL_FILE:-}" ]] && return 0
  [[ -f "$EMBEDDED_SQL_FILE" ]] || return 0
  if command -v perl >/dev/null 2>&1; then
    perl -e 'unlink @ARGV' "$EMBEDDED_SQL_FILE" >/dev/null 2>&1 || : > "$EMBEDDED_SQL_FILE"
  else
    : > "$EMBEDDED_SQL_FILE"
  fi
}

trap cleanup_embedded_sql EXIT

write_embedded_sql

read_sql(){
  local key="$1" marker="--@@ $1" cap=0 line sql=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$cap" -eq 0 ]]; then [[ "$line" == "$marker" ]] && cap=1; continue; fi
    [[ "$line" == --@@\ * ]] && break
    sql+="$line"$'\n'
  done < "$EMBEDDED_SQL_FILE"
  sql="${sql//__FUNC_SOURCE_EXPR__/$FUNC_SOURCE_EXPR}"
  printf '%s' "$sql"
}
run_tsv(){ local f="$1"; shift; "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -F $'\t' -P footer=off -c "$*" > "$f"; }
run_scalar(){ "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -t -c "$1" | xargs; }
table_exists(){ [[ "$(run_scalar "SELECT to_regclass('$1') IS NOT NULL;")" == "t" ]]; }
row_count_tsv(){ [[ -s "$1" ]] && awk 'END{print (NR>0?NR-1:0)}' "$1" || echo 0; }
count_rows(){ [[ -s "$1" ]] && wc -l < "$1" | xargs || echo 0; }
count_bad(){ [[ -s "$1" ]] && awk '/badge-bad/{c++} END{print c+0}' "$1" || echo 0; }
html_escape(){
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' \
          -e 's/</\&lt;/g' \
          -e 's/>/\&gt;/g' \
          -e 's/"/\&quot;/g' \
          -e "s/'/\&#39;/g"
}
purge_files(){
  local f
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    if command -v perl >/dev/null 2>&1; then
      perl -e 'unlink @ARGV' "$f" >/dev/null 2>&1 || : > "$f"
    else
      : > "$f"
    fi
  done
}

safe_remove_dir(){
  local d="$1"
  if [[ -z "$d" || "$d" == "/" || "$d" == "." ]]; then
    echo "[ERROR] refusing to clean unsafe path: $d" >&2
    return 1
  fi
  [[ -d "$d" ]] || return 0
  if command -v perl >/dev/null 2>&1; then
    perl -MFile::Find -e '
      my $root = shift;
      finddepth(sub {
        return if $File::Find::name eq $root;
        if (-f $_ || -l $_) { unlink $_; return; }
        if (-d $_) { rmdir $_; return; }
      }, $root);
      rmdir $root;
    ' "$d" || return 1
  else
    echo "[WARN] perl is not available; output directory cleanup is skipped: $d" >&2
    return 1
  fi
}

# Single-script version branch:
# - EPAS/PG 14+ : keep existing pg_get_function_sqlbody path
# - EPAS/PG 13- : use compatibility fallback path
FUNC_SOURCE_EXPR=""
configure_function_source_expr(){
  local server_version_num="" has_sqlbody_fn="f" use_sqlbody=0
  server_version_num="$(run_scalar "SELECT current_setting('server_version_num');" 2>/dev/null || true)"

  if [[ "$server_version_num" =~ ^[0-9]+$ && "$server_version_num" -ge 140000 ]]; then
    has_sqlbody_fn="$(run_scalar "SELECT (to_regprocedure('pg_catalog.pg_get_function_sqlbody(oid)') IS NOT NULL)::text;" 2>/dev/null || true)"
    [[ "$has_sqlbody_fn" == "t" ]] && use_sqlbody=1
  fi

  if [[ "$use_sqlbody" -eq 1 ]]; then
    FUNC_SOURCE_EXPR="COALESCE(pg_catalog.pg_get_function_sqlbody(p.oid), p.prosrc)"
  else
    FUNC_SOURCE_EXPR="COALESCE(NULLIF(p.prosrc, ''), pg_catalog.pg_get_functiondef(p.oid))"
  fi
}
configure_function_source_expr
EPAS_VERSION_INFO_RAW="$(run_scalar "SELECT split_part(version(), ',', 1);" 2>/dev/null || true)"
[[ -n "$EPAS_VERSION_INFO_RAW" ]] || EPAS_VERSION_INFO_RAW="Unknown"
EPAS_VERSION_INFO="$(html_escape "$EPAS_VERSION_INFO_RAW")"
OS_INFO_RAW="$(run_scalar "SELECT CASE WHEN position(' on ' in version()) > 0 THEN split_part(split_part(version(), ' on ', 2), ',', 1) ELSE 'Unknown' END;" 2>/dev/null || true)"
[[ -n "$OS_INFO_RAW" ]] || OS_INFO_RAW="Unknown"
OS_INFO="$(html_escape "$OS_INFO_RAW")"

PROGRESS_TOTAL=7
PROGRESS_CUR=0
PROGRESS_LAST_MSG=""

build_progress_line(){
  local pct="$1" msg="$2"
  local width=30
  local filled=$((pct*width/100))
  local empty=$((width-filled))
  local bar_filled bar_empty
  bar_filled=$(printf "%${filled}s" "" | tr ' ' '#')
  bar_empty=$(printf "%${empty}s" "" | tr ' ' '-')
  printf '[%s%s] %3d%% %s' "$bar_filled" "$bar_empty" "$pct" "$msg"
}

progress_step(){
  local msg="$1"
  if [[ -n "$PROGRESS_LAST_MSG" ]]; then
    if [[ -t 1 ]]; then
      printf '\r\033[2K[DONE] %s\n' "$PROGRESS_LAST_MSG"
    else
      printf '[DONE] %s\n' "$PROGRESS_LAST_MSG"
    fi
  fi

  PROGRESS_CUR=$((PROGRESS_CUR+1))
  local pct=$((PROGRESS_CUR*100/PROGRESS_TOTAL))
  PROGRESS_LAST_MSG="$msg"
  local line
  line="$(build_progress_line "$pct" "$msg")"
  if [[ -t 1 ]]; then
    printf '\r\033[2K%s' "$line"
  else
    printf '%s\n' "$line"
  fi
}

progress_finish(){
  [[ -n "$PROGRESS_LAST_MSG" ]] || return 0
  if [[ -t 1 ]]; then
    printf '\r\033[2K[DONE] %s\n' "$PROGRESS_LAST_MSG"
  else
    printf '[DONE] %s\n' "$PROGRESS_LAST_MSG"
  fi
  PROGRESS_LAST_MSG=""
}

export_wireframe_tsvs(){
  # Details 1-1 ~ 4-1 (reference: ds1.html)
  run_tsv "$OUT_DIR/01_parameters.tsv" "$(read_sql sec_1_1_parameters)"
  run_tsv "$OUT_DIR/02_summary_packages.tsv" "$(read_sql sec_2_1_packages_summary)"
  run_tsv "$OUT_DIR/02_summary_synonyms.tsv" "$(read_sql sec_2_4_synonyms)" || true
  run_tsv "$OUT_DIR/02_summary_policies.tsv" "$(read_sql sec_3_1_policies_pg)"
  if table_exists sys.all_policies; then
    run_tsv "$OUT_DIR/02_summary_policies_dbms_rls.tsv" "$(read_sql sec_3_1_policies_dbms)"
  else
    : > "$OUT_DIR/02_summary_policies_dbms_rls.tsv"
  fi
  if table_exists public.edb_redaction_policy && table_exists public.edb_redaction_column; then
    run_tsv "$OUT_DIR/02_summary_redaction.tsv" "$(read_sql sec_3_2_redaction)"
  elif table_exists pg_catalog.edb_redaction_policy && table_exists pg_catalog.edb_redaction_column; then
    run_tsv "$OUT_DIR/02_summary_redaction.tsv" "$(read_sql sec_3_2_redaction)"
  else
    : > "$OUT_DIR/02_summary_redaction.tsv"
  fi
  run_tsv "$OUT_DIR/03_detail_keywords.tsv" "$(read_sql sec_2_1_keywords)"
  run_tsv "$OUT_DIR/03_detail_datatypes_objects.tsv" "$(read_sql sec_2_2_datatypes_objects)"
  run_tsv "$OUT_DIR/03_detail_datatypes_tables.tsv" "$(read_sql sec_2_2_datatypes_tables)"
  run_tsv "$OUT_DIR/03_detail_expr_keywords.tsv" "$(read_sql sec_2_3_expr_keywords)"
  if run_tsv "$OUT_DIR/04_policy_edb_profile.tsv" "$(read_sql sec_3_3_profiles_dba)" 2>/dev/null; then
    :
  elif table_exists pg_catalog.edb_profile; then
    run_tsv "$OUT_DIR/04_policy_edb_profile.tsv" "$(read_sql sec_3_3_profiles)"
  else
    : > "$OUT_DIR/04_policy_edb_profile.tsv"
  fi
  if table_exists pg_catalog.edb_resource_group; then
    run_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv" "$(read_sql sec_3_4_resource_groups)"
  else
    : > "$OUT_DIR/04_policy_edb_resource_group.tsv"
  fi
  if table_exists pg_catalog.edb_dblink; then
    run_tsv "$OUT_DIR/04_policy_edb_dblink.tsv" "$(read_sql sec_4_1_dblink)"
  else
    : > "$OUT_DIR/04_policy_edb_dblink.tsv"
  fi
}

export_source_component_tsvs(){
  # Source navigator payload components
  run_tsv "$OUT_DIR/02_summary_packages_raw.tsv" "$(read_sql raw_2_1_packages)"
  run_tsv "$OUT_DIR/03_detail_keywords_raw.tsv" "$(read_sql raw_2_1_keywords)"
  run_tsv "$OUT_DIR/03_detail_expr_raw.tsv" "$(read_sql raw_2_3_expr)"
  run_tsv "$OUT_DIR/03_detail_table_columns_raw.tsv" "$(read_sql raw_tables_columns)"
  run_tsv "$OUT_DIR/03_detail_table_objects_raw.tsv" "$(read_sql raw_tables_objects)"
}

# data exports
progress_step "Exporting base TSV datasets"
export_wireframe_tsvs
export_source_component_tsvs
progress_step "Building intermediate report rows"

PARAM_ROWS="$OUT_DIR/.param_rows.html"; FEATURE_ROWS="$OUT_DIR/.feature_rows.html"; DTYPE_ROWS="$OUT_DIR/.dtype_rows.html"; EXPR_ROWS="$OUT_DIR/.expr_rows.html"

awk -F $'\t' '
function status_label(op){
  return (op=="HIGH"?"높음":(op=="MEDIUM"?"중간":"낮음"))
}
function desc_ko(param, raw){
  if(param=="edb_audit") return "EDB 감사 기능으로 PostgreSQL 전환 시 대체 검토가 필요합니다."
  if(param=="edb_audit_archiver") return "EDB 감사 아카이브 기능으로 PostgreSQL에서 동일 동작 검토가 필요합니다."
  if(param=="edb_early_lock_release") return "잠금 해제 동작 차이로 인한 트랜잭션 영향 검토가 필요합니다."
  if(param=="edb_max_capture_privileges_policies") return "권한 캡처 정책 관련 EDB 전용 기능 사용 여부를 점검해야 합니다."
  if(param=="qreplace_function") return "쿼리 대체 함수 사용 여부 및 대체 구현 검토가 필요합니다."
  if(param=="edb_stmt_level_tx") return "문장 단위 트랜잭션 처리 차이로 오류 동작 점검이 필요합니다."
  if(param=="data_encryption_key_unwrap_command") return "TDE 키 해제 명령은 PostgreSQL 대체 방식 검토가 필요합니다."
  if(param=="edb_max_resource_groups") return "리소스 그룹 제한 설정은 PostgreSQL 정책과 매핑 검토가 필요합니다."
  if(param=="edb_resource_group") return "세션 리소스 그룹 설정의 운영 정책 전환 검토가 필요합니다."
  if(param=="edb_redwood_strings") return "문자열/NULL 처리 방식 차이로 애플리케이션 로직 검토가 필요합니다."
  if(param=="db_dialect") return "오라클 호환 문법 모드가 SQL 동작에 영향을 줄 수 있습니다."
  if(param=="datestyle") return "날짜 파싱 및 출력 형식 차이로 데이터 처리 검토가 필요합니다."
  if(param=="edb_redwood_greatest_least") return "GREATEST/LEAST의 NULL 처리 방식 차이를 확인해야 합니다."
  if(param=="edb_redwood_date") return "DATE/TIMESTAMP 처리 방식 차이 존재 여부를 확인해야 합니다."
  if(param=="edb_dynatune") return "자동 메모리 튜닝 프로파일이 PostgreSQL 기본값과 다를 수 있습니다."
  if(param=="edb_dynatune_profile") return "동적 튜닝 프로파일 값의 수동 조정 검토가 필요합니다."
  if(param=="optimizer_mode") return "옵티마이저 모드 설정 차이로 실행 계획 검토가 필요합니다."
  if(param=="default_with_rowids") return "ROWID 의존 SQL은 PostgreSQL에서 재작성 검토가 필요합니다."
  if(param=="enable_hints") return "힌트 기능 의존 시 pg_hint_plan 적용 여부 검토가 필요합니다."
  if(param=="oracle_home") return "Oracle DBLink 연계 경로 정보 점검이 필요합니다."
  if(param=="extension_control_path") return "확장 제어 경로 설정의 운영 환경 반영 여부를 확인해야 합니다."
  if(param=="edb_redwood_raw_names") return "대소문자/인용 객체명 처리 방식 차이를 확인해야 합니다."
  if(param=="timed_statistics") return "I/O 타이밍 통계 수집 정책 차이를 점검해야 합니다."
  if(param=="max_generic_plan_partition_size") return "제네릭 플랜 파티션 관련 설정 영향도 검토가 필요합니다."
  return raw
}
NR>1{
  op="LOW"
  if($1 ~ /^(edb_audit|edb_audit_archiver|edb_early_lock_release|edb_max_capture_privileges_policies|qreplace_function|edb_stmt_level_tx|data_encryption_key_unwrap_command|edb_max_resource_groups|edb_resource_group)$/) op="HIGH"
  else if($1 ~ /^(edb_redwood_strings|db_dialect|datestyle|edb_redwood_greatest_least|edb_redwood_date|edb_dynatune|edb_dynatune_profile|optimizer_mode|default_with_rowids|enable_hints)$/) op="MEDIUM"

  p=$1; dflt=$2; cur=$3; desc=desc_ko($1,$5)
  gsub("&","&amp;",p); gsub("<","&lt;",p); gsub(">","&gt;",p)
  gsub("&","&amp;",dflt); gsub("<","&lt;",dflt); gsub(">","&gt;",dflt)
  gsub("&","&amp;",cur); gsub("<","&lt;",cur); gsub(">","&gt;",cur)
  gsub("&","&amp;",desc); gsub("<","&lt;",desc); gsub(">","&gt;",desc)

  txt=status_label(op)
  b=(op=="HIGH"?"badge-bad":(op=="MEDIUM"?"badge-high":"badge-low"))
  printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge %s\">%s</span></td></tr>\n",p,dflt,cur,desc,b,txt
}' "$OUT_DIR/01_parameters.tsv" > "$PARAM_ROWS"

awk -F $'\t' 'NR>1{print $1 "\t" $2 "\t" $3 "\t" $4 "\tPACKAGE"}' "$OUT_DIR/02_summary_packages.tsv" > "$OUT_DIR/.f.tsv"
awk -F $'\t' 'NR>1{print $1 "\t" $2 "\t" $3 "\t" $4 "\tKEYWORD"}' "$OUT_DIR/03_detail_keywords.tsv" >> "$OUT_DIR/.f.tsv"
awk -F $'	' '{
  t=$1; s=$2; o=$3; token=tolower($4); k=t SUBSEP s SUBSEP o
  if(token=="") token="(no keyword)"
  ph=(token=="(no keyword)")
  if(!ph && !((k SUBSEP token) in seen)){seen[k SUBSEP token]=1; toks[k]=(toks[k]?toks[k]", " :"")token}
  cat=($5=="PACKAGE"?"PACKAGE":"KEYWORD")
  if(!ph && !((k SUBSEP cat SUBSEP token) in seen_cat)){seen_cat[k SUBSEP cat SUBSEP token]=1; cat_cnt[k SUBSEP cat]++}
  lv=0
  if(token ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|raise_application_error)$/) lv=2
  else if(token ~ /^(dbms_crypto(\.[a-z0-9_]+)?|dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\.[a-z0-9_]+|htf\.[a-z0-9_]+|sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|greatest|least|clob|bfile|raw|listagg|wm_concat|substrb|instrb|lengthb)$/) lv=1
  if(lv > level[k]) level[k]=lv
  touched[k]=1
} END{
  for(k in touched){
    split(k,a,SUBSEP)
    ord=(a[1]=="F"?1:(a[1]=="P"?2:3))
    tn=(a[1]=="F"?"FUNCTION":(a[1]=="P"?"PROCEDURE":"VIEW"))
    op=(level[k]==2?"HIGH":(level[k]==1?"MEDIUM":"LOW"))
    pkg=cat_cnt[k SUBSEP "PACKAGE"]+0
    kw=cat_cnt[k SUBSEP "KEYWORD"]+0
    role=(pkg>0?"PACKAGE(" pkg ")":"")
    if(kw>0) role=(role?role"+":"")"KEYWORD(" kw ")"
    if(role=="") role="KEYWORD(0)"
    detail=(toks[k]!=""?toks[k]:"(no keyword)")
    print ord"	"a[2]"	"tn"	"role"	"a[2]"."a[3]"	"detail"	"op"	"a[2]"."a[3]
  }
}' "$OUT_DIR/.f.tsv" | sort -t $'	' -k1,1n -k2,2 -k5,5 | awk -F $'\t' '{  id=$8; gsub(/[^[:alnum:]_.-]/,"_",id);  gsub("&","&amp;",$6);gsub("<","&lt;",$6);gsub(">","&gt;",$6);  b=($7=="HIGH"?"badge-bad":($7=="MEDIUM"?"badge-high":"badge-low")); txt=($7=="HIGH"?"&#45458;&#51020;":($7=="MEDIUM"?"&#51473;&#44036;":"&#45230;&#51020;"));  printf "<tr><td><code>%s</code></td><td>%s</td><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",$3,$4,ENVIRON["SOURCE_DIR_BASENAME"],id,$5,$6,b,txt}' > "$FEATURE_ROWS"

awk -F $'	' 'NR>1{print $1"	"$2"	"$3"	"$4}' "$OUT_DIR/03_detail_datatypes_objects.tsv" > "$OUT_DIR/.d.tsv"
awk -F $'\t' 'NR>1{key=$1"."$2; dt=tolower($4); if(!seen[key SUBSEP dt]++){dtypes[key]=(dtypes[key]?dtypes[key]", ":"")dt}; sch[key]=$1; touched[key]=1} END{for(k in touched){print "T\t"sch[k]"\t"k"\t"dtypes[k]}}' "$OUT_DIR/03_detail_datatypes_tables.tsv" >> "$OUT_DIR/.d.tsv"
awk -F $'\t' '!seen[$0]++{  ord=($1=="P"?1:($1=="F"?2:($1=="V"?3:4)));  tn=($1=="P"?"PROCEDURE":($1=="F"?"FUNCTION":($1=="V"?"VIEW":"TABLE COLUMN")));  obj=($1=="T"?$3:$2"."$3);  print ord"\t"$2"\t"tn"\t"obj"\t"$4}' "$OUT_DIR/.d.tsv" | sort -t $'\t' -k1,1n -k2,2 -k4,4 | awk -F $'\t' '{  obj=$4; id=obj; gsub(/[^[:alnum:]_.-]/,"_",id);  printf "<tr><td><code>%s</code></td><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td><td><span class=\"badge badge-low\">&#45230;&#51020;</span></td></tr>\n",$3,ENVIRON["SOURCE_DIR_BASENAME"],id,obj,$5}' > "$DTYPE_ROWS"

awk -F $'\t' 'NR>1{  obj=($1=="INDEX EXPRESSION"?$2"."$4:$2"."$3"."$4);  k=obj SUBSEP $1; token=tolower($5); if(token=="") token="(no keyword)";  if(!((k SUBSEP token) in seen)){seen[k SUBSEP token]=1; kws[k]=(kws[k]?kws[k]", ":"")token};  lv=0;  if(token ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|raise_application_error)$/) lv=2;  else if(token ~ /^(dbms_crypto(\.[a-z0-9_]+)?|dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\.[a-z0-9_]+|htf\.[a-z0-9_]+|sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|greatest|least)$/) lv=1;  if(lv > level[k]) level[k]=lv} END{  for(k in kws){split(k,a,SUBSEP); op=(level[k]==2?"HIGH":(level[k]==1?"MEDIUM":"LOW")); print a[1]"\t"a[2]"\t"kws[k]"\t"op}}' "$OUT_DIR/03_detail_expr_keywords.tsv" | sort -t $'\t' -k1,1 -k2,2 | awk -F $'\t' '{  id=$1; gsub(/[^[:alnum:]_.-]/,"_",id);  gsub("&","&amp;",$3);gsub("<","&lt;",$3);gsub(">","&gt;",$3);  b=($4=="HIGH"?"badge-bad":($4=="MEDIUM"?"badge-high":"badge-low")); txt=($4=="HIGH"?"&#45458;&#51020;":($4=="MEDIUM"?"&#51473;&#44036;":"&#45230;&#51020;"));  printf "<tr><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",ENVIRON["SOURCE_DIR_BASENAME"],id,$1,$2,$3,b,txt}' > "$EXPR_ROWS"

calc_counts(){ local f="$1" t b; t=$(count_rows "$f"); b=$(count_bad "$f"); echo "$t $((t-b)) $b"; }
set -- $(calc_counts "$PARAM_ROWS"); param_total="$1"; param_ok="$2"; param_bad="$3"
set -- $(calc_counts "$FEATURE_ROWS"); feature_total="$1"; feature_ok="$2"; feature_bad="$3"
set -- $(calc_counts "$EXPR_ROWS"); expr_total="$1"; expr_ok="$2"; expr_bad="$3"
dtype_total=$(count_rows "$DTYPE_ROWS"); dtype_ok=$dtype_total; dtype_bad=0
syn_total=$(row_count_tsv "$OUT_DIR/02_summary_synonyms.tsv"); syn_ok=$syn_total; syn_bad=0
rls_pg_total=$(row_count_tsv "$OUT_DIR/02_summary_policies.tsv")
rls_dbms_total=$(row_count_tsv "$OUT_DIR/02_summary_policies_dbms_rls.tsv")
rls_total=$((rls_pg_total + rls_dbms_total)); rls_ok=$rls_total; rls_bad=0
redaction_total=$(row_count_tsv "$OUT_DIR/02_summary_redaction.tsv"); redaction_ok=$redaction_total; redaction_bad=0
profile_total=$(row_count_tsv "$OUT_DIR/04_policy_edb_profile.tsv"); profile_ok=$profile_total; profile_bad=0
rg_total=$(row_count_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv"); rg_ok=$rg_total; rg_bad=0
dblink_total=$(row_count_tsv "$OUT_DIR/04_policy_edb_dblink.tsv"); dblink_ok=$dblink_total; dblink_bad=0
progress_step "Preparing visualization dataset"

# Summary scope: USER_CREATED objects only (exclude built-ins).
UC_OBJ_SET="$OUT_DIR/.user_created_objects.tsv"
awk -F $'\t' 'NR>1{
  src=tolower($4)
  if(src ~ /user_created/) print $1 "\t" $2 "\t" $3
}' "$OUT_DIR/02_summary_packages_raw.tsv" | sort -u > "$UC_OBJ_SET"

# Some environments do not embed the USER_CREATED marker in source_text.
# Fallback to all already-filtered raw objects (built-ins are excluded upstream).
if [[ ! -s "$UC_OBJ_SET" ]]; then
  awk -F $'\t' 'NR>1{print $1 "\t" $2 "\t" $3}' "$OUT_DIR/02_summary_packages_raw.tsv" | sort -u > "$UC_OBJ_SET"
fi

# Summary totals must include non-impacted USER_CREATED objects as denominator.
pkg_total=$(awk -F $'\t' '{print $2"."$3}' "$UC_OBJ_SET" | sort -u | wc -l | xargs)
fun_total=$(awk -F $'\t' '$1=="F"{print $2"."$3}' "$UC_OBJ_SET" | sort -u | wc -l | xargs)
prc_total=$(awk -F $'\t' '$1=="P"{print $2"."$3}' "$UC_OBJ_SET" | sort -u | wc -l | xargs)
viw_total=$(awk -F $'\t' '$1=="V"{print $2"."$3}' "$UC_OBJ_SET" | sort -u | wc -l | xargs)
tbl_total=$(awk -F $'\t' 'NR>1{print $1"."$2}' "$OUT_DIR/03_detail_table_objects_raw.tsv" | sort -u | wc -l | xargs)

pkg_imp=$(awk -F $'\t' 'FNR==NR{u[$1 SUBSEP $2 SUBSEP $3]=1; next} NR>1{k=$1 SUBSEP $2 SUBSEP $3; if(u[k]) s[$2"."$3]=1} END{for(i in s)c++; print c+0}' "$UC_OBJ_SET" "$OUT_DIR/02_summary_packages.tsv")
fun_imp=$(awk -F $'\t' 'FNR==NR{u[$1 SUBSEP $2 SUBSEP $3]=1; next} NR>1 && $1=="F"{k=$1 SUBSEP $2 SUBSEP $3; if(u[k]) s[$2"."$3]=1} END{for(i in s)c++; print c+0}' "$UC_OBJ_SET" "$OUT_DIR/03_detail_keywords.tsv")
prc_imp=$(awk -F $'\t' 'FNR==NR{u[$1 SUBSEP $2 SUBSEP $3]=1; next} NR>1 && $1=="P"{k=$1 SUBSEP $2 SUBSEP $3; if(u[k]) s[$2"."$3]=1} END{for(i in s)c++; print c+0}' "$UC_OBJ_SET" "$OUT_DIR/03_detail_keywords.tsv")
viw_imp=$(awk -F $'\t' 'FNR==NR{u[$1 SUBSEP $2 SUBSEP $3]=1; next} NR>1 && $1=="V"{k=$1 SUBSEP $2 SUBSEP $3; if(u[k]) s[$2"."$3]=1} END{for(i in s)c++; print c+0}' "$UC_OBJ_SET" "$OUT_DIR/03_detail_keywords.tsv")
tbl_imp=$(
  {
    awk -F $'\t' 'NR>1{print $1"."$2}' "$OUT_DIR/03_detail_datatypes_tables.tsv"
    awk -F $'\t' 'NR>1 && $2!="" && $3!=""{print $2"."$3}' "$OUT_DIR/03_detail_expr_keywords.tsv"
  } | sort -u | wc -l | xargs
)

if [[ "$pkg_imp" -gt "$pkg_total" ]]; then pkg_imp="$pkg_total"; fi
if [[ "$fun_imp" -gt "$fun_total" ]]; then fun_imp="$fun_total"; fi
if [[ "$prc_imp" -gt "$prc_total" ]]; then prc_imp="$prc_total"; fi
if [[ "$viw_imp" -gt "$viw_total" ]]; then viw_imp="$viw_total"; fi
if [[ "$tbl_imp" -gt "$tbl_total" ]]; then tbl_imp="$tbl_total"; fi

: > "$OUT_DIR/.vis_keywords.tsv"
awk -F $'\t' 'FNR==NR{u[$1 SUBSEP $2 SUBSEP $3]=1; next} NR>1{k=$1 SUBSEP $2 SUBSEP $3; if(u[k]){kw=tolower($4); if(kw!="") c[kw]++}} END{for(kw in c) print "PACKAGE\t"kw"\t"c[kw]}' "$UC_OBJ_SET" "$OUT_DIR/02_summary_packages.tsv" >> "$OUT_DIR/.vis_keywords.tsv"
awk -F $'\t' 'FNR==NR{u[$1 SUBSEP $2 SUBSEP $3]=1; next} NR>1{k=$1 SUBSEP $2 SUBSEP $3; if(!u[k]) next; t=($1=="F"?"FUNCTION":($1=="P"?"PROCEDURE":($1=="V"?"VIEW":""))); if(t!=""){kw=tolower($4); if(kw!="") c[t SUBSEP kw]++}} END{for(x in c){split(x,a,SUBSEP); print a[1]"\t"a[2]"\t"c[x]}}' "$UC_OBJ_SET" "$OUT_DIR/03_detail_keywords.tsv" >> "$OUT_DIR/.vis_keywords.tsv"
awk -F $'\t' 'NR>1{k=tolower($4); if(k!="") c[k]++} END{for(k in c) print "TABLE\t"k"\t"c[k]}' "$OUT_DIR/03_detail_datatypes_tables.tsv" >> "$OUT_DIR/.vis_keywords.tsv"
awk -F $'\t' 'NR>1{k=tolower($5); if(k!="") c[k]++} END{for(k in c) print "TABLE\t"k"\t"c[k]}' "$OUT_DIR/03_detail_expr_keywords.tsv" >> "$OUT_DIR/.vis_keywords.tsv"

build_kw_js(){
  local t="$1"
  local out
  out=$(awk -F $'\t' -v T="$t" '$1==T{c[$2]+=$3} END{for(k in c) print c[k]"\t"k}' "$OUT_DIR/.vis_keywords.tsv" | sort -rn | head -10 | awk -F $'\t' '{gsub(/\\/,"\\\\",$2); gsub(/"/,"\\\"",$2); printf "[\"%s\",%d],",$2,$1}')
  if [[ -z "$out" ]]; then
    printf '["(none)",0]'
  else
    printf '%s' "${out%,}"
  fi
}

pkg_kw_js="$(build_kw_js PACKAGE)"
fun_kw_js="$(build_kw_js FUNCTION)"
prc_kw_js="$(build_kw_js PROCEDURE)"
viw_kw_js="$(build_kw_js VIEW)"
tbl_kw_js="$(build_kw_js TABLE)"
: > "$OUT_DIR/.vis_impact.tsv"

awk -F $'\t' '
FNR==NR{u[$1 SUBSEP $2 SUBSEP $3]=1; next}
NR>1{
  k=$1 SUBSEP $2 SUBSEP $3
  if(!u[k]) next
  token=tolower($4)
  lv=0
  if(token ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|raise_application_error)$/) lv=2
  else if(token ~ /^(dbms_crypto(\.[a-z0-9_]+)?|dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\.[a-z0-9_]+|htf\.[a-z0-9_]+|sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|greatest|least|clob|bfile|raw|listagg|wm_concat|substrb|instrb|lengthb)$/) lv=1
  if(lv > level[k]) level[k]=lv
  touched[k]=1
}
END{
  for(k in touched){
    op=(level[k]==2?"HIGH":(level[k]==1?"MEDIUM":"LOW"))
    c["PACKAGE" SUBSEP op]++
  }
  for(x in c){split(x,a,SUBSEP); print a[1] "\t" a[2] "\t" c[x]}
}' "$UC_OBJ_SET" "$OUT_DIR/02_summary_packages.tsv" >> "$OUT_DIR/.vis_impact.tsv"

awk -F $'\t' '
FNR==NR{u[$1 SUBSEP $2 SUBSEP $3]=1; next}
NR>1{
  k=$1 SUBSEP $2 SUBSEP $3
  if(!u[k]) next
  token=tolower($4)
  lv=0
  if(token ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|raise_application_error)$/) lv=2
  else if(token ~ /^(dbms_crypto(\.[a-z0-9_]+)?|dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\.[a-z0-9_]+|htf\.[a-z0-9_]+|sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|greatest|least|clob|bfile|raw|listagg|wm_concat|substrb|instrb|lengthb)$/) lv=1
  if(lv > level[k]) level[k]=lv
  touched[k]=1
}
END{
  for(k in touched){
    split(k,a,SUBSEP)
    t=(a[1]=="F"?"FUNCTION":(a[1]=="P"?"PROCEDURE":"VIEW"))
    op=(level[k]==2?"HIGH":(level[k]==1?"MEDIUM":"LOW"))
    c[t SUBSEP op]++
  }
  for(x in c){split(x,a,SUBSEP); print a[1] "\t" a[2] "\t" c[x]}
}' "$UC_OBJ_SET" "$OUT_DIR/03_detail_keywords.tsv" >> "$OUT_DIR/.vis_impact.tsv"

{
  awk -F $'\t' 'NR>1{print $1 "." $2 "\t" $4}' "$OUT_DIR/03_detail_datatypes_tables.tsv"
  awk -F $'\t' 'NR>1 && $2!="" && $3!=""{print $2 "." $3 "\t" $5}' "$OUT_DIR/03_detail_expr_keywords.tsv"
} | awk -F $'\t' '
{
  key=$1
  token=tolower($2)
  lv=0
  if(token ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|raise_application_error)$/) lv=2
  else if(token ~ /^(dbms_crypto(\.[a-z0-9_]+)?|dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\.[a-z0-9_]+|htf\.[a-z0-9_]+|sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|greatest|least|clob|bfile|raw|listagg|wm_concat|substrb|instrb|lengthb)$/) lv=1
  if(lv > level[key]) level[key]=lv
  touched[key]=1
}
END{
  for(key in touched){
    op=(level[key]==2?"HIGH":(level[key]==1?"MEDIUM":"LOW"))
    c[op]++
  }
  for(op in c) print "TABLE\t" op "\t" c[op]
}' >> "$OUT_DIR/.vis_impact.tsv"

impact_count(){
  local t="$1" level="$2"
  awk -F $'\t' -v T="$t" -v L="$level" '$1==T && $2==L{s+=$3} END{print s+0}' "$OUT_DIR/.vis_impact.tsv"
}

pkg_high="$(impact_count PACKAGE HIGH)"; pkg_med="$(impact_count PACKAGE MEDIUM)"; pkg_low="$(impact_count PACKAGE LOW)"
fun_high="$(impact_count FUNCTION HIGH)"; fun_med="$(impact_count FUNCTION MEDIUM)"; fun_low="$(impact_count FUNCTION LOW)"
prc_high="$(impact_count PROCEDURE HIGH)"; prc_med="$(impact_count PROCEDURE MEDIUM)"; prc_low="$(impact_count PROCEDURE LOW)"
viw_high="$(impact_count VIEW HIGH)"; viw_med="$(impact_count VIEW MEDIUM)"; viw_low="$(impact_count VIEW LOW)"
tbl_high="$(impact_count TABLE HIGH)"; tbl_med="$(impact_count TABLE MEDIUM)"; tbl_low="$(impact_count TABLE LOW)"
# source html best-effort
progress_step "Generating source navigator pages"
PY_RENDERED=0
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  PYBIN=$(command -v python3 || command -v python)
  if "$PYBIN" - <<'PY' "$OUT_DIR" "$SOURCE_HTML_PATH" "$SOURCE_DIR_PATH" "$HTML_BASENAME"
import csv,html,re,sys,hashlib
from pathlib import Path
out=Path(sys.argv[1]); target=Path(sys.argv[2]); src_dir=Path(sys.argv[3]); precheck_name=sys.argv[4]
src_dir.mkdir(parents=True, exist_ok=True)

def rows(p):
  if not p.exists(): return []
  with p.open(encoding='utf-8',newline='') as f:
    r=csv.reader(f,delimiter='\t'); next(r,None); return list(r)

def iter_fields(path, size):
  for row in rows(path):
    if not row:
      continue
    if len(row) < size:
      row = row + [''] * (size - len(row))
    elif len(row) > size:
      row = row[:size-1] + ['\t'.join(row[size-1:])]
    yield row

def slug(name):
  base=re.sub(r'[^A-Za-z0-9_.-]', '_', name)
  if len(base) <= 120:
    return base
  h=hashlib.sha1(name.encode('utf-8')).hexdigest()[:12]
  return base[:100] + '_' + h

def full_type(t):
  m={
    'F':'FUNCTION','P':'PROCEDURE','V':'VIEW','T':'TABLE COLUMN',
    'DEFAULT VALUE':'DEFAULT VALUE','CHECK CONSTRAINT':'CHECK CONSTRAINT','INDEX EXPRESSION':'INDEX EXPRESSION','UNKNOWN':'UNKNOWN','TABLE':'TABLE','PROFILE':'PROFILE','RESOURCE GROUP':'RESOURCE GROUP','DBLINK':'DBLINK'
  }
  return m.get(t, t)



def restore_text(s):
  if s is None:
    return ''
  return s.replace('\\n','\n')

def highlight_text(src, kws):
  esc=html.escape(src)
  for k in sorted([x for x in kws if x and x != '(no keyword)'], key=len, reverse=True):
    esc=re.sub(rf'(?i)({re.escape(k)})', r'<span class="kw">\1</span>', esc)
  return esc

kw={}
for t,s,o,k in iter_fields(out/'03_detail_keywords.tsv', 4):
  obj=f'{s}.{o}'
  kw.setdefault(obj,set()).add(k.lower() if k else '(no keyword)')
for ot,s,t,tr,k in iter_fields(out/'03_detail_expr_keywords.tsv', 5):
  obj = f'{s}.{tr}' if ot=='INDEX EXPRESSION' else f'{s}.{t}.{tr}'
  kw.setdefault(obj,set()).add(k.lower() if k else '(no keyword)')
for t,s,o,k in iter_fields(out/'02_summary_packages.tsv', 4):
  kw.setdefault(f'{s}.{o}',set()).add(k.lower() if k else '(no keyword)')
for s,t,c,d in iter_fields(out/'03_detail_datatypes_tables.tsv', 4):
  kw.setdefault(f'{s}.{t}',set()).add(d.lower() if d else '(no keyword)')
for object_owner, schema_name, object_name, policy_group, policy_name, pf_owner, package, function_name in iter_fields(out/'02_summary_policies_dbms_rls.tsv', 8):
  obj=f'policy.rls.{schema_name}.{object_name}.{policy_name}'
  if function_name:
    kw.setdefault(obj,set()).add(function_name.lower())
  if package and function_name:
    kw.setdefault(obj,set()).add(f'{package.lower()}.{function_name.lower()}')

raw={}
for t,s,o,src in list(iter_fields(out/'02_summary_packages_raw.tsv', 4))+list(iter_fields(out/'03_detail_keywords_raw.tsv', 4)):
  if src:
    raw[f'{s}.{o}']=(full_type(t),restore_text(src))
for ot,s,t,tr,e in iter_fields(out/'03_detail_expr_raw.tsv', 5):
  obj = f'{s}.{tr}' if ot=='INDEX EXPRESSION' else f'{s}.{t}.{tr}'
  if e:
    raw[obj]=(full_type(ot),restore_text(e))
for prf, detail, users in iter_fields(out/'04_policy_edb_profile.tsv', 3):
  obj=f'policy.profile.{prf}'
  raw[obj]=('PROFILE', restore_text(detail) if detail else f'PROFILE: {prf}\nAPPLIED USERS: {users if users else "(not applied)"}')
for schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check in iter_fields(out/'02_summary_policies.tsv', 8):
  obj=f'policy.rls.{schemaname}.{tablename}.{policyname}'
  raw[obj]=('RLS POLICY', f'Schema: {schemaname}\nTable: {tablename}\nPolicy: {policyname}\nPermissive: {permissive}\nRoles: {roles}\nCommand: {cmd}\nUsing: {qual}\nWith check: {with_check}')
policy_meta={}
for schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check in iter_fields(out/'02_summary_policies.tsv', 8):
  policy_meta[(schemaname.lower(), tablename.lower(), policyname.lower())]=(permissive, roles, cmd, qual, with_check)
function_meta={}
function_lang={}
for object_type, schema_name, object_name, source_text in iter_fields(out/'02_summary_packages_raw.tsv', 4):
  if (object_type or '').upper() in ('F','P'):
    restored=restore_text(source_text)
    function_meta[(schema_name.lower(), object_name.lower())]=restored
    m=re.search(r'^Language:\s*(.+)$', restored, re.IGNORECASE | re.MULTILINE)
    if m:
      function_lang[(schema_name.lower(), object_name.lower())]=m.group(1).strip().lower()
for object_owner, schema_name, object_name, policy_group, policy_name, pf_owner, package, function_name in iter_fields(out/'02_summary_policies_dbms_rls.tsv', 8):
  obj=f'policy.rls.{schema_name}.{object_name}.{policy_name}'
  lines=[
    f'Owner: {object_owner}',
    f'Schema: {schema_name}',
    f'Object: {object_name}',
    f'Policy group: {policy_group}',
    f'Policy name: {policy_name}',
    f'Function owner: {pf_owner}',
    f'Package: {package}',
    f'Function: {function_name}'
  ]
  meta=policy_meta.get((schema_name.lower(), object_name.lower(), policy_name.lower()))
  if meta:
    permissive, roles, cmd, qual, with_check = meta
    lines.extend([
      '',
      '[Policy rule summary]',
      f'Command: {cmd}',
      f'Permissive: {permissive}',
      f'Roles: {roles}',
      f'Using: {qual}',
      f'With check: {with_check}'
    ])
  function_key=(pf_owner.lower(), function_name.lower())
  function_source=function_meta.get(function_key)
  if function_source:
    lines.extend(['', '[Policy function definition]', function_source])
  language_kw=function_lang.get(function_key)
  if language_kw:
    kw.setdefault(obj,set()).add(language_kw)
  raw[obj]=('RLS POLICY', '\n'.join(lines))

table_lines={}
for s,t,c,ctype,nullok,default in iter_fields(out/'03_detail_table_columns_raw.tsv', 6):
  key=f'{s}.{t}'
  row=f"{c} | {ctype} | {'not null' if (nullok or '').upper()=='NO' else ''} | {default or ''}"
  table_lines.setdefault(key,[]).append(row)

table_raw={}
for s,t,src in iter_fields(out/'03_detail_table_objects_raw.tsv', 3):
  if src:
    table_raw[f'{s}.{t}']=restore_text(src)
for k,v in table_raw.items():
  raw.setdefault(k, ('TABLE COLUMN', v))

idx_to_table={}
for ot,s,t,tr,e in iter_fields(out/'03_detail_expr_raw.tsv', 5):
  if ot=='INDEX EXPRESSION':
    idx_to_table[f'{s}.{tr}']=f'{s}.{t}'

def column_block(table_key):
  rows=table_lines.get(table_key,[])
  if not rows:
    return ''
  head='Column | Type | Nullable | Default\n' + '-'*80
  return f'Object "{table_key}"\n{head}\n' + '\n'.join(rows)

for obj in list(kw.keys()):
  parts=obj.split('.')
  if len(parts)==3:
    table_key=f'{parts[0]}.{parts[1]}'
    if table_key in table_lines and (obj not in raw or raw[obj][0] in ('DEFAULT VALUE','CHECK CONSTRAINT','INDEX EXPRESSION','UNKNOWN')):
      extra=''
      if obj in raw and raw[obj][0] in ('DEFAULT VALUE','CHECK CONSTRAINT','INDEX EXPRESSION'):
        extra='\n\n[Detected Expression Target: '+obj+']\n'+raw[obj][1]
      parent=raw.get(table_key, ('',''))[1]
      coltxt=column_block(table_key)
      if table_key in table_raw:
        base=table_raw[table_key]
      elif parent:
        base=coltxt + ('\n\nDefinition:\n'+parent if coltxt else parent)
      else:
        base=coltxt or ('OBJECT '+table_key)
      raw[obj]=('TABLE COLUMN', base+extra)
  elif len(parts)==2 and obj in idx_to_table and obj in raw and raw[obj][0]=='INDEX EXPRESSION':
    table_key=idx_to_table[obj]
    coltxt=column_block(table_key)
    base=table_raw.get(table_key, coltxt if coltxt else ('OBJECT '+table_key))
    raw[obj]=('INDEX EXPRESSION', base+'\n\n[Detected Expression Target: '+obj+']\n'+raw[obj][1])

objects=[]
for obj in sorted(set(kw) | set(raw)):
  kws=sorted(kw.get(obj,[]), key=len, reverse=True)
  typ,src = raw.get(obj, ('UNKNOWN','(source not available)'))
  sid=slug(obj)
  file_name=f'src-{sid}.html'
  kw_label=', '.join(kws) if kws else 'no keyword'
  kw_badge = '<span class="badge badge-none">no keyword</span>' if (not kws or kws==['(no keyword)']) else html.escape(kw_label)
  highlighted = highlight_text(src, kws)
  obj_html = (
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>'+html.escape(obj)+' source</title>'
    '<style>body{font-family:Arial,sans-serif;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:18px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:14px}h3{margin:0 0 8px}.source-keywords{margin:0 0 10px;font-size:14px;color:#1f2937}.source-keywords b{font-weight:800}pre{margin:0;background:#111827;color:#e5e7eb;padding:12px;border-radius:8px;overflow:auto;white-space:pre;tab-size:4;line-height:1.4;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}.kw{color:#f59e0b;font-weight:700}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}.badge-none{color:#374151;background:#e5e7eb;border:1px solid #d1d5db}</style></head><body><div class="container">'
    '<div class="card"><h3>Source (keyword highlighted)</h3><p class="source-keywords"><b>Keywords:</b> '+kw_badge+'</p><pre>'+highlighted+'</pre></div>'
    '</div></body></html>'
  )
  (src_dir/file_name).write_text(obj_html, encoding='utf-8')
  objects.append((obj, full_type(typ), kws, file_name))

source_total=len(objects)
parts=['<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Source Navigator</title><style>body{font-family:Arial,sans-serif;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:24px 36px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:16px;margin-bottom:14px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #d1d5db;padding:8px}th{background:#f3f4f6}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}a{color:#1d4ed8}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}.badge-none{color:#374151;background:#e5e7eb;border:1px solid #d1d5db}.modal-backdrop{position:fixed;inset:0;background:rgba(15,23,42,.62);display:none;align-items:center;justify-content:center;padding:18px;z-index:9999}.modal-backdrop.show{display:flex}.modal-panel{width:min(980px,100%);background:#fff;border:1px solid #d1d5db;border-radius:14px;box-shadow:0 24px 60px rgba(15,23,42,.28);display:flex;flex-direction:column}.modal-header{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:12px 14px;border-bottom:1px solid #e5e7eb}.modal-title-wrap{display:flex;align-items:center;gap:8px;min-width:0}.modal-header h3{margin:0;font-size:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.modal-type{display:inline-flex;align-items:center;padding:3px 8px;border-radius:999px;border:1px solid #93c5fd;background:#eff6ff;color:#1e3a8a;font-size:12px;font-weight:800}.modal-close{border:1px solid #cbd5e1;background:#fff;border-radius:8px;padding:6px 10px;font-size:12px;cursor:pointer}.modal-body{padding:14px;max-height:calc(20 * 1.45em + 144px);overflow:auto}.modal-body iframe{width:100%;height:calc(20 * 1.45em + 96px);border:1px solid #d1d5db;border-radius:10px;background:#fff}</style></head><body><div class="container"><h1>Source Navigator ('+str(source_total)+')</h1>']
parts.append('<div class="card"><p><a href="'+html.escape(precheck_name)+'">Back to precheck</a></p><p>Click an object name to open the detail modal. (scroll appears after about 10 lines)</p><table><tr><th>Object</th><th>Type</th><th>Detected Keywords</th></tr>')
if objects:
  for obj, typ, kws, file_name in objects:
    if kws and kws != ['(no keyword)']:
      kw_cell=html.escape(', '.join(kws))
    else:
      kw_cell='<span class="badge badge-none">no keyword</span>'
    parts.append('<tr><td><a href="'+html.escape(src_dir.name)+'/'+html.escape(file_name)+'"><code>'+html.escape(obj)+'</code></a></td><td>'+html.escape(typ)+'</td><td>'+kw_cell+'</td></tr>')
else:
  parts.append('<tr><td colspan="3">No source</td></tr>')
parts.append('</table></div><div class="modal-backdrop" id="source-detail-modal" aria-hidden="true"><div class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="source-detail-title"><div class="modal-header"><div class="modal-title-wrap"><h3 id="source-detail-title">Object detail</h3><span class="modal-type" id="source-detail-type"></span></div><button type="button" class="modal-close" id="source-detail-close">Close</button></div><div class="modal-body"><iframe id="source-detail-frame" title="Object detail" loading="lazy"></iframe></div></div></div><script>(function(){const modalRoot=document.getElementById("source-detail-modal");const modalFrame=document.getElementById("source-detail-frame");const modalTitle=document.getElementById("source-detail-title");const modalType=document.getElementById("source-detail-type");const closeBtn=document.getElementById("source-detail-close");if(!modalRoot||!modalFrame||!modalTitle||!modalType||!closeBtn){return;}function isSourceObjectLink(a){const h=(a.getAttribute("href")||"").trim().toLowerCase();if(!h||h.startsWith("#")||h.startsWith("javascript:"))return false;return /(^|\\/)src-[^\\/]+\\.html(?:[?#].*)?$/.test(h);}function detectTypeFromRow(anchor){const row=anchor.closest("tr");if(!row){return "";}const known=["FUNCTION","PROCEDURE","VIEW","TABLE COLUMN","TABLE","DEFAULT VALUE","CHECK CONSTRAINT","INDEX EXPRESSION","PROFILE","RLS POLICY","RESOURCE GROUP","DBLINK","PACKAGE","UNKNOWN"];const cells=[...row.querySelectorAll("td,th")].map((cell)=>cell.textContent.replace(/\\s+/g," ").trim().toUpperCase());for(const k of known){if(cells.some((v)=>v===k||v.includes(k))){return k;}}return "";}function openModal(anchor){const codeNode=anchor.querySelector("code");modalTitle.textContent=codeNode&&codeNode.textContent?codeNode.textContent.trim():"Object detail";const objectType=detectTypeFromRow(anchor);modalType.textContent=objectType||"-";modalFrame.setAttribute("src",anchor.getAttribute("href"));modalRoot.classList.add("show");modalRoot.setAttribute("aria-hidden","false");document.body.style.overflow="hidden";}function closeModal(){modalRoot.classList.remove("show");modalRoot.setAttribute("aria-hidden","true");modalFrame.setAttribute("src","about:blank");document.body.style.overflow="";}document.addEventListener("click",function(e){const a=e.target.closest("a[href]");if(!a)return;if(e.defaultPrevented||e.button!==0||e.metaKey||e.ctrlKey||e.shiftKey||e.altKey)return;if(!isSourceObjectLink(a))return;e.preventDefault();openModal(a);});closeBtn.addEventListener("click",closeModal);modalRoot.addEventListener("click",function(e){if(e.target===modalRoot){closeModal();}});document.addEventListener("keydown",function(e){if(e.key==="Escape"&&modalRoot.classList.contains("show")){closeModal();}});})();</script></div></body></html>')
target.write_text('\n'.join(parts),encoding='utf-8')
PY
  then
    PY_RENDERED=1
  else
    echo "[WARN] Python renderer failed; falling back to shell renderer." >&2
  fi
fi
if [[ "$PY_RENDERED" -eq 0 ]]; then
  mkdir -p "$SOURCE_DIR_PATH"
  RAW_MERGED="$OUT_DIR/.raw_merged.tsv"
  RAW_AGG="$OUT_DIR/.raw_agg.tsv"
  KW_MERGED="$OUT_DIR/.kw_merged.tsv"
  KW_AGG="$OUT_DIR/.kw_agg.tsv"
  TABLE_RAW_AGG="$OUT_DIR/.table_raw_agg.tsv"
  COLUMN_LIST_AGG="$OUT_DIR/.column_list_agg.tsv"
  IDX_TABLE_MAP="$OUT_DIR/.idx_table_map.tsv"
  IDX_ROWS="$OUT_DIR/.source_index_rows.html"

  : > "$RAW_MERGED"
  : > "$KW_MERGED"

  awk -F $'	' 'NR>1{print $2"."$3"	"$1"	"$4}' "$OUT_DIR/02_summary_packages_raw.tsv" >> "$RAW_MERGED"
  awk -F $'	' 'NR>1{print $2"."$3"	"$1"	"$4}' "$OUT_DIR/03_detail_keywords_raw.tsv" >> "$RAW_MERGED"
  awk -F $'	' 'NR>1{obj=($1=="INDEX EXPRESSION"?$2"."$4:$2"."$3"."$4); print obj"	"$1"	"$5}' "$OUT_DIR/03_detail_expr_raw.tsv" >> "$RAW_MERGED"
  awk -F $'\t' 'NR>1{print $1"."$2"\tTABLE COLUMN\t"$3}' "$OUT_DIR/03_detail_table_objects_raw.tsv" >> "$RAW_MERGED"

  awk -F $'	' 'NR>1{users=($3==""?"(not applied)":$3); detail=($2==""?"PROFILE: "$1"\\nAPPLIED USERS: "users:$2); printf "policy.profile.%s\tPROFILE\t%s\n", $1, detail}' "$OUT_DIR/04_policy_edb_profile.tsv" >> "$RAW_MERGED"
  awk -F $'\t' 'NR>1{printf "policy.rls.%s.%s.%s\tRLS POLICY\tSchema: %s\\nTable: %s\\nPolicy: %s\\nPermissive: %s\\nRoles: %s\\nCommand: %s\\nUsing: %s\\nWith check: %s\n", $1,$2,$3,$1,$2,$3,$4,$5,$6,$7,$8}' "$OUT_DIR/02_summary_policies.tsv" >> "$RAW_MERGED"
  awk -F $'\t' '
    ARGIND==1 && FNR>1{
      key=tolower($1) SUBSEP tolower($2) SUBSEP tolower($3)
      pm[key]="Command: "$6"\\nPermissive: "$4"\\nRoles: "$5"\\nUsing: "$7"\\nWith check: "$8
      next
    }
    ARGIND==2 && FNR>1{
      if($1=="F" || $1=="P"){
        fk=tolower($2) SUBSEP tolower($3)
        fs[fk]=$4
      }
      next
    }
    ARGIND==3 && FNR>1{
      obj="policy.rls."$2"."$3"."$5
      key=tolower($2) SUBSEP tolower($3) SUBSEP tolower($5)
      fkey=tolower($6) SUBSEP tolower($8)
      detail="Owner: "$1"\\nSchema: "$2"\\nObject: "$3"\\nPolicy group: "$4"\\nPolicy name: "$5"\\nFunction owner: "$6"\\nPackage: "$7"\\nFunction: "$8
      if(pm[key]!="") detail=detail"\\n\\n[Policy rule summary]\\n"pm[key]
      if(fs[fkey]!="") detail=detail"\\n\\n[Policy function definition]\\n"fs[fkey]
      printf "%s\tRLS POLICY\t%s\n", obj, detail
    }
  ' "$OUT_DIR/02_summary_policies.tsv" "$OUT_DIR/02_summary_packages_raw.tsv" "$OUT_DIR/02_summary_policies_dbms_rls.tsv" >> "$RAW_MERGED"

  awk -F $'	' 'NR>1{print $2"."$3"	"$4}' "$OUT_DIR/02_summary_packages.tsv" >> "$KW_MERGED"
  awk -F $'	' 'NR>1{print $2"."$3"	"$4}' "$OUT_DIR/03_detail_keywords.tsv" >> "$KW_MERGED"
  awk -F $'	' 'NR>1{obj=($1=="INDEX EXPRESSION"?$2"."$4:$2"."$3"."$4); print obj"	"$5}' "$OUT_DIR/03_detail_expr_keywords.tsv" >> "$KW_MERGED"
  awk -F $'\t' 'NR>1{print $1"."$2"\t"$4}' "$OUT_DIR/03_detail_datatypes_tables.tsv" >> "$KW_MERGED"
  awk -F $'\t' 'NR>1{obj="policy.rls."$2"."$3"."$5; fn=tolower($8); pkg=tolower($7); if(fn!="") print obj"\t"fn; if(pkg!=""&&fn!="") print obj"\t"pkg"."fn}' "$OUT_DIR/02_summary_policies_dbms_rls.tsv" >> "$KW_MERGED"

  awk -F $'	' '!seen[$1]++{print $1"	"$2"	"$3}' "$RAW_MERGED" > "$RAW_AGG"
  awk -F $'	' '{k=$1; t=tolower($2); if(t=="") t="(no keyword)"; if(!seen[k SUBSEP t]++){a[k]=(a[k]?a[k]", ":"")t}} END{for(k in a) print k"	"a[k]}' "$KW_MERGED" > "$KW_AGG"
  awk -F $'\t' 'NR>1{print $1"."$2"\t"$3}' "$OUT_DIR/03_detail_table_objects_raw.tsv" > "$TABLE_RAW_AGG"
  awk -F $'	' 'NR>1{k=$1"."$2; line=$3" | "$4" | "(($5 ~ /^(NO|no)$/)?"not null":"")" | "$6; a[k]=(a[k]?a[k]"\n":"")line} END{for(k in a) print k"\t""Object \""k"\"\nColumn | Type | Nullable | Default\n--------------------------------------------------------------------------------\n"a[k]}' "$OUT_DIR/03_detail_table_columns_raw.tsv" > "$COLUMN_LIST_AGG"
  awk -F $'\t' 'NR>1 && $1=="INDEX EXPRESSION"{print $2"."$4"\t"$2"."$3}' "$OUT_DIR/03_detail_expr_raw.tsv" > "$IDX_TABLE_MAP"

  : > "$IDX_ROWS"
  SOURCE_TOTAL=0
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    SOURCE_TOTAL=$((SOURCE_TOTAL+1))
    sid=$(printf '%s' "$obj" | tr -c '[:alnum:]_.-' '_')
    if [[ ${#sid} -gt 120 ]]; then
      if command -v sha1sum >/dev/null 2>&1; then
        sid_hash=$(printf '%s' "$obj" | sha1sum | awk '{print substr($1,1,12)}')
      else
        sid_hash=$(printf '%s' "$obj" | cksum | awk '{print $1}')
      fi
      sid="${sid:0:100}_${sid_hash}"
    fi
    page="$SOURCE_DIR_PATH/src-$sid.html"

    typ=$(awk -F $'	' -v o="$obj" '$1==o{print $2; exit}' "$RAW_AGG")
    [ -n "$typ" ] || typ="UNKNOWN"
    src=$(awk -F $'	' -v o="$obj" '$1==o{print $3; exit}' "$RAW_AGG")
    [ -n "$src" ] || src='(source not available)'
    kws=$(awk -F $'	' -v o="$obj" '$1==o{print $2; exit}' "$KW_AGG")
    [ -n "$kws" ] || kws='no keyword'

    # TABLE/VIEW COLUMN + EXPRESSION fallback enrichment
    table_key=$(printf '%s' "$obj" | awk -F'.' 'NF>=3{print $1"."$2}')
    table_src=""
    if [[ -n "$table_key" ]]; then
      table_src=$(awk -F $'	' -v k="$table_key" '$1==k{print $2; exit}' "$TABLE_RAW_AGG")
      col_src=$(awk -F $'	' -v k="$table_key" '$1==k{print $2; exit}' "$COLUMN_LIST_AGG")
      parent_src=$(awk -F $'	' -v k="$table_key" '$1==k{print $3; exit}' "$RAW_AGG")
      if [[ -z "$table_src" && -n "$col_src" && -n "$parent_src" ]]; then
        table_src="$col_src\n\nDefinition:\n$parent_src"
      elif [[ -z "$table_src" && -n "$col_src" ]]; then
        table_src="$col_src"
      fi
    fi

    if [[ "$typ" == "INDEX EXPRESSION" ]]; then
      idx_table=$(awk -F $'	' -v k="$obj" '$1==k{print $2; exit}' "$IDX_TABLE_MAP")
      if [[ -n "$idx_table" ]]; then
        table_src=$(awk -F $'	' -v k="$idx_table" '$1==k{print $2; exit}' "$TABLE_RAW_AGG")
        [[ -n "$table_src" ]] || table_src=$(awk -F $'	' -v k="$idx_table" '$1==k{print $2; exit}' "$COLUMN_LIST_AGG")
      fi
    fi

    if [[ -n "$table_src" ]]; then
      if [[ "$typ" == "UNKNOWN" ]]; then
        typ="TABLE COLUMN"
        src="$table_src"
      elif [[ "$typ" == "DEFAULT VALUE" || "$typ" == "CHECK CONSTRAINT" || "$typ" == "INDEX EXPRESSION" ]]; then
        src="$table_src

[Detected Expression Target: ${obj}]
$src"
      fi
    fi

    case "$typ" in
      F) typ="FUNCTION" ;;
      P) typ="PROCEDURE" ;;
      V) typ="VIEW" ;;
      T) typ="TABLE COLUMN" ;;
    esac
    esc_obj=$(printf '%s' "$obj" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    esc_typ=$(printf '%s' "$typ" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    esc_kws=$(printf '%s' "$kws" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    esc_src=$(printf '%s' "$src" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    esc_src=$(printf '%s' "$esc_src" | awk '{gsub(/\\n/,"\n"); print}')
    if [[ -n "$kws" && "$kws" != "no keyword" ]]; then
      IFS=',' read -r -a _kw_arr <<< "$kws"
      for _kw in "${_kw_arr[@]}"; do
        _kw=$(printf '%s' "$_kw" | sed -e 's/^ *//' -e 's/ *$//')
        _kw=$(printf '%s' "$_kw" | tr '[:upper:]' '[:lower:]')
        [[ -n "$_kw" && "$_kw" != "(no keyword)" ]] || continue
        esc_src=$(awk -v src="$esc_src" -v kw="$_kw" 'BEGIN{if(kw==""){print src; exit} lsrc=tolower(src); lkw=tolower(kw); out=""; pos=1; klen=length(kw); while(1){tmp=substr(lsrc,pos); idx=index(tmp,lkw); if(idx==0) break; abs=pos+idx-1; out=out substr(src,pos,abs-pos) "<span class=\"kw\">" substr(src,abs,klen) "</span>"; pos=abs+klen;} out=out substr(src,pos); print out}')
      done
    fi

    cat > "$page" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${esc_obj} source</title>
<style>body{font-family:Arial,sans-serif;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:18px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:14px}h3{margin:0 0 8px}.source-keywords{margin:0 0 10px;font-size:14px;color:#1f2937}.source-keywords b{font-weight:800}pre{margin:0;background:#111827;color:#e5e7eb;padding:12px;border-radius:8px;overflow:auto;white-space:pre;tab-size:4;line-height:1.4;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}.kw{color:#f59e0b;font-weight:700}.badge-none{color:#374151;background:#e5e7eb;border:1px solid #d1d5db;display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}</style></head><body><div class="container">
<div class="card"><h3>Source (keyword highlighted)</h3><p class="source-keywords"><b>Keywords:</b> ${esc_kws}</p><pre>${esc_src}</pre></div>
</div></body></html>
EOF

    printf '<tr><td><a href="%s/src-%s.html"><code>%s</code></a></td><td>%s</td><td>%s</td></tr>
' "$SOURCE_DIR_BASENAME" "$sid" "$esc_obj" "$esc_typ" "$esc_kws" >> "$IDX_ROWS"
  done < <((cut -f1 "$RAW_AGG"; cut -f1 "$KW_AGG") | sort -u)

  cat > "$SOURCE_HTML_PATH" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Source Navigator</title>
<style>body{font-family:Arial,sans-serif;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:24px 36px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:16px;margin-bottom:14px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #d1d5db;padding:8px}th{background:#f3f4f6}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}a{color:#1d4ed8}.modal-backdrop{position:fixed;inset:0;background:rgba(15,23,42,.62);display:none;align-items:center;justify-content:center;padding:18px;z-index:9999}.modal-backdrop.show{display:flex}.modal-panel{width:min(980px,100%);background:#fff;border:1px solid #d1d5db;border-radius:14px;box-shadow:0 24px 60px rgba(15,23,42,.28);display:flex;flex-direction:column}.modal-header{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:12px 14px;border-bottom:1px solid #e5e7eb}.modal-title-wrap{display:flex;align-items:center;gap:8px;min-width:0}.modal-header h3{margin:0;font-size:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.modal-type{display:inline-flex;align-items:center;padding:3px 8px;border-radius:999px;border:1px solid #93c5fd;background:#eff6ff;color:#1e3a8a;font-size:12px;font-weight:800}.modal-close{border:1px solid #cbd5e1;background:#fff;border-radius:8px;padding:6px 10px;font-size:12px;cursor:pointer}.modal-body{padding:14px;max-height:calc(20 * 1.45em + 144px);overflow:auto}.modal-body iframe{width:100%;height:calc(20 * 1.45em + 96px);border:1px solid #d1d5db;border-radius:10px;background:#fff}</style></head><body><div class="container">
<h1>Source Navigator (${SOURCE_TOTAL})</h1>
<div class="card"><p><a href="${HTML_BASENAME}">Back to precheck</a></p><p>Click an object name to open the detail modal. (scroll appears after about 10 lines)</p>
<table><tr><th>Object</th><th>Type</th><th>Detected Keywords</th></tr>
$( [ -s "$IDX_ROWS" ] && cat "$IDX_ROWS" || echo '<tr><td colspan="3">No source</td></tr>' )
</table></div><div class="modal-backdrop" id="source-detail-modal" aria-hidden="true"><div class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="source-detail-title"><div class="modal-header"><div class="modal-title-wrap"><h3 id="source-detail-title">Object detail</h3><span class="modal-type" id="source-detail-type"></span></div><button type="button" class="modal-close" id="source-detail-close">Close</button></div><div class="modal-body"><iframe id="source-detail-frame" title="Object detail" loading="lazy"></iframe></div></div></div><script>(function(){const modalRoot=document.getElementById("source-detail-modal");const modalFrame=document.getElementById("source-detail-frame");const modalTitle=document.getElementById("source-detail-title");const modalType=document.getElementById("source-detail-type");const closeBtn=document.getElementById("source-detail-close");if(!modalRoot||!modalFrame||!modalTitle||!modalType||!closeBtn){return;}function isSourceObjectLink(a){const h=(a.getAttribute("href")||"").trim().toLowerCase();if(!h||h.startsWith("#")||h.startsWith("javascript:"))return false;return /(^|\/)src-[^\/]+\.html(?:[?#].*)?$/.test(h);}function detectTypeFromRow(anchor){const row=anchor.closest("tr");if(!row){return "";}const known=["FUNCTION","PROCEDURE","VIEW","TABLE COLUMN","TABLE","DEFAULT VALUE","CHECK CONSTRAINT","INDEX EXPRESSION","PROFILE","RLS POLICY","RESOURCE GROUP","DBLINK","PACKAGE","UNKNOWN"];const cells=[...row.querySelectorAll("td,th")].map((cell)=>cell.textContent.replace(/\s+/g," ").trim().toUpperCase());for(const k of known){if(cells.some((v)=>v===k||v.includes(k))){return k;}}return "";}function openModal(anchor){const codeNode=anchor.querySelector("code");modalTitle.textContent=codeNode&&codeNode.textContent?codeNode.textContent.trim():"Object detail";const objectType=detectTypeFromRow(anchor);modalType.textContent=objectType||"-";modalFrame.setAttribute("src",anchor.getAttribute("href"));modalRoot.classList.add("show");modalRoot.setAttribute("aria-hidden","false");document.body.style.overflow="hidden";}function closeModal(){modalRoot.classList.remove("show");modalRoot.setAttribute("aria-hidden","true");modalFrame.setAttribute("src","about:blank");document.body.style.overflow="";}document.addEventListener("click",function(e){const a=e.target.closest("a[href]");if(!a)return;if(e.defaultPrevented||e.button!==0||e.metaKey||e.ctrlKey||e.shiftKey||e.altKey)return;if(!isSourceObjectLink(a))return;e.preventDefault();openModal(a);});closeBtn.addEventListener("click",closeModal);modalRoot.addEventListener("click",function(e){if(e.target===modalRoot){closeModal();}});document.addEventListener("keydown",function(e){if(e.key==="Escape"&&modalRoot.classList.contains("show")){closeModal();}});})();</script></div></body></html>
EOF

  purge_files "$RAW_MERGED" "$RAW_AGG" "$KW_MERGED" "$KW_AGG" "$TABLE_RAW_AGG" "$COLUMN_LIST_AGG" "$IDX_TABLE_MAP" "$IDX_ROWS"
fi
[[ -f "$SOURCE_HTML_PATH" ]] || echo '<!doctype html><html><body><h1>Source navigator was not generated.</h1><p>Source payload is empty or rendering step failed.</p></body></html>' > "$SOURCE_HTML_PATH"

default_row_if_empty(){ [[ -s "$1" ]] && cat "$1" || printf '<tr><td colspan="%s">&#45936;&#51060;&#53552;&#44032; &#50630;&#49845;&#45768;&#45796;.</td></tr>' "$2"; }
syn_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s.%s</code></td><td><code>%s.%s</code></td><td><span class=\"badge badge-low\">&#45230;&#51020;</span></td></tr>\n",$1,$2,$3,$4}' "$OUT_DIR/02_summary_synonyms.tsv")
rls_pg_rows=$(awk -F $'\t' 'NR>1{obj="policy.rls."$1"."$2"."$3; id=obj; gsub(/[^[:alnum:]_.-]/,"_",id); printf "<tr><td><code>%s.%s</code></td><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td>%s</td><td><span class=\"badge badge-low\">&#45230;&#51020;</span></td></tr>\n",$1,$2,ENVIRON["SOURCE_DIR_BASENAME"],id,$3,$6}' "$OUT_DIR/02_summary_policies.tsv")
rls_dbms_rows=$(awk -F $'\t' 'NR>1{obj="policy.rls."$2"."$3"."$5; id=obj; gsub(/[^[:alnum:]_.-]/,"_",id); printf "<tr><td><code>%s.%s</code></td><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td>%s.%s</td><td><span class=\"badge badge-low\">&#45230;&#51020;</span></td></tr>\n",$2,$3,ENVIRON["SOURCE_DIR_BASENAME"],id,$5,$7,$8}' "$OUT_DIR/02_summary_policies_dbms_rls.tsv")
rls_rows_html="${rls_pg_rows}${rls_dbms_rows}"
redaction_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s.%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td><span class=\"badge badge-high\">&#51473;&#44036;</span></td></tr>\n",$1,$2,$3,$4}' "$OUT_DIR/02_summary_redaction.tsv")
profile_rows_html=$(awk -F $'\t' 'NR>1{users=($3==""?"(&#45936;&#51060;&#53552; &#50630;&#51020)":$3); obj="policy.profile."$1; id=obj; gsub(/[^[:alnum:]_.-]/,"_",id); printf "<tr><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td><td><span class=\"badge badge-low\">&#45230;&#51020;</span></td></tr>\n",ENVIRON["SOURCE_DIR_BASENAME"],id,$1,users}' "$OUT_DIR/04_policy_edb_profile.tsv")
rg_rows_html=$(awk -F $'\t' 'NR>1{users=($4==""?"(&#45936;&#51060;&#53552; &#50630;&#51020)":$4); printf "<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td><code>%s</code></td><td><span class=\"badge badge-low\">&#45230;&#51020;</span></td></tr>\n",$1,$2,$3,users}' "$OUT_DIR/04_policy_edb_resource_group.tsv")
dblink_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s</code></td><td>%s</td><td><code>%s</code></td><td><span class=\"badge badge-low\">&#45230;&#51020;</span></td></tr>\n",$1,$5,$6}' "$OUT_DIR/04_policy_edb_dblink.tsv")

progress_step "Rendering prototype-based main report"
cat > "$HTML_PATH" <<HTML
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>EPAS PostgreSQL &#49324;&#51204; &#51652;&#45800; &#47532;&#54252;&#53944; - ${DBNAME}</title>
<style>
:root{--bg-0:#f4f8ff;--bg-1:#e6f0ff;--ink-0:#0b1020;--ink-1:#22304a;--ink-2:#5f6f8f;--surface:rgba(255,255,255,.9);--stroke:rgba(17,31,62,.14);--shadow:0 20px 50px rgba(19,38,82,.12);--critical:#ef4444;--warning:#f59e0b;--safe:#10b981;--none:#94a3b8}
*{box-sizing:border-box}
body{margin:0;color:var(--ink-0);font-family:"Pretendard","Noto Sans KR","Segoe UI",Arial,sans-serif;background:radial-gradient(circle at 10% 0,#dceeff 0,rgba(220,238,255,0) 35%),radial-gradient(circle at 100% 10%,#ddfff4 0,rgba(221,255,244,0) 38%),linear-gradient(180deg,var(--bg-0),var(--bg-1))}
.container{max-width:1320px;margin:0 auto;padding:28px 28px 42px}
.hero{border:1px solid var(--stroke);background:var(--surface);border-radius:22px;padding:20px 22px;box-shadow:var(--shadow);margin-bottom:14px}
.hero h1{margin:0;font-size:30px;line-height:1.2}.hero p{margin:8px 0 0;color:var(--ink-1);font-size:14px}
.card{border:1px solid var(--stroke);background:var(--surface);border-radius:20px;padding:16px;box-shadow:0 10px 24px rgba(19,38,82,.08);margin-bottom:14px}
.h2{margin:0;font-size:20px}.muted{margin:8px 0 0;color:var(--ink-1);font-size:14px}
.controls{margin-top:12px;display:flex;flex-wrap:wrap;gap:8px}.chip{border:1px solid #cfd9f0;background:#fff;border-radius:999px;padding:8px 14px;font-size:12px;font-weight:800;color:#2b3f67;cursor:pointer}
.chip.active{background:linear-gradient(120deg,rgba(15,111,255,.14),rgba(0,179,164,.14));border-color:rgba(15,111,255,.55);color:#0e3f86}
.grid{margin-top:14px;display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:12px}.span12{grid-column:span 12}.span6{grid-column:span 6}
.bars{margin-top:10px;display:grid;grid-template-columns:repeat(auto-fit,minmax(182px,1fr));gap:12px;align-items:end;min-height:182px}
.bar-item{border:0;background:transparent;padding:0;text-align:center;cursor:pointer}.bar-wrap{height:148px;display:flex;align-items:end;justify-content:center;border-radius:14px;background:linear-gradient(180deg,rgba(203,218,242,.52),rgba(203,218,242,.38));border:1px solid rgba(99,122,162,.22);padding:8px;outline:2px solid transparent;position:relative}
.bar-item.active .bar-wrap{outline-color:rgba(15,111,255,.55)}.bar-stack{width:60px;height:126px;position:relative;display:flex;align-items:end;justify-content:center}
.bar-total{position:absolute;bottom:0;left:50%;transform:translateX(-50%);width:56px;border-radius:10px 10px 4px 4px;height:126px;background:linear-gradient(180deg,rgba(15,111,255,.38),rgba(0,179,164,.38))}
.bar-impact{position:absolute;bottom:0;left:50%;transform:translateX(-50%);width:42px;border-radius:8px 8px 3px 3px;height:max(8px,calc(var(--ratio-impact)*126px));background:linear-gradient(180deg,#f97316,#ef4444)}
.impact-label{position:absolute;left:50%;transform:translateX(-50%);bottom:max(12px,calc(var(--ratio-impact,0)*126px - 16px));white-space:nowrap;line-height:1;font-weight:900;font-size:11px;color:#143968;z-index:6;-webkit-text-stroke:.35px rgba(255,255,255,.92);text-shadow:0 0 1px rgba(255,255,255,.9),0 1px 1px rgba(15,23,42,.08)}
.bar-label{margin-top:8px;font-size:11px;color:var(--ink-1);font-weight:800;letter-spacing:.02em}.bar-count{margin-top:2px;font-size:10px;color:var(--ink-2);font-weight:700}
.keyword-list{margin-top:10px;display:grid;gap:9px}.keyword-row{display:grid;grid-template-columns:34px minmax(190px,2.2fr) minmax(120px,3fr) 46px;gap:8px;align-items:center;font-size:13px;color:var(--ink-1)}.keyword-rank{text-align:center;font-size:12px;font-weight:800;color:var(--ink-2)}.keyword-label{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}.keyword-value{text-align:right;font-weight:700;color:var(--ink-1)}
.keyword-track{height:10px;border-radius:999px;background:rgba(203,218,242,.46);overflow:hidden}.keyword-fill{height:100%;border-radius:inherit;background:linear-gradient(90deg,#1e57ff,#31d2bd);width:calc(var(--ratio)*100%)}
.impact-wrap{margin-top:10px;display:grid;grid-template-columns:180px 1fr;gap:12px;align-items:center}.donut{width:180px;aspect-ratio:1;border-radius:50%;position:relative}.donut::after{content:"";position:absolute;inset:25px;background:#fff;border-radius:50%;box-shadow:inset 0 0 0 1px rgba(17,31,62,.08)}
.donut-center{position:absolute;inset:0;display:grid;place-items:center;z-index:1;font-size:22px;font-weight:800;color:#0d3370}.legend{display:grid;gap:8px}.legend-item{display:flex;justify-content:space-between;align-items:center;background:rgba(255,255,255,.65);border:1px solid var(--stroke);border-radius:12px;padding:8px 10px;font-size:13px}
.dot{width:10px;height:10px;border-radius:50%;display:inline-block}.tag{display:inline-flex;align-items:center;gap:6px;font-weight:700}
.summary-pane{display:flex;justify-content:center}
.summary-subcard{width:min(100%,500px);background:rgba(255,255,255,.88);border:1px solid var(--stroke);border-radius:16px;padding:12px;box-shadow:0 8px 18px rgba(19,38,82,.07)}
.summary-subcard h3{margin:0 0 8px}
.summary-subcard .keyword-list,.summary-subcard .impact-wrap{margin-top:8px}
.impact-subcard{width:min(100%,470px)}
.empty{display:none;margin-top:12px;border:1px dashed rgba(17,31,62,.32);border-radius:20px;background:rgba(255,255,255,.82);padding:18px}.empty.show{display:block}
h2{margin:0 0 10px;font-size:20px}h3{margin:16px 0 8px;font-size:17px;color:var(--ink-1)}
table{width:100%;border-collapse:collapse;background:rgba(255,255,255,.92);border-radius:12px;overflow:hidden}
th,td{border:1px solid #d7dfef;padding:8px 10px;font-size:14px;vertical-align:top}
th{background:#eef3ff;text-align:left;color:#1f3356}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:800}
.badge-bad{color:#991b1b;background:#fee2e2;border:1px solid #fecaca}.badge-high{color:#92400e;background:#fef3c7;border:1px solid #fcd34d}.badge-low{color:#065f46;background:#d1fae5;border:1px solid #a7f3d0}.badge-none{color:#374151;background:#e5e7eb;border:1px solid #d1d5db}
code{background:#f3f6ff;padding:2px 5px;border-radius:6px}a{color:#1b4fc7}.sub-link{margin:0 0 10px;font-size:14px;color:var(--ink-1)}
.detail-guide{margin:2px 0 0;color:#4f648e;font-size:13px;font-weight:800}
.details-layout{margin-top:10px;display:grid;grid-template-columns:220px minmax(0,1fr);gap:12px;align-items:start}
.detail-shell{background:rgba(255,255,255,.88);border:1px solid var(--stroke);border-radius:16px;padding:12px;box-shadow:0 8px 18px rgba(19,38,82,.07)}
.detail-chip-col{display:flex;flex-direction:column;gap:8px}
.detail-chip-col .chip{width:100%;text-align:left}
.detail-content h3{margin-top:0}
.modal-backdrop{position:fixed;inset:0;background:rgba(15,23,42,.62);display:none;align-items:center;justify-content:center;padding:18px;z-index:9999}
.modal-backdrop.show{display:flex}
.modal-panel{width:min(980px,100%);background:#fff;border:1px solid #d1d5db;border-radius:16px;box-shadow:0 24px 60px rgba(15,23,42,.28);display:flex;flex-direction:column}
.modal-header{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:12px 14px;border-bottom:1px solid #e5e7eb}
.modal-title-wrap{display:flex;align-items:center;gap:8px;min-width:0}
.modal-header h3{margin:0;font-size:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.modal-type{display:inline-flex;align-items:center;padding:3px 8px;border-radius:999px;border:1px solid #93c5fd;background:#eff6ff;color:#1e3a8a;font-size:12px;font-weight:800}
.modal-close{border:1px solid #cbd5e1;background:#fff;border-radius:8px;padding:6px 10px;font-size:12px;cursor:pointer}
.modal-body{padding:14px;max-height:calc(20 * 1.45em + 144px);overflow:auto}
.modal-body iframe{width:100%;height:calc(20 * 1.45em + 96px);border:1px solid #d1d5db;border-radius:10px;background:#fff}
@media (max-width:900px){.container{padding:16px}.hero h1{font-size:24px}th,td{font-size:13px;padding:7px 8px}.span6{grid-column:span 12}.impact-wrap{grid-template-columns:1fr;justify-items:center}.keyword-row{grid-template-columns:28px minmax(130px,2fr) minmax(90px,3fr) 38px}.summary-subcard,.impact-subcard{width:100%}.details-layout{grid-template-columns:1fr}}
</style></head><body><div class="container">
<div class="hero"><h1>EPAS PostgreSQL &#49324;&#51204; &#51652;&#45800; &#47532;&#54252;&#53944;</h1><p>DB &#51060;&#47492;: <strong>${DBNAME}</strong></p><p>O/S &#51221;&#48372;: <strong>${OS_INFO}</strong></p><p>EPAS &#48260;&#51204;: <strong>${EPAS_VERSION_INFO}</strong></p></div>
<div class="card">
  <h2 class="h2">Summary</h2>
  <div class="controls" id="type-chips"></div>
  <div class="grid" id="viz-grid">
    <div class="span12"><div class="bars" id="object-bars"></div></div>
    <div class="span6 summary-pane"><div class="summary-subcard"><h3 style="margin-top:0">&#53412;&#50892;&#46300; &#49345;&#50948; 10&#44060;</h3><div class="keyword-list" id="keyword-list"></div></div></div>
    <div class="span6 summary-pane"><div class="summary-subcard impact-subcard"><h3 style="margin-top:0">&#50689;&#54693;&#46020; &#54140;&#49468;&#53944;</h3><div class="impact-wrap"><div class="donut" id="impact-donut"><div class="donut-center" id="impact-total">0</div></div><div class="legend" id="impact-legend"></div></div></div></div>
  </div>
  <div class="empty" id="empty-state"><h3>USER_CREATED &#44061;&#52404;&#44032; &#50630;&#49845;&#45768;&#45796;</h3><p>&#49884;&#44033;&#54868;&#50640; &#54596;&#50836;&#54620; &#45936;&#51060;&#53552;&#44032; &#50630;&#50612;&#46020; &#47532;&#54252;&#53944; &#49373;&#49457;&#51008; &#51221;&#49345;&#51201;&#51004;&#47196; &#50756;&#47308;&#46121;&#45768;&#45796;.</p></div>
</div>
<div class="card"><h2>Details</h2><p class="sub-link">Source navigator: <a href="${SOURCE_HTML_BASENAME}">${SOURCE_HTML_BASENAME}</a></p><p class="detail-guide">&#49345;&#49464; &#54637;&#47785; &#48516;&#47448; &#52857;</p><div class="details-layout"><div class="detail-shell"><div class="detail-chip-col" id="detail-chips"></div></div><div class="detail-shell"><div class="detail-content" id="detail-content">
<h3>1-1. &#54028;&#46972;&#48120;&#53552; (${param_total})</h3><table><tr><th>Parameter</th><th>Default</th><th>Current</th><th>Description</th><th>Status</th></tr>$(default_row_if_empty "$PARAM_ROWS" 5)</table>
<h3>2-1. &#54840;&#54872;&#49457; &#44061;&#52404; (${feature_total})</h3><table><tr><th>Type</th><th>Category</th><th>Object</th><th>Detected</th><th>Status</th></tr>$(default_row_if_empty "$FEATURE_ROWS" 5)</table>
<h3>2-2. &#45936;&#51060;&#53552; &#53440;&#51077; (${dtype_total})</h3><table><tr><th>Type</th><th>Object</th><th>Datatype</th><th>Status</th></tr>$(default_row_if_empty "$DTYPE_ROWS" 4)</table>
<h3>2-3. &#54364;&#54788;&#49885; (${expr_total})</h3><table><tr><th>Object</th><th>Type</th><th>Keyword</th><th>Status</th></tr>$(default_row_if_empty "$EXPR_ROWS" 4)</table>
<h3>2-4. &#49884;&#45432;&#45784; (${syn_total})</h3><table><tr><th>Synonym</th><th>Target Object</th><th>Status</th></tr>$( [ -n "$syn_rows_html" ] && echo "$syn_rows_html" || echo '<tr><td colspan="3">&#45936;&#51060;&#53552;&#44032; &#50630;&#49845;&#45768;&#45796;.</td></tr>' )</table>
<h3>3-1. RLS &#51221;&#52293; (${rls_total})</h3><table><tr><th>Target</th><th>Policy</th><th>Command</th><th>Status</th></tr>$( [ -n "$rls_rows_html" ] && echo "$rls_rows_html" || echo '<tr><td colspan="4">&#45936;&#51060;&#53552;&#44032; &#50630;&#49845;&#45768;&#45796;.</td></tr>' )</table>
<h3>3-2. Redication (${redaction_total})</h3><table><tr><th>Target</th><th>Policy</th><th>Column</th><th>Status</th></tr>$( [ -n "$redaction_rows_html" ] && echo "$redaction_rows_html" || echo '<tr><td colspan="4">&#45936;&#51060;&#53552;&#44032; &#50630;&#49845;&#45768;&#45796;.</td></tr>' )</table>
<h3>3-3. &#54532;&#47196;&#54028;&#51068; (${profile_total})</h3><table><tr><th>Profile</th><th>Users</th><th>Status</th></tr>$( [ -n "$profile_rows_html" ] && echo "$profile_rows_html" || echo '<tr><td colspan="3">&#45936;&#51060;&#53552;&#44032; &#50630;&#49845;&#45768;&#45796;.</td></tr>' )</table>
<h3>3-4. &#47532;&#49548;&#49828; &#44536;&#47353; (${rg_total})</h3><table><tr><th>Group</th><th>CPU rate</th><th>dirtyratelimit</th><th>Users</th><th>Status</th></tr>$( [ -n "$rg_rows_html" ] && echo "$rg_rows_html" || echo '<tr><td colspan="5">&#45936;&#51060;&#53552;&#44032; &#50630;&#49845;&#45768;&#45796;.</td></tr>' )</table>
<h3>4-1. DBLink (${dblink_total})</h3><table><tr><th>DBLINK</th><th>User</th><th>Connection</th><th>Status</th></tr>$( [ -n "$dblink_rows_html" ] && echo "$dblink_rows_html" || echo '<tr><td colspan="4">&#45936;&#51060;&#53552;&#44032; &#50630;&#49845;&#45768;&#45796;.</td></tr>' )</table>
</div></div></div></div>
<div class="modal-backdrop" id="source-detail-modal" aria-hidden="true"><div class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="source-detail-title"><div class="modal-header"><div class="modal-title-wrap"><h3 id="source-detail-title">Object detail</h3><span class="modal-type" id="source-detail-type"></span></div><button type="button" class="modal-close" id="source-detail-close">Close</button></div><div class="modal-body"><iframe id="source-detail-frame" title="Object detail" loading="lazy"></iframe></div></div></div>
<script>
function splitImpact(total, impacted, criticalCount, warningCount, safeCount){const tt=Math.max(0,Number(total)||0);const ii=Math.max(0,Number(impacted)||0);const cc=Math.max(0,Number(criticalCount)||0);const wc=Math.max(0,Number(warningCount)||0);const sc=Math.max(0,Number(safeCount)||0);const nc=Math.max(0,tt-ii);if(tt<=0){return {critical:0,warning:0,safe:0,none:0,criticalCount:cc,warningCount:wc,safeCount:sc,noneCount:nc};}let critical=Math.round((cc*100)/tt);let warning=Math.round((wc*100)/tt);let safe=Math.round((sc*100)/tt);let none=Math.max(0,100-critical-warning-safe);const sum=critical+warning+safe+none;if(sum!==100){none=Math.max(0,100-critical-warning-safe);}return {critical,warning,safe,none,criticalCount:cc,warningCount:wc,safeCount:sc,noneCount:nc};}
const objectTypes=["PACKAGE","FUNCTION","PROCEDURE","VIEW","TABLE"];
const dataset={
  PACKAGE:{total:${pkg_total},impacted:${pkg_imp},keywords:[${pkg_kw_js}],impact:splitImpact(${pkg_total},${pkg_imp},${pkg_high},${pkg_med},${pkg_low})},
  FUNCTION:{total:${fun_total},impacted:${fun_imp},keywords:[${fun_kw_js}],impact:splitImpact(${fun_total},${fun_imp},${fun_high},${fun_med},${fun_low})},
  PROCEDURE:{total:${prc_total},impacted:${prc_imp},keywords:[${prc_kw_js}],impact:splitImpact(${prc_total},${prc_imp},${prc_high},${prc_med},${prc_low})},
  VIEW:{total:${viw_total},impacted:${viw_imp},keywords:[${viw_kw_js}],impact:splitImpact(${viw_total},${viw_imp},${viw_high},${viw_med},${viw_low})},
  TABLE:{total:${tbl_total},impacted:${tbl_imp},keywords:[${tbl_kw_js}],impact:splitImpact(${tbl_total},${tbl_imp},${tbl_high},${tbl_med},${tbl_low})}
};
const state={selectedType:"PACKAGE"};const detailState={selectedKey:""};const detailBlocks=[];
const chipsRoot=document.getElementById("type-chips");const barsRoot=document.getElementById("object-bars");const keywordRoot=document.getElementById("keyword-list");const donut=document.getElementById("impact-donut");const impactTotal=document.getElementById("impact-total");const legendRoot=document.getElementById("impact-legend");const vizGrid=document.getElementById("viz-grid");const empty=document.getElementById("empty-state");const detailChipsRoot=document.getElementById("detail-chips");const detailContentRoot=document.getElementById("detail-content");const modalRoot=document.getElementById("source-detail-modal");const modalFrame=document.getElementById("source-detail-frame");const modalTitle=document.getElementById("source-detail-title");const modalClose=document.getElementById("source-detail-close");
function renderChips(){chipsRoot.innerHTML="";objectTypes.forEach((t)=>{const b=document.createElement("button");b.className="chip "+(state.selectedType===t?"active":"");b.textContent=t;b.addEventListener("click",()=>{state.selectedType=t;render();});chipsRoot.appendChild(b);});}
function renderBars(){barsRoot.innerHTML="";objectTypes.forEach((t)=>{const d=dataset[t];const ratio=d.total>0?(d.impacted/d.total):0;const pct=Math.round(ratio*100);const item=document.createElement("button");item.className="bar-item "+(state.selectedType===t?"active":"");item.innerHTML='<div class="bar-wrap"><div class="bar-stack"><div class="bar-total"></div><div class="bar-impact" style="--ratio-impact:'+ratio.toFixed(3)+'"></div><span class="impact-label" style="--ratio-impact:'+ratio.toFixed(3)+'">'+pct+'%</span></div></div><div class="bar-label">'+t+'</div><div class="bar-count">'+d.impacted+' / '+d.total+'</div>';item.addEventListener("click",()=>{state.selectedType=t;render();});barsRoot.appendChild(item);});}
function escHtml(v){return String(v).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
function legendItem(colorVar,label,pct){return '<div class="legend-item"><span class="tag"><span class="dot" style="background:'+colorVar+'"></span>'+label+'</span><strong>'+pct+'%</strong></div>';}
function renderKeywords(){keywordRoot.innerHTML="";const items=[...(dataset[state.selectedType].keywords||[])].sort((a,b)=>b[1]-a[1]).slice(0,10);const max=Math.max(1,...items.map(i=>i[1]||0));if(items.length===0){keywordRoot.innerHTML=' <div class="keyword-row"><span class="keyword-rank">-</span><strong class="keyword-label">(&#50630;&#51020;)</strong><div class="keyword-track"><div class="keyword-fill" style="--ratio:0"></div></div><span class="keyword-value">0</span></div>';return;}items.forEach(([k,v],idx)=>{const r=(v||0)/max;const row=document.createElement("div");row.className="keyword-row";row.innerHTML=' <span class="keyword-rank">'+(idx+1)+'</span><strong class="keyword-label" title="'+escHtml(k)+'">'+escHtml(k)+'</strong><div class="keyword-track"><div class="keyword-fill" style="--ratio:'+r.toFixed(3)+'"></div></div><span class="keyword-value">'+v+'</span>';keywordRoot.appendChild(row);});}
function renderImpact(){const d=dataset[state.selectedType];const i=d.impact;const c=i.critical;const w=i.warning;const s=i.safe;const n=i.none;if((c+w+s+n)<=0){donut.style.background='conic-gradient(#e2e8f0 0% 100%)';}else{donut.style.background='conic-gradient(var(--critical) 0% '+c+'%,var(--warning) '+c+'% '+(c+w)+'%,var(--safe) '+(c+w)+'% '+(c+w+s)+'%,var(--none) '+(c+w+s)+'% 100%)';}const totalPct=d.total>0?Math.round((d.impacted*100)/d.total):0;impactTotal.textContent=String(totalPct)+'%';legendRoot.innerHTML=[legendItem('var(--critical)','&#44256;&#50689;&#54693;&#46020;',c),legendItem('var(--warning)','&#51473;&#50689;&#54693;&#46020;',w),legendItem('var(--safe)','&#51200;&#50689;&#54693;&#46020;',s),legendItem('var(--none)','&#50689;&#54693;&#50630;&#51020;',n)].join("");}
function bindSourceModal(){const modalType=document.getElementById("source-detail-type");if(!modalRoot||!modalFrame||!modalTitle||!modalClose||!modalType){return;}function isSourceObjectLink(a){const h=(a.getAttribute("href")||"").trim().toLowerCase();if(!h||h.startsWith("#")||h.startsWith("javascript:"))return false;return /(^|\/)src-[^\/]+\.html(?:[?#].*)?$/.test(h);}function detectTypeFromRow(anchor){const row=anchor.closest("tr");if(!row){return "";}const known=["FUNCTION","PROCEDURE","VIEW","TABLE COLUMN","TABLE","DEFAULT VALUE","CHECK CONSTRAINT","INDEX EXPRESSION","PROFILE","RLS POLICY","RESOURCE GROUP","DBLINK","PACKAGE","UNKNOWN"];const cells=[...row.querySelectorAll("td,th")].map((cell)=>cell.textContent.replace(/\s+/g," ").trim().toUpperCase());for(const k of known){if(cells.some((v)=>v===k||v.includes(k))){return k;}}return "";}function openModal(anchor){const codeNode=anchor.querySelector("code");modalTitle.textContent=codeNode&&codeNode.textContent?codeNode.textContent.trim():"Object detail";const objectType=detectTypeFromRow(anchor);modalType.textContent=objectType||"-";modalFrame.setAttribute("src",anchor.getAttribute("href"));modalRoot.classList.add("show");modalRoot.setAttribute("aria-hidden","false");document.body.style.overflow="hidden";}function closeModal(){modalRoot.classList.remove("show");modalRoot.setAttribute("aria-hidden","true");modalFrame.setAttribute("src","about:blank");document.body.style.overflow="";}document.addEventListener("click",(e)=>{const a=e.target.closest("a[href]");if(!a)return;if(e.defaultPrevented||e.button!==0||e.metaKey||e.ctrlKey||e.shiftKey||e.altKey)return;if(!isSourceObjectLink(a))return;e.preventDefault();openModal(a);});modalClose.addEventListener("click",closeModal);modalRoot.addEventListener("click",(e)=>{if(e.target===modalRoot){closeModal();}});document.addEventListener("keydown",(e)=>{if(e.key==="Escape"&&modalRoot.classList.contains("show")){closeModal();}});}
function initDetailSections(){if(!detailChipsRoot||!detailContentRoot){return;}const headers=[...detailContentRoot.querySelectorAll("h3")];headers.forEach((header)=>{const originalTitle=header.textContent.trim();const keyMatch=originalTitle.match(/^(\d-\d)\.\s*/);const key=keyMatch?keyMatch[1]:originalTitle;const table=(header.nextElementSibling&&header.nextElementSibling.tagName==="TABLE")?header.nextElementSibling:null;const titleWithoutPrefix=originalTitle.replace(/^\d-\d\.\s*/,"");const label=titleWithoutPrefix.replace(/\s*\(\d+\)\s*$/,"");header.textContent=titleWithoutPrefix;detailBlocks.push({key,label,header,table});});if(detailBlocks.length>0){detailState.selectedKey=detailBlocks[0].key;}renderDetailChips();renderDetailSections();}
function renderDetailChips(){if(!detailChipsRoot){return;}detailChipsRoot.innerHTML="";const uniq=new Map();detailBlocks.forEach((b)=>{if(!uniq.has(b.key)){uniq.set(b.key,b);}});uniq.forEach((block,key)=>{const chip=document.createElement("button");chip.className="chip "+(detailState.selectedKey===key?"active":"");chip.textContent=block&&block.label?block.label:key;chip.addEventListener("click",()=>{detailState.selectedKey=key;renderDetailChips();renderDetailSections();});detailChipsRoot.appendChild(chip);});}
function renderDetailSections(){detailBlocks.forEach((block)=>{const visible=detailState.selectedKey===block.key;block.header.style.display=visible?"":"none";if(block.table){block.table.style.display=visible?"table":"none";}});}
function render(){renderChips();const grand=objectTypes.reduce((a,t)=>a+(dataset[t].total||0),0);if(grand===0){vizGrid.style.display="none";empty.classList.add("show");return;}vizGrid.style.display="grid";empty.classList.remove("show");renderBars();renderKeywords();renderImpact();}
bindSourceModal();
render();
initDetailSections();
</script>
</div></body></html>
HTML

# remove helper artifacts from output dir
purge_files "$OUT_DIR"/.f.tsv "$OUT_DIR"/.d.tsv "$OUT_DIR"/.vis_keywords.tsv "$OUT_DIR"/.vis_impact.tsv "$OUT_DIR"/.user_created_objects.tsv "$OUT_DIR"/.param_rows.html "$OUT_DIR"/.feature_rows.html "$OUT_DIR"/.dtype_rows.html "$OUT_DIR"/.expr_rows.html

progress_step "Writing report index"
cat > "$OUT_DIR/REPORT_INDEX.txt" <<TXT
[EPAS PostgreSQL Precheck]
Output directory : $OUT_DIR
Connection info  : host=${HOST:-N/A}, port=${PORT:-N/A}, db=${DBNAME:-N/A}, user=${DBUSER:-N/A}
Main HTML report : ${HTML_BASENAME}
Source HTML page : ${SOURCE_HTML_BASENAME}
Source directory : ${SOURCE_DIR_BASENAME}/
Compatibility    : OS[RHEL 7/8/9, Ubuntu 20/22/24], EPAS[9.6/10/14/17]
TXT

progress_step "Finalizing report"
progress_finish
echo "[DONE] Report generated at: $OUT_DIR"
echo "       Main HTML  : $OUT_DIR/$HTML_BASENAME"
echo "       Source HTML: $OUT_DIR/$SOURCE_HTML_BASENAME"
echo "       Source dir : $OUT_DIR/$SOURCE_DIR_BASENAME/"

if [[ -n "$COMPRESS" ]]; then
  if ! command -v tar >/dev/null 2>&1; then
    echo "[ERROR] compression requested but 'tar' is not installed" >&2
    exit 1
  fi
  if [[ "$COMPRESS" == "gz" ]] && ! command -v gzip >/dev/null 2>&1; then
    echo "[ERROR] compression requested but 'gzip' is not installed" >&2
    exit 1
  fi

  parent_dir=$(dirname "$OUT_DIR")
  out_name=$(basename "$OUT_DIR")
  archive_base="$OUT_DIR"
  if [[ "$COMPRESS" == "tar" ]]; then
    tar -cf "${archive_base}.tar" -C "$parent_dir" "$out_name"
    safe_remove_dir "$OUT_DIR"
    echo "[DONE] Compressed: ${archive_base}.tar"
  else
    tar -czf "${archive_base}.tar.gz" -C "$parent_dir" "$out_name"
    safe_remove_dir "$OUT_DIR"
    echo "[DONE] Compressed: ${archive_base}.tar.gz"
  fi
fi
