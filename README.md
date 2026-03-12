# EPAS to PostgreSQL Precheck

EPAS 환경에서 PostgreSQL 이관 전에 확인해야 할 Oracle/EDB 특화 요소를 점검하는 스크립트다.  
실행 결과는 TSV(분석용) + HTML(리뷰용)로 생성된다.

## 1) 제공 기능

- 파라미터 점검(핵심 파라미터 + 기본값 대비 변경값)
- EDB/Oracle 특화 기능/키워드 탐지
- 오라클 데이터타입 사용 객체 탐지
- 기본값/제약조건/인덱스 표현식 점검
- synonym / RLS / profile / resource group / dblink 점검
- 객체별 원문(source) HTML 생성 + 키워드 강조

## 2) 요구사항

- Bash
- `psql`
- `python3` (선택: 설치 시 고급 하이라이트 원문 페이지 생성)

### OS 호환 기준

- Ubuntu 20.04+
- Rocky Linux 8.x
- RHEL 6+

`sh script.sh ...` 형태로 실행하더라도 내부에서 Bash 비-POSIX 모드로 재실행하도록 처리되어, 오래된 배포판의 `/bin/sh` 차이로 인한 구문 오류를 피하도록 구성되어 있다.
Python 미설치 시에도 셸 기반 fallback으로 원문 인덱스/객체 페이지를 생성한다(고급 하이라이트는 Python 경로에서 제공).
- 압축 옵션 사용 시:
  - `tar` (`-c tar`, `-c gz` 공통)
  - `gzip` (`-c gz`일 때 추가 필요)

## 3) 파일 구성

- `generate_epas_migration_report.sh` : 메인 실행 스크립트
- `migration_report_queries.sql` : 쿼리 라이브러리 (`--@@ section`)
- `README.md` : 사용 가이드

## 4) 실행 방법

### 기본 실행 (`-o` 필수)

```bash
bash generate_epas_migration_report.sh -d <DBNAME> -U <USER> -o ./out
```

### 비밀번호를 옵션으로 전달

```bash
bash generate_epas_migration_report.sh -d <DBNAME> -U <USER> -W '<PASSWORD>'
```

### 압축 옵션 사용

```bash
# tar
bash generate_epas_migration_report.sh -d <DBNAME> -U <USER> -o ./out -c tar

# tar.gz
bash generate_epas_migration_report.sh -d <DBNAME> -U <USER> -o ./out -c gz
```

압축 옵션(`-c`)을 사용하면 압축 파일만 남기고 `-o` 폴더는 자동 삭제된다.

## 5) 옵션

- `-h, --host` : DB host
- `-p, --port` : DB port
- `-d, --dbname` : DB 이름 (필수)
- `-U, --user` : 사용자 (필수)
- `-W, --password` : 비밀번호
- `-o, --output` : 출력 디렉터리 (필수)
- `-c, --compress` : `tar` 또는 `gz`
- `--connect-timeout` : 접속 타임아웃(초)
- `--help` : 도움말 출력

> 인자를 하나도 주지 않고 실행하면 도움말만 출력하고 종료한다.
> 또한 `-o` 옵션이 없으면 스크립트는 에러로 종료한다.

## 6) 출력물

요약 카드 제목에는 `요약 (DB NAME : <dbname>)` 형식으로 DB 이름을 함께 표기한다.

기본적으로 `-o <DIR>` 아래 생성:

- `01_parameters.tsv`
- `02_summary_packages.tsv`
- `02_summary_synonyms.tsv`
- `02_summary_policies.tsv`
- `02_summary_policies_dbms_rls.tsv`
- `02_summary_redaction.tsv`
- `03_detail_keywords.tsv`
- `03_detail_datatypes_objects.tsv`
- `03_detail_datatypes_tables.tsv`
- `03_detail_expr_keywords.tsv`
- `04_policy_edb_profile.tsv` (프로파일 상세 + 적용 유저)
- `04_policy_edb_resource_group.tsv`
- `04_policy_edb_dblink.tsv`
- `<DBNAME>.html` (요약/상세 HTML)
- `<DBNAME>_source.html` (원문 인덱스)
- `<DBNAME>_sources/` (객체별 원문 페이지)
- `REPORT_INDEX.txt`

## 7) 판정 기준

구분 컬럼은 반복 문자열(예: `키워드+키워드+키워드`) 대신 집계 표기(예: `키워드(3)`, `패키지(5)+키워드(3)`)로 출력된다. 동일 키워드를 여러 번 사용한 경우에도 고유 키워드 기준으로 1건만 카운트한다(예: `raw` 4회 사용 -> `raw(1)`).

HTML 판정 배지:

- `불가` (빨강)
- `가능(난이도 높음)` (노랑)
- `가능(난이도 낮음)` (초록)

난이도 분류 로직(핵심):

- **불가**: `ROWNUM`, `ROWID`, `DUAL`, `MINUS`, `CONNECT BY` 계열, `PRAGMA`, `RAISE_APPLICATION_ERROR` 등
- **가능(난이도 높음)**: `DBMS_*`, `DBMS_CRYPTO`, `UTL_*`, `OWA_*`, `HTP.*`, `HTF.*`, `NVL/DECODE`, 날짜 함수, `CLOB/BFILE/RAW` 등
- **가능(난이도 낮음)**: 그 외 탐지 키워드

## 8) DBMS_CRYPTO 탐지

- 키워드 하이라이트는 대소문자를 구분하지 않고(case-insensitive) 적용되며, 표기/카운트는 소문자 기준으로 통합된다.

다음 영역에서 `DBMS_CRYPTO` 사용을 탐지한다.

- 특화기능/패키지 점검
- 키워드 상세 점검

`DBMS_CRYPTO`, `DBMS_CRYPTO.HASH`, `DBMS_CRYPTO.ENCRYPT` 같은 형태를 검출 대상으로 포함한다.

## 9) RLS / Redaction 보강

- `pg_policies` 기반 RLS 조회에 더해 `sys.all_policies`(DBMS_RLS 계열 메타) 조회를 추가로 수행한다.
- Redaction은 `edb_redaction_policy`, `edb_redaction_column`을 사용해 정책/컬럼/마스킹 함수 정보를 수집한다.
- 해당 카탈로그/뷰가 없는 버전에서는 자동으로 빈 TSV를 생성하고 계속 진행한다.

## 10) 트러블슈팅

### `ERR_FILE_NOT_FOUND` (객체 링크 클릭 시)

- 산출물 폴더와 `<DBNAME>_sources/` 폴더를 함께 이동했는지 확인
- 상대 경로가 깨지지 않게 HTML과 sources 디렉터리를 같은 루트에 유지

### 압축 실패

- `-c tar`/`-c gz` 사용 시 `tar` 설치 확인
- `-c gz` 사용 시 `gzip` 설치 확인

### `syntax error near unexpected token "<"`

- `sh`가 POSIX 모드로 스크립트를 실행하면 process substitution(`<<`/`< <(...)`) 구문에서 오류가 발생할 수 있다.
- 현재 스크립트는 Bash 모드 재실행 + 비 process-substitution 방식으로 수정되어 Rocky/RHEL 계열에서도 동일하게 동작하도록 했다.

### Python 미설치

- 셸 fallback으로 원문 인덱스/객체 HTML은 계속 생성됨
- Python 설치 시 키워드 하이라이트 품질/가독성이 더 좋아짐

## 11) 보안 주의사항

- `-W`로 비밀번호를 직접 전달하면 히스토리에 남을 수 있다.
- 가능하면 `PGPASSWORD` 환경변수 또는 `.pgpass` 사용을 권장한다.

