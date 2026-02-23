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
OUTPUT_SPECIFIED=0
PROMPT_MODE=0

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

tsv_col_count() {
  local file="$1"
  local col="$2"
  local value="$3"
  if [[ -f "$file" ]]; then
    awk -F '\t' -v c="$col" -v v="$value" '$c == v {n++} END {print n+0}' "$file"
  else
    echo 0
  fi
}

tsv_key_count() {
  local file="$1"
  local key="$2"
  if [[ -f "$file" ]]; then
    awk -F '\t' -v k="$key" '$1 == k {print $2; found=1} END {if (!found) print 0}' "$file"
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
  local f_summary="$F_SUMMARY"
  local f_count="$F_COUNT_SUMMARY"
  local f_guide="$F_GUIDE"
  local f_plain="$F_PLAIN_SUMMARY"

  local c_instance c_extensions c_objects c_routines c_grants c_types c_sequences c_edb_ext c_edb_rtn c_epas c_risk c_epas_builtin c_epas_user c_oracle
  local c_synonym c_package c_dbms c_authid c_sys_context c_nvl c_sysdate c_clob
  c_instance=$(line_count "$F_INSTANCE_SETTINGS")
  c_extensions=$(line_count "$F_EXTENSIONS")
  c_objects=$(line_count "$F_OBJECTS")
  c_routines=$(line_count "$F_ROUTINES")
  c_grants=$(line_count "$F_TABLE_GRANTS")
  c_types=$(line_count "$F_TYPE_HOTSPOTS")
  c_sequences=$(line_count "$F_SEQUENCES")
  c_edb_ext=$(nonempty_line_count "$F_EDB_EXT_HITS")
  c_edb_rtn=$(nonempty_line_count "$F_EDB_ROUTINE_HITS")
  c_epas=$(nonempty_line_count "$F_EPAS_FEATURE_HITS")
  c_risk=$(nonempty_line_count "$F_MIGRATION_RISK_HITS")
  c_epas_builtin=$(tsv_col_count "$F_EPAS_FEATURE_HITS" 4 "EDB_BUILTIN")
  c_epas_user=$(tsv_col_count "$F_EPAS_FEATURE_HITS" 4 "USER_CREATED")
  c_synonym=$(tsv_key_count "$F_EPAS_GROUP_COUNTS" "SYNONYM")
  c_package=$(tsv_key_count "$F_EPAS_GROUP_COUNTS" "PACKAGE")
  c_dbms=$(tsv_col_count "$F_EPAS_FEATURE_HITS" 3 "DBMS_RLS")
  c_authid=$(tsv_key_count "$F_EPAS_GROUP_COUNTS" "AUTHID")
  c_sys_context=$(tsv_col_count "$F_EPAS_FEATURE_HITS" 3 "SYS_CONTEXT(")
  c_nvl=$(tsv_col_count "$F_EPAS_FEATURE_HITS" 3 "NVL(")
  c_sysdate=$(tsv_col_count "$F_EPAS_FEATURE_HITS" 3 "SYSDATE")
  c_clob=$(tsv_key_count "$F_EPAS_GROUP_COUNTS" "CLOB")
  c_oracle=0
  if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
    c_oracle=$(nonempty_line_count "$F_ORACLE_KEYWORD_HITS")
  fi

  echo "[INFO] Writing count summary..."
  {
    echo "metric\tcount"
    echo -e "instance_settings\t${c_instance}"
    echo -e "extensions\t${c_extensions}"
    echo -e "objects\t${c_objects}"
    echo -e "object_kinds\t$(line_count "$F_OBJECT_KIND_COUNTS")"
    echo -e "routines\t${c_routines}"
    echo -e "routine_kinds\t$(line_count "$F_ROUTINE_KIND_COUNTS")"
    echo -e "table_grants\t${c_grants}"
    echo -e "type_hotspots\t${c_types}"
    echo -e "sequences\t${c_sequences}"
    echo -e "edb_extensions\t${c_edb_ext}"
    echo -e "edb_named_routines\t${c_edb_rtn}"
    echo -e "epas_feature_hits\t${c_epas}"
    echo -e "epas_builtin_feature_hits\t${c_epas_builtin}"
    echo -e "epas_user_feature_hits\t${c_epas_user}"
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
    echo "epas_builtin_feature_hits=${c_epas_builtin}"
    echo "epas_user_feature_hits=${c_epas_user}"
    echo "migration_risk_hits=${c_risk}"
    if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
      echo "oracle_keyword_hits=${c_oracle}"
    fi
    echo
    echo "See also: 90_count_summary.tsv, 05_object_kind_counts.tsv, 07_routine_kind_counts.tsv, 92_migration_guide_report.md, 93_migration_summary_report.txt"
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
    echo "Counts (Overview)"
    echo "--------------------"
    printf "%-26s : %s\n" "Objects total" "$c_objects"
    printf "%-26s : %s\n" "Routines total" "$c_routines"
    printf "%-26s : %s\n" "Type hotspots total" "$c_types"
    printf "%-26s : %s\n" "Sequences total" "$c_sequences"
    printf "%-26s : %s\n" "EPAS feature hits total" "$c_epas"
    printf "%-26s : %s\n" "Migration risk hits total" "$c_risk"
    if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
      printf "%-26s : %s\n" "Oracle keyword hits total" "$c_oracle"
    fi
    echo
    echo "Counts (Object kind grouping)"
    echo "--------------------"
    if [[ -s "$F_OBJECT_KIND_COUNTS" ]]; then
      awk -F '\t' '
      BEGIN {
        map["r"]="table"; map["p"]="partitioned_table"; map["v"]="view";
        map["m"]="materialized_view"; map["S"]="sequence"; map["f"]="foreign_table";
      }
      { printf "%-24s : %s\n", (map[$1] ? map[$1] : $1), $2 }
      ' "$F_OBJECT_KIND_COUNTS" | sort
    else
      echo "No object kind data."
    fi
    echo
    echo "Counts (Routine kind grouping)"
    echo "--------------------"
    if [[ -s "$F_ROUTINE_KIND_COUNTS" ]]; then
      awk -F '\t' '
      BEGIN { map["f"]="function"; map["p"]="procedure"; map["a"]="aggregate"; map["w"]="window"; }
      { printf "%-24s : %s\n", (map[$1] ? map[$1] : $1), $2 }
      ' "$F_ROUTINE_KIND_COUNTS" | sort
    else
      echo "No routine kind data."
    fi
    echo
    echo "Counts (Routine kind grouping by owner)"
    echo "--------------------"
    if [[ -s "$F_ROUTINE_KIND_OWNER_COUNTS" ]]; then
      awk -F '\t' '
      BEGIN { map["f"]="function"; map["p"]="procedure"; map["a"]="aggregate"; map["w"]="window"; }
      { printf "%-12s %-12s : %s\n", $1, (map[$2] ? map[$2] : $2), $3 }
      ' "$F_ROUTINE_KIND_OWNER_COUNTS" | sort
    else
      echo "No routine owner-kind data."
    fi
    echo
    echo "## 2) 호환성/대체기능/수동수정 가이드"
    echo
    echo "Counts (Section 2 grouping)"
    echo "--------------------"
    printf "%-24s : %s\n" "EDB ext hits" "$c_edb_ext"
    printf "%-24s : %s\n" "EDB named routines" "$c_edb_rtn"
    printf "%-24s : %s\n" "EPAS feature hits" "$c_epas"
    printf "%-24s : %s\n" "EPAS builtin features" "$c_epas_builtin"
    printf "%-24s : %s\n" "EPAS user features" "$c_epas_user"
    if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
      printf "%-24s : %s\n" "Oracle keyword hits" "$c_oracle"
    fi
    printf "%-24s : %s\n" "Type hotspots" "$c_types"
    printf "%-24s : %s\n" "Sequences" "$c_sequences"
    echo
    echo "- EDB 전용 확장(edb%): 유사 확장/표준 SQL 대체 검토 (근거: 11_edb_extension_hits.txt)"
    echo "- EDB 전용 함수/프로시저 네이밍: PL/pgSQL 표준 함수로 치환 검토 (근거: 12_edb_function_name_hits.txt, 06_routines.tsv)"
    echo "- EPAS/Oracle 특화 함수 패턴(SYS_CONTEXT, AUTHID, NVL 등): CURRENT_USER/COALESCE/now() 치환 검토 (근거: 13_epas_feature_hits.tsv)"
    if [[ "$ORACLE_CHECKS" -eq 1 ]]; then
      echo "- Oracle 호환 키워드: CASE/COALESCE/표준 SQL 치환 검토 (근거: 15_oracle_keyword_hits.tsv)"
    else
      echo "- Oracle 호환 키워드: --oracle-checks 실행 후 판단"
    fi
    echo "- 타입 핫스팟: 타입별 매핑 정책 수립 (근거: 09_type_hotspots.tsv)"
    echo "- 시퀀스/자동증가: identity/sequence setval 전략 점검 (근거: 10_sequences.tsv)"
    echo
    echo "## 3) 이관 실패 예방 체크리스트"
    echo
    echo "Counts (Section 3 grouping)"
    echo "--------------------"
    echo "SYSDATE_DEFAULT           : $(grep -c $'\tSYSDATE_DEFAULT\t' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo "EDBSPL_ROUTINE            : $(grep -c $'\tEDBSPL_ROUTINE\t' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo "PG_STAT_STATEMENTS_OBJECT : $(grep -c $'\tPG_STAT_STATEMENTS_OBJECT\t' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo "POLICY_OR_CONTEXT         : $(grep -c $'\tPOLICY_OR_CONTEXT\t' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo "BUILTIN_RISK              : $(grep -c $'\tEDB_BUILTIN$' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo "USER_RISK                 : $(grep -c $'\tUSER_CREATED$' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo
    echo "- DEFAULT SYSDATE 구문 -> DEFAULT now()/CURRENT_TIMESTAMP 치환 (14_migration_risk_hits.tsv:SYSDATE_DEFAULT)"
    echo "- language edbspl 객체 -> PL/pgSQL 재작성 (14_migration_risk_hits.tsv:EDBSPL_ROUTINE)"
    echo "- pg_stat_statements 객체 충돌 -> extension 관리 객체 이관 제외 (14_migration_risk_hits.tsv:PG_STAT_STATEMENTS_OBJECT)"
    echo "- EPAS 정책/컨텍스트 함수 -> PostgreSQL RLS + CURRENT_USER 기반으로 재작성 (14_migration_risk_hits.tsv:POLICY_OR_CONTEXT)"
    echo
    echo "## 4) 덤프 기반 추가 체크리스트"
    echo
    echo "Counts (Section 4 grouping)"
    echo "--------------------"
    printf "%-24s : %s\n" "SYNONYM" "$c_synonym"
    printf "%-24s : %s\n" "PACKAGE" "$c_package"
    printf "%-24s : %s\n" "DBMS_RLS" "$c_dbms"
    printf "%-24s : %s\n" "AUTHID" "$c_authid"
    printf "%-24s : %s\n" "SYS_CONTEXT" "$c_sys_context"
    printf "%-24s : %s\n" "NVL" "$c_nvl"
    printf "%-24s : %s\n" "SYSDATE" "$c_sysdate"
    printf "%-24s : %s\n" "CLOB" "$c_clob"
    echo
    echo "- SYNONYM (${c_synonym}): 비호환 -> VIEW/search_path/SQL 재작성"
    echo "- PACKAGE (${c_package}): 비호환 -> 스키마 + 함수/프로시저로 분해"
    echo "- DBMS_RLS 계열 (${c_dbms}): 부분 호환 -> PostgreSQL RLS POLICY 재구현"
    echo "- AUTHID 계열 (${c_authid}): SECURITY DEFINER/INVOKER 전략 재설계"
    echo "- SYS_CONTEXT 계열 (${c_sys_context}): CURRENT_USER/SESSION_USER로 치환"
    echo "- NVL 계열 (${c_nvl}) / SYSDATE 계열 (${c_sysdate}): COALESCE, CURRENT_TIMESTAMP/now()로 치환"
    echo "- CLOB 타입 (${c_clob}): text로 매핑"
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
    echo "- 91_summary.md: 요약"
    echo "- 90_count_summary.tsv: 머신 파싱용 카운트"
    echo "- 04_objects.tsv / 05_object_kind_counts.tsv: 객체 인벤토리"
    echo "- 06_routines.tsv / 07_routine_kind_counts.tsv: 루틴 인벤토리"
    echo "- 09_type_hotspots.tsv / 10_sequences.tsv: 마이그레이션 민감 항목"
    echo "- 13_epas_feature_hits.tsv: EPAS/Oracle 특화 패턴 히트"
    echo "- 14_migration_risk_hits.tsv: 이관 실패 위험 패턴 히트"
    echo "- 11_edb_extension_hits.txt / 12_edb_function_name_hits.txt / 15_oracle_keyword_hits.tsv(옵션): 호환성 리스크 근거"
    echo "- 94_user_created_risk_hits.txt: USER_CREATED 리스크 목록 (변환 우선 대상)"
    echo "- 95_builtin_risk_hits.txt: EDB_BUILTIN 리스크 목록 (이관 제외/선별 대상)"

    echo
    echo "## 7) Migration Summary"
    echo
    echo "총 객체 점검 수: $((c_objects + c_routines))"
    echo "주요 리스크 건수: ${c_risk}"
    echo "- SYSDATE_DEFAULT: $(grep -c $'\tSYSDATE_DEFAULT\t' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo "- EDBSPL_ROUTINE: $(grep -c $'\tEDBSPL_ROUTINE\t' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo "- PG_STAT_STATEMENTS_OBJECT: $(grep -c $'\tPG_STAT_STATEMENTS_OBJECT\t' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo "- POLICY_OR_CONTEXT: $(grep -c $'\tPOLICY_OR_CONTEXT\t' "$F_MIGRATION_RISK_HITS" 2>/dev/null || true)"
    echo
    echo "## 8) List of migration risk hits"
    echo
    if [[ -s "$F_MIGRATION_RISK_HITS" ]]; then
      if [[ "$PROMPT_MODE" -eq 1 ]]; then
        awk -F '\t' '$4=="USER_CREATED" {printf "%d. %s | %s | %s\n", NR, $1, $2, $4}' "$F_MIGRATION_RISK_HITS"
      else
        awk -F '\t' '{printf "%d. %s | %s | %s\n", NR, $1, $2, $4}' "$F_MIGRATION_RISK_HITS"
      fi
    else
      echo "- No risk hits detected."
    fi
  } > "$f_guide"

  {
    echo "******************** Migration Summary ********************"
    echo "Target: ${HOST}:${PORT}/${DBNAME}"
    [[ -n "$SCHEMA" ]] && echo "Schema filter: $SCHEMA" || echo "Schema filter: (none)"
    echo
    echo "Counts (Overview)"
    echo "--------------------"
    echo "Objects total              : ${c_objects}"
    echo "Routines total             : ${c_routines}"
    echo "Type hotspots total        : ${c_types}"
    echo "Sequences total            : ${c_sequences}"
    echo "EPAS feature hits total    : ${c_epas}"
    echo "Migration risk hits total  : ${c_risk}"
    [[ "$ORACLE_CHECKS" -eq 1 ]] && echo "Oracle keyword hits total  : ${c_oracle}"

    echo
    echo "Counts (Object kind grouping)"
    echo "--------------------"
    if [[ -s "$F_OBJECT_KIND_COUNTS" ]]; then
      awk -F '\t' '
      BEGIN {
        map["r"]="table"; map["p"]="partitioned_table"; map["v"]="view";
        map["m"]="materialized_view"; map["S"]="sequence"; map["f"]="foreign_table";
      }
      { printf "%-24s : %s\n", (map[$1] ? map[$1] : $1), $2 }
      ' "$F_OBJECT_KIND_COUNTS"
    else
      echo "No object kind data."
    fi

    echo
    echo "Counts (Routine kind grouping)"
    echo "--------------------"
    if [[ -s "$F_ROUTINE_KIND_COUNTS" ]]; then
      awk -F '\t' '
      BEGIN { map["f"]="function"; map["p"]="procedure"; map["a"]="aggregate"; map["w"]="window"; }
      { printf "%-24s : %s\n", (map[$1] ? map[$1] : $1), $2 }
      ' "$F_ROUTINE_KIND_COUNTS"
    else
      echo "No routine kind data."
    fi

    echo
    echo "Counts (Routine kind grouping by owner)"
    echo "--------------------"
    if [[ -s "$F_ROUTINE_KIND_OWNER_COUNTS" ]]; then
      awk -F '\t' '
      BEGIN { map["f"]="function"; map["p"]="procedure"; map["a"]="aggregate"; map["w"]="window"; }
      { printf "%-12s %-12s : %s\n", $1, (map[$2] ? map[$2] : $2), $3 }
      ' "$F_ROUTINE_KIND_OWNER_COUNTS" | sort
    else
      echo "No routine owner-kind data."
    fi

    echo
    echo "Counts (EPAS feature owner grouping)"
    echo "--------------------"
    echo "Built-in/extension feature : ${c_epas_builtin}"
    echo "User-created feature       : ${c_epas_user}"

    echo
    echo "Counts (Migration risk grouping)"
    echo "--------------------"
    if [[ -s "$F_MIGRATION_RISK_HITS" ]]; then
      awk -F '\t' '
      { risk[$2]++; owner[$4]++ }
      END {
        for (k in risk) printf "risk.%-19s : %d\n", k, risk[k];
        for (k in owner) printf "owner.%-18s : %d\n", k, owner[k];
      }
      ' "$F_MIGRATION_RISK_HITS" | sort
    else
      echo "No migration risk data."
    fi
    echo
    echo "List of migration risk hits"
    echo "======================"
    if [[ -s "$F_MIGRATION_RISK_HITS" ]]; then
      awk -F '\t' '{print NR ". " $1 " [" $2 " | " $4 "]"}' "$F_MIGRATION_RISK_HITS"
    else
      echo "No risk hits detected."
    fi
  } > "$f_plain"

  if [[ -f "$F_MIGRATION_RISK_HITS" ]]; then
    awk -F '\t' '$4=="USER_CREATED" {print NR ". " $1 " [" $2 " | " $4 "]"}' "$F_MIGRATION_RISK_HITS" > "$OUTPUT_DIR/94_user_created_risk_hits.txt"
    awk -F '\t' '$4=="EDB_BUILTIN" {print NR ". " $1 " [" $2 " | " $4 "]"}' "$F_MIGRATION_RISK_HITS" > "$OUTPUT_DIR/95_builtin_risk_hits.txt"
  else
    : > "$OUTPUT_DIR/94_user_created_risk_hits.txt"
    : > "$OUTPUT_DIR/95_builtin_risk_hits.txt"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host) HOST="$2"; shift 2 ;;
    -p|--port) PORT="$2"; shift 2 ;;
    -d|--dbname) DBNAME="$2"; shift 2 ;;
    -U|--user) DBUSER="$2"; shift 2 ;;
    -W|--password) DBPASSWORD="$2"; shift 2 ;;
    -s|--schema) SCHEMA="$2"; shift 2 ;;
    -o|--output) OUTPUT_DIR="$2"; OUTPUT_SPECIFIED=1; shift 2 ;;
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

