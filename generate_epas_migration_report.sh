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

SQL_FILE="${SQL_FILE:-$(cd "$(dirname "$0")" && pwd)/migration_report_queries.sql}"
if [[ ! -f "$SQL_FILE" ]]; then
  echo "[ERROR] SQL file not found: $SQL_FILE" >&2
  exit 1
fi

read_sql() {
  local key="$1"
  awk -v k="$key" '
    $0=="--@@ " k {in=1; next}
    /^--@@ / && in {exit}
    in {print}
  ' "$SQL_FILE"
}

# -----------------------------
# 1) 파라미터
# -----------------------------
run_tsv "$OUT_DIR/01_parameters.tsv" "$(read_sql parameters)"

# -----------------------------
# 2) EDB 특화 기능 summary
# -----------------------------
run_tsv "$OUT_DIR/02_summary_packages.tsv" "$(read_sql summary_packages)"

run_tsv "$OUT_DIR/02_summary_synonyms.tsv" "$(read_sql summary_synonyms)" || true

run_tsv "$OUT_DIR/02_summary_policies.tsv" "$(read_sql summary_policies)"

# -----------------------------
# 3) 디테일 (user created)
# -----------------------------
run_tsv "$OUT_DIR/03_detail_keywords.tsv" "$(read_sql detail_keywords)"

run_tsv "$OUT_DIR/03_detail_datatypes_objects.tsv" "$(read_sql detail_datatypes_objects)"

run_tsv "$OUT_DIR/03_detail_datatypes_tables.tsv" "$(read_sql detail_datatypes_tables)"

run_tsv "$OUT_DIR/03_detail_expr_keywords.tsv" "$(read_sql detail_expr_keywords)"

# -----------------------------
# 4) 폴리시 디테일 (user created)
# -----------------------------
if table_exists "pg_catalog.edb_profile"; then
  run_tsv "$OUT_DIR/04_policy_edb_profile.tsv" "$(read_sql policy_edb_profile)"
else
  : >"$OUT_DIR/04_policy_edb_profile.tsv"
fi

if table_exists "pg_catalog.edb_resource_group"; then
  run_tsv "$OUT_DIR/04_policy_edb_resource_group.tsv" "$(read_sql policy_edb_resource_group)"
else
  : >"$OUT_DIR/04_policy_edb_resource_group.tsv"
fi

if table_exists "pg_catalog.edb_dblink"; then
  run_tsv "$OUT_DIR/04_policy_edb_dblink.tsv" "$(read_sql policy_edb_dblink)"
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

default_row_if_empty() {
  local s="$1"
  local colspan="$2"
  if [[ -z "${s//[[:space:]]/}" ]]; then
    printf '<tr><td colspan="%s">검출 없음</td></tr>' "$colspan"
  else
    printf "%s" "$s"
  fi
}

param_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  opinion="대체 가능"
  if ($5 ~ /^\[CRITICAL\]/) opinion="대체 불가(수동 수정 필요)"
  else if ($5 ~ /^\[WARNING\]/) opinion="조건부 대체 가능"
  badge=(opinion=="대체 불가(수동 수정 필요)"?"badge-crit":(opinion=="조건부 대체 가능"?"badge-warn":"badge-ok"));
  printf "<tr><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge %s\">%s</span></td></tr>\n", $1, $2, $3, $5, badge, opinion
}' "$OUT_DIR/01_parameters.tsv")
param_rows_html=$(default_row_if_empty "$param_rows_html" 5)

pkg_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  opinion="조건부 대체 가능";
  badge="badge-warn";
  printf "<tr><td>%s</td><td><code>%s.%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n", $1, $2, $3, $4, badge, opinion
}' "$OUT_DIR/02_summary_packages.tsv")
pkg_rows_html=$(default_row_if_empty "$pkg_rows_html" 4)

syn_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  opinion="조건부 대체 가능"; badge="badge-warn";
  printf "<tr><td><code>%s.%s</code></td><td><code>%s.%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n", $1,$2,$3,$4,badge,opinion
}' "$OUT_DIR/02_summary_synonyms.tsv")
syn_rows_html=$(default_row_if_empty "$syn_rows_html" 3)

rls_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  opinion="조건부 대체 가능"; badge="badge-warn";
  printf "<tr><td><code>%s.%s</code></td><td><code>%s</code></td><td>%s</td><td><span class=\"badge %s\">%s</span></td></tr>\n", $1,$2,$3,$6,badge,opinion
}' "$OUT_DIR/02_summary_policies.tsv")
rls_rows_html=$(default_row_if_empty "$rls_rows_html" 4)

