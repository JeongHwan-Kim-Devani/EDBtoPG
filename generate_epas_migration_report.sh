#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

usage(){ cat <<'USAGE'
EPAS -> PostgreSQL pre-diagnostic helper
Usage: ./generate_epas_migration_report.sh [options] [OUT_DIR]
Options:
  -h, --host HOST
  -p, --port PORT
  -d, --dbname DBNAME   (required)
  -U, --user USER       (required)
  -W, --password PASS
  -o, --output DIR      Output directory (if omitted, only HTMLs are kept in cwd)
  --connect-timeout SEC
  --help
USAGE
}

PSQL_BIN="${PSQL_BIN:-psql}"
HOST="${PGHOST:-localhost}"; PORT="${PGPORT:-5444}"
DBNAME="${PGDATABASE:-}"; DBUSER="${PGUSER:-}"; DBPASSWORD="${PGPASSWORD:-}"
OUT_DIR=""; CONNECT_TIMEOUT=5; CLEANUP_TEMP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    -h|--host) HOST="$2"; shift 2 ;;
    -p|--port) PORT="$2"; shift 2 ;;
    -d|--dbname) DBNAME="$2"; shift 2 ;;
    -U|--user) DBUSER="$2"; shift 2 ;;
    -W|--password) DBPASSWORD="$2"; shift 2 ;;
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    -s|--schema|--oracle-checks) shift; [[ "$1" != -* ]] && shift || true ;;
    --) shift; break ;;
    -*) echo "[ERROR] Unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

