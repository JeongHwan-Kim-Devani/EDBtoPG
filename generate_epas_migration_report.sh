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
SOURCE_HTML_BASENAME="${DBNAME_SAFE}_source.html"
SOURCE_HTML_PATH="$OUT_DIR/$SOURCE_HTML_BASENAME"

read_sql() {
  local key="$1"
  local marker="--@@ ${key}"
  local capturing=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$capturing" -eq 0 ]]; then
      [[ "$line" == "$marker" ]] && capturing=1
      continue
    fi
    [[ "$line" == --@@\ * ]] && break
    printf '%s\n' "$line"
  done < "$SQL_FILE"
}

run_tsv(){ local f="$1"; shift; "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -F $'\t' -P footer=off -c "$*" > "$f"; }
run_scalar(){ "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -t -c "$1" | xargs; }
table_exists(){ [[ "$(run_scalar "SELECT to_regclass('$1') IS NOT NULL;")" == "t" ]]; }

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

run_tsv "$OUT_DIR/02_summary_packages_raw.tsv" "$(read_sql summary_packages_raw)"
run_tsv "$OUT_DIR/03_detail_keywords_raw.tsv" "$(read_sql detail_keywords_raw)"
run_tsv "$OUT_DIR/03_detail_expr_raw.tsv" "$(read_sql detail_expr_raw)"

# merged outputs
PARAM_ROWS="$OUT_DIR/.param_rows.html"
FEATURE_ROWS="$OUT_DIR/.feature_rows.html"
DTYPE_ROWS="$OUT_DIR/.dtype_rows.html"
EXPR_ROWS="$OUT_DIR/.expr_rows.html"

# 1) parameter rows
awk -F $'\t' 'NR==1{next}
{
  op="대체 가능"
  if ($1 ~ /^(edb_audit|edb_audit_archiver|edb_early_lock_release|edb_max_capture_privileges_policies|qreplace_function|edb_stmt_level_tx|data_encryption_key_unwrap_command|edb_max_resource_groups|edb_resource_group)$/) op="대체 불가"
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  b=(op=="대체 불가"?"badge-crit":"badge-ok")
  printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge %s\">%s</span></td></tr>\n",$1,$2,$3,$5,b,op
}' "$OUT_DIR/01_parameters.tsv" > "$PARAM_ROWS"

# 2-1) packages + keywords merged, sort by type F/P/V and full name labels
awk -F $'\t' 'NR==1{next}{print $1"\t"$2"\t"$3"\t"$4"\tPACKAGE"}' "$OUT_DIR/02_summary_packages.tsv" > "$OUT_DIR/.feature_src.tsv"
awk -F $'\t' 'NR==1{next}{print $1"\t"$2"\t"$3"\t"$4"\tKEYWORD"}' "$OUT_DIR/03_detail_keywords.tsv" >> "$OUT_DIR/.feature_src.tsv"

awk -F $'\t' '
{
  t=$1;s=$2;o=$3;token=$4;src=$5; k=t SUBSEP s SUBSEP o
  if(!((k SUBSEP token) in seen)){seen[k SUBSEP token]=1; tokens[k]=(tokens[k]?tokens[k]", ":"")token}
  if(src=="PACKAGE") has_pkg[k]=1; if(src=="KEYWORD") has_kw[k]=1
  op="가능"
  if(token ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|sqlerrm|raise_application_error)$/) op="불가"
  if(!((k SUBSEP op) in opseen)){ opseen[k SUBSEP op]=1; ops[k]=(ops[k]?ops[k]", ":"")op }
}
END{
  for(k in tokens){
    split(k,a,SUBSEP)
    ord=(a[1]=="F"?1:(a[1]=="P"?2:3))
    tname=(a[1]=="F"?"FUNCTION":(a[1]=="P"?"PROCEDURE":"VIEW"))
    role=(has_pkg[k]&&has_kw[k]?"패키지+키워드":(has_pkg[k]?"패키지":"키워드"))
    objid=a[2]"."a[3]
    print ord"\t"a[2]"\t"tname"\t"role"\t"a[2]"."a[3]"\t"tokens[k]"\t"ops[k]"\t"objid
  }
}' "$OUT_DIR/.feature_src.tsv" | sort -t $'\t' -k1,1n -k2,2 -k5,5 | awk -F $'\t' '
{
  objid=$8; gsub(/[^[:alnum:]_.-]/,"_",objid)
  gsub("&","&amp;",$6); gsub("<","&lt;",$6); gsub(">","&gt;",$6)
  b=(index($7,"불가")?"badge-crit":"badge-ok")
  printf "<tr><td><code>%s</code></td><td>%s</td><td><a href=\"%s#src-%s\"><code>%s</code></a></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",$3,$4,ENVIRON["SOURCE_HTML_BASENAME"],objid,$5,$6,b,$7
}' > "$FEATURE_ROWS"

# 3-1) datatype merged sort P/F/V/T and full names
awk -F $'\t' 'NR==1{next}{print $1"\t"$2"\t"$3"\t"$4}' "$OUT_DIR/03_detail_datatypes_objects.tsv" > "$OUT_DIR/.dtype_src.tsv"
awk -F $'\t' 'NR==1{next}{print "T\t"$1"\t"$2"."$3"\t"$4}' "$OUT_DIR/03_detail_datatypes_tables.tsv" >> "$OUT_DIR/.dtype_src.tsv"
awk -F $'\t' '
{
  ord=($1=="P"?1:($1=="F"?2:($1=="V"?3:4)))
  tname=($1=="P"?"PROCEDURE":($1=="F"?"FUNCTION":($1=="V"?"VIEW":"TABLE COLUMN")))
  print ord"\t"$2"\t"tname"\t"$3"\t"$4
}' "$OUT_DIR/.dtype_src.tsv" | sort -t $'\t' -k1,1n -k2,2 -k4,4 | awk -F $'\t' '{printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td></tr>\n",$3,$4,$5}' > "$DTYPE_ROWS"

# 3-4) expression rows
awk -F $'\t' 'NR==1{next}
{
  obj=($1=="INDEX EXPRESSION"?$2"."$4:$2"."$3"."$4); k=obj SUBSEP $1
  if(!((k SUBSEP $5) in seen)){ seen[k SUBSEP $5]=1; kws[k]=(kws[k]?kws[k]", ":"")$5 }
  op="가능"; if($5 !~ /^(sysdate|systimestamp|add_months|months_between|last_day|next_day|instr)$/) op="불가"
  if(!((k SUBSEP op) in opseen)){ opseen[k SUBSEP op]=1; ops[k]=(ops[k]?ops[k]", ":"")op }
}
END{ for(k in kws){ split(k,a,SUBSEP); print a[1]"\t"a[2]"\t"kws[k]"\t"ops[k] } }
' "$OUT_DIR/03_detail_expr_keywords.tsv" | sort -t $'\t' -k1,1 -k2,2 | awk -F $'\t' '
{
  objid=$1; gsub(/[^[:alnum:]_.-]/,"_",objid)
  gsub("&","&amp;",$3); gsub("<","&lt;",$3); gsub(">","&gt;",$3)
  b=(index($4,"불가")?"badge-crit":"badge-ok")
  printf "<tr><td><a href=\"%s#src-%s\"><code>%s</code></a></td><td><code>%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",ENVIRON["SOURCE_HTML_BASENAME"],objid,$1,$2,$3,b,$4
}' > "$EXPR_ROWS"

count_rows(){ [[ -s "$1" ]] && wc -l < "$1" | xargs || echo 0; }
count_bad(){ [[ -s "$1" ]] && grep -c "불가" "$1" || echo 0; }

calc_counts() {
  local file="$1"; local total bad ok
  total=$(count_rows "$file")
  bad=$(count_bad "$file")
  ok=$(( total - bad ))
  printf '%s\t%s\t%s' "$total" "$ok" "$bad"
}

IFS=$'\t' read -r param_total param_ok param_bad < <(calc_counts "$PARAM_ROWS")
IFS=$'\t' read -r feature_total feature_ok feature_bad < <(calc_counts "$FEATURE_ROWS")
syn_total=$(row_count_tsv "$OUT_DIR/02_summary_synonyms.tsv"); syn_bad=0; syn_ok=$syn_total
rls_total=$(row_count_tsv "$OUT_DIR/02_summary_policies.tsv"); rls_bad=0; rls_ok=$rls_total
dtype_total=$(count_rows "$DTYPE_ROWS"); dtype_bad=0; dtype_ok=$dtype_total
IFS=$'\t' read -r expr_total expr_ok expr_bad < <(calc_counts "$EXPR_ROWS")
profile_total=$(row_count_tsv "$OUT_DIR/04_policy_edb_profile.tsv"); profile_bad=0; profile_ok=$profile_total
rg_total=$(row_count_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv"); rg_bad=0; rg_ok=$rg_total
dblink_total=$(row_count_tsv "$OUT_DIR/04_policy_edb_dblink.tsv"); dblink_bad=0; dblink_ok=$dblink_total

# source html generation with highlight + cleanup
python - <<'PY' "$OUT_DIR" "$SOURCE_HTML_PATH" "$SOURCE_HTML_BASENAME"
import csv, html, re, sys
from pathlib import Path
out=Path(sys.argv[1]); source_path=Path(sys.argv[2]); base=sys.argv[3]

def read_tsv(path):
    rows=[]
    if not Path(path).exists(): return rows
    with open(path, newline='', encoding='utf-8') as f:
        r=csv.reader(f, delimiter='\t')
        hdr=next(r, None)
        for row in r:
            rows.append(row)
    return rows

# keyword map per object
kwmap={}
for t,s,o,k in read_tsv(out/'03_detail_keywords.tsv'):
    key=f"{s}.{o}"; kwmap.setdefault(key,set()).add(k)
for ot,s,tg,tr,k in read_tsv(out/'03_detail_expr_keywords.tsv'):
    key=f"{s}.{tr}" if ot=="INDEX EXPRESSION" else f"{s}.{tg}.{tr}"
    kwmap.setdefault(key,set()).add(k)
for t,s,o,k in read_tsv(out/'02_summary_packages.tsv'):
    key=f"{s}.{o}"; kwmap.setdefault(key,set()).add(k)

raw={}
for t,s,o,src in read_tsv(out/'02_summary_packages_raw.tsv') + read_tsv(out/'03_detail_keywords_raw.tsv'):
    key=f"{s}.{o}"
    raw[key]=(t,src)
for ot,s,tg,tr,expr in read_tsv(out/'03_detail_expr_raw.tsv'):
    key=f"{s}.{tr}" if ot=="INDEX EXPRESSION" else f"{s}.{tg}.{tr}"
    raw[key]=(ot,expr)

cleaned=[]
for obj,(typ,src) in raw.items():
    if obj not in kwmap: 
        continue
    if '$$__EDBwrapped__' in src:
        continue
    lines=[]
    for ln in src.splitlines():
        st=ln.strip()
        if not st: continue
        if len(st)>200 and re.fullmatch(r'[A-Za-z0-9+/=_$().-]+', st):
            continue
        lines.append(ln)
    text='\n'.join(lines).strip()
    if not text: continue
    esc=html.escape(text)
    kws=sorted(kwmap[obj], key=len, reverse=True)
    for kw in kws:
        if not kw: continue
        esc=re.sub(rf'(?i)\\b({re.escape(kw)})\\b', r'<mark>\1</mark>', esc)
    anchor=re.sub(r'[^A-Za-z0-9_.-]','_',obj)
    cleaned.append((obj,typ,anchor,', '.join(sorted(kwmap[obj])),esc))

cleaned.sort(key=lambda x:x[0])
html_body=['<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>원문 상세</title>',
'<style>body{font-family:Arial,sans-serif;background:#f8fafc;margin:0}.container{max-width:1200px;margin:0 auto;padding:24px}.card{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:16px;margin-bottom:12px}pre{background:#111827;color:#e5e7eb;padding:12px;border-radius:8px;white-space:pre-wrap;overflow:auto}code{background:#eef2ff;padding:2px 6px;border-radius:6px}mark{background:#fde68a;padding:0 2px;border-radius:3px}</style></head><body><div class="container">',
'<h1>원문 상세</h1>']
for obj,typ,anchor,kws,src in cleaned:
    html_body.append(f'<div class="card" id="src-{anchor}"><h3><code>{html.escape(obj)}</code> ({html.escape(typ)})</h3><p>검출 키워드: <code>{html.escape(kws)}</code></p><pre>{src}</pre></div>')
if not cleaned:
    html_body.append('<div class="card">원문 없음</div>')
html_body.append('</div></body></html>')
source_path.write_text('\n'.join(html_body), encoding='utf-8')
PY

default_row_if_empty(){ [[ -s "$1" ]] && cat "$1" || printf '<tr><td colspan="%s">검출 없음</td></tr>' "$2"; }
syn_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s.%s</code></td><td><code>%s.%s</code></td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$1,$2,$3,$4}' "$OUT_DIR/02_summary_synonyms.tsv")
rls_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s.%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$1,$2,$3,$6}' "$OUT_DIR/02_summary_policies.tsv")
profile_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s</code></td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$2}' "$OUT_DIR/04_policy_edb_profile.tsv")
rg_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s</code></td><td>%s</td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$4,$2}' "$OUT_DIR/04_policy_edb_resource_group.tsv")
dblink_rows_html=$(awk -F $'\t' 'NR==1{next}{printf "<tr><td><code>%s</code></td><td>%s</td><td><code>%s</code></td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$1,$5,$6}' "$OUT_DIR/04_policy_edb_dblink.tsv")

