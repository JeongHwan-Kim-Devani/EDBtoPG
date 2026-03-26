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
Usage: ./generate_epas_migration_report.sh [options]
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
OUT_DIR=""; CONNECT_TIMEOUT=5; CLEANUP_TEMP=0; COMPRESS=""

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
SQL_FILE="${SQL_FILE:-$(cd "$(dirname "$0")" && pwd)/migration_report_queries.sql}"
[[ -f "$SQL_FILE" ]] || { echo "[ERROR] SQL file not found: $SQL_FILE" >&2; exit 1; }
DBNAME_SAFE="$(printf '%s' "$DBNAME" | tr -cs '[:alnum:]_.-' '_')"
HTML_BASENAME="${DBNAME_SAFE}.html"; HTML_PATH="$OUT_DIR/$HTML_BASENAME"
SOURCE_HTML_BASENAME="${DBNAME_SAFE}_source.html"; SOURCE_HTML_PATH="$OUT_DIR/$SOURCE_HTML_BASENAME"
SOURCE_DIR_BASENAME="${DBNAME_SAFE}_sources"; SOURCE_DIR_PATH="$OUT_DIR/$SOURCE_DIR_BASENAME"
export SOURCE_HTML_BASENAME SOURCE_DIR_BASENAME HTML_BASENAME

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
count_bad(){ [[ -s "$1" ]] && awk '/遺덇?/{c++} END{print c+0}' "$1" || echo 0; }
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

# data exports
run_tsv "$OUT_DIR/01_parameters.tsv" "$(read_sql parameters)"
run_tsv "$OUT_DIR/02_summary_packages.tsv" "$(read_sql summary_packages)"
run_tsv "$OUT_DIR/02_summary_synonyms.tsv" "$(read_sql summary_synonyms)" || true
run_tsv "$OUT_DIR/02_summary_policies.tsv" "$(read_sql summary_policies)"
if table_exists sys.all_policies; then run_tsv "$OUT_DIR/02_summary_policies_dbms_rls.tsv" "$(read_sql summary_policies_dbms_rls)"; else : > "$OUT_DIR/02_summary_policies_dbms_rls.tsv"; fi
if table_exists public.edb_redaction_policy && table_exists public.edb_redaction_column; then run_tsv "$OUT_DIR/02_summary_redaction.tsv" "$(read_sql summary_redaction)"; elif table_exists pg_catalog.edb_redaction_policy && table_exists pg_catalog.edb_redaction_column; then run_tsv "$OUT_DIR/02_summary_redaction.tsv" "$(read_sql summary_redaction)"; else : > "$OUT_DIR/02_summary_redaction.tsv"; fi
run_tsv "$OUT_DIR/03_detail_keywords.tsv" "$(read_sql detail_keywords)"
run_tsv "$OUT_DIR/03_detail_datatypes_objects.tsv" "$(read_sql detail_datatypes_objects)"
run_tsv "$OUT_DIR/03_detail_datatypes_tables.tsv" "$(read_sql detail_datatypes_tables)"
run_tsv "$OUT_DIR/03_detail_expr_keywords.tsv" "$(read_sql detail_expr_keywords)"
if run_tsv "$OUT_DIR/04_policy_edb_profile.tsv" "$(read_sql policy_edb_profile_dba)" 2>/dev/null; then
  :
elif table_exists pg_catalog.edb_profile; then
  run_tsv "$OUT_DIR/04_policy_edb_profile.tsv" "$(read_sql policy_edb_profile)"
else
  : > "$OUT_DIR/04_policy_edb_profile.tsv"
fi
if table_exists pg_catalog.edb_resource_group; then run_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv" "$(read_sql policy_edb_resource_group)"; else : > "$OUT_DIR/04_policy_edb_resource_group.tsv"; fi
if table_exists pg_catalog.edb_dblink; then run_tsv "$OUT_DIR/04_policy_edb_dblink.tsv" "$(read_sql policy_edb_dblink)"; else : > "$OUT_DIR/04_policy_edb_dblink.tsv"; fi
run_tsv "$OUT_DIR/02_summary_packages_raw.tsv" "$(read_sql summary_packages_raw)"
run_tsv "$OUT_DIR/03_detail_keywords_raw.tsv" "$(read_sql detail_keywords_raw)"
run_tsv "$OUT_DIR/03_detail_expr_raw.tsv" "$(read_sql detail_expr_raw)"
run_tsv "$OUT_DIR/03_detail_table_columns_raw.tsv" "$(read_sql detail_table_columns_raw)"
run_tsv "$OUT_DIR/03_detail_table_objects_raw.tsv" "$(read_sql detail_table_objects_raw)"

