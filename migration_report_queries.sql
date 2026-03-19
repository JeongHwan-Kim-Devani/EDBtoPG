--@@ parameters
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
            WHEN 'edb_audit' THEN 'EDB 전용 감사 기능 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_audit_archiver' THEN 'EDB 전용 기능 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_early_lock_release' THEN 'EDB 전용 락 제어 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_max_capture_privileges_policies' THEN 'EDB 전용 보안 정책 (PostgreSQL에서 사용 불가)'
            WHEN 'qreplace_function' THEN '쿼리를 자동으로 수정하게 조정 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_stmt_level_tx' THEN '트랜잭션 내 오류 발생 시 해당 문장만 롤백 여부 (PostgreSQL에서 사용 불가)'
            WHEN 'data_encryption_key_unwrap_command' THEN 'EDB 전용 TDE 암호화 제어 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_max_resource_groups' THEN 'EDB 전용 리소스 제어 한도 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_resource_group' THEN 'EDB 전용 세션별 리소스 할당 (PostgreSQL에서 사용 불가)'
            WHEN 'edb_redwood_strings' THEN '빈 문자열과 NULL 처리 방식 변경 (앱 로직 수정 필요)'
            WHEN 'db_dialect' THEN '오라클 호환 문법 비활성화 (표준 SQL 재작성 필요)'
            WHEN 'datestyle' THEN '날짜 문자열 파싱 이슈 가능 (ISO 통일 필요)'
            WHEN 'edb_redwood_greatest_least' THEN 'GREATEST/LEAST의 NULL 처리 차이 주의'
            WHEN 'edb_redwood_date' THEN 'DATE 시간 정보 유실 위험 (TIMESTAMP 권장)'
            WHEN 'edb_dynatune' THEN '자동 메모리 튜닝 상실 (수동 튜닝 필요)'
            WHEN 'edb_dynatune_profile' THEN '동적 프로파일링 상실 (work_mem 등 수동 설정 필요)'
            WHEN 'optimizer_mode' THEN '오라클 방식 실행 계획 무시됨 (재튜닝 필요)'
            WHEN 'default_with_rowids' THEN 'ROWID 의존 쿼리 비호환 가능'
            WHEN 'enable_hints' THEN 'EDB 힌트 기능 상실 (pg_hint_plan 검토 필요)'
            WHEN 'oracle_home' THEN '오라클 DB 링크 경로 정보'
            WHEN 'extension_control_path' THEN 'EDB 확장 제어 경로'
            WHEN 'edb_redwood_raw_names' THEN '대문자 객체명 처리 관련'
            WHEN 'timed_statistics' THEN 'track_io_timing 등으로 대체 가능'
            WHEN 'max_generic_plan_partition_size' THEN 'EDB 전용 제네릭 플랜 제어'
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
        WHEN parameter_name IN ('edb_audit','edb_audit_archiver','edb_early_lock_release','edb_max_capture_privileges_policies','qreplace_function','edb_stmt_level_tx','data_encryption_key_unwrap_command','edb_max_resource_groups','edb_resource_group') THEN 1
        WHEN parameter_name IN ('edb_redwood_strings','db_dialect','datestyle','edb_redwood_greatest_least','edb_redwood_date','edb_dynatune','edb_dynatune_profile','optimizer_mode','default_with_rowids','enable_hints') THEN 2
        ELSE 3
    END,
    parameter_name;

--@@ summary_packages
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
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND n.nspname NOT LIKE 'dbms_%'
      AND n.nspname NOT LIKE 'utl_%'
    UNION ALL
    SELECT
        'V' AS object_type,
        v.schemaname AS schema_name,
        v.viewname AS object_name,
        m[1] AS feature
    FROM pg_views v,
    LATERAL regexp_matches(lower(v.definition), '(\m(?:dbms_crypto(?:\.[a-z0-9_]+)?|dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\.[a-z0-9_]+|htf\.[a-z0-9_]+)\M)', 'g') AS m
    WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND v.schemaname NOT LIKE 'dbms_%'
      AND v.schemaname NOT LIKE 'utl_%'
) x
ORDER BY schema_name, CASE object_type WHEN 'P' THEN 1 WHEN 'F' THEN 2 WHEN 'V' THEN 3 ELSE 9 END, object_name;