cat > "$HTML_PATH" <<HTML
<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>EPAS to PostgreSQL Precheck - ${DBNAME}</title>
<style>
body{font-family:Arial,sans-serif;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:24px 44px}.card{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:16px 20px;margin-bottom:16px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #d1d5db;padding:8px;vertical-align:top}th{background:#f3f4f6}.group-title td{background:#e0e7ff;font-weight:700}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}.badge-crit{color:#991b1b;background:#fee2e2;border:1px solid #fecaca}.badge-ok{color:#065f46;background:#d1fae5;border:1px solid #a7f3d0}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}.link-note{font-size:12px;color:#374151}
</style></head><body><div class="container">
<h1>EPAS to PostgreSQL Precheck</h1>
<div class="card"><h2>요약</h2><table>
<tr><th>항목</th><th>검출 건수</th><th>가능</th><th>불가</th><th>설명</th></tr>
<tr class="group-title"><td colspan="5">1. 파라미터</td></tr><tr><td>1-1. 파라미터</td><td>${param_total}</td><td>${param_ok}</td><td>${param_bad}</td><td>핵심 파라미터 + 변경값</td></tr>
<tr class="group-title"><td colspan="5">2. EDB(Oracle) 특화기능 Summary</td></tr><tr><td>2-1. 특화기능+키워드</td><td>${feature_total}</td><td>${feature_ok}</td><td>${feature_bad}</td><td>패키지/키워드</td></tr><tr><td>2-2. 시노님</td><td>${syn_total}</td><td>${syn_ok}</td><td>${syn_bad}</td><td>시노님</td></tr><tr><td>2-3. 정책(RLS)</td><td>${rls_total}</td><td>${rls_ok}</td><td>${rls_bad}</td><td>RLS 정책</td></tr>
<tr class="group-title"><td colspan="5">3. 디테일 (user created)</td></tr><tr><td>3-1. 오라클 데이터타입</td><td>${dtype_total}</td><td>${dtype_ok}</td><td>${dtype_bad}</td><td>객체/테이블</td></tr><tr><td>3-4. 표현식</td><td>${expr_total}</td><td>${expr_ok}</td><td>${expr_bad}</td><td>기본값/제약조건/인덱스</td></tr>
<tr class="group-title"><td colspan="5">4. 폴리시 디테일 (user created)</td></tr><tr><td>4-1. 프로파일</td><td>${profile_total}</td><td>${profile_ok}</td><td>${profile_bad}</td><td>non-default</td></tr><tr><td>4-2. 리소스 그룹</td><td>${rg_total}</td><td>${rg_ok}</td><td>${rg_bad}</td><td>resource group</td></tr><tr><td>4-3. DBLINK</td><td>${dblink_total}</td><td>${dblink_ok}</td><td>${dblink_bad}</td><td>dblink</td></tr>
</table></div>

<div class="card"><h2>검출 상세(표)</h2>
<p class="link-note">객체를 클릭하면 원문 상세 페이지로 이동합니다: <a href="${SOURCE_HTML_BASENAME}">${SOURCE_HTML_BASENAME}</a></p>
<h3>1-1. 파라미터 (${param_total}건)</h3><table><tr><th>파라미터</th><th>기본값</th><th>현재값</th><th>설명</th><th>판정</th></tr>$(default_row_if_empty "$PARAM_ROWS" 5)</table>
<h3>2-1. 특화기능+키워드 (${feature_total}건)</h3><table><tr><th>타입</th><th>구분</th><th>객체</th><th>검출 내용</th><th>판정</th></tr>$(default_row_if_empty "$FEATURE_ROWS" 5)</table>
<h3>2-2. 시노님 (${syn_total}건)</h3><table><tr><th>시노님</th><th>대상 객체</th><th>판정</th></tr>$( [ -n "$syn_rows_html" ] && echo "$syn_rows_html" || echo '<tr><td colspan="3">검출 없음</td></tr>' )</table>
<h3>2-3. 정책(RLS) (${rls_total}건)</h3><table><tr><th>대상 테이블</th><th>정책명</th><th>명령</th><th>판정</th></tr>$( [ -n "$rls_rows_html" ] && echo "$rls_rows_html" || echo '<tr><td colspan="4">검출 없음</td></tr>' )</table>
<h3>3-1. 오라클 데이터타입 (${dtype_total}건)</h3><table><tr><th>타입</th><th>객체</th><th>데이터타입</th></tr>$(default_row_if_empty "$DTYPE_ROWS" 3)</table>
<h3>3-4. 기본값/제약조건/인덱스 표현식 (${expr_total}건)</h3><table><tr><th>객체</th><th>타입</th><th>검출 키워드</th><th>판정</th></tr>$(default_row_if_empty "$EXPR_ROWS" 4)</table>
<h3>4-1. 프로파일 (${profile_total}건)</h3><table><tr><th>프로파일</th><th>판정</th></tr>$( [ -n "$profile_rows_html" ] && echo "$profile_rows_html" || echo '<tr><td colspan="2">검출 없음</td></tr>' )</table>
<h3>4-2. 리소스 그룹 (${rg_total}건)</h3><table><tr><th>리소스 그룹</th><th>CPU limit</th><th>판정</th></tr>$( [ -n "$rg_rows_html" ] && echo "$rg_rows_html" || echo '<tr><td colspan="3">검출 없음</td></tr>' )</table>
<h3>4-3. DBLINK (${dblink_total}건)</h3><table><tr><th>DBLINK</th><th>USER</th><th>연결정보</th><th>판정</th></tr>$( [ -n "$dblink_rows_html" ] && echo "$dblink_rows_html" || echo '<tr><td colspan="4">검출 없음</td></tr>' )</table>
</div>
</div></body></html>
HTML

cat > "$OUT_DIR/REPORT_INDEX.txt" <<TXT
[EPAS to PostgreSQL Precheck]
Output directory : $OUT_DIR
Connection hints : host=${HOST:-N/A}, port=${PORT:-N/A}, db=${DBNAME:-N/A}, user=${DBUSER:-N/A}
HTML report      : ${HTML_BASENAME}
Source HTML      : ${SOURCE_HTML_BASENAME}
TXT

if [[ "$CLEANUP_TEMP" -eq 1 ]]; then
  cp "$HTML_PATH" "./$HTML_BASENAME"
  cp "$SOURCE_HTML_PATH" "./$SOURCE_HTML_BASENAME"
  rm -rf "$OUT_DIR"
  echo "[DONE] Report generated: ./$HTML_BASENAME, ./$SOURCE_HTML_BASENAME (temporary TSV files removed)"
else
  echo "[DONE] Report generated at: $OUT_DIR"
  echo "       Open HTML: $OUT_DIR/$HTML_BASENAME"
  echo "       Source   : $OUT_DIR/$SOURCE_HTML_BASENAME"
fi