PARAM_ROWS="$OUT_DIR/.param_rows.html"; FEATURE_ROWS="$OUT_DIR/.feature_rows.html"; DTYPE_ROWS="$OUT_DIR/.dtype_rows.html"; EXPR_ROWS="$OUT_DIR/.expr_rows.html"

awk -F $'	' 'NR>1{  op="媛???쒖씠????쓬)";  if($1 ~ /^(edb_audit|edb_audit_archiver|edb_early_lock_release|edb_max_capture_privileges_policies|qreplace_function|edb_stmt_level_tx|data_encryption_key_unwrap_command|edb_max_resource_groups|edb_resource_group)$/) op="遺덇?";  else if($1 ~ /^(edb_redwood_strings|db_dialect|datestyle|edb_redwood_greatest_least|edb_redwood_date|edb_dynatune|edb_dynatune_profile|optimizer_mode|default_with_rowids|enable_hints)$/) op="媛???쒖씠???믪쓬)";  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)};  b=(op=="遺덇?"?"badge-bad":(op=="媛???쒖씠???믪쓬)"?"badge-high":"badge-low"));  printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge %s\">%s</span></td></tr>\n",$1,$2,$3,$5,b,op}' "$OUT_DIR/01_parameters.tsv" > "$PARAM_ROWS"

awk -F $'\t' 'NR>1{print $1 "\t" $2 "\t" $3 "\t" $4 "\tPACKAGE"}' "$OUT_DIR/02_summary_packages.tsv" > "$OUT_DIR/.f.tsv"
awk -F $'\t' 'NR>1{print $1 "\t" $2 "\t" $3 "\t" $4 "\tKEYWORD"}' "$OUT_DIR/03_detail_keywords.tsv" >> "$OUT_DIR/.f.tsv"
awk -F $'	' '{
  t=$1; s=$2; o=$3; token=tolower($4); k=t SUBSEP s SUBSEP o
  if(token=="") token="(寃異??ㅼ썙???놁쓬)"
  ph=(token=="(寃異??ㅼ썙???놁쓬)")
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
    op=(level[k]==2?"遺덇?":(level[k]==1?"媛???쒖씠???믪쓬)":"媛???쒖씠????쓬)"))
    pkg=cat_cnt[k SUBSEP "PACKAGE"]+0
    kw=cat_cnt[k SUBSEP "KEYWORD"]+0
    role=(pkg>0?"PACKAGE(" pkg ")":"")
    if(kw>0) role=(role?role"+":"")"KEYWORD(" kw ")"
    if(role=="") role="KEYWORD(0)"
    detail=(toks[k]!=""?toks[k]:"(寃異??ㅼ썙???놁쓬)")
    print ord"	"a[2]"	"tn"	"role"	"a[2]"."a[3]"	"detail"	"op"	"a[2]"."a[3]
  }
}' "$OUT_DIR/.f.tsv" | sort -t $'	' -k1,1n -k2,2 -k5,5 | awk -F $'	'  '{  id=$8; gsub(/[^[:alnum:]_.-]/,"_",id);  gsub("&","&amp;",$6);gsub("<","&lt;",$6);gsub(">","&gt;",$6);  b=($7=="遺덇?"?"badge-bad":($7=="媛???쒖씠???믪쓬)"?"badge-high":"badge-low"));  printf "<tr><td><code>%s</code></td><td>%s</td><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",$3,$4,ENVIRON["SOURCE_DIR_BASENAME"],id,$5,$6,b,$7}' > "$FEATURE_ROWS"

awk -F $'	' 'NR>1{print $1"	"$2"	"$3"	"$4}' "$OUT_DIR/03_detail_datatypes_objects.tsv" > "$OUT_DIR/.d.tsv"
awk -F $'\t' 'NR>1{key=$1"."$2; dt=tolower($4); if(!seen[key SUBSEP dt]++){dtypes[key]=(dtypes[key]?dtypes[key]", ":"")dt}; sch[key]=$1; touched[key]=1} END{for(k in touched){print "T\t"sch[k]"\t"k"\t"dtypes[k]}}' "$OUT_DIR/03_detail_datatypes_tables.tsv" >> "$OUT_DIR/.d.tsv"
awk -F $'\t' '!seen[$0]++{  ord=($1=="P"?1:($1=="F"?2:($1=="V"?3:4)));  tn=($1=="P"?"PROCEDURE":($1=="F"?"FUNCTION":($1=="V"?"VIEW":"TABLE COLUMN")));  obj=($1=="T"?$3:$2"."$3);  print ord"\t"$2"\t"tn"\t"obj"\t"$4}' "$OUT_DIR/.d.tsv" | sort -t $'\t' -k1,1n -k2,2 -k4,4 | awk -F $'\t' '{  obj=$4; id=obj; gsub(/[^[:alnum:]_.-]/,"_",id);  printf "<tr><td><code>%s</code></td><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td></tr>\n",$3,ENVIRON["SOURCE_DIR_BASENAME"],id,obj,$5}' > "$DTYPE_ROWS"