--@@ summary_synonyms
SELECT ns.nspname AS synonym_schema, s.synname, s.synobjschema, s.synobjname, COALESCE(s.synlink,'') AS synlink
FROM pg_catalog.pg_synonym s
JOIN pg_namespace ns ON ns.oid = s.synnamespace
ORDER BY ns.nspname, s.synname;

--@@ summary_policies
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
ORDER BY schemaname, tablename, policyname;


--@@ summary_policies_dbms_rls
SELECT object_owner, schema_name, object_name, policy_group, policy_name, pf_owner, package, function
FROM sys.all_policies
ORDER BY schema_name, object_name, policy_name;

--@@ summary_redaction
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

--@@ detail_keywords
SELECT object_type, schema_name, object_name, detected_keyword
FROM (
    SELECT CASE WHEN p.prokind='p' THEN 'P' ELSE 'F' END AS object_type, n.nspname AS schema_name, p.proname AS object_name,
           m[1] AS detected_keyword
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid,
    LATERAL regexp_matches(lower(p.prosrc), '(\m(?:dbms_crypto(?:\.[a-z0-9_]+)?|clob|bfile|raw|greatest|least|sysdate|systimestamp|rownum|rowid|level|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|listagg|wm_concat|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|pragma|sqlcode|sqlerrm|raise_application_error|numtodsinterval|numtoyminterval|sys_extract_utc|tz_offset|dbtimezone|sessiontimezone|lnnvl|nanvl|ratio_to_report|substrb|instrb|lengthb)\M)', 'g') AS m
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
    UNION ALL
    SELECT CASE WHEN p.prokind='p' THEN 'P' ELSE 'F' END AS object_type,
           n.nspname AS schema_name,
           p.proname AS object_name,
           lower(l.lanname) AS detected_keyword
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    JOIN pg_language l ON l.oid = p.prolang
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND l.lanname IS NOT NULL
    UNION ALL
    SELECT 'V' AS object_type, v.schemaname AS schema_name, v.viewname AS object_name,
           m[1] AS detected_keyword
    FROM pg_views v,
    LATERAL regexp_matches(lower(v.definition), '(\m(?:dbms_crypto(?:\.[a-z0-9_]+)?|clob|bfile|raw|greatest|least|sysdate|systimestamp|rownum|rowid|level|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|listagg|wm_concat|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|pragma|sqlcode|sqlerrm|raise_application_error|numtodsinterval|numtoyminterval|sys_extract_utc|tz_offset|dbtimezone|sessiontimezone|lnnvl|nanvl|ratio_to_report|substrb|instrb|lengthb)\M)', 'g') AS m
    WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
) z
ORDER BY schema_name, CASE object_type WHEN 'P' THEN 1 WHEN 'F' THEN 2 WHEN 'V' THEN 3 ELSE 9 END, object_name;

--@@ detail_datatypes_objects
SELECT object_type, schema_name, object_name, detected_datatype
FROM (
    SELECT CASE WHEN p.prokind='p' THEN 'P' ELSE 'F' END AS object_type, n.nspname AS schema_name, p.proname AS object_name,
           m[1] AS detected_datatype
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid,
    LATERAL regexp_matches(lower(p.prosrc), '(\m(?:clob|bfile|raw)\M)', 'g') AS m
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
    UNION ALL
    SELECT 'V' AS object_type, v.schemaname AS schema_name, v.viewname AS object_name,
           m[1] AS detected_datatype
    FROM pg_views v,
    LATERAL regexp_matches(lower(v.definition), '(\m(?:clob|bfile|raw)\M)', 'g') AS m
    WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
) z
ORDER BY schema_name, CASE object_type WHEN 'P' THEN 1 WHEN 'F' THEN 2 WHEN 'V' THEN 3 ELSE 9 END, object_name;

--@@ detail_datatypes_tables
SELECT table_schema AS schema_name, table_name, column_name,
       COALESCE(domain_name, udt_name) AS current_datatype
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
  AND (udt_name IN ('clob', 'bfile', 'raw')
       OR domain_name IN ('clob', 'bfile', 'raw'))
ORDER BY schema_name, table_name, column_name;