if [[ "$OUTPUT_SPECIFIED" -eq 0 ]]; then
  PROMPT_MODE=1
  OUTPUT_DIR=$(mktemp -d -t epas_precheck_XXXXXX)
fi

mkdir -p "$OUTPUT_DIR"

F_VERSION="$OUTPUT_DIR/01_version.txt"
F_INSTANCE_SETTINGS="$OUTPUT_DIR/02_instance_settings.tsv"
F_EXTENSIONS="$OUTPUT_DIR/03_extensions.tsv"
F_OBJECTS="$OUTPUT_DIR/04_objects.tsv"
F_OBJECT_KIND_COUNTS="$OUTPUT_DIR/05_object_kind_counts.tsv"
F_ROUTINES="$OUTPUT_DIR/06_routines.tsv"
F_ROUTINE_KIND_COUNTS="$OUTPUT_DIR/07_routine_kind_counts.tsv"
F_ROUTINE_KIND_OWNER_COUNTS="$OUTPUT_DIR/07b_routine_kind_owner_counts.tsv"
F_TABLE_GRANTS="$OUTPUT_DIR/08_table_grants.tsv"
F_TYPE_HOTSPOTS="$OUTPUT_DIR/09_type_hotspots.tsv"
F_SEQUENCES="$OUTPUT_DIR/10_sequences.tsv"
F_EDB_EXT_HITS="$OUTPUT_DIR/11_edb_extension_hits.txt"
F_EDB_ROUTINE_HITS="$OUTPUT_DIR/12_edb_function_name_hits.txt"
F_EPAS_FEATURE_HITS="$OUTPUT_DIR/13_epas_feature_hits.tsv"
F_MIGRATION_RISK_HITS="$OUTPUT_DIR/14_migration_risk_hits.tsv"
F_ORACLE_KEYWORD_HITS="$OUTPUT_DIR/15_oracle_keyword_hits.tsv"
F_EPAS_GROUP_COUNTS="$OUTPUT_DIR/16_epas_group_counts.tsv"
F_COUNT_SUMMARY="$OUTPUT_DIR/90_count_summary.tsv"
F_SUMMARY="$OUTPUT_DIR/91_summary.md"
F_GUIDE="$OUTPUT_DIR/92_migration_guide_report.md"
F_PLAIN_SUMMARY="$OUTPUT_DIR/93_migration_summary_report.txt"