awk -F $'	' 'NR>1{  obj=($1=="INDEX EXPRESSION"?$2"."$4:$2"."$3"."$4);  k=obj SUBSEP $1; token=tolower($5); if(token=="") token="(寃異??ㅼ썙???놁쓬)";  if(!((k SUBSEP token) in seen)){seen[k SUBSEP token]=1; kws[k]=(kws[k]?kws[k]", ":"")token};  lv=0;  if(token ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|raise_application_error)$/) lv=2;  else if(token ~ /^(dbms_crypto(\.[a-z0-9_]+)?|dbms_[a-z0-9_]+|utl_[a-z0-9_]+|owa_[a-z0-9_]+|htp\.[a-z0-9_]+|htf\.[a-z0-9_]+|sysdate|systimestamp|nvl|nvl2|decode|add_months|months_between|last_day|next_day|instr|greatest|least)$/) lv=1;  if(lv > level[k]) level[k]=lv} END{  for(k in kws){split(k,a,SUBSEP); op=(level[k]==2?"遺덇?":(level[k]==1?"媛???쒖씠???믪쓬)":"媛???쒖씠????쓬)")); print a[1]"	"a[2]"	"kws[k]"	"op}}' "$OUT_DIR/03_detail_expr_keywords.tsv" | sort -t $'	' -k1,1 -k2,2 | awk -F $'	' '{  id=$1; gsub(/[^[:alnum:]_.-]/,"_",id);  gsub("&","&amp;",$3);gsub("<","&lt;",$3);gsub(">","&gt;",$3);  b=($4=="遺덇?"?"badge-bad":($4=="媛???쒖씠???믪쓬)"?"badge-high":"badge-low"));  printf "<tr><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n",ENVIRON["SOURCE_DIR_BASENAME"],id,$1,$2,$3,b,$4}' > "$EXPR_ROWS"

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

# source html best-effort
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
  for k in sorted([x for x in kws if x and x != '(寃異??ㅼ썙???놁쓬)'], key=len, reverse=True):
    esc=re.sub(rf'(?i)({re.escape(k)})', r'<span class="kw">\1</span>', esc)
  return esc

kw={}
for t,s,o,k in iter_fields(out/'03_detail_keywords.tsv', 4):
  obj=f'{s}.{o}'
  kw.setdefault(obj,set()).add(k.lower() if k else '(寃異??ㅼ썙???놁쓬)')
for ot,s,t,tr,k in iter_fields(out/'03_detail_expr_keywords.tsv', 5):
  obj = f'{s}.{tr}' if ot=='INDEX EXPRESSION' else f'{s}.{t}.{tr}'
  kw.setdefault(obj,set()).add(k.lower() if k else '(寃異??ㅼ썙???놁쓬)')
for t,s,o,k in iter_fields(out/'02_summary_packages.tsv', 4):
  kw.setdefault(f'{s}.{o}',set()).add(k.lower() if k else '(寃異??ㅼ썙???놁쓬)')
