#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

usage() {
  cat <<'USAGE'
EPAS -> PostgreSQL pre-diagnostic helper

Usage:
  ./generate_epas_migration_report.sh [options] [OUT_DIR]

Options:
  -h, --host HOST         Database host (default: localhost)
  -p, --port PORT         Database port (default: 5444)
  -d, --dbname DBNAME     Database name (required)
  -U, --user USER         Database user (required)
  -W, --password PASSWORD Database password (or use PGPASSWORD env)
  -s, --schema SCHEMA     Reserved option (currently unused)
  -o, --output DIR        Output directory (if omitted, only <DBNAME>.html is kept)
  --oracle-checks         Reserved option
  --connect-timeout SEC   libpq connection timeout seconds (default: 5)
  --help                  Show this help
USAGE
}

PSQL_BIN="${PSQL_BIN:-psql}"
HOST="${PGHOST:-localhost}"
PORT="${PGPORT:-5444}"
DBNAME="${PGDATABASE:-}"
DBUSER="${PGUSER:-}"
DBPASSWORD="${PGPASSWORD:-}"
SCHEMA=""
OUT_DIR=""
ORACLE_CHECKS=0
CONNECT_TIMEOUT="5"
OUTPUT_SPECIFIED=0
CLEANUP_TEMP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    -h|--host) HOST="$2"; shift 2 ;;
    -p|--port) PORT="$2"; shift 2 ;;
    -d|--dbname) DBNAME="$2"; shift 2 ;;
    -U|--user) DBUSER="$2"; shift 2 ;;
    -W|--password) DBPASSWORD="$2"; shift 2 ;;
    -s|--schema) SCHEMA="$2"; shift 2 ;;
    -o|--output) OUT_DIR="$2"; OUTPUT_SPECIFIED=1; shift 2 ;;
    --oracle-checks) ORACLE_CHECKS=1; shift ;;
    --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "[ERROR] Unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