export PGPASSWORD="$DBPASSWORD"
export PGCONNECT_TIMEOUT="$CONNECT_TIMEOUT"
PSQL=(psql -X -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$DBUSER" -d "$DBNAME")

echo "[INFO] Output directory: $OUTPUT_DIR"
echo "[INFO] Checking DB connectivity..."
if ! run_sql "$F_VERSION" "select version();"; then
  echo "[ERROR] Connection failed. Check host/port/db/user/password and role existence." >&2
  echo "[HINT] Example check: psql -h '$HOST' -p '$PORT' -U '$DBUSER' -d '$DBNAME' -c 'select current_user, current_database();'" >&2
  exit 1
fi

schema_filter=""
schema_filter_table=""
if [[ -n "$SCHEMA" ]]; then
  schema_lit=$(sql_literal "$SCHEMA")
  schema_filter="AND n.nspname = ${schema_lit}"
  schema_filter_table="AND table_schema = ${schema_lit}"
fi

echo "[INFO] Collecting instance settings (encoding/collation/timezone)..."
run_sql "$F_INSTANCE_SETTINGS" "
SELECT name || E'\\t' || setting
FROM pg_settings
WHERE name IN ('server_encoding','lc_collate','lc_ctype','TimeZone')
ORDER BY name;"

echo "[INFO] Collecting extension inventory..."
run_sql "$F_EXTENSIONS" "
SELECT extname || E'\\t' || extversion
FROM pg_extension
ORDER BY extname;"

echo "[INFO] Collecting schema/object inventory..."
run_sql "$F_OBJECTS" "
SELECT n.nspname || E'\\t' || c.relname || E'\\t' || c.relkind
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND c.relkind IN ('r','p','v','m','S','f')
  ${schema_filter}
ORDER BY n.nspname, c.relkind, c.relname;"

echo "[INFO] Collecting object kind counts..."
run_sql "$F_OBJECT_KIND_COUNTS" "
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
run_sql "$F_ROUTINES" "
SELECT n.nspname || E'\\t' || p.proname || E'\\t' || l.lanname || E'\\t' || p.prokind
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter}
ORDER BY n.nspname, p.proname;"

