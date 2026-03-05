# EPAS to PostgreSQL Precheck

`generate_epas_migration_report.sh`는 EPAS(Oracle 호환 모드 포함) 환경에서 **현재 사용 중인 Oracle/EDB 특화 요소를 점검**하고,
요청하신 5개 파트 형식의 이관 리포트 산출물(TSV + HTML)을 자동 생성하는 스크립트입니다.

구성은 **2개 파일**로 분리되어 있습니다.
- `generate_epas_migration_report.sh` : 실행/리포트 생성 로직
- `migration_report_queries.sql` : 점검 SQL 모음

---

## 1) 무엇을 해주는 스크립트인가?

이 스크립트는 다음 항목을 자동 조회합니다.

1. **파라미터 점검**
   - 핵심 Oracle 호환 파라미터 강제 점검
   - 기본값 대비 현재값이 달라진 파라미터만 추출
2. **EDB(Oracle) 특화 기능 Summary**
   - 2-1에서 패키지 + Oracle 키워드를 통합 표시(동일 객체 merge)
   - Synonym
   - 정책(RLS)
3. **디테일(User Created)**
   - 3-2/3-3에서 Oracle 데이터타입을 통합 표시(소견 제외)
   - 기본값/제약조건/함수기반 인덱스 표현식의 Oracle 함수 사용(인덱스는 인덱스명 표시)
4. **폴리시 디테일(User Created)**
   - EDB Profile (default 제외)
   - EDB Resource Group
   - EDB DBLINK
5. **소견(HTML)**
   - 대체 가능 / 조건부 대체 / 대체 불가(수동 수정) 관점 요약

---

## 2) 요구사항

- Bash
- `psql` 클라이언트
- 점검 대상 DB 접속 정보 (`-h/-p/-d/-U` 옵션 또는 `PG*` 환경변수)
- (권장) 메타데이터 조회 권한

> 참고: EPAS 버전/권한에 따라 `pg_catalog.edb_profile`, `pg_catalog.edb_resource_group`, `pg_catalog.edb_dblink`가 없거나 조회 불가일 수 있습니다.
> 이 경우 스크립트는 실패하지 않고 해당 파일을 빈 파일로 생성합니다.

---

## 3) 빠른 시작

> 실행 권장: `bash generate_epas_migration_report.sh`
> (`sh`로 실행해도 스크립트가 내부적으로 bash로 재실행되도록 처리되어 있습니다.)


```bash
chmod +x generate_epas_migration_report.sh

# 기본 실행(출력 디렉터리 미지정)
# => 최종 결과는 ./<DBNAME>.html 만 남고, 중간 TSV는 삭제됨
./generate_epas_migration_report.sh -d edb -U enterprisedb

# 출력 디렉터리 지정
./generate_epas_migration_report.sh -h 127.0.0.1 -p 5444 -d edb -U enterprisedb -o ./migration_report_prod_2026-03-03
```

### 도움말

```bash
./generate_epas_migration_report.sh --help
```

### 주요 옵션

- `-h, --host` : DB host (default: `localhost`)
- `-p, --port` : DB port (default: `5444`)
- `-d, --dbname` : DB name (필수)
- `-U, --user` : DB user (필수)
- `-W, --password` : DB password
- `-o, --output` : 출력 디렉터리 (미지정 시 `./<DBNAME>.html`만 최종 보관, 중간 TSV는 임시 생성 후 삭제)
- `--connect-timeout` : 연결 타임아웃 초

---

## 4) 접속 설정 방법

`psql` 환경변수를 그대로 사용합니다.

```bash
export PGHOST=127.0.0.1
export PGPORT=5444
export PGDATABASE=edb
export PGUSER=enterprisedb
# export PGPASSWORD='********'   # 필요 시

./generate_epas_migration_report.sh ./report_local
```

### psql 경로를 직접 지정하고 싶은 경우

```bash
PSQL_BIN=/usr/edb/as16/bin/psql ./generate_epas_migration_report.sh
```

---

## 5) 생성 파일 구조

실행이 끝나면 출력 디렉터리에 다음 파일이 생성됩니다.

```text
01_parameters.tsv
02_summary_packages.tsv
02_summary_synonyms.tsv
02_summary_policies.tsv
03_detail_keywords.tsv
03_detail_datatypes_objects.tsv
03_detail_datatypes_tables.tsv
03_detail_expr_keywords.tsv
04_policy_edb_profile.tsv
04_policy_edb_resource_group.tsv
04_policy_edb_dblink.tsv
<DBNAME>.html
REPORT_INDEX.txt

# SQL source
migration_report_queries.sql
```

---

## 6) 각 파일 해석 가이드

### `01_parameters.tsv`
- 핵심 점검 파라미터 또는 기본값 대비 변경된 파라미터 목록
- `check_required = O` 는 반드시 검토 권장
- `description` 컬럼으로 파라미터 영향도 설명 확인