if [[ -z "$OUT_DIR" ]]; then
  if [[ $# -gt 0 ]]; then
    OUT_DIR="$1"
    OUTPUT_SPECIFIED=1
    shift
  else
    OUT_DIR="$(mktemp -d migration_report_tmp_XXXXXX)"
    CLEANUP_TEMP=1
  fi
fi

if [[ -z "$DBNAME" || -z "$DBUSER" ]]; then
  echo "[ERROR] --dbname and --user are required." >&2
  usage
  exit 1
fi

if ! command -v "$PSQL_BIN" >/dev/null 2>&1; then
  echo "[ERROR] psql command not found." >&2
  exit 1
fi

export PGHOST="$HOST"
export PGPORT="$PORT"
export PGDATABASE="$DBNAME"
export PGUSER="$DBUSER"
export PGCONNECT_TIMEOUT="$CONNECT_TIMEOUT"
[[ -n "$DBPASSWORD" ]] && export PGPASSWORD="$DBPASSWORD"

mkdir -p "$OUT_DIR"

SQL_FILE="${SQL_FILE:-$(cd "$(dirname "$0")" && pwd)/migration_report_queries.sql}"
[[ -f "$SQL_FILE" ]] || { echo "[ERROR] SQL file not found: $SQL_FILE" >&2; exit 1; }

DBNAME_SAFE="$(printf '%s' "$DBNAME" | tr -cs '[:alnum:]_.-' '_' )"
HTML_BASENAME="${DBNAME_SAFE}.html"
HTML_PATH="$OUT_DIR/$HTML_BASENAME"

read_sql() {
  local key="$1"
  awk -v marker="--@@ ${key}" '
    BEGIN { capture=0 }
    $0==marker { capture=1; next }
    /^--@@ / && capture { exit }
    capture { print }
  ' "$SQL_FILE"
}

run_tsv() {
  local outfile="$1"; shift
  "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -F $'\t' -P footer=off -c "$*" > "$outfile"
}

run_scalar() {
  "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -t -c "$1" | xargs
}

table_exists() {
  [[ "$(run_scalar "SELECT to_regclass('$1') IS NOT NULL;")" == "t" ]]
}

# Queries
run_tsv "$OUT_DIR/01_parameters.tsv" "$(read_sql parameters)"
run_tsv "$OUT_DIR/02_summary_packages.tsv" "$(read_sql summary_packages)"
run_tsv "$OUT_DIR/02_summary_synonyms.tsv" "$(read_sql summary_synonyms)" || true
run_tsv "$OUT_DIR/02_summary_policies.tsv" "$(read_sql summary_policies)"
run_tsv "$OUT_DIR/03_detail_keywords.tsv" "$(read_sql detail_keywords)"
run_tsv "$OUT_DIR/03_detail_datatypes_objects.tsv" "$(read_sql detail_datatypes_objects)"
run_tsv "$OUT_DIR/03_detail_datatypes_tables.tsv" "$(read_sql detail_datatypes_tables)"
run_tsv "$OUT_DIR/03_detail_expr_keywords.tsv" "$(read_sql detail_expr_keywords)"

if table_exists "pg_catalog.edb_profile"; then
  run_tsv "$OUT_DIR/04_policy_edb_profile.tsv" "$(read_sql policy_edb_profile)"
else : > "$OUT_DIR/04_policy_edb_profile.tsv"; fi
if table_exists "pg_catalog.edb_resource_group"; then
  run_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv" "$(read_sql policy_edb_resource_group)"
else : > "$OUT_DIR/04_policy_edb_resource_group.tsv"; fi
if table_exists "pg_catalog.edb_dblink"; then
  run_tsv "$OUT_DIR/04_policy_edb_dblink.tsv" "$(read_sql policy_edb_dblink)"
else : > "$OUT_DIR/04_policy_edb_dblink.tsv"; fi

# raw detail files (kept when -o used)
run_tsv "$OUT_DIR/02_summary_packages_raw.tsv" "$(read_sql summary_packages_raw)"
run_tsv "$OUT_DIR/03_detail_keywords_raw.tsv" "$(read_sql detail_keywords_raw)"
run_tsv "$OUT_DIR/03_detail_expr_raw.tsv" "$(read_sql detail_expr_raw)"

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# merged rows
PARAM_ROWS="$OUT_DIR/.param_rows.html"
awk -F $'\t' 'NR==1{next}
{
  opinion="대체 가능";
  if ($1 ~ /^(edb_audit|edb_audit_archiver|edb_early_lock_release|edb_max_capture_privileges_policies|qreplace_function|edb_stmt_level_tx|data_encryption_key_unwrap_command|edb_max_resource_groups|edb_resource_group)$/) opinion="대체 불가(수동 수정 필요)";
  else if ($1 ~ /^(edb_redwood_strings|db_dialect|datestyle|edb_redwood_greatest_least|edb_redwood_date|edb_dynatune|edb_dynatune_profile|optimizer_mode|default_with_rowids|enable_hints)$/) opinion="조건부 대체 가능";
  gsub("&","\\&amp;",$1); gsub("<","\\&lt;",$1); gsub(">","\\&gt;",$1);
  gsub("&","\\&amp;",$2); gsub("<","\\&lt;",$2); gsub(">","\\&gt;",$2);
  gsub("&","\\&amp;",$3); gsub("<","\\&lt;",$3); gsub(">","\\&gt;",$3);
  gsub("&","\\&amp;",$5); gsub("<","\\&lt;",$5); gsub(">","\\&gt;",$5);
  badge=(opinion=="대체 불가(수동 수정 필요)"?"badge-crit":(opinion=="조건부 대체 가능"?"badge-warn":"badge-ok"));
  print "<tr><td><code>"$1"</code></td><td><code>"$2"</code></td><td><code>"$3"</code></td><td>"$5"</td><td><span class=\"badge "badge"\">"opinion"</span></td></tr>";
}' "$OUT_DIR/01_parameters.tsv" > "$PARAM_ROWS"

PKG_ROWS="$OUT_DIR/.pkg_rows.html"
awk -F $'\t' 'NR==1{next}
{
  obj=$2"."$3; k=$1 SUBSEP obj;
  if(!((k SUBSEP $4) in seen)){seen[k SUBSEP $4]=1; feat[k]=(feat[k]?feat[k]", ":"")$4}
}
END{
  for(k in feat){
    split(k,a,SUBSEP); opinion="조건부 대체 가능"; badge="badge-warn";
    objid=a[2]; gsub(/[^[:alnum:]_.-]/,"_",objid);
    line="<tr><td>"a[1]"</td><td><a href=\"#src-"objid"\"><code>"a[2]"</code></a></td><td><code>"feat[k]"</code></td><td><span class=\"badge "badge"\">"opinion"</span></td></tr>";
    gsub("&","\\&amp;",line); gsub("\\&amp;lt;","&lt;",line);
    print line;
  }
}' "$OUT_DIR/02_summary_packages.tsv" > "$PKG_ROWS"

KW_ROWS="$OUT_DIR/.kw_rows.html"
awk -F $'\t' 'NR==1{next}
{
  obj=$2"."$3; key=$1 SUBSEP obj;
  kw=$4;
  op="조건부 대체 가능";
  if (kw ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|sqlerrm|raise_application_error)$/) op="대체 불가(수동 수정 필요)";
  else if (kw ~ /^(sysdate|systimestamp|nvl|nvl2|add_months|months_between|last_day|next_day|instr|greatest|least|substrb|instrb|lengthb|numtodsinterval|numtoyminterval)$/) op="대체 가능";
  if(!((key SUBSEP kw) in seen)){seen[key SUBSEP kw]=1; kws[key]=(kws[key]?kws[key]", ":"")kw}
  if(!((key SUBSEP op) in opseen)){ opm[key]=(opm[key]?opm[key]", ":"")op; opseen[key SUBSEP op]=1 }
}
END{
  for(key in kws){
    split(key,a,SUBSEP); objid=a[2]; gsub(/[^[:alnum:]_.-]/,"_",objid);
    opin=opm[key]; badge=(index(opin,"대체 불가")?"badge-crit":(index(opin,"조건부")?"badge-warn":"badge-ok"));
    print "<tr><td>"a[1]"</td><td><a href=\"#src-"objid"\"><code>"a[2]"</code></a></td><td><code>"kws[key]"</code></td><td><span class=\"badge "badge"\">"opin"</span></td></tr>";
  }
}' "$OUT_DIR/03_detail_keywords.tsv" > "$KW_ROWS"

EXPR_ROWS="$OUT_DIR/.expr_rows.html"
awk -F $'\t' 'NR==1{next}
{
  obj=$2"."$3"."$4; key=$1 SUBSEP obj; kw=$5;
  op=(kw ~ /^(sysdate|systimestamp|add_months|months_between|last_day|next_day|instr)$/)?"대체 가능":"조건부 대체 가능";
  if(!((key SUBSEP kw) in seen)){seen[key SUBSEP kw]=1; kws[key]=(kws[key]?kws[key]", ":"")kw}
  if(!((key SUBSEP op) in opseen)){ opm[key]=(opm[key]?opm[key]", ":"")op; opseen[key SUBSEP op]=1 }
}
END{
  for(key in kws){
    split(key,a,SUBSEP); objid=a[2]; gsub(/[^[:alnum:]_.-]/,"_",objid);
    opin=opm[key]; badge=(index(opin,"대체 불가")?"badge-crit":(index(opin,"조건부")?"badge-warn":"badge-ok"));
    print "<tr><td>"a[1]"</td><td><a href=\"#src-"objid"\"><code>"a[2]"</code></a></td><td><code>"kws[key]"</code></td><td><span class=\"badge "badge"\">"opin"</span></td></tr>";
  }
}' "$OUT_DIR/03_detail_expr_keywords.tsv" > "$EXPR_ROWS"

row_count_file(){ [[ -s "$1" ]] && wc -l < "$1" | xargs || echo 0; }
param_cnt=$(row_count_file "$PARAM_ROWS")
pkg_cnt=$(row_count_file "$PKG_ROWS")
kw_cnt=$(row_count_file "$KW_ROWS")
expr_cnt=$(row_count_file "$EXPR_ROWS")
syn_cnt=$(( $( [[ -s "$OUT_DIR/02_summary_synonyms.tsv" ]] && wc -l < "$OUT_DIR/02_summary_synonyms.tsv" || echo 0 ) > 0 ? $(wc -l < "$OUT_DIR/02_summary_synonyms.tsv") - 1 : 0 ))
rls_cnt=$(( $( [[ -s "$OUT_DIR/02_summary_policies.tsv" ]] && wc -l < "$OUT_DIR/02_summary_policies.tsv" || echo 0 ) > 0 ? $(wc -l < "$OUT_DIR/02_summary_policies.tsv") - 1 : 0 ))
dtype_obj_cnt=$(( $( [[ -s "$OUT_DIR/03_detail_datatypes_objects.tsv" ]] && wc -l < "$OUT_DIR/03_detail_datatypes_objects.tsv" || echo 0 ) > 0 ? $(wc -l < "$OUT_DIR/03_detail_datatypes_objects.tsv") - 1 : 0 ))
dtype_tbl_cnt=$(( $( [[ -s "$OUT_DIR/03_detail_datatypes_tables.tsv" ]] && wc -l < "$OUT_DIR/03_detail_datatypes_tables.tsv" || echo 0 ) > 0 ? $(wc -l < "$OUT_DIR/03_detail_datatypes_tables.tsv") - 1 : 0 ))
profile_cnt=$(( $( [[ -s "$OUT_DIR/04_policy_edb_profile.tsv" ]] && wc -l < "$OUT_DIR/04_policy_edb_profile.tsv" || echo 0 ) > 0 ? $(wc -l < "$OUT_DIR/04_policy_edb_profile.tsv") - 1 : 0 ))
rg_cnt=$(( $( [[ -s "$OUT_DIR/04_policy_edb_resource_group.tsv" ]] && wc -l < "$OUT_DIR/04_policy_edb_resource_group.tsv" || echo 0 ) > 0 ? $(wc -l < "$OUT_DIR/04_policy_edb_resource_group.tsv") - 1 : 0 ))
dblink_cnt=$(( $( [[ -s "$OUT_DIR/04_policy_edb_dblink.tsv" ]] && wc -l < "$OUT_DIR/04_policy_edb_dblink.tsv" || echo 0 ) > 0 ? $(wc -l < "$OUT_DIR/04_policy_edb_dblink.tsv") - 1 : 0 ))

default_row_if_empty() {
  local f="$1" cols="$2"
  if [[ ! -s "$f" ]]; then
    printf '<tr><td colspan="%s">검출 없음</td></tr>' "$cols"
  else
    cat "$f"
  fi
}

syn_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s.%s</code></td><td><code>%s.%s</code></td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$1,$2,$3,$4}' "$OUT_DIR/02_summary_synonyms.tsv")
rls_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s.%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$1,$2,$3,$6}' "$OUT_DIR/02_summary_policies.tsv")
dtype_obj_rows_html=$(awk -F $'\t' 'NR==1{next}{o=($4=="clob"?"대체 가능":"조건부 대체 가능"); b=(o=="대체 가능"?"badge-ok":"badge-warn"); printf "<tr><td>%s</td><td><code>%s.%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",$1,$2,$3,$4,b,o}' "$OUT_DIR/03_detail_datatypes_objects.tsv")
dtype_tbl_rows_html=$(awk -F $'\t' 'NR==1{next}{o=($4=="clob"?"대체 가능":"조건부 대체 가능"); b=(o=="대체 가능"?"badge-ok":"badge-warn"); printf "<tr><td><code>%s.%s.%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",$1,$2,$3,$4,b,o}' "$OUT_DIR/03_detail_datatypes_tables.tsv")
profile_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s</code></td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$2}' "$OUT_DIR/04_policy_edb_profile.tsv")
rg_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s</code></td><td>%s</td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$4,$2}' "$OUT_DIR/04_policy_edb_resource_group.tsv")
dblink_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s</code></td><td>%s</td><td><code>%s</code></td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$1,$5,$6}' "$OUT_DIR/04_policy_edb_dblink.tsv")