echo "[INFO] Collecting routine kind counts..."
run_sql "$F_ROUTINE_KIND_COUNTS" "
SELECT prokind || E'\\t' || count(*)
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter}
GROUP BY prokind
ORDER BY prokind;"

echo "[INFO] Collecting routine kind counts by owner class..."
run_sql "$F_ROUTINE_KIND_OWNER_COUNTS" "
WITH ext_owned_proc AS (
  SELECT d.objid
  FROM pg_depend d
  JOIN pg_extension e ON e.oid = d.refobjid
  WHERE d.classid = 'pg_proc'::regclass
    AND d.deptype = 'e'
)
SELECT owner_class || E'\t' || prokind || E'\t' || cnt
FROM (
  SELECT
    CASE
      WHEN ep.objid IS NOT NULL THEN 'EDB_BUILTIN'
      WHEN n.nspname IN ('sys','edb') THEN 'EDB_BUILTIN'
      WHEN n.nspname ILIKE 'utl\_%' ESCAPE '\\' THEN 'EDB_BUILTIN'
      WHEN n.nspname ILIKE 'dbms\_%' ESCAPE '\\' THEN 'EDB_BUILTIN'
      WHEN p.proname IN ('pg_stat_statements','pg_stat_statements_info','pg_stat_statements_reset') THEN 'EDB_BUILTIN'
      ELSE 'USER_CREATED'
    END AS owner_class,
    p.prokind,
    count(*) AS cnt
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  LEFT JOIN ext_owned_proc ep ON ep.objid = p.oid
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
  GROUP BY 1, 2
) t
ORDER BY owner_class, prokind;"