### `02_summary_*`, `03_detail_*`
- HTML에서 `02_summary_packages.tsv` + `03_detail_keywords.tsv`를 **통합(2-1)** 하여 표시합니다.
- 동일 객체 기준으로 키워드/패키지 검출값을 merge하고 중복을 제거합니다.
- 정렬은 스키마 기준, 동일 스키마 내 객체 타입 `P/F/V` 순으로 표시합니다.
- 데이터타입은 `03_detail_datatypes_objects.tsv` + `03_detail_datatypes_tables.tsv`를 **통합(3-2/3-3)** 하여 소견 없이 표시합니다.

### `04_policy_*`
- 이관 시 운영정책 영향이 큰 항목
- profile/resource group/dblink는 대체 설계 필요성이 큰 편

### `<DBNAME>.html`
- 비기술 담당자도 보기 쉬운 형태의 최종 소견
- 1~4 항목이 그룹 단위로 구분된 요약 표 제공 (예: 2-1, 2-2, 2-3)
- 요약 표에서 검출 건수와 함께 가능/불가 상태를 함께 표시하고, 항목별 **상세 표**를 제공합니다
- 상세 표 마지막 컬럼에 항목별 소견(대체 가능/조건부 대체 가능/대체 불가) 제공

### 소견 분류 규칙(상세 표)
- `파라미터`는 파라미터 이름 기준으로 자동 분류합니다.
  - EDB 고유 보안/감사/리소스 제어 파라미터 → 대체 불가(수동 수정 필요)
  - 문법/동작 차이 유발 파라미터 → 조건부 대체 가능
  - 그 외 → 대체 가능
- `오라클 키워드/함수`는 대표 키워드 기반으로 분류합니다.
  - 예: `rownum`, `rowid`, `dual` 등은 대체 불가(수동 수정 필요)
  - 예: `sysdate`, `nvl`, `add_months` 등은 대체 가능
  - 그 외는 조건부 대체 가능

---

## 7) 운영 추천 절차

1. 사전 백업/스냅샷 확보
2. 운영계정(또는 점검용 읽기권한 계정)으로 스크립트 실행
3. `<DBNAME>.html`로 전체 위험도 확인
4. `03_detail_*` 및 `*_raw.tsv` 기준으로 SQL/PL 코드 수정 Backlog 생성
5. CRITICAL 항목 우선 대체 설계
6. 테스트 환경에서 회귀 테스트 후 본 이관 계획 확정

---

## 8) 자주 발생하는 이슈(트러블슈팅)

### Q1. `psql command not found`
- `psql` 미설치 또는 PATH 문제
- 해결: `PSQL_BIN=/path/to/psql`로 지정

### Q2. 특정 파일이 비어있음
- 실제 사용이 없을 수 있음
- 또는 계정 권한 부족/EPAS 버전 차이 가능
- 운영 권한 계정으로 재실행 권장

### Q3. HTML 요약 건수가 TSV 행수와 다름
- 일부 구간(2-1, 3-2/3-3, 3-4)은 HTML에서 **객체 단위 merge/중복제거** 후 카운트됩니다.

### Q4. synonym/profile/dblink 결과가 없음
- 해당 기능 미사용 또는 카탈로그 미노출 가능

---

## 9) 보안 주의사항

- 스크립트는 DBLINK 조회 시 비밀번호 컬럼을 직접 출력하지 않도록 최소 컬럼만 선택합니다.
- 보고서 산출물에는 객체명/스키마명/연결 문자열 등 민감할 수 있는 메타 정보가 포함될 수 있습니다.
- 외부 공유 전 마스킹 정책을 적용하세요.

---

## 10) 예시 실행

```bash
PGHOST=192.168.56.100 \
PGPORT=5444 \
PGDATABASE=edb \
PGUSER=enterprisedb \
./generate_epas_migration_report.sh ./report_edb_prod
```

실행 완료 후:

- `./report_edb_prod/<DBNAME>.html` 열어서 전체 소견 확인
- `./report_edb_prod/03_detail_*.tsv` 기준으로 수동 수정 대상 리스트업

---

## 11) 한계 및 참고

- 정규식 기반 탐지는 문자열/주석 맥락에 따라 오탐 가능성이 있습니다.
- SQL 동적 생성 패턴은 정적 조회로 100% 식별되지 않을 수 있습니다.
- 본 스크립트는 **점검 보고 자동화 도구**이며, 실제 이관 가능성 확정은 기능 테스트/성능 테스트를 통해 보완해야 합니다.


## 12) SQL 정리 원칙

- SQL 정규식에서 과도한 탐지를 유발할 수 있는 불필요 패턴은 제거했습니다.
- 예: `\M|\m(?:user_[a-z0-9_]+|all_[a-z0-9_]+|dba_[a-z0-9_]+|v\$[a-z0-9_]+)\M` 패턴은 제외했습니다.
- 표현식 점검도 핵심 함수 위주(`sysdate`, `nvl`, `add_months` 등)로 정리했습니다.


## 추가 동작

- `-o` 옵션으로 출력 디렉터리를 지정하면 `*_raw.tsv` 파일이 함께 생성되어 원문(함수/뷰 본문, 표현식)을 확인할 수 있습니다.
- HTML의 객체명은 클릭 가능한 링크로 표시되며, 문서 하단 **원문 상세** 섹션으로 이동해 원문을 볼 수 있습니다.