if [[ -z "$OUT_DIR" ]]; then
  if [[ $# -gt 0 ]]; then OUT_DIR="$1"; shift
  else OUT_DIR="$(mktemp -d migration_report_tmp_XXXXXX)"; CLEANUP_TEMP=1
  fi
fi

[[ -n "$DBNAME" && -n "$DBUSER" ]] || { echo "[ERROR] --dbname and --user are required." >&2; exit 1; }
command -v "$PSQL_BIN" >/dev/null 2>&1 || { echo "[ERROR] psql not found" >&2; exit 1; }

export PGHOST="$HOST" PGPORT="$PORT" PGDATABASE="$DBNAME" PGUSER="$DBUSER" PGCONNECT_TIMEOUT="$CONNECT_TIMEOUT"
[[ -n "$DBPASSWORD" ]] && export PGPASSWORD="$DBPASSWORD"

mkdir -p "$OUT_DIR"
SQL_FILE="${SQL_FILE:-$(cd "$(dirname "$0")" && pwd)/migration_report_queries.sql}"
[[ -f "$SQL_FILE" ]] || { echo "[ERROR] SQL file not found: $SQL_FILE" >&2; exit 1; }
DBNAME_SAFE="$(printf '%s' "$DBNAME" | tr -cs '[:alnum:]_.-' '_')"
HTML_BASENAME="${DBNAME_SAFE}.html"; HTML_PATH="$OUT_DIR/$HTML_BASENAME"
SOURCE_HTML_BASENAME="${DBNAME_SAFE}_source.html"; SOURCE_HTML_PATH="$OUT_DIR/$SOURCE_HTML_BASENAME"
SOURCE_DIR_BASENAME="${DBNAME_SAFE}_sources"; SOURCE_DIR_PATH="$OUT_DIR/$SOURCE_DIR_BASENAME"
export SOURCE_HTML_BASENAME SOURCE_DIR_BASENAME

read_sql(){
  local key="$1" marker="--@@ $1" cap=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$cap" -eq 0 ]]; then [[ "$line" == "$marker" ]] && cap=1; continue; fi
    [[ "$line" == --@@\ * ]] && break
    printf '%s\n' "$line"
  done < "$SQL_FILE"
}
run_tsv(){ local f="$1"; shift; "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -F $'\t' -P footer=off -c "$*" > "$f"; }
run_scalar(){ "$PSQL_BIN" -v ON_ERROR_STOP=1 -X -A -t -c "$1" | xargs; }
table_exists(){ [[ "$(run_scalar "SELECT to_regclass('$1') IS NOT NULL;")" == "t" ]]; }
row_count_tsv(){ [[ -s "$1" ]] && awk 'END{print (NR>0?NR-1:0)}' "$1" || echo 0; }
count_rows(){ [[ -s "$1" ]] && wc -l < "$1" | xargs || echo 0; }
count_bad(){ [[ -s "$1" ]] && awk '/불가/{c++} END{print c+0}' "$1" || echo 0; }

# data exports
run_tsv "$OUT_DIR/01_parameters.tsv" "$(read_sql parameters)"
run_tsv "$OUT_DIR/02_summary_packages.tsv" "$(read_sql summary_packages)"
run_tsv "$OUT_DIR/02_summary_synonyms.tsv" "$(read_sql summary_synonyms)" || true
run_tsv "$OUT_DIR/02_summary_policies.tsv" "$(read_sql summary_policies)"
run_tsv "$OUT_DIR/03_detail_keywords.tsv" "$(read_sql detail_keywords)"
run_tsv "$OUT_DIR/03_detail_datatypes_objects.tsv" "$(read_sql detail_datatypes_objects)"
run_tsv "$OUT_DIR/03_detail_datatypes_tables.tsv" "$(read_sql detail_datatypes_tables)"
run_tsv "$OUT_DIR/03_detail_expr_keywords.tsv" "$(read_sql detail_expr_keywords)"
if table_exists pg_catalog.edb_profile; then run_tsv "$OUT_DIR/04_policy_edb_profile.tsv" "$(read_sql policy_edb_profile)"; else : > "$OUT_DIR/04_policy_edb_profile.tsv"; fi
if table_exists pg_catalog.edb_resource_group; then run_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv" "$(read_sql policy_edb_resource_group)"; else : > "$OUT_DIR/04_policy_edb_resource_group.tsv"; fi
if table_exists pg_catalog.edb_dblink; then run_tsv "$OUT_DIR/04_policy_edb_dblink.tsv" "$(read_sql policy_edb_dblink)"; else : > "$OUT_DIR/04_policy_edb_dblink.tsv"; fi
run_tsv "$OUT_DIR/02_summary_packages_raw.tsv" "$(read_sql summary_packages_raw)"
run_tsv "$OUT_DIR/03_detail_keywords_raw.tsv" "$(read_sql detail_keywords_raw)"
run_tsv "$OUT_DIR/03_detail_expr_raw.tsv" "$(read_sql detail_expr_raw)"

PARAM_ROWS="$OUT_DIR/.param_rows.html"; FEATURE_ROWS="$OUT_DIR/.feature_rows.html"; DTYPE_ROWS="$OUT_DIR/.dtype_rows.html"; EXPR_ROWS="$OUT_DIR/.expr_rows.html"

awk -F $'\t' 'NR>1{op="가능"; if($1 ~ /^(edb_audit|edb_audit_archiver|edb_early_lock_release|edb_max_capture_privileges_policies|qreplace_function|edb_stmt_level_tx|data_encryption_key_unwrap_command|edb_max_resource_groups|edb_resource_group)$/)op="불가"; for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}; b=(op=="불가"?"badge-crit":"badge-ok"); printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge %s\">%s</span></td></tr>\n",$1,$2,$3,$5,b,op}' "$OUT_DIR/01_parameters.tsv" > "$PARAM_ROWS"

awk -F $'\t' 'NR>1{print $1"\t"$2"\t"$3"\t"$4"\tPACKAGE"}' "$OUT_DIR/02_summary_packages.tsv" > "$OUT_DIR/.f.tsv"
awk -F $'\t' 'NR>1{print $1"\t"$2"\t"$3"\t"$4"\tKEYWORD"}' "$OUT_DIR/03_detail_keywords.tsv" >> "$OUT_DIR/.f.tsv"
awk -F $'\t' '{t=$1;s=$2;o=$3;token=$4;k=t SUBSEP s SUBSEP o; if(!((k SUBSEP token) in seen)){seen[k SUBSEP token]=1; toks[k]=(toks[k]?toks[k]", ":"")token}; op="가능"; if(token ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|sqlerrm|raise_application_error)$/)op="불가"; if(!((k SUBSEP op) in opseen)){opseen[k SUBSEP op]=1; ops[k]=(ops[k]?ops[k]", ":"")op}; role[k]=($5=="PACKAGE"?(role[k]?role[k]"+":"")"패키지":(role[k]?role[k]"+":"")"키워드")} END{for(k in toks){split(k,a,SUBSEP); ord=(a[1]=="F"?1:(a[1]=="P"?2:3)); tn=(a[1]=="F"?"FUNCTION":(a[1]=="P"?"PROCEDURE":"VIEW")); print ord"\t"a[2]"\t"tn"\t"role[k]"\t"a[2]"."a[3]"\t"toks[k]"\t"ops[k]"\t"a[2]"."a[3]}}' "$OUT_DIR/.f.tsv" | sort -t $'\t' -k1,1n -k2,2 -k5,5 | awk -F $'\t' '{id=$8; gsub(/[^[:alnum:]_.-]/,"_",id); gsub("&","&amp;",$6); gsub("<","&lt;",$6); gsub(">","&gt;",$6); b=(index($7,"불가")?"badge-crit":"badge-ok"); printf "<tr><td><code>%s</code></td><td>%s</td><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",$3,$4,ENVIRON["SOURCE_DIR_BASENAME"],id,$5,$6,b,$7}' > "$FEATURE_ROWS"

awk -F $'\t' 'NR>1{print $1"\t"$2"\t"$3"\t"$4}' "$OUT_DIR/03_detail_datatypes_objects.tsv" > "$OUT_DIR/.d.tsv"
awk -F $'\t' 'NR>1{print "T\t"$1"\t"$2"."$3"\t"$4}' "$OUT_DIR/03_detail_datatypes_tables.tsv" >> "$OUT_DIR/.d.tsv"
awk -F $'\t' '{ord=($1=="P"?1:($1=="F"?2:($1=="V"?3:4))); tn=($1=="P"?"PROCEDURE":($1=="F"?"FUNCTION":($1=="V"?"VIEW":"TABLE COLUMN"))); print ord"\t"$2"\t"tn"\t"$3"\t"$4}' "$OUT_DIR/.d.tsv" | sort -t $'\t' -k1,1n -k2,2 -k4,4 | awk -F $'\t' '{printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td></tr>\n",$3,$4,$5}' > "$DTYPE_ROWS"

awk -F $'\t' 'NR>1{obj=($1=="INDEX EXPRESSION"?$2"."$4:$2"."$3"."$4);k=obj SUBSEP $1; if(!((k SUBSEP $5) in seen)){seen[k SUBSEP $5]=1; kws[k]=(kws[k]?kws[k]", ":"")$5}; op="가능"; if($5 !~ /^(sysdate|systimestamp|add_months|months_between|last_day|next_day|instr)$/)op="불가"; if(!((k SUBSEP op) in opseen)){opseen[k SUBSEP op]=1; ops[k]=(ops[k]?ops[k]", ":"")op}} END{for(k in kws){split(k,a,SUBSEP); print a[1]"\t"a[2]"\t"kws[k]"\t"ops[k]}}' "$OUT_DIR/03_detail_expr_keywords.tsv" | sort -t $'\t' -k1,1 -k2,2 | awk -F $'\t' '{id=$1; gsub(/[^[:alnum:]_.-]/,"_",id); gsub("&","&amp;",$3); gsub("<","&lt;",$3); gsub(">","&gt;",$3); b=(index($4,"불가")?"badge-crit":"badge-ok"); printf "<tr><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",ENVIRON["SOURCE_DIR_BASENAME"],id,$1,$2,$3,b,$4}' > "$EXPR_ROWS"

calc_counts(){ local f="$1" t b; t=$(count_rows "$f"); b=$(count_bad "$f"); echo "$t $((t-b)) $b"; }
read -r param_total param_ok param_bad < <(calc_counts "$PARAM_ROWS")
read -r feature_total feature_ok feature_bad < <(calc_counts "$FEATURE_ROWS")
read -r expr_total expr_ok expr_bad < <(calc_counts "$EXPR_ROWS")
dtype_total=$(count_rows "$DTYPE_ROWS"); dtype_ok=$dtype_total; dtype_bad=0
syn_total=$(row_count_tsv "$OUT_DIR/02_summary_synonyms.tsv"); syn_ok=$syn_total; syn_bad=0
rls_total=$(row_count_tsv "$OUT_DIR/02_summary_policies.tsv"); rls_ok=$rls_total; rls_bad=0
profile_total=$(row_count_tsv "$OUT_DIR/04_policy_edb_profile.tsv"); profile_ok=$profile_total; profile_bad=0
rg_total=$(row_count_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv"); rg_ok=$rg_total; rg_bad=0
dblink_total=$(row_count_tsv "$OUT_DIR/04_policy_edb_dblink.tsv"); dblink_ok=$dblink_total; dblink_bad=0

# source html best-effort
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  PYBIN=$(command -v python3 || command -v python)
  "$PYBIN" - <<'PY' "$OUT_DIR" "$SOURCE_HTML_PATH" "$SOURCE_DIR_PATH"
import csv,html,re,sys
from pathlib import Path
out=Path(sys.argv[1]); target=Path(sys.argv[2]); src_dir=Path(sys.argv[3])
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
  return re.sub(r'[^A-Za-z0-9_.-]', '_', name)

kw={}
for t,s,o,k in iter_fields(out/'03_detail_keywords.tsv', 4):
  if k: kw.setdefault(f'{s}.{o}',set()).add(k)
for ot,s,t,tr,k in iter_fields(out/'03_detail_expr_keywords.tsv', 5):
  obj = f'{s}.{tr}' if ot=='INDEX EXPRESSION' else f'{s}.{t}.{tr}'
  if k: kw.setdefault(obj,set()).add(k)
for t,s,o,k in iter_fields(out/'02_summary_packages.tsv', 4):
  if k: kw.setdefault(f'{s}.{o}',set()).add(k)

raw={}
for t,s,o,src in list(iter_fields(out/'02_summary_packages_raw.tsv', 4))+list(iter_fields(out/'03_detail_keywords_raw.tsv', 4)):
  if src:
    raw[f'{s}.{o}']=(t,src)
for ot,s,t,tr,e in iter_fields(out/'03_detail_expr_raw.tsv', 5):
  obj = f'{s}.{tr}' if ot=='INDEX EXPRESSION' else f'{s}.{t}.{tr}'
  if e:
    raw[obj]=(ot,e)

objects=[]
for obj in sorted(set(kw) | set(raw)):
  kws=sorted(kw.get(obj,[]), key=len, reverse=True)
  typ,src = raw.get(obj, ('UNKNOWN',''))
  if not src:
    src='(원문을 찾지 못했습니다.)'
  esc=html.escape(src)
  for k in kws:
    esc=re.sub(rf'(?i)\\b({re.escape(k)})\\b', r'<mark>\\1</mark>', esc)
  sid=slug(obj)
  file_name=f'src-{sid}.html'
  obj_html = (
    '<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>'+html.escape(obj)+' 원문</title>'
    '<style>body{font-family:Arial;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:22px 30px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:14px;margin-bottom:14px}pre{background:#111827;color:#e5e7eb;padding:12px;border-radius:8px;overflow:auto;white-space:pre-wrap}mark{background:#fde68a}a{color:#1d4ed8}</style></head><body><div class="container">'
    '<h1><code>'+html.escape(obj)+'</code></h1>'
    '<p><a href="../'+html.escape(target.name)+'">Back to source index</a></p>'
    '<div class="card"><h3>객체 정보</h3><p><b>타입:</b> '+html.escape(typ)+'</p><p><b>검출 키워드:</b> '+html.escape(', '.join(kws) if kws else '-')+'</p></div>'
    '<div class="card"><h3>원문 (키워드 하이라이트)</h3><pre>'+esc+'</pre></div>'
    '<div class="card"><h3>원문 (Raw Full Text)</h3><pre>'+html.escape(src)+'</pre></div>'
    '</div></body></html>'
  )
  (src_dir/file_name).write_text(obj_html, encoding='utf-8')
  objects.append((obj, typ, ', '.join(kws) if kws else '-', file_name))

parts=['<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>원문 인덱스</title><style>body{font-family:Arial;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:24px 36px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:16px;margin-bottom:14px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #d1d5db;padding:8px}th{background:#f3f4f6}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}a{color:#1d4ed8}</style></head><body><div class="container"><h1>원문 인덱스</h1>']
parts.append('<div class="card"><p>객체명을 클릭하면 전체 원문 페이지로 이동합니다.</p><table><tr><th>객체</th><th>타입</th><th>검출 키워드</th></tr>')
if objects:
  for obj, typ, kws, file_name in objects:
    parts.append('<tr><td><a href="'+html.escape(src_dir.name)+'/'+html.escape(file_name)+'"><code>'+html.escape(obj)+'</code></a></td><td>'+html.escape(typ)+'</td><td>'+html.escape(kws)+'</td></tr>')
else:
  parts.append('<tr><td colspan="3">원문 없음</td></tr>')
parts.append('</table></div></div></body></html>')
target.write_text('\n'.join(parts),encoding='utf-8')
PY
fi
[[ -f "$SOURCE_HTML_PATH" ]] || echo '<!doctype html><html><body><h1>원문 상세</h1><p>원문 페이지를 생성하지 못했습니다.</p></body></html>' > "$SOURCE_HTML_PATH"

default_row_if_empty(){ [[ -s "$1" ]] && cat "$1" || printf '<tr><td colspan="%s">검출 없음</td></tr>' "$2"; }
syn_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s.%s</code></td><td><code>%s.%s</code></td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$1,$2,$3,$4}' "$OUT_DIR/02_summary_synonyms.tsv")
rls_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s.%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$1,$2,$3,$6}' "$OUT_DIR/02_summary_policies.tsv")
profile_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s</code></td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$2}' "$OUT_DIR/04_policy_edb_profile.tsv")
rg_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s</code></td><td>%s</td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$4,$2}' "$OUT_DIR/04_policy_edb_resource_group.tsv")
dblink_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s</code></td><td>%s</td><td><code>%s</code></td><td><span class=\"badge badge-ok\">가능</span></td></tr>\n",$1,$5,$6}' "$OUT_DIR/04_policy_edb_dblink.tsv")