kw_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  keyword=$4; opinion="조건부 대체 가능";
  if (keyword ~ /^(rownum|rowid|dual|minus|sys_connect_by_path|connect_by_root|connect_by_isleaf|level|pragma|sqlcode|sqlerrm|raise_application_error)$/) opinion="대체 불가(수동 수정 필요)";
  else if (keyword ~ /^(sysdate|systimestamp|nvl|nvl2|add_months|months_between|last_day|next_day|instr|greatest|least|substrb|instrb|lengthb|numtodsinterval|numtoyminterval)$/) opinion="대체 가능";
  obj=$2 "." $3;
  k=$1 SUBSEP obj SUBSEP opinion;
  if (keyword != "") {
    if (!(k in kwset) || index("," kwset[k] ",", "," keyword ",") == 0) {
      kwset[k]=(k in kwset && kwset[k]!="" ? kwset[k] ", " : "") keyword;
    }
  }
}
END {
  for (k in kwset) {
    split(k,a,SUBSEP);
    badge=(a[3]=="대체 불가(수동 수정 필요)"?"badge-crit":(a[3]=="조건부 대체 가능"?"badge-warn":"badge-ok"));
    printf "<tr><td>%s</td><td><code>%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n", a[1],a[2],kwset[k],badge,a[3];
  }
}' "$OUT_DIR/03_detail_keywords.tsv")
kw_rows_html=$(default_row_if_empty "$kw_rows_html" 4)

dtype_obj_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  dtype=$4; opinion="조건부 대체 가능";
  if (dtype ~ /^(clob)$/) opinion="대체 가능";
  badge=(opinion=="조건부 대체 가능"?"badge-warn":"badge-ok");
  printf "<tr><td>%s</td><td><code>%s.%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n", $1,$2,$3,$4,badge,opinion
}' "$OUT_DIR/03_detail_datatypes_objects.tsv")
dtype_obj_rows_html=$(default_row_if_empty "$dtype_obj_rows_html" 4)

dtype_tbl_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  dtype=$4; opinion="조건부 대체 가능";
  if (dtype ~ /^(clob)$/) opinion="대체 가능";
  badge=(opinion=="조건부 대체 가능"?"badge-warn":"badge-ok");
  printf "<tr><td><code>%s.%s.%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n", $1,$2,$3,$4,badge,opinion
}' "$OUT_DIR/03_detail_datatypes_tables.tsv")
dtype_tbl_rows_html=$(default_row_if_empty "$dtype_tbl_rows_html" 3)

expr_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  kw=$5; opinion="조건부 대체 가능";
  if (kw ~ /^(sysdate|systimestamp|add_months|months_between|last_day|next_day|instr)$/) opinion="대체 가능";
  obj=$2 "." $3;
  k=$1 SUBSEP obj SUBSEP opinion;
  if (kw != "") {
    if (!(k in kwset) || index("," kwset[k] ",", "," kw ",") == 0) {
      kwset[k]=(k in kwset && kwset[k]!="" ? kwset[k] ", " : "") kw;
    }
  }
}
END {
  for (k in kwset) {
    split(k,a,SUBSEP);
    badge=(a[3]=="대체 불가(수동 수정 필요)"?"badge-crit":(a[3]=="조건부 대체 가능"?"badge-warn":"badge-ok"));
    printf "<tr><td>%s</td><td><code>%s</code></td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n", a[1],a[2],kwset[k],badge,a[3];
  }
}' "$OUT_DIR/03_detail_expr_keywords.tsv")
expr_rows_html=$(default_row_if_empty "$expr_rows_html" 4)

profile_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  opinion="조건부 대체 가능"; badge="badge-warn";
  printf "<tr><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n", $2,badge,opinion
}' "$OUT_DIR/04_policy_edb_profile.tsv")
profile_rows_html=$(default_row_if_empty "$profile_rows_html" 2)

rg_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  opinion="조건부 대체 가능"; badge="badge-warn";
  printf "<tr><td><code>%s</code></td><td>%s</td><td><span class=\"badge %s\">%s</span></td></tr>\n", $4,$2,badge,opinion
}' "$OUT_DIR/04_policy_edb_resource_group.tsv")
rg_rows_html=$(default_row_if_empty "$rg_rows_html" 3)