# source blocks
SRC_BLOCKS="$OUT_DIR/.src_blocks.html"
: > "$SRC_BLOCKS"
awk -F $'\t' 'NR==1{next}{id=$2"."$3; gsub(/[^[:alnum:]_.-]/,"_",id); print id "\t" $1 "\t" $2 "." $3 "\t" $4}' "$OUT_DIR/02_summary_packages_raw.tsv" > "$OUT_DIR/.src_raw.tsv"
awk -F $'\t' 'NR==1{next}{id=$2"."$3; gsub(/[^[:alnum:]_.-]/,"_",id); print id "\t" $1 "\t" $2 "." $3 "\t" $4}' "$OUT_DIR/03_detail_keywords_raw.tsv" >> "$OUT_DIR/.src_raw.tsv"
awk -F $'\t' 'NR==1{next}{id=$2"."$3"."$4; gsub(/[^[:alnum:]_.-]/,"_",id); print id "\t" $1 "\t" $2 "." $3 "." $4 "\t" $5}' "$OUT_DIR/03_detail_expr_raw.tsv" >> "$OUT_DIR/.src_raw.tsv"
awk -F $'\t' '!seen[$1]++{print}' "$OUT_DIR/.src_raw.tsv" | while IFS=$'\t' read -r sid stype sobj stext; do
  esc=$(printf '%s' "$stext" | html_escape)
  printf '<details id="src-%s"><summary><code>%s</code> (%s)</summary><pre>%s</pre></details>\n' "$sid" "$sobj" "$stype" "$esc" >> "$SRC_BLOCKS"