for s,t,c,d in iter_fields(out/'03_detail_datatypes_tables.tsv', 4):
  kw.setdefault(f'{s}.{t}',set()).add(d.lower() if d else '(寃異??ㅼ썙???놁쓬)')
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
  raw[obj]=('PROFILE', restore_text(detail) if detail else f'PROFILE: {prf}\nAPPLIED USERS: {users if users else "(誘몄쟻??"}')
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
  typ,src = raw.get(obj, ('UNKNOWN','(?먮Ц??李얠? 紐삵뻽?듬땲??)'))
  sid=slug(obj)
  file_name=f'src-{sid}.html'
  kw_label=', '.join(kws) if kws else '?ㅼ썙???놁쓬'
  kw_badge = '<span class="badge badge-none">?ㅼ썙???놁쓬</span>' if (not kws or kws==['(寃異??ㅼ썙???놁쓬)']) else html.escape(kw_label)
  highlighted = highlight_text(src, kws)
  obj_html = (
    '<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>'+html.escape(obj)+' ?먮Ц</title>'
    '<style>body{font-family:Arial;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:22px 30px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:14px;margin-bottom:14px}pre{background:#111827;color:#e5e7eb;padding:12px;border-radius:8px;overflow:auto;white-space:pre;tab-size:4;line-height:1.4;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}.kw{color:#f59e0b;font-weight:700}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}.badge-none{color:#374151;background:#e5e7eb;border:1px solid #d1d5db}a{color:#1d4ed8}</style></head><body><div class="container">'
    '<h1><code>'+html.escape(obj)+'</code></h1>'
    '<p><a href="../'+html.escape(target.name)+'">Back to source index</a> &nbsp;|&nbsp; <a href="../'+html.escape(precheck_name)+'">Back to precheck</a></p>'
    '<div class="card"><h3>媛앹껜 ?뺣낫</h3><p><b>???</b> '+html.escape(full_type(typ))+'</p><p><b>寃異??ㅼ썙??</b> '+kw_badge+'</p></div>'
    '<div class="card"><h3>?먮Ц ?꾩껜 (?ㅼ썙???됱긽 媛뺤“)</h3><pre>'+highlighted+'</pre></div>'
    '</div></body></html>'
  )
  (src_dir/file_name).write_text(obj_html, encoding='utf-8')
  objects.append((obj, full_type(typ), kws, file_name))

source_total=len(objects)
parts=['<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>?먮Ц ?몃뜳??/title><style>body{font-family:Arial;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:24px 36px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:16px;margin-bottom:14px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #d1d5db;padding:8px}th{background:#f3f4f6}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}a{color:#1d4ed8}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}.badge-none{color:#374151;background:#e5e7eb;border:1px solid #d1d5db}</style></head><body><div class="container"><h1>?먮Ц ?몃뜳??(珥?'+str(source_total)+'嫄?</h1>']
parts.append('<div class="card"><p><a href="'+html.escape(precheck_name)+'">Back to precheck</a></p><p>媛앹껜紐낆쓣 ?대┃?섎㈃ ?꾩껜 ?먮Ц ?섏씠吏濡??대룞?⑸땲??</p><table><tr><th>媛앹껜</th><th>???/th><th>寃異??ㅼ썙??/th></tr>')
if objects:
  for obj, typ, kws, file_name in objects:
    if kws and kws != ['(寃異??ㅼ썙???놁쓬)']:
      kw_cell=html.escape(', '.join(kws))
    else:
      kw_cell='<span class="badge badge-none">?ㅼ썙???놁쓬</span>'
    parts.append('<tr><td><a href="'+html.escape(src_dir.name)+'/'+html.escape(file_name)+'"><code>'+html.escape(obj)+'</code></a></td><td>'+html.escape(typ)+'</td><td>'+kw_cell+'</td></tr>')
else:
  parts.append('<tr><td colspan="3">?먮Ц ?놁쓬</td></tr>')
parts.append('</table></div></div></body></html>')
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

  awk -F $'	' 'NR>1{users=($3==""?"(誘몄쟻??":$3); detail=($2==""?"PROFILE: "$1"\\nAPPLIED USERS: "users:$2); printf "policy.profile.%s\tPROFILE\t%s\n", $1, detail}' "$OUT_DIR/04_policy_edb_profile.tsv" >> "$RAW_MERGED"
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
  awk -F $'	' '{k=$1; t=tolower($2); if(t=="") t="(寃異??ㅼ썙???놁쓬)"; if(!seen[k SUBSEP t]++){a[k]=(a[k]?a[k]", ":"")t}} END{for(k in a) print k"	"a[k]}' "$KW_MERGED" > "$KW_AGG"
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
    [ -n "$src" ] || src='(?먮Ц??李얠? 紐삵뻽?듬땲??)'
    kws=$(awk -F $'	' -v o="$obj" '$1==o{print $2; exit}' "$KW_AGG")
    [ -n "$kws" ] || kws='?ㅼ썙???놁쓬'

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
    if [[ -n "$kws" && "$kws" != "?ㅼ썙???놁쓬" ]]; then
      IFS=',' read -r -a _kw_arr <<< "$kws"
      for _kw in "${_kw_arr[@]}"; do
        _kw=$(printf '%s' "$_kw" | sed -e 's/^ *//' -e 's/ *$//')
        _kw=$(printf '%s' "$_kw" | tr '[:upper:]' '[:lower:]')
        [[ -n "$_kw" && "$_kw" != "(寃異??ㅼ썙???놁쓬)" ]] || continue
        esc_src=$(awk -v src="$esc_src" -v kw="$_kw" 'BEGIN{if(kw==""){print src; exit} lsrc=tolower(src); lkw=tolower(kw); out=""; pos=1; klen=length(kw); while(1){tmp=substr(lsrc,pos); idx=index(tmp,lkw); if(idx==0) break; abs=pos+idx-1; out=out substr(src,pos,abs-pos) "<span class=\"kw\">" substr(src,abs,klen) "</span>"; pos=abs+klen;} out=out substr(src,pos); print out}')
      done
    fi

    cat > "$page" <<EOF