echo "[INFO] Collecting role/grant summary..."
run_sql "$F_TABLE_GRANTS" "
SELECT grantee || E'\\t' || table_schema || E'\\t' || table_name || E'\\t' || privilege_type
FROM information_schema.table_privileges
WHERE table_schema NOT IN ('pg_catalog','information_schema')
  ${schema_filter_table}
ORDER BY grantee, table_schema, table_name;"

echo "[INFO] Collecting data type hotspot inventory..."
run_sql "$F_TYPE_HOTSPOTS" "
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
run_sql "$F_SEQUENCES" "
SELECT n.nspname || E'\\t' || c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'S'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter}
ORDER BY n.nspname, c.relname;"

echo "[INFO] Checking for EPAS/EDB specific extensions or names..."
run_sql "$F_EDB_EXT_HITS" "
SELECT extname
FROM pg_extension
WHERE extname ILIKE 'edb%'
ORDER BY extname;"

run_sql "$F_EDB_ROUTINE_HITS" "
SELECT n.nspname || E'.' || p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND p.proname ILIKE 'edb%'
  ${schema_filter}
ORDER BY 1;"

echo "[INFO] Scanning EPAS/Oracle-specific compatibility patterns..."
run_sql "$F_EPAS_FEATURE_HITS" "
WITH ext_owned_proc AS (
  SELECT d.objid
  FROM pg_depend d
  JOIN pg_extension e ON e.oid = d.refobjid
  WHERE d.classid = 'pg_proc'::regclass
    AND d.deptype = 'e'
),
ext_owned_rel AS (
  SELECT d.objid
  FROM pg_depend d
  JOIN pg_extension e ON e.oid = d.refobjid
  WHERE d.classid = 'pg_class'::regclass
    AND d.deptype = 'e'
),
routine_hits AS (
  SELECT n.nspname || E'.' || p.proname AS object_name,
         'ROUTINE' AS source,
         kw.keyword,
         CASE
           WHEN ep.objid IS NOT NULL THEN 'EDB_BUILTIN'
           WHEN n.nspname IN ('sys','edb') THEN 'EDB_BUILTIN'
           WHEN n.nspname ILIKE 'utl\_%' ESCAPE '\\' THEN 'EDB_BUILTIN'
           WHEN n.nspname ILIKE 'dbms\_%' ESCAPE '\\' THEN 'EDB_BUILTIN'
           WHEN p.proname IN ('pg_stat_statements','pg_stat_statements_info','pg_stat_statements_reset') THEN 'EDB_BUILTIN'
           ELSE 'USER_CREATED'
         END AS owner_class
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  LEFT JOIN ext_owned_proc ep ON ep.objid = p.oid
  CROSS JOIN LATERAL (
    VALUES ('SYS_CONTEXT('), ('AUTHID'), ('NVL('), ('SYSDATE'), ('SYSTIMESTAMP'), ('DBMS_RLS'), ('DECODE('), ('ROWNUM'), ('DUAL'), ('CLOB')
  ) kw(keyword)
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
    AND p.prokind IN ('f','p')
    AND pg_get_functiondef(p.oid) ILIKE '%' || kw.keyword || '%'
),
default_hits AS (
  SELECT n.nspname || E'.' || c.relname || E'.' || a.attname AS object_name,
         'COLUMN_DEFAULT' AS source,
         'SYSDATE' AS keyword,
         CASE
           WHEN er.objid IS NOT NULL THEN 'EDB_BUILTIN'
           WHEN n.nspname IN ('sys','edb') THEN 'EDB_BUILTIN'
           WHEN n.nspname ILIKE 'dbms\_%' ESCAPE '\\' THEN 'EDB_BUILTIN'
           ELSE 'USER_CREATED'
         END AS owner_class
  FROM pg_attrdef d
  JOIN pg_class c ON c.oid = d.adrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
  LEFT JOIN ext_owned_rel er ON er.objid = c.oid
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
    ${schema_filter}
    AND pg_get_expr(d.adbin, d.adrelid) ILIKE '%sysdate%'
),
type_hits AS (
  SELECT table_schema || E'.' || table_name || E'.' || column_name AS object_name,
         'COLUMN_TYPE' AS source,
         upper(udt_name) AS keyword,
         CASE
           WHEN er.objid IS NOT NULL THEN 'EDB_BUILTIN'
           WHEN table_schema IN ('sys','edb') THEN 'EDB_BUILTIN'
           WHEN table_schema ILIKE 'dbms\_%' ESCAPE '\\' THEN 'EDB_BUILTIN'
           ELSE 'USER_CREATED'
         END AS owner_class
  FROM information_schema.columns
  JOIN pg_namespace n ON n.nspname = table_schema
  JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = table_name
  LEFT JOIN ext_owned_rel er ON er.objid = c.oid
  WHERE table_schema NOT IN ('pg_catalog','information_schema')
    ${schema_filter_table}
    AND lower(udt_name) IN ('clob','blob','varchar2','nvarchar2')
)
SELECT object_name || E'\t' || source || E'\t' || keyword || E'\t' || owner_class
FROM (
  SELECT * FROM routine_hits
  UNION ALL
  SELECT * FROM default_hits
  UNION ALL
  SELECT * FROM type_hits
) t
ORDER BY 1;"

