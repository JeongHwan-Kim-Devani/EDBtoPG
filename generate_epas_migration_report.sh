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
OUT_DIR=""
CONNECT_TIMEOUT="5"
CLEANUP_TEMP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    -h|--host) HOST="$2"; shift 2 ;;
    -p|--port) PORT="$2"; shift 2 ;;
    -d|--dbname) DBNAME="$2"; shift 2 ;;
    -U|--user) DBUSER="$2"; shift 2 ;;
    -W|--password) DBPASSWORD="$2"; shift 2 ;;
    -s|--schema) shift 2 ;;
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    --oracle-checks) shift ;;
    --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "[ERROR] Unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

if [[ -z "$OUT_DIR" ]]; then
  if [[ $# -gt 0 ]]; then
    OUT_DIR="$1"; shift
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
command -v "$PSQL_BIN" >/dev/null 2>&1 || { echo "[ERROR] psql not found" >&2; exit 1; }

export PGHOST="$HOST" PGPORT="$PORT" PGDATABASE="$DBNAME" PGUSER="$DBUSER" PGCONNECT_TIMEOUT="$CONNECT_TIMEOUT"
[[ -n "$DBPASSWORD" ]] && export PGPASSWORD="$DBPASSWORD"

mkdir -p "$OUT_DIR"
SQL_FILE="${SQL_FILE:-$(cd "$(dirname "$0")" && pwd)/migration_report_queries.sql}"
[[ -f "$SQL_FILE" ]] || { echo "[ERROR] SQL file not found: $SQL_FILE" >&2; exit 1; }
DBNAME_SAFE="$(printf '%s' "$DBNAME" | tr -cs '[:alnum:]_.-' '_')"
HTML_BASENAME="${DBNAME_SAFE}.html"
HTML_PATH="$OUT_DIR/$HTML_BASENAME"

read_sql() {
  local key="$1"
  awk -v marker="--@@ ${key}" 'BEGIN{capture=0} $0==marker{capture=1;next} /^--@@ /&&capture{exit} capture{print}' "$SQL_FILE"
}
run_tsv(){ local f="$1"; shift; "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -F $'\t' -P footer=off -c "$*" > "$f"; }
run_scalar(){ "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -t -c "$1" | xargs; }
table_exists(){ [[ "$(run_scalar "SELECT to_regclass('$1') IS NOT NULL;")" == "t" ]]; }
row_count_tsv(){ [[ -s "$1" ]] && awk 'END{print (NR>0?NR-1:0)}' "$1" || echo 0; }
row_count_plain(){ [[ -s "$1" ]] && wc -l < "$1" | xargs || echo 0; }

# Extracts
run_tsv "$OUT_DIR/01_parameters.tsv" "$(read_sql parameters)"
run_tsv "$OUT_DIR/02_summary_packages.tsv" "$(read_sql summary_packages)"
run_tsv "$OUT_DIR/02_summary_synonyms.tsv" "$(read_sql summary_synonyms)" || true
run_tsv "$OUT_DIR/02_summary_policies.tsv" "$(read_sql summary_policies)"
run_tsv "$OUT_DIR/03_detail_keywords.tsv" "$(read_sql detail_keywords)"
run_tsv "$OUT_DIR/03_detail_datatypes_objects.tsv" "$(read_sql detail_datatypes_objects)"
run_tsv "$OUT_DIR/03_detail_datatypes_tables.tsv" "$(read_sql detail_datatypes_tables)"
run_tsv "$OUT_DIR/03_detail_expr_keywords.tsv" "$(read_sql detail_expr_keywords)"

if table_exists "pg_catalog.edb_profile"; then run_tsv "$OUT_DIR/04_policy_edb_profile.tsv" "$(read_sql policy_edb_profile)"; else : > "$OUT_DIR/04_policy_edb_profile.tsv"; fi
if table_exists "pg_catalog.edb_resource_group"; then run_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv" "$(read_sql policy_edb_resource_group)"; else : > "$OUT_DIR/04_policy_edb_resource_group.tsv"; fi
if table_exists "pg_catalog.edb_dblink"; then run_tsv "$OUT_DIR/04_policy_edb_dblink.tsv" "$(read_sql policy_edb_dblink)"; else : > "$OUT_DIR/04_policy_edb_dblink.tsv"; fi

# raw details for drill-down
run_tsv "$OUT_DIR/02_summary_packages_raw.tsv" "$(read_sql summary_packages_raw)"
run_tsv "$OUT_DIR/03_detail_keywords_raw.tsv" "$(read_sql detail_keywords_raw)"
run_tsv "$OUT_DIR/03_detail_expr_raw.tsv" "$(read_sql detail_expr_raw)"

# HTML row temp files
PARAM_ROWS="$OUT_DIR/.param_rows.html"
FEATURE_ROWS="$OUT_DIR/.feature_rows.html"
DTYPE_ROWS="$OUT_DIR/.dtype_rows.html"
EXPR_ROWS="$OUT_DIR/.expr_rows.html"
SRC_BLOCKS="$OUT_DIR/.src_blocks.html"

awk -F $'\t' 'NR==1{next}
{
  op="대체 가능"
  if ($1 ~ /^(edb_audit|edb_audit_archiver|edb_early_lock_release|edb_max_capture_privileges_policies|qreplace_function|edb_stmt_level_tx|data_encryption_key_unwrap_command|edb_max_resource_groups|edb_resource_group)$/) op="대체 불가(수동 수정 필요)"
  else if ($1 ~ /^(edb_redwood_strings|db_dialect|datestyle|edb_redwood_greatest_least|edb_redwood_date|edb_dynatune|edb_dynatune_profile|optimizer_mode|default_with_rowids|enable_hints)$/) op="조건부 대체 가능"
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  b=(op=="대체 불가(수동 수정 필요)"?"badge-crit":(op=="조건부 대체 가능"?"badge-warn":"badge-ok"))
  printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge %s\">%s</span></td></tr>\n",$1,$2,$3,$5,b,op
}' "$OUT_DIR/01_parameters.tsv" > "$PARAM_ROWS"

# 2-1 + 3-1 merged
awk -F $'\t' 'NR==1{next}{print $1"\t"$2"\t"$3"\t"$4"\tPACKAGE"}' "$OUT_DIR/02_summary_packages.tsv" > "$OUT_DIR/.feature_src.tsv"
awk -F $'\t' 'NR==1{next}{print $1"\t"$2"\t"$3"\t"$4"\tKEYWORD"}' "$OUT_DIR/03_detail_keywords.tsv" >> "$OUT_DIR/.feature_src.tsv"
awk -F $'\t' '
{
  type=$1; schema=$2; obj=$3; token=$4; src=$5; k=schema SUBSEP type SUBSEP obj
  if (!((k SUBSEP token) in seen)){ seen[k SUBSEP token]=1; tokens[k]=(tokens[k]?tokens[k]", ":"")token }
  if (src=="PACKAGE") pkg[k]=1; else kw[k]=1
  op="조건부 대체 가능"
  if (token ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|sqlerrm|raise_application_error)$/) op="대체 불가(수동 수정 필요)"
  else if (token ~ /^(sysdate|systimestamp|nvl|nvl2|add_months|months_between|last_day|next_day|instr|greatest|least|substrb|instrb|lengthb|numtodsinterval|numtoyminterval)$/) op="대체 가능"
  if (!((k SUBSEP op) in opseen)){ opseen[k SUBSEP op]=1; ops[k]=(ops[k]?ops[k]", ":"")op }
}
END{
  for(k in tokens){
    split(k,a,SUBSEP)
    gsub("&","&amp;",tokens[k]); gsub("<","&lt;",tokens[k]); gsub(">","&gt;",tokens[k])
    obj=a[2]"|"a[1]"."a[3]
    role=(pkg[k]&&kw[k]?"패키지+키워드":(pkg[k]?"패키지":"키워드"))
    print a[1]"\t"a[2]"\t"a[3]"\t"role"\t"tokens[k]"\t"ops[k]"\t"obj
  }
}' "$OUT_DIR/.feature_src.tsv" | sort -t $'\t' -k1,1 -k2,2 -k3,3 | awk -F $'\t' '
{
  schema=$1; type=$2; obj=$3; role=$4; tokens=$5; op=$6; objid=$7
  gsub(/[^[:alnum:]_.|-]/,"_",objid); gsub("|",".",objid)
  b=(index(op,"대체 불가")?"badge-crit":(index(op,"조건부")?"badge-warn":"badge-ok"))
  printf "<tr><td><code>%s</code></td><td>%s</td><td><a href=\"#src-%s\"><code>%s.%s</code></a></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",type,role,objid,schema,obj,tokens,b,op
}' > "$FEATURE_ROWS"

# 3-2 + 3-3 merged (no opinion)
awk -F $'\t' 'NR==1{next}{printf "%s\t%s\t%s\t%s\n",$1,$2,$3,$4}' "$OUT_DIR/03_detail_datatypes_objects.tsv" > "$OUT_DIR/.dtype_src.tsv"
awk -F $'\t' 'NR==1{next}{printf "T\t%s\t%s.%s\t%s\n",$1,$2,$3,$4}' "$OUT_DIR/03_detail_datatypes_tables.tsv" >> "$OUT_DIR/.dtype_src.tsv"
sort -t $'\t' -k2,2 -k1,1 -k3,3 "$OUT_DIR/.dtype_src.tsv" | awk -F $'\t' '
{printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td></tr>\n",$1,$2"."$3,$4}
' > "$DTYPE_ROWS"

# 3-4 object/type order + index name
awk -F $'\t' 'NR==1{next}
{
  type=$1; schema=$2; tab=$3; target=$4; kw=$5
  obj=(type=="INDEX EXPRESSION"?schema"."target:schema"."tab"."target)
  k=obj SUBSEP type
  if(!((k SUBSEP kw) in seen)){ seen[k SUBSEP kw]=1; kws[k]=(kws[k]?kws[k]", ":"")kw }
  op=(kw ~ /^(sysdate|systimestamp|add_months|months_between|last_day|next_day|instr)$/)?"대체 가능":"조건부 대체 가능"
  if(!((k SUBSEP op) in opseen)){ opseen[k SUBSEP op]=1; ops[k]=(ops[k]?ops[k]", ":"")op }
}
END{
  for(k in kws){ split(k,a,SUBSEP); print a[1]"\t"a[2]"\t"kws[k]"\t"ops[k] }
}' "$OUT_DIR/03_detail_expr_keywords.tsv" | sort -t $'\t' -k1,1 -k2,2 | awk -F $'\t' '
{
  obj=$1; type=$2; kw=$3; op=$4; objid=obj; gsub(/[^[:alnum:]_.-]/,"_",objid)
  gsub("&","&amp;",kw); gsub("<","&lt;",kw); gsub(">","&gt;",kw)
  b=(index(op,"대체 불가")?"badge-crit":(index(op,"조건부")?"badge-warn":"badge-ok"))
  printf "<tr><td><a href=\"#src-%s\"><code>%s</code></a></td><td><code>%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",objid,obj,type,kw,b,op
}' > "$EXPR_ROWS"

# source drill-down
: > "$SRC_BLOCKS"
awk -F $'\t' 'NR==1{next}{id=$1"|"$2"."$3; gsub(/[^[:alnum:]_.|-]/,"_",id); print id"\t"$1"\t"$2"."$3"\t"$4}' "$OUT_DIR/02_summary_packages_raw.tsv" > "$OUT_DIR/.src.tsv"
awk -F $'\t' 'NR==1{next}{id=$1"|"$2"."$3; gsub(/[^[:alnum:]_.|-]/,"_",id); print id"\t"$1"\t"$2"."$3"\t"$4}' "$OUT_DIR/03_detail_keywords_raw.tsv" >> "$OUT_DIR/.src.tsv"
awk -F $'\t' 'NR==1{next}{obj=($1=="INDEX EXPRESSION"?$2"."$4:$2"."$3"."$4); id=obj; gsub(/[^[:alnum:]_.-]/,"_",id); print id"\t"$1"\t"obj"\t"$5}' "$OUT_DIR/03_detail_expr_raw.tsv" >> "$OUT_DIR/.src.tsv"
awk -F $'\t' '!seen[$1]++{print}' "$OUT_DIR/.src.tsv" | while IFS=$'\t' read -r sid stype sobj stext; do
  esc=$(printf '%s' "$stext" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
  printf '<details id="src-%s"><summary><code>%s</code> (%s)</summary><pre>%s</pre></details>\n' "$sid" "$sobj" "$stype" "$esc" >> "$SRC_BLOCKS"
done

param_cnt=$(row_count_plain "$PARAM_ROWS")
feature_cnt=$(row_count_plain "$FEATURE_ROWS")
syn_cnt=$(row_count_tsv "$OUT_DIR/02_summary_synonyms.tsv")
rls_cnt=$(row_count_tsv "$OUT_DIR/02_summary_policies.tsv")
dtype_cnt=$(row_count_plain "$DTYPE_ROWS")
expr_cnt=$(row_count_plain "$EXPR_ROWS")
profile_cnt=$(row_count_tsv "$OUT_DIR/04_policy_edb_profile.tsv")
rg_cnt=$(row_count_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv")
dblink_cnt=$(row_count_tsv "$OUT_DIR/04_policy_edb_dblink.tsv")

section_status() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    echo "대체 가능"
    return
  fi
  if grep -q "대체 불가" "$file"; then
    echo "대체 불가 포함"
  elif grep -q "조건부" "$file"; then
    echo "조건부 대체"
  else
    echo "대체 가능"
  fi
}

param_status=$(section_status "$PARAM_ROWS")
feature_status=$(section_status "$FEATURE_ROWS")
syn_status="조건부 대체"
rls_status="조건부 대체"
dtype_status="조건부 대체"
expr_status=$(section_status "$EXPR_ROWS")
profile_status="조건부 대체"
rg_status="조건부 대체"
dblink_status="조건부 대체"

default_row_if_empty(){ [[ -s "$1" ]] && cat "$1" || printf '<tr><td colspan="%s">검출 없음</td></tr>' "$2"; }

syn_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s.%s</code></td><td><code>%s.%s</code></td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$1,$2,$3,$4}' "$OUT_DIR/02_summary_synonyms.tsv")
rls_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s.%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$1,$2,$3,$6}' "$OUT_DIR/02_summary_policies.tsv")
profile_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s</code></td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$2}' "$OUT_DIR/04_policy_edb_profile.tsv")
rg_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s</code></td><td>%s</td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$4,$2}' "$OUT_DIR/04_policy_edb_resource_group.tsv")
dblink_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s</code></td><td>%s</td><td><code>%s</code></td><td><span class=\"badge badge-warn\">조건부 대체 가능</span></td></tr>\n",$1,$5,$6}' "$OUT_DIR/04_policy_edb_dblink.tsv")