<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>${esc_obj} ?먮Ц</title>
<style>body{font-family:Arial;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:22px 30px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:14px;margin-bottom:14px}pre{background:#111827;color:#e5e7eb;padding:12px;border-radius:8px;overflow:auto;white-space:pre;tab-size:4;line-height:1.4;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}.kw{color:#f59e0b;font-weight:700}a{color:#1d4ed8}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}</style></head><body><div class="container">
<h1><code>${esc_obj}</code></h1>
<p><a href="../${SOURCE_HTML_BASENAME}">Back to source index</a> &nbsp;|&nbsp; <a href="../${HTML_BASENAME}">Back to precheck</a></p>
<div class="card"><h3>媛앹껜 ?뺣낫</h3><p><b>???</b> ${esc_typ}</p><p><b>寃異??ㅼ썙??</b> ${esc_kws}</p></div>
<div class="card"><h3>?먮Ц ?꾩껜</h3><pre>${esc_src}</pre></div>
</div></body></html>
EOF

    printf '<tr><td><a href="%s/src-%s.html"><code>%s</code></a></td><td>%s</td><td>%s</td></tr>
' "$SOURCE_DIR_BASENAME" "$sid" "$esc_obj" "$esc_typ" "$esc_kws" >> "$IDX_ROWS"
  done < <((cut -f1 "$RAW_AGG"; cut -f1 "$KW_AGG") | sort -u)

  cat > "$SOURCE_HTML_PATH" <<EOF
<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>?먮Ц ?몃뜳??/title>
<style>body{font-family:Arial;background:#f8fafc;margin:0;color:#111827}.container{max-width:1300px;margin:0 auto;padding:24px 36px}.card{background:#fff;border:1px solid #ddd;border-radius:10px;padding:16px;margin-bottom:14px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #d1d5db;padding:8px}th{background:#f3f4f6}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}a{color:#1d4ed8}</style></head><body><div class="container">
<h1>?먮Ц ?몃뜳??(珥?${SOURCE_TOTAL}嫄?</h1>
<div class="card"><p><a href="${HTML_BASENAME}">Back to precheck</a></p><p>媛앹껜紐낆쓣 ?대┃?섎㈃ ?꾩껜 ?먮Ц ?섏씠吏濡??대룞?⑸땲??</p>
<table><tr><th>媛앹껜</th><th>???/th><th>寃異??ㅼ썙??/th></tr>
$( [ -s "$IDX_ROWS" ] && cat "$IDX_ROWS" || echo '<tr><td colspan="3">?먮Ц ?놁쓬</td></tr>' )
</table></div></div></body></html>
EOF

  purge_files "$RAW_MERGED" "$RAW_AGG" "$KW_MERGED" "$KW_AGG" "$TABLE_RAW_AGG" "$COLUMN_LIST_AGG" "$IDX_TABLE_MAP" "$IDX_ROWS"
fi
[[ -f "$SOURCE_HTML_PATH" ]] || echo '<!doctype html><html><body><h1>?먮Ц ?곸꽭</h1><p>?먮Ц ?섏씠吏瑜??앹꽦?섏? 紐삵뻽?듬땲??</p></body></html>' > "$SOURCE_HTML_PATH"

default_row_if_empty(){ [[ -s "$1" ]] && cat "$1" || printf '<tr><td colspan="%s">寃異??놁쓬</td></tr>' "$2"; }
syn_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s.%s</code></td><td><code>%s.%s</code></td><td><span class=\"badge badge-low\">媛???쒖씠????쓬)</span></td></tr>\n",$1,$2,$3,$4}' "$OUT_DIR/02_summary_synonyms.tsv")
rls_pg_rows=$(awk -F $'\t' 'NR>1{obj="policy.rls."$1"."$2"."$3; id=obj; gsub(/[^[:alnum:]_.-]/,"_",id); printf "<tr><td><code>%s.%s</code></td><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td>%s</td><td><span class=\"badge badge-low\">媛???쒖씠????쓬)</span></td></tr>\n",$1,$2,ENVIRON["SOURCE_DIR_BASENAME"],id,$3,$6}' "$OUT_DIR/02_summary_policies.tsv")
rls_dbms_rows=$(awk -F $'\t' 'NR>1{obj="policy.rls."$2"."$3"."$5; id=obj; gsub(/[^[:alnum:]_.-]/,"_",id); printf "<tr><td><code>%s.%s</code></td><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td>%s.%s</td><td><span class=\"badge badge-low\">媛???쒖씠????쓬)</span></td></tr>\n",$2,$3,ENVIRON["SOURCE_DIR_BASENAME"],id,$5,$7,$8}' "$OUT_DIR/02_summary_policies_dbms_rls.tsv")
rls_rows_html="${rls_pg_rows}${rls_dbms_rows}"
redaction_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s.%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td><span class=\"badge badge-high\">媛???쒖씠???믪쓬)</span></td></tr>\n",$1,$2,$3,$4}' "$OUT_DIR/02_summary_redaction.tsv")
profile_rows_html=$(awk -F $'\t' 'NR>1{users=($3==""?"(誘몄쟻??":$3); obj="policy.profile."$1; id=obj; gsub(/[^[:alnum:]_.-]/,"_",id); printf "<tr><td><a href=\"%s/src-%s.html\"><code>%s</code></a></td><td><code>%s</code></td><td><span class=\"badge badge-low\">媛???쒖씠????쓬)</span></td></tr>\n",ENVIRON["SOURCE_DIR_BASENAME"],id,$1,users}' "$OUT_DIR/04_policy_edb_profile.tsv")
rg_rows_html=$(awk -F $'\t' 'NR>1{users=($4==""?"(誘몄쟻??":$4); printf "<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td><code>%s</code></td><td><span class=\"badge badge-low\">媛???쒖씠????쓬)</span></td></tr>\n",$1,$2,$3,users}' "$OUT_DIR/04_policy_edb_resource_group.tsv")
dblink_rows_html=$(awk -F $'\t' 'NR>1{printf "<tr><td><code>%s</code></td><td>%s</td><td><code>%s</code></td><td><span class=\"badge badge-low\">媛???쒖씠????쓬)</span></td></tr>\n",$1,$5,$6}' "$OUT_DIR/04_policy_edb_dblink.tsv")

cat > "$HTML_PATH" <<HTML
<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>EPAS to PostgreSQL Precheck - ${DBNAME}</title>
<style>
:root{--bg-0:#f4f8ff;--bg-1:#e6f0ff;--ink-0:#0b1020;--ink-1:#22304a;--ink-2:#5f6f8f;--surface:rgba(255,255,255,.9);--stroke:rgba(17,31,62,.14);--shadow:0 20px 50px rgba(19,38,82,.12)}
*{box-sizing:border-box}
body{margin:0;color:var(--ink-0);font-family:"Pretendard","Noto Sans KR","Segoe UI",Arial,sans-serif;background:radial-gradient(circle at 10% 0,#dceeff 0,rgba(220,238,255,0) 35%),radial-gradient(circle at 100% 10%,#ddfff4 0,rgba(221,255,244,0) 38%),linear-gradient(180deg,var(--bg-0),var(--bg-1))}
.container{max-width:1320px;margin:0 auto;padding:28px 28px 42px}
.hero{border:1px solid var(--stroke);background:var(--surface);border-radius:22px;padding:20px 22px;box-shadow:var(--shadow);margin-bottom:14px}
.hero h1{margin:0;font-size:30px;line-height:1.2}
.hero p{margin:8px 0 0;color:var(--ink-1);font-size:14px}
.card{border:1px solid var(--stroke);background:var(--surface);border-radius:20px;padding:16px;box-shadow:0 10px 24px rgba(19,38,82,.08);margin-bottom:14px}
h2{margin:0 0 10px;font-size:20px}
h3{margin:16px 0 8px;font-size:17px;color:var(--ink-1)}
table{width:100%;border-collapse:collapse;background:rgba(255,255,255,.92);border-radius:12px;overflow:hidden}
th,td{border:1px solid #d7dfef;padding:8px 10px;font-size:14px;vertical-align:top}
th{background:#eef3ff;text-align:left;color:#1f3356}
.group-title td{background:#dfe9ff;font-weight:800;color:#1e3360}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:800}
.badge-bad{color:#991b1b;background:#fee2e2;border:1px solid #fecaca}
.badge-high{color:#92400e;background:#fef3c7;border:1px solid #fcd34d}
.badge-low{color:#065f46;background:#d1fae5;border:1px solid #a7f3d0}
.badge-none{color:#374151;background:#e5e7eb;border:1px solid #d1d5db}
code{background:#f3f6ff;padding:2px 5px;border-radius:6px}
a{color:#1b4fc7}
.sub-link{margin:0 0 10px;font-size:14px;color:var(--ink-1)}
@media (max-width:900px){.container{padding:16px}.hero h1{font-size:24px}th,td{font-size:13px;padding:7px 8px}}
</style></head><body><div class="container">
<div class="hero"><h1>EPAS to PostgreSQL Precheck</h1><p>DB NAME: <strong>${DBNAME}</strong></p></div>
<div class="card"><h2>?붿빟</h2><table>
<tr><th>??ぉ</th><th>寃異?嫄댁닔</th><th>媛??/th><th>遺덇?</th><th>?ㅻ챸</th></tr>
<tr class="group-title"><td colspan="5">1. ?뚮씪誘명꽣</td></tr><tr><td>1-1. ?뚮씪誘명꽣</td><td>${param_total}</td><td>${param_ok}</td><td>${param_bad}</td><td>?듭떖 ?뚮씪誘명꽣 + 蹂寃쎄컪</td></tr>
<tr class="group-title"><td colspan="5">2. EDB / Oracle Compatibility</td></tr><tr><td>2-1. ?ㅻ씪???명솚 ?ㅻ툕?앺듃</td><td>${feature_total}</td><td>${feature_ok}</td><td>${feature_bad}</td><td>?⑦궎吏/?ㅼ썙??/td></tr><tr><td>2-2. ?ㅻ씪???곗씠?고???/td><td>${dtype_total}</td><td>${dtype_ok}</td><td>${dtype_bad}</td><td>媛앹껜/?뚯씠釉?/td></tr><tr><td>2-3. ?쒗쁽??/td><td>${expr_total}</td><td>${expr_ok}</td><td>${expr_bad}</td><td>湲곕낯媛??쒖빟議곌굔/?몃뜳??/td></tr><tr><td>2-4. ?쒕끂??/td><td>${syn_total}</td><td>${syn_ok}</td><td>${syn_bad}</td><td>?쒕끂??/td></tr>
<tr class="group-title"><td colspan="5">3. ?뺤콉 諛??대━??/td></tr><tr><td>3-1. ?뺤콉(RLS)</td><td>${rls_total}</td><td>${rls_ok}</td><td>${rls_bad}</td><td>pg_policies + sys.all_policies</td></tr><tr><td>3-2. Redaction</td><td>${redaction_total}</td><td>${redaction_ok}</td><td>${redaction_bad}</td><td>edb_redaction_*</td></tr><tr><td>3-3. ?꾨줈?뚯씪</td><td>${profile_total}</td><td>${profile_ok}</td><td>${profile_bad}</td><td>non-default</td></tr><tr><td>3-4. 由ъ냼??洹몃９</td><td>${rg_total}</td><td>${rg_ok}</td><td>${rg_bad}</td><td>resource group</td></tr>
<tr class="group-title"><td colspan="5">4. DBLINK</td></tr><tr><td>4-1. DBLINK</td><td>${dblink_total}</td><td>${dblink_ok}</td><td>${dblink_bad}</td><td>dblink</td></tr>
</table></div>
<div class="card"><h2>寃異??곸꽭(??</h2><p class="sub-link">媛앹껜 ?대┃ ???먮Ц: <a href="${SOURCE_HTML_BASENAME}">${SOURCE_HTML_BASENAME}</a></p>
<h3>1-1. ?뚮씪誘명꽣 (珥?${param_total}嫄?</h3><table><tr><th>?뚮씪誘명꽣</th><th>湲곕낯媛?/th><th>?꾩옱媛?/th><th>?ㅻ챸</th><th>?먯젙</th></tr>$(default_row_if_empty "$PARAM_ROWS" 5)</table>
<h3>2-1. ?ㅻ씪???명솚 ?ㅻ툕?앺듃 (珥?${feature_total}嫄?</h3><table><tr><th>???/th><th>援щ텇</th><th>媛앹껜</th><th>寃異??댁슜</th><th>?먯젙</th></tr>$(default_row_if_empty "$FEATURE_ROWS" 5)</table>
<h3>2-2. ?ㅻ씪???곗씠?고???(珥?${dtype_total}嫄?</h3><table><tr><th>???/th><th>媛앹껜</th><th>?곗씠?고???/th></tr>$(default_row_if_empty "$DTYPE_ROWS" 3)</table>
<h3>2-3. ?쒗쁽??(珥?${expr_total}嫄?</h3><table><tr><th>媛앹껜</th><th>???/th><th>寃異??ㅼ썙??/th><th>?먯젙</th></tr>$(default_row_if_empty "$EXPR_ROWS" 4)</table>
<h3>2-4. ?쒕끂??(珥?${syn_total}嫄?</h3><table><tr><th>?쒕끂??/th><th>???媛앹껜</th><th>?먯젙</th></tr>$( [ -n "$syn_rows_html" ] && echo "$syn_rows_html" || echo '<tr><td colspan="3">寃異??놁쓬</td></tr>' )</table>
<h3>3-1. ?뺤콉(RLS) (珥?${rls_total}嫄? - Row Level Security ?뺤콉 ?먭?</h3><table><tr><th>????뚯씠釉?/th><th>?뺤콉紐?/th><th>紐낅졊</th><th>?먯젙</th></tr>$( [ -n "$rls_rows_html" ] && echo "$rls_rows_html" || echo '<tr><td colspan="4">寃異??놁쓬</td></tr>' )</table>
<h3>3-2. Redaction (珥?${redaction_total}嫄? - ?곗씠??留덉뒪???뺤콉 ?먭?</h3><table><tr><th>????뚯씠釉?/th><th>?뺤콉紐?/th><th>而щ읆</th><th>?먯젙</th></tr>$( [ -n "$redaction_rows_html" ] && echo "$redaction_rows_html" || echo '<tr><td colspan="4">寃異??놁쓬</td></tr>' )</table>
<h3>3-3. ?꾨줈?뚯씪 (珥?${profile_total}嫄?</h3><table><tr><th>?꾨줈?뚯씪</th><th>?곸슜 ?좎?</th><th>?먯젙</th></tr>$( [ -n "$profile_rows_html" ] && echo "$profile_rows_html" || echo '<tr><td colspan="3">寃異??놁쓬</td></tr>' )</table>
<h3>3-4. 由ъ냼??洹몃９ (珥?${rg_total}嫄?</h3><table><tr><th>由ъ냼??洹몃９</th><th>CPU rate</th><th>dirtyratelimit</th><th>?곸슜 ?좎?</th><th>?먯젙</th></tr>$( [ -n "$rg_rows_html" ] && echo "$rg_rows_html" || echo '<tr><td colspan="5">寃異??놁쓬</td></tr>' )</table>
<h3>4-1. DBLINK (珥?${dblink_total}嫄?</h3><table><tr><th>DBLINK</th><th>USER</th><th>?곌껐?뺣낫</th><th>?먯젙</th></tr>$( [ -n "$dblink_rows_html" ] && echo "$dblink_rows_html" || echo '<tr><td colspan="4">寃異??놁쓬</td></tr>' )</table>
</div></div></body></html>
HTML

# remove helper artifacts from output dir
purge_files "$OUT_DIR"/.f.tsv "$OUT_DIR"/.d.tsv "$OUT_DIR"/.param_rows.html "$OUT_DIR"/.feature_rows.html "$OUT_DIR"/.dtype_rows.html "$OUT_DIR"/.expr_rows.html

cat > "$OUT_DIR/REPORT_INDEX.txt" <<TXT
[EPAS to PostgreSQL Precheck]
Output directory : $OUT_DIR
Connection hints : host=${HOST:-N/A}, port=${PORT:-N/A}, db=${DBNAME:-N/A}, user=${DBUSER:-N/A}
HTML report      : ${HTML_BASENAME}
Source HTML      : ${SOURCE_HTML_BASENAME}
Source directory : ${SOURCE_DIR_BASENAME}/
Compatibility   : OS[RHEL 7/8/9, Ubuntu 20/22/24], EPAS[9.6/10/14/17]
TXT

echo "[DONE] Report generated at: $OUT_DIR"
echo "       Open HTML: $OUT_DIR/$HTML_BASENAME"
echo "       Source   : $OUT_DIR/$SOURCE_HTML_BASENAME"
echo "       Objects  : $OUT_DIR/$SOURCE_DIR_BASENAME/"

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