echo "[INFO] Collecting grouped dump-check counters..."
if "${PSQL[@]}" -Atqc "SELECT to_regclass('pg_catalog.pg_synonym') IS NOT NULL;" | grep -qx 't'; then
  run_sql "$F_EPAS_GROUP_COUNTS" "
SELECT 'SYNONYM' || E'\t' || count(*)
FROM pg_catalog.pg_synonym s
JOIN pg_namespace n ON n.oid = s.synnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter};"
else
  run_sql "$F_EPAS_GROUP_COUNTS" "
SELECT 'SYNONYM' || E'\t' || count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND c.relkind = 'y'
  ${schema_filter};"
fi

if "${PSQL[@]}" -Atqc "SELECT to_regclass('pg_catalog.pg_package') IS NOT NULL;" | grep -qx 't'; then
  run_sql "$OUTPUT_DIR/.tmp_package_count.tsv" "
SELECT 'PACKAGE' || E'\t' || count(*)
FROM pg_catalog.pg_package p
JOIN pg_namespace n ON n.oid = p.pkgnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter};"
else
  run_sql "$OUTPUT_DIR/.tmp_package_count.tsv" "
SELECT 'PACKAGE' || E'\t' || count(*)
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND p.prokind IN ('f','p')
  AND p.proname ILIKE 'pkg\_%' ESCAPE '\\'
  ${schema_filter};"