dblink_rows_html=$(awk -F $'	' 'NR==1{next}
{
  for(i=1;i<=NF;i++){gsub("&","&amp;",$i);gsub("<","&lt;",$i);gsub(">","&gt;",$i)}
  opinion="조건부 대체 가능"; badge="badge-warn";
  printf "<tr><td><code>%s</code></td><td>%s</td><td><code>%s</code></td><td><span class=\"badge %s\">%s</span></td></tr>\n", $1,$5,$6,badge,opinion
}' "$OUT_DIR/04_policy_edb_dblink.tsv")
dblink_rows_html=$(default_row_if_empty "$dblink_rows_html" 4)

cat >"$OUT_DIR/05_opinion.html" <<HTML
<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <title>EPAS 이관 점검 리포트</title>
  <style>
    body { font-family: "Segoe UI", Arial, sans-serif; margin: 0; background: #f8fafc; color: #1f2937; }
    .container { max-width: 1300px; margin: 28px auto; padding: 0 28px 36px; }
    h1, h2, h3 { color: #1f2937; margin-top: 24px; }
    .card { background: #fff; border: 1px solid #e5e7eb; border-radius: 12px; padding: 18px; box-shadow: 0 1px 2px rgba(0,0,0,0.04); }
    table { border-collapse: collapse; width: 100%; margin: 12px 0; background: #fff; }
    th, td { border: 1px solid #d1d5db; padding: 8px; text-align: left; vertical-align: top; }
    th { background: #f3f4f6; }
    .matrix th { text-align: center; font-size: 12px; }
    .matrix td { text-align: center; font-weight: 600; }
    .ok { color: #065f46; font-weight: 700; }
    .warn { color: #92400e; font-weight: 700; }
    .crit { color: #991b1b; font-weight: 700; }
    .group-title { background: #e0e7ff; font-weight: 700; }
    .opinion-item { padding: 10px 12px; border-radius: 8px; margin: 8px 0; border: 1px solid transparent; }
    .opinion-crit { background: #fef2f2; border-color: #fecaca; }
    .opinion-warn { background: #fffbeb; border-color: #fde68a; }
    .opinion-ok { background: #ecfdf5; border-color: #a7f3d0; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; font-weight: 700; }
    .badge-crit { color: #991b1b; background: #fee2e2; border: 1px solid #fecaca; }
    .badge-warn { color: #92400e; background: #fef3c7; border: 1px solid #fde68a; }
    .badge-ok { color: #065f46; background: #d1fae5; border: 1px solid #a7f3d0; }
    code { background: #f3f4f6; padding: 2px 4px; border-radius: 4px; }
  </style>
</head>
<body>
  <div class="container">
  <h1>이관 리포트 (EPAS → PostgreSQL)</h1>
  <div class="card">
  <h2>요약</h2>
  <table>
    <tr><th>항목</th><th>검출 건수</th><th>가벼운 설명</th></tr>
    <tr class="group-title"><td colspan="3">1. 파라미터</td></tr>
    <tr><td>1-1. 파라미터(점검 대상)</td><td>${param_cnt}</td><td>핵심 호환 파라미터 + 기본값 대비 변경값 점검</td></tr>

    <tr class="group-title"><td colspan="3">2. EDB(Oracle) 특화기능 Summary</td></tr>
    <tr><td>2-1. EDB 특화 기능(패키지/프로시저/함수/뷰)</td><td>${pkg_cnt}</td><td>DBMS/UTL/OWA/HTP/HTF 계열 사용 흔적</td></tr>
    <tr><td>2-2. 시노님</td><td>${syn_cnt}</td><td>synonym → 실제 객체 매핑 현황</td></tr>
    <tr><td>2-3. 정책(RLS)</td><td>${rls_cnt}</td><td>RLS 정책 존재 여부와 대상 테이블</td></tr>

    <tr class="group-title"><td colspan="3">3. 디테일 (user created)</td></tr>
    <tr><td>3-1. 오라클 키워드/함수</td><td>${kw_cnt}</td><td>객체 정의에서 Oracle 키워드/함수 의존 흔적</td></tr>
    <tr><td>3-2. 오라클 데이터타입(함수/프로시저/뷰)</td><td>${dtype_obj_cnt}</td><td>코드/뷰 내부 Oracle 데이터타입 사용</td></tr>
    <tr><td>3-3. 오라클 데이터타입(테이블)</td><td>${dtype_tbl_cnt}</td><td>테이블 컬럼 datatype 의존</td></tr>
    <tr><td>3-4. 기본값/제약조건/인덱스 표현식</td><td>${expr_cnt}</td><td>표현식 내 Oracle 함수 사용</td></tr>

    <tr class="group-title"><td colspan="3">4. 폴리시 디테일 (user created)</td></tr>
    <tr><td>4-1. 프로파일(Non-default)</td><td>${profile_cnt}</td><td>default 이외 profile 존재 여부</td></tr>
    <tr><td>4-2. 리소스 그룹</td><td>${rg_cnt}</td><td>리소스 그룹 설정 현황</td></tr>
    <tr><td>4-3. DBLINK</td><td>${dblink_cnt}</td><td>DBLINK 정의 현황</td></tr>
  </table>

  <h3>요약 매트릭스 (X축: 항목 / Y축: 검출 건수)</h3>
  <table class="matrix">
    <tr>
      <th>1-1 파라미터</th>
      <th>2-1 특화 기능</th>
      <th>2-2 시노님</th>
      <th>2-3 정책(RLS)</th>
      <th>3-1 키워드/함수</th>
      <th>3-2 데이터타입(객체)</th>
      <th>3-3 데이터타입(테이블)</th>
      <th>3-4 표현식</th>
      <th>4-1 프로파일</th>
      <th>4-2 리소스 그룹</th>
      <th>4-3 DBLINK</th>
    </tr>
    <tr>
      <td>${param_cnt}</td>
      <td>${pkg_cnt}</td>
      <td>${syn_cnt}</td>
      <td>${rls_cnt}</td>
      <td>${kw_cnt}</td>
      <td>${dtype_obj_cnt}</td>
      <td>${dtype_tbl_cnt}</td>
      <td>${expr_cnt}</td>
      <td>${profile_cnt}</td>
      <td>${rg_cnt}</td>
      <td>${dblink_cnt}</td>
    </tr>
  </table>
  </div>

  <div class="card">
  <h2>검출 상세(표)</h2>

  <h3>1-1. 파라미터 (${param_cnt}건)</h3>
  <table>
    <tr><th>파라미터</th><th>기본값</th><th>현재값</th><th>설명</th><th>소견</th></tr>
    ${param_rows_html}
  </table>

  <h3>2-1. EDB 특화 기능(패키지/프로시저/함수/뷰) (${pkg_cnt}건)</h3>
  <table>
    <tr><th>객체 타입</th><th>객체</th><th>검출 내용</th><th>소견</th></tr>
    ${pkg_rows_html}
  </table>

  <h3>2-2. 시노님 (${syn_cnt}건)</h3>
  <table>
    <tr><th>시노님</th><th>대상 객체</th><th>소견</th></tr>
    ${syn_rows_html}
  </table>

  <h3>2-3. 정책(RLS) (${rls_cnt}건)</h3>
  <table>
    <tr><th>대상 테이블</th><th>정책명</th><th>명령</th><th>소견</th></tr>
    ${rls_rows_html}
  </table>

  <h3>3-1. 오라클 키워드/함수 (${kw_cnt}건)</h3>
  <table>
    <tr><th>객체 타입</th><th>객체</th><th>검출 키워드</th><th>소견</th></tr>
    ${kw_rows_html}
  </table>

  <h3>3-2. 오라클 데이터타입(함수/프로시저/뷰) (${dtype_obj_cnt}건)</h3>
  <table>
    <tr><th>객체 타입</th><th>객체</th><th>데이터타입</th><th>소견</th></tr>
    ${dtype_obj_rows_html}
  </table>

  <h3>3-3. 오라클 데이터타입(테이블) (${dtype_tbl_cnt}건)</h3>
  <table>
    <tr><th>컬럼</th><th>데이터타입</th><th>소견</th></tr>
    ${dtype_tbl_rows_html}
  </table>

  <h3>3-4. 기본값/제약조건/인덱스 표현식 (${expr_cnt}건)</h3>
  <table>
    <tr><th>객체 타입</th><th>객체</th><th>검출 키워드</th><th>소견</th></tr>
    ${expr_rows_html}
  </table>

  <h3>4-1. 프로파일(Non-default) (${profile_cnt}건)</h3>
  <table>
    <tr><th>프로파일</th><th>소견</th></tr>
    ${profile_rows_html}
  </table>

  <h3>4-2. 리소스 그룹 (${rg_cnt}건)</h3>
  <table>
    <tr><th>리소스 그룹</th><th>CPU limit</th><th>소견</th></tr>
    ${rg_rows_html}
  </table>

  <h3>4-3. DBLINK (${dblink_cnt}건)</h3>
  <table>
    <tr><th>DBLINK</th><th>USER</th><th>연결정보</th><th>소견</th></tr>
    ${dblink_rows_html}
  </table>

  <h2>5. 종합 소견</h2>
  <ul>
    <li class="opinion-item opinion-crit"><span class="crit">대체 불가(수동 수정 필요)</span>: CRITICAL 파라미터/EDB 고유 보안·리소스 제어 기능은 PostgreSQL 기본 기능으로 1:1 대체가 어렵습니다.</li>
    <li class="opinion-item opinion-warn"><span class="warn">조건부 대체 가능</span>: SQL 재작성, 기능 대체 설계, 성능 재튜닝을 통해 전환 가능합니다.</li>
    <li class="opinion-item opinion-ok"><span class="ok">대체 가능</span>: 일부 항목은 PostgreSQL 표준 기능 또는 확장(예: <code>orafce</code>, <code>oracle_fdw</code>, <code>pg_hint_plan</code>)으로 대체 가능합니다.</li>
  </ul>

  <h2>산출물 파일</h2>
  <p>같은 디렉터리의 <code>01_*.tsv</code> ~ <code>04_*.tsv</code> 파일을 근거 데이터로 사용하세요.</p>
  </div>
  </div>
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