cat > "$HTML_PATH" <<HTML
<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>EPAS to PostgreSQL Precheck - ${DBNAME}</title>
<style>body{font-family:Arial;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:24px 44px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:16px;margin-bottom:16px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #d1d5db;padding:8px}th{background:#f3f4f6}.group-title td{background:#e0e7ff;font-weight:700}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}.badge-crit{color:#991b1b;background:#fee2e2;border:1px solid #fecaca}.badge-ok{color:#065f46;background:#d1fae5;border:1px solid #a7f3d0}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}</style></head><body><div class="container">
<h1>EPAS to PostgreSQL Precheck</h1>
<div class="card"><h2>요약</h2><table>
<tr><th>항목</th><th>검출 건수</th><th>가능</th><th>불가</th><th>설명</th></tr>
<tr class="group-title"><td colspan="5">1. 파라미터</td></tr><tr><td>1-1. 파라미터</td><td>${param_total}</td><td>${param_ok}</td><td>${param_bad}</td><td>핵심 파라미터 + 변경값</td></tr>
<tr class="group-title"><td colspan="5">2. EDB(Oracle) 특화기능 Summary</td></tr><tr><td>2-1. 특화기능+키워드</td><td>${feature_total}</td><td>${feature_ok}</td><td>${feature_bad}</td><td>패키지/키워드</td></tr><tr><td>2-2. 시노님</td><td>${syn_total}</td><td>${syn_ok}</td><td>${syn_bad}</td><td>시노님</td></tr><tr><td>2-3. 정책(RLS)</td><td>${rls_total}</td><td>${rls_ok}</td><td>${rls_bad}</td><td>RLS 정책</td></tr>
<tr class="group-title"><td colspan="5">3. 디테일 (user created)</td></tr><tr><td>3-1. 오라클 데이터타입</td><td>${dtype_total}</td><td>${dtype_ok}</td><td>${dtype_bad}</td><td>객체/테이블</td></tr><tr><td>3-2. 표현식</td><td>${expr_total}</td><td>${expr_ok}</td><td>${expr_bad}</td><td>기본값/제약조건/인덱스</td></tr>
<tr class="group-title"><td colspan="5">4. 폴리시 디테일 (user created)</td></tr><tr><td>4-1. 프로파일</td><td>${profile_total}</td><td>${profile_ok}</td><td>${profile_bad}</td><td>non-default</td></tr><tr><td>4-2. 리소스 그룹</td><td>${rg_total}</td><td>${rg_ok}</td><td>${rg_bad}</td><td>resource group</td></tr><tr><td>4-3. DBLINK</td><td>${dblink_total}</td><td>${dblink_ok}</td><td>${dblink_bad}</td><td>dblink</td></tr>
</table></div>
<div class="card"><h2>검출 상세(표)</h2><p>객체 클릭 시 원문: <a href="${SOURCE_HTML_BASENAME}">${SOURCE_HTML_BASENAME}</a></p>
<h3>1-1. 파라미터</h3><table><tr><th>파라미터</th><th>기본값</th><th>현재값</th><th>설명</th><th>판정</th></tr>$(default_row_if_empty "$PARAM_ROWS" 5)</table>
<h3>2-1. 특화기능+키워드</h3><table><tr><th>타입</th><th>구분</th><th>객체</th><th>검출 내용</th><th>판정</th></tr>$(default_row_if_empty "$FEATURE_ROWS" 5)</table>
<h3>2-2. 시노님</h3><table><tr><th>시노님</th><th>대상 객체</th><th>판정</th></tr>$( [ -n "$syn_rows_html" ] && echo "$syn_rows_html" || echo '<tr><td colspan="3">검출 없음</td></tr>' )</table>
<h3>2-3. 정책(RLS)</h3><table><tr><th>대상 테이블</th><th>정책명</th><th>명령</th><th>판정</th></tr>$( [ -n "$rls_rows_html" ] && echo "$rls_rows_html" || echo '<tr><td colspan="4">검출 없음</td></tr>' )</table>
<h3>3-1. 오라클 데이터타입</h3><table><tr><th>타입</th><th>객체</th><th>데이터타입</th></tr>$(default_row_if_empty "$DTYPE_ROWS" 3)</table>
<h3>3-2. 표현식</h3><table><tr><th>객체</th><th>타입</th><th>검출 키워드</th><th>판정</th></tr>$(default_row_if_empty "$EXPR_ROWS" 4)</table>
<h3>4-1. 프로파일</h3><table><tr><th>프로파일</th><th>판정</th></tr>$( [ -n "$profile_rows_html" ] && echo "$profile_rows_html" || echo '<tr><td colspan="2">검출 없음</td></tr>' )</table>
<h3>4-2. 리소스 그룹</h3><table><tr><th>리소스 그룹</th><th>CPU limit</th><th>판정</th></tr>$( [ -n "$rg_rows_html" ] && echo "$rg_rows_html" || echo '<tr><td colspan="3">검출 없음</td></tr>' )</table>
<h3>4-3. DBLINK</h3><table><tr><th>DBLINK</th><th>USER</th><th>연결정보</th><th>판정</th></tr>$( [ -n "$dblink_rows_html" ] && echo "$dblink_rows_html" || echo '<tr><td colspan="4">검출 없음</td></tr>' )</table>
</div></div></body></html>
HTML

# remove helper artifacts from output dir
rm -f "$OUT_DIR"/.f.tsv "$OUT_DIR"/.d.tsv "$OUT_DIR"/.param_rows.html "$OUT_DIR"/.feature_rows.html "$OUT_DIR"/.dtype_rows.html "$OUT_DIR"/.expr_rows.html

cat > "$OUT_DIR/REPORT_INDEX.txt" <<TXT
[EPAS to PostgreSQL Precheck]
Output directory : $OUT_DIR
Connection hints : host=${HOST:-N/A}, port=${PORT:-N/A}, db=${DBNAME:-N/A}, user=${DBUSER:-N/A}
HTML report      : ${HTML_BASENAME}
Source HTML      : ${SOURCE_HTML_BASENAME}
Source directory : ${SOURCE_DIR_BASENAME}/
TXT

if [[ "$CLEANUP_TEMP" -eq 1 ]]; then
  cp "$HTML_PATH" "./$HTML_BASENAME"
  cp "$SOURCE_HTML_PATH" "./$SOURCE_HTML_BASENAME"
  if [[ -d "$SOURCE_DIR_PATH" ]]; then
    rm -rf "./$SOURCE_DIR_BASENAME"
    cp -R "$SOURCE_DIR_PATH" "./$SOURCE_DIR_BASENAME"
  fi
  rm -rf "$OUT_DIR"
  echo "[DONE] Report generated: ./$HTML_BASENAME, ./$SOURCE_HTML_BASENAME, ./$SOURCE_DIR_BASENAME/ (temporary TSV files removed)"
else
  echo "[DONE] Report generated at: $OUT_DIR"
  echo "       Open HTML: $OUT_DIR/$HTML_BASENAME"
  echo "       Source   : $OUT_DIR/$SOURCE_HTML_BASENAME"
  echo "       Objects  : $OUT_DIR/$SOURCE_DIR_BASENAME/"
fi