--@@ detail_expr_keywords
SELECT object_type, schema_name, table_name, target_name, detected_keyword
FROM (
    SELECT 'DEFAULT VALUE' AS object_type, n.nspname AS schema_name, c.relname AS table_name, a.attname AS target_name,
           substring(lower(pg_get_expr(d.adbin, d.adrelid)) from '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M') AS detected_keyword
    FROM pg_attrdef d
    JOIN pg_attribute a ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    JOIN pg_class c ON d.adrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND pg_get_expr(d.adbin, d.adrelid) ~* '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M'
    UNION ALL
    SELECT 'CHECK CONSTRAINT' AS object_type, n.nspname AS schema_name, c.relname AS table_name, con.conname AS target_name,
           substring(lower(pg_get_expr(con.conbin, con.conrelid)) from '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M') AS detected_keyword
    FROM pg_constraint con
    JOIN pg_class c ON con.conrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE con.contype = 'c'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND pg_get_expr(con.conbin, con.conrelid) ~* '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M'
    UNION ALL
    SELECT 'INDEX EXPRESSION' AS object_type, n.nspname AS schema_name, c.relname AS table_name, i.relname AS target_name,
           substring(lower(pg_get_expr(idx.indexprs, idx.indrelid)) from '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M') AS detected_keyword
    FROM pg_index idx
    JOIN pg_class c ON idx.indrelid = c.oid
    JOIN pg_class i ON idx.indexrelid = i.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE idx.indexprs IS NOT NULL
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
      AND pg_get_expr(idx.indexprs, idx.indrelid) ~* '\m(sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr)\M'
) z
ORDER BY schema_name, table_name, target_name, object_type;

--@@ policy_edb_profile
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
    'APPLIED USERS: ' || CASE WHEN applied_users = '' THEN '(미적용)' ELSE applied_users END,
    E'[\r\n]+', E'\\n', 'g'
  ) AS profile_detail,
  applied_users
FROM profile_rows
GROUP BY profile_name, applied_users
ORDER BY profile_name;
--@@ policy_edb_profile_dba
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
    'APPLIED USERS: ' || CASE WHEN u.applied_users = '' THEN '(미적용)' ELSE u.applied_users END,
    E'[\r\n]+', E'\\n', 'g'
  ) AS profile_detail,
  u.applied_users
FROM prof_detail d
LEFT JOIN prof_users u ON u.profile_name = d.profile_name
ORDER BY d.profile_name;

--@@ policy_edb_resource_group
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

--@@ policy_edb_dblink
SELECT lnkname, lnkowner, lnktype, lnkispublic, lnkuser, lnkconnstr, oid
FROM pg_catalog.edb_dblink
ORDER BY lnkname;


--@@ summary_packages_raw
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
         'Source code:' || E'\n' || COALESCE(pg_catalog.pg_get_function_sqlbody(p.oid), p.prosrc),
         E'[\r\n]+', E'\\n', 'g'
       ) AS source_text
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
LEFT JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
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
WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb');
--@@ detail_keywords_raw
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
         'Source code:' || E'\n' || COALESCE(pg_catalog.pg_get_function_sqlbody(p.oid), p.prosrc),
         E'[\r\n]+', E'\\n', 'g'
       ) AS source_text
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
LEFT JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
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
WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb');
--@@ detail_expr_raw
SELECT 'DEFAULT VALUE' AS object_type, n.nspname AS schema_name, c.relname AS table_name, a.attname AS target_name,
       regexp_replace(pg_get_expr(d.adbin, d.adrelid), E'[\r\n]+', E'\\n', 'g') AS expression
FROM pg_attrdef d
JOIN pg_attribute a ON d.adrelid = a.attrelid AND d.adnum = a.attnum
JOIN pg_class c ON d.adrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
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
WHERE con.contype = 'c' AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
UNION ALL
SELECT 'INDEX EXPRESSION' AS object_type, n.nspname AS schema_name, c.relname AS table_name, i.relname AS target_name,
       regexp_replace(pg_get_expr(idx.indexprs, idx.indrelid), E'[\r\n]+', E'\\n', 'g') AS expression
FROM pg_index idx
JOIN pg_class c ON idx.indrelid = c.oid
JOIN pg_class i ON idx.indexrelid = i.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE idx.indexprs IS NOT NULL AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb');

--@@ detail_table_columns_raw
SELECT table_schema, table_name, column_name,
       COALESCE(domain_name, udt_name) AS column_type,
       is_nullable,
       COALESCE(column_default, '') AS column_default
FROM information_schema.columns
WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
ORDER BY table_schema, table_name, ordinal_position;


--@@ detail_table_objects_raw
WITH tbl AS (
  SELECT c.oid, n.nspname AS schema_name, c.relname AS table_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r','p')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'sys', 'dbo', 'sys_catalog', 'enterprisedb')
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