done

cat > "$HTML_PATH" <<HTML
<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>EPAS to PostgreSQL Precheck - ${DBNAME}</title>
<style>
body{font-family:Arial,sans-serif;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:24px 44px}.card{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:16px 20px;margin-bottom:16px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #d1d5db;padding:8px;vertical-align:top}th{background:#f3f4f6}.group-title td{background:#e0e7ff;font-weight:700}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}.badge-crit{color:#991b1b;background:#fee2e2;border:1px solid #fecaca}.badge-warn{color:#92400e;background:#fef3c7;border:1px solid #fde68a}.badge-ok{color:#065f46;background:#d1fae5;border:1px solid #a7f3d0}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}details{margin:8px 0}pre{background:#0b1020;color:#f8fafc;padding:12px;border-radius:8px;overflow:auto;white-space:pre-wrap}
</style></head><body><div class="container">
<h1>EPAS to PostgreSQL Precheck</h1>
<div class="card"><h2>요약</h2><table>
<tr><th>항목</th><th>검출 건수</th><th>설명</th></tr>
<tr class="group-title"><td colspan="3">1. 파라미터</td></tr><tr><td>1-1. 파라미터(점검 대상)</td><td>${param_cnt}</td><td>핵심 호환 파라미터 + 기본값 대비 변경값</td></tr>
<tr class="group-title"><td colspan="3">2. EDB(Oracle) 특화기능 Summary</td></tr><tr><td>2-1. EDB 특화 기능</td><td>${pkg_cnt}</td><td>객체 기준 중복 제거 후 집계</td></tr><tr><td>2-2. 시노님</td><td>${syn_cnt}</td><td>시노님 정의</td></tr><tr><td>2-3. 정책(RLS)</td><td>${rls_cnt}</td><td>RLS 정책</td></tr>
<tr class="group-title"><td colspan="3">3. 디테일 (user created)</td></tr><tr><td>3-1. 오라클 키워드/함수</td><td>${kw_cnt}</td><td>동일 객체 키워드 merge</td></tr><tr><td>3-2. 오라클 데이터타입(함수/프로시저/뷰)</td><td>${dtype_obj_cnt}</td><td>객체 내부 타입</td></tr><tr><td>3-3. 오라클 데이터타입(테이블)</td><td>${dtype_tbl_cnt}</td><td>컬럼 타입</td></tr><tr><td>3-4. 기본값/제약조건/인덱스 표현식</td><td>${expr_cnt}</td><td>동일 객체 키워드 merge</td></tr>
<tr class="group-title"><td colspan="3">4. 폴리시 디테일 (user created)</td></tr><tr><td>4-1. 프로파일</td><td>${profile_cnt}</td><td>non-default profile</td></tr><tr><td>4-2. 리소스 그룹</td><td>${rg_cnt}</td><td>resource group</td></tr><tr><td>4-3. DBLINK</td><td>${dblink_cnt}</td><td>dblink</td></tr>
</table></div>
<div class="card"><h2>대체 가능 여부</h2><table><tr><th>구분</th><th>설명</th></tr><tr><td><span class="badge badge-crit">대체 불가(수동 수정 필요)</span></td><td>수동 재작성 또는 기능 재설계가 필요합니다.</td></tr><tr><td><span class="badge badge-warn">조건부 대체 가능</span></td><td>부분 재작성/확장모듈/설정 변경으로 전환 가능합니다.</td></tr><tr><td><span class="badge badge-ok">대체 가능</span></td><td>표준 기능 또는 대체 함수로 대응 가능합니다.</td></tr></table></div>
<div class="card"><h2>검출 상세(표)</h2>
<h3>1-1. 파라미터 (${param_cnt}건)</h3><table><tr><th>파라미터</th><th>기본값</th><th>현재값</th><th>설명</th><th>소견</th></tr>$(default_row_if_empty "$PARAM_ROWS" 5)</table>
<h3>2-1. EDB 특화 기능 (${pkg_cnt}건)</h3><table><tr><th>객체 타입</th><th>객체</th><th>검출 내용</th><th>소견</th></tr>$(default_row_if_empty "$PKG_ROWS" 4)</table>
<h3>2-2. 시노님 (${syn_cnt}건)</h3><table><tr><th>시노님</th><th>대상 객체</th><th>소견</th></tr>$( [ -n "$syn_rows_html" ] && echo "$syn_rows_html" || echo '<tr><td colspan="3">검출 없음</td></tr>' )</table>
<h3>2-3. 정책(RLS) (${rls_cnt}건)</h3><table><tr><th>대상 테이블</th><th>정책명</th><th>명령</th><th>소견</th></tr>$( [ -n "$rls_rows_html" ] && echo "$rls_rows_html" || echo '<tr><td colspan="4">검출 없음</td></tr>' )</table>
<h3>3-1. 오라클 키워드/함수 (${kw_cnt}건)</h3><table><tr><th>객체 타입</th><th>객체</th><th>검출 키워드</th><th>소견</th></tr>$(default_row_if_empty "$KW_ROWS" 4)</table>
<h3>3-2. 오라클 데이터타입(함수/프로시저/뷰) (${dtype_obj_cnt}건)</h3><table><tr><th>객체 타입</th><th>객체</th><th>데이터타입</th><th>소견</th></tr>$( [ -n "$dtype_obj_rows_html" ] && echo "$dtype_obj_rows_html" || echo '<tr><td colspan="4">검출 없음</td></tr>' )</table>
<h3>3-3. 오라클 데이터타입(테이블) (${dtype_tbl_cnt}건)</h3><table><tr><th>컬럼</th><th>데이터타입</th><th>소견</th></tr>$( [ -n "$dtype_tbl_rows_html" ] && echo "$dtype_tbl_rows_html" || echo '<tr><td colspan="3">검출 없음</td></tr>' )</table>
<h3>3-4. 기본값/제약조건/인덱스 표현식 (${expr_cnt}건)</h3><table><tr><th>객체 타입</th><th>객체</th><th>검출 키워드</th><th>소견</th></tr>$(default_row_if_empty "$EXPR_ROWS" 4)</table>
<h3>4-1. 프로파일 (${profile_cnt}건)</h3><table><tr><th>프로파일</th><th>소견</th></tr>$( [ -n "$profile_rows_html" ] && echo "$profile_rows_html" || echo '<tr><td colspan="2">검출 없음</td></tr>' )</table>
<h3>4-2. 리소스 그룹 (${rg_cnt}건)</h3><table><tr><th>리소스 그룹</th><th>CPU limit</th><th>소견</th></tr>$( [ -n "$rg_rows_html" ] && echo "$rg_rows_html" || echo '<tr><td colspan="3">검출 없음</td></tr>' )</table>
<h3>4-3. DBLINK (${dblink_cnt}건)</h3><table><tr><th>DBLINK</th><th>USER</th><th>연결정보</th><th>소견</th></tr>$( [ -n "$dblink_rows_html" ] && echo "$dblink_rows_html" || echo '<tr><td colspan="4">검출 없음</td></tr>' )</table>
</div>
<div class="card"><h2>원문 상세 (객체 클릭 시 이동)</h2>$( [ -s "$SRC_BLOCKS" ] && cat "$SRC_BLOCKS" || echo '<p>원문 없음</p>' )</div>
</div></body></html>
HTML

cat > "$OUT_DIR/REPORT_INDEX.txt" <<TXT
[EPAS to PostgreSQL Precheck]
Output directory : $OUT_DIR
Connection hints : host=${HOST:-N/A}, port=${PORT:-N/A}, db=${DBNAME:-N/A}, user=${DBUSER:-N/A}
HTML report      : ${HTML_BASENAME}
TXT

if [[ "$CLEANUP_TEMP" -eq 1 ]]; then
  cp "$HTML_PATH" "./$HTML_BASENAME"
  rm -rf "$OUT_DIR"
  echo "[DONE] Report generated: ./$HTML_BASENAME (temporary TSV files removed)"
else
  echo "[DONE] Report generated at: $OUT_DIR"
  echo "       Open HTML: $OUT_DIR/$HTML_BASENAME"
fi