fi
cat "$OUTPUT_DIR/.tmp_package_count.tsv" >> "$F_EPAS_GROUP_COUNTS"
rm -f "$OUTPUT_DIR/.tmp_package_count.tsv"

# AUTHID grouped counter (routine defs + package catalog rows when available)
run_sql "$OUTPUT_DIR/.tmp_authid_proc_count.tsv" "
SELECT 'AUTHID' || E'\t' || count(*)
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND p.prokind IN ('f','p')
  ${schema_filter}
  AND pg_get_functiondef(p.oid) ILIKE '%authid%';"
_authid_pkg_count=0
if "${PSQL[@]}" -Atqc "SELECT to_regclass('pg_catalog.pg_package') IS NOT NULL;" | grep -qx 't'; then
  _authid_pkg_count=$("${PSQL[@]}" -Atqc "
SELECT count(*)
FROM pg_catalog.pg_package p
JOIN pg_namespace n ON n.oid = p.pkgnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter}
  AND row_to_json(p)::text ILIKE '%authid%';" 2>/dev/null || echo 0)
fi
_authid_proc_count=$(awk -F '\t' '$1=="AUTHID" {print $2}' "$OUTPUT_DIR/.tmp_authid_proc_count.tsv" 2>/dev/null)
_authid_proc_count=${_authid_proc_count:-0}
echo -e "AUTHID\t$((_authid_proc_count + _authid_pkg_count))" >> "$F_EPAS_GROUP_COUNTS"
rm -f "$OUTPUT_DIR/.tmp_authid_proc_count.tsv"