cat > "$HTML_PATH" <<HTML
<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>EPAS to PostgreSQL Precheck - ${DBNAME}</title>
<style>
body{font-family:Arial,sans-serif;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:24px 44px}.card{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:16px 20px;margin-bottom:16px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #d1d5db;padding:8px;vertical-align:top}th{background:#f3f4f6}.group-title td{background:#e0e7ff;font-weight:700}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}.badge-crit{color:#991b1b;background:#fee2e2;border:1px solid #fecaca}.badge-warn{color:#92400e;background:#fef3c7;border:1px solid #fde68a}.badge-ok{color:#065f46;background:#d1fae5;border:1px solid #a7f3d0}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}details{margin:8px 0}pre{background:#0b1020;color:#f8fafc;padding:12px;border-radius:8px;overflow:auto;white-space:pre-wrap}
</style></head><body><div class="container">
<h1>EPAS to PostgreSQL Precheck</h1>
<div class="card"><h2>요약</h2><table>
<tr><th>항목</th><th>검출 건수</th><th>가능/불가</th><th>설명</th></tr>
<tr class="group-title"><td colspan="4">1. 파라미터</td></tr><tr><td>1-1. 파라미터</td><td>${param_cnt}</td><td>${param_status}</td><td>핵심 파라미터 + 변경값</td></tr>
<tr class="group-title"><td colspan="4">2. EDB(Oracle) 특화기능 + 키워드</td></tr><tr><td>2-1. 패키지/키워드 통합</td><td>${feature_cnt}</td><td>${feature_status}</td><td>2-1 + 3-1 통합, 동일 객체 merge</td></tr><tr><td>2-2. 시노님</td><td>${syn_cnt}</td><td>${syn_status}</td><td>시노님 정의</td></tr><tr><td>2-3. 정책(RLS)</td><td>${rls_cnt}</td><td>${rls_status}</td><td>RLS 정책</td></tr>
<tr class="group-title"><td colspan="4">3. 디테일 (user created)</td></tr><tr><td>3-2/3-3. 오라클 데이터타입 통합</td><td>${dtype_cnt}</td><td>${dtype_status}</td><td>객체+테이블 merge (소견 제외)</td></tr><tr><td>3-4. 기본값/제약조건/인덱스 표현식</td><td>${expr_cnt}</td><td>${expr_status}</td><td>오브젝트/타입 순 정렬</td></tr>
<tr class="group-title"><td colspan="4">4. 폴리시 디테일 (user created)</td></tr><tr><td>4-1. 프로파일</td><td>${profile_cnt}</td><td>${profile_status}</td><td>non-default</td></tr><tr><td>4-2. 리소스 그룹</td><td>${rg_cnt}</td><td>${rg_status}</td><td>resource group</td></tr><tr><td>4-3. DBLINK</td><td>${dblink_cnt}</td><td>${dblink_status}</td><td>dblink</td></tr>
</table></div>
<div class="card"><h2>대체 가능 여부</h2><table><tr><th>구분</th><th>설명</th></tr><tr><td><span class="badge badge-crit">대체 불가(수동 수정 필요)</span></td><td>수동 재작성 또는 기능 재설계가 필요합니다.</td></tr><tr><td><span class="badge badge-warn">조건부 대체 가능</span></td><td>부분 재작성/확장모듈/설정 변경으로 전환 가능합니다.</td></tr><tr><td><span class="badge badge-ok">대체 가능</span></td><td>표준 기능 또는 대체 함수로 대응 가능합니다.</td></tr></table></div>
<div class="card"><h2>검출 상세(표)</h2>
<h3>1-1. 파라미터 (${param_cnt}건)</h3><table><tr><th>파라미터</th><th>기본값</th><th>현재값</th><th>설명</th><th>소견</th></tr>$(default_row_if_empty "$PARAM_ROWS" 5)</table>
<h3>2-1. 특화기능+오라클 키워드 통합 (${feature_cnt}건)</h3><table><tr><th>타입(P/F/V)</th><th>구분</th><th>객체</th><th>검출 내용</th><th>소견</th></tr>$(default_row_if_empty "$FEATURE_ROWS" 5)</table>
<h3>2-2. 시노님 (${syn_cnt}건)</h3><table><tr><th>시노님</th><th>대상 객체</th><th>소견</th></tr>$( [ -n "$syn_rows_html" ] && echo "$syn_rows_html" || echo '<tr><td colspan="3">검출 없음</td></tr>' )</table>
<h3>2-3. 정책(RLS) (${rls_cnt}건)</h3><table><tr><th>대상 테이블</th><th>정책명</th><th>명령</th><th>소견</th></tr>$( [ -n "$rls_rows_html" ] && echo "$rls_rows_html" || echo '<tr><td colspan="4">검출 없음</td></tr>' )</table>
<h3>3-2/3-3. 오라클 데이터타입 통합 (${dtype_cnt}건)</h3><table><tr><th>타입(P/F/V/T)</th><th>객체</th><th>데이터타입</th></tr>$(default_row_if_empty "$DTYPE_ROWS" 3)</table>
<h3>3-4. 기본값/제약조건/인덱스 표현식 (${expr_cnt}건)</h3><table><tr><th>객체</th><th>타입</th><th>검출 키워드</th><th>소견</th></tr>$(default_row_if_empty "$EXPR_ROWS" 4)</table>
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