# CLOB grouped counter (column type + routine defs + package catalog rows when available)
run_sql "$OUTPUT_DIR/.tmp_clob_base_count.tsv" "
SELECT 'CLOB' || E'\t' || (
  COALESCE((
    SELECT count(*)
    FROM information_schema.columns c
    WHERE c.table_schema NOT IN ('pg_catalog','information_schema')
      ${schema_filter_table}
      AND (
        lower(c.udt_name) LIKE '%clob%'
        OR lower(c.data_type) LIKE '%clob%'
      )
  ),0)
  +
  COALESCE((
    SELECT count(*)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT IN ('pg_catalog','information_schema')
      AND p.prokind IN ('f','p')
      ${schema_filter}
      AND pg_get_functiondef(p.oid) ILIKE '%clob%'
  ),0)
);"
_clob_pkg_count=0
if "${PSQL[@]}" -Atqc "SELECT to_regclass('pg_catalog.pg_package') IS NOT NULL;" | grep -qx 't'; then
  _clob_pkg_count=$("${PSQL[@]}" -Atqc "
SELECT count(*)
FROM pg_catalog.pg_package p
JOIN pg_namespace n ON n.oid = p.pkgnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ${schema_filter}
  AND row_to_json(p)::text ILIKE '%clob%';" 2>/dev/null || echo 0)
fi
_clob_base_count=$(awk -F '\t' '$1=="CLOB" {print $2}' "$OUTPUT_DIR/.tmp_clob_base_count.tsv" 2>/dev/null)
_clob_base_count=${_clob_base_count:-0}
echo -e "CLOB\t$((_clob_base_count + _clob_pkg_count))" >> "$F_EPAS_GROUP_COUNTS"
rm -f "$OUTPUT_DIR/.tmp_clob_base_count.tsv"

echo "[INFO] Scanning migration failure risk patterns..."
run_sql "$F_MIGRATION_RISK_HITS" "
WITH sysdate_defaults AS (
  SELECT n.nspname || E'.' || c.relname || E'.' || a.attname AS object_name,
         'SYSDATE_DEFAULT' AS risk_code,
         'DEFAULT uses SYSDATE; convert to now()/CURRENT_TIMESTAMP' AS recommendation,
         CASE WHEN EXISTS (
           SELECT 1 FROM pg_depend d
           JOIN pg_extension e ON e.oid = d.refobjid
           WHERE d.classid = 'pg_class'::regclass
             AND d.objid = c.oid
             AND d.deptype = 'e'
         ) OR n.nspname IN ('sys','edb') THEN 'EDB_BUILTIN' ELSE 'USER_CREATED' END AS owner_class
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
         'Rewrite to PL/pgSQL before migration' AS recommendation,
         CASE WHEN EXISTS (
           SELECT 1 FROM pg_depend d
           JOIN pg_extension e ON e.oid = d.refobjid
           WHERE d.classid = 'pg_proc'::regclass
             AND d.objid = p.oid
             AND d.deptype = 'e'
         ) OR n.nspname IN ('sys','edb') OR n.nspname ILIKE 'utl\_%' ESCAPE '\\' OR n.nspname ILIKE 'dbms\_%' ESCAPE '\\'
           THEN 'EDB_BUILTIN' ELSE 'USER_CREATED' END AS owner_class
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
         'Skip migrating extension-managed objects (view/function)' AS recommendation,
         'EDB_BUILTIN' AS owner_class
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
    AND c.relname IN ('pg_stat_statements','pg_stat_statements_info')
  UNION ALL
  SELECT n.nspname || E'.' || p.proname AS object_name,
         'PG_STAT_STATEMENTS_OBJECT' AS risk_code,
         'Skip migrating extension-managed objects (view/function)' AS recommendation,
         'EDB_BUILTIN' AS owner_class
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
    AND p.proname IN ('pg_stat_statements','pg_stat_statements_info','pg_stat_statements_reset')
),
policy_context AS (
  SELECT n.nspname || E'.' || p.proname AS object_name,
         'POLICY_OR_CONTEXT' AS risk_code,
         'Map DBMS_RLS/SYS_CONTEXT semantics to PostgreSQL RLS + CURRENT_USER logic' AS recommendation,
         CASE WHEN EXISTS (
           SELECT 1 FROM pg_depend d
           JOIN pg_extension e ON e.oid = d.refobjid
           WHERE d.classid = 'pg_proc'::regclass
             AND d.objid = p.oid
             AND d.deptype = 'e'
         ) OR n.nspname IN ('sys','edb') OR n.nspname ILIKE 'utl\_%' ESCAPE '\\' OR n.nspname ILIKE 'dbms\_%' ESCAPE '\\'
           THEN 'EDB_BUILTIN' ELSE 'USER_CREATED' END AS owner_class
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ${schema_filter}
    AND p.prokind IN ('f','p')
    AND (
      pg_get_functiondef(p.oid) ILIKE '%dbms_rls%'
      OR pg_get_functiondef(p.oid) ILIKE '%sys_context(%'
    )
)
SELECT object_name || E'\t' || risk_code || E'\t' || recommendation || E'\t' || owner_class
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
  run_sql "$F_ORACLE_KEYWORD_HITS" "
  SELECT n.nspname || E'.' || p.proname || E'\\t' || kw.keyword
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL (
    VALUES ('SYSDATE'), ('SYSTIMESTAMP'), ('ROWNUM'), ('NVL('), ('DECODE('), ('DUAL')
  ) kw(keyword)
  WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    AND p.prokind IN ('f','p')
    AND pg_get_functiondef(p.oid) ILIKE '%' || kw.keyword || '%'
    ${schema_filter}
  ORDER BY 1;"
fi

write_reports

if [[ "$PROMPT_MODE" -eq 1 ]]; then
  echo "[INFO] --output not provided. Printing 92_migration_guide_report.md content below."
  cat "$F_GUIDE"
  rm -rf "$OUTPUT_DIR"
  echo "[DONE] Prompt mode completed."
else
  echo "[DONE] Pre-diagnostic data collected. See: $OUTPUT_DIR"
fi
