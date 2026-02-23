# EPAS Precheck

`epas_precheck.sh`는 **EPAS(EDB Postgres Advanced Server) → PostgreSQL 마이그레이션 사전진단**을 위한 Bash 스크립트입니다.

데이터베이스에 접속해서 확장/객체/루틴/권한/타입 핫스팟/시퀀스 등의 기본 인벤토리를 수집하고,
요약 리포트(`91_summary.md`), 머신 파싱용 카운트(`90_count_summary.tsv`),
그리고 가독성 중심의 마이그레이션 가이드(`92_migration_guide_report.md`)를 생성합니다.

---

## 1) 요구사항

- Bash
- `psql` (PostgreSQL client)
- 대상 DB 접속 권한

> 스크립트를 `sh epas_precheck.sh ...`로 실행해도 내부적으로 bash로 재실행됩니다.

---

## 2) 빠른 시작

```bash
chmod +x epas_precheck.sh
./epas_precheck.sh -h localhost -p 5444 -d mydb -U enterprisedb -o ./precheck.out
```

`-o/--output`을 지정하지 않으면, 스크립트는 임시 디렉터리에 결과를 생성한 뒤
`92_migration_guide_report.md` 내용을 표준출력으로 보여주고 종료합니다(이때 `## 8) List of migration risk hits` 섹션은 USER_CREATED만 출력).

비밀번호를 옵션으로 전달하지 않고 환경변수로 주는 것을 권장합니다.

```bash
export PGPASSWORD='your-password'
./epas_precheck.sh -h localhost -p 5444 -d mydb -U enterprisedb -o ./precheck.out
```

---

## 3) 옵션

```text
-h, --host HOST         Database host (default: localhost)
-p, --port PORT         Database port (default: 5444)
-d, --dbname DBNAME     Database name (required)
-U, --user USER         Database user (required)
-W, --password PASSWORD Database password (or use PGPASSWORD env)
-s, --schema SCHEMA     Limit object inventory to one schema
-o, --output DIR        Output directory (default: ./precheck_output_<timestamp>)
--oracle-checks         Run Oracle-compatibility pattern checks on function bodies
--connect-timeout SEC   libpq connection timeout seconds (default: 5)
```

---

## 4) 실행 예시

### 기본 진단

```bash
./epas_precheck.sh -h 10.0.0.10 -p 5444 -d appdb -U enterprisedb -o ./precheck.appdb
```

### 특정 스키마만 진단

```bash
./epas_precheck.sh -h 10.0.0.10 -p 5444 -d appdb -U enterprisedb -s app -o ./precheck.app
```

### Oracle 호환 패턴 검사 포함

```bash
./epas_precheck.sh -h 10.0.0.10 -p 5444 -d appdb -U enterprisedb --oracle-checks -o ./precheck.oracle
```

---

## 5) 결과물 설명

출력 디렉터리(`-o`) 아래에 주요 파일이 생성됩니다.

- `01_version.txt`: DB 버전
- `02_instance_settings.tsv`: 인코딩/Collation/Timezone
- `03_extensions.tsv`: 확장 목록
- `04_objects.tsv`: 스키마 객체 목록
- `05_object_kind_counts.tsv`: 객체 kind별 집계
- `06_routines.tsv`: 함수/프로시저 목록
- `07_routine_kind_counts.tsv`: 루틴 kind별 집계
- `07b_routine_kind_owner_counts.tsv`: 루틴 kind + 소유 구분(EDB_BUILTIN/USER_CREATED) 집계
- `08_table_grants.tsv`: 테이블 권한 목록
- `09_type_hotspots.tsv`: 마이그레이션 민감 타입 컬럼 목록
- `10_sequences.tsv`: 시퀀스 목록
- `11_edb_extension_hits.txt`: `edb%` 확장 히트
- `12_edb_function_name_hits.txt`: `edb%` 함수명 히트
- `13_epas_feature_hits.tsv`: EPAS/Oracle 특화 패턴 히트 (예: `SYS_CONTEXT`, `AUTHID`, `NVL`, `SYSDATE`, `DBMS_RLS`, `CLOB` 등) + `EDB_BUILTIN`/`USER_CREATED` 구분
- `14_migration_risk_hits.tsv`: 이관 시 자주 실패하는 패턴 히트 (`SYSDATE DEFAULT`, `edbspl`, `pg_stat_statements` 객체 충돌 등)
- `15_oracle_keyword_hits.tsv`: Oracle 키워드 히트 (`--oracle-checks` 사용 시)
- `16_epas_group_counts.tsv`: Section 4 주요 그룹 카운트(SYNONYM/PACKAGE/AUTHID/CLOB)
- `90_count_summary.tsv`: `metric<TAB>count` 집계
- `91_summary.md`: 사람 읽기용 요약
- `92_migration_guide_report.md`: 호환성/대체기능/수동수정 필요 여부 + 덤프 기반 추가 체크리스트를 정리한 가이드 리포트
- `93_migration_summary_report.txt`: 한눈에 보는 텍스트 요약 리포트
- `94_user_created_risk_hits.txt`: 변환 우선 대상(USER_CREATED) 리스크 목록
- `95_builtin_risk_hits.txt`: 이관 제외/선별 대상(EDB_BUILTIN) 리스크 목록

`90_count_summary.tsv`에는 `epas_builtin_feature_hits`, `epas_user_feature_hits`가 포함되어
내장/확장 객체와 사용자 생성 객체의 특화 기능 사용량을 분리해 볼 수 있습니다.

분류 기준(요약):
- `EDB_BUILTIN`: extension 소유 객체, `sys`/`edb`/`utl_%`/`dbms_%` 스키마 객체, `pg_stat_statements` 계열 객체
- `USER_CREATED`: 위 기준에 해당하지 않는 사용자 스키마/객체

---

## 6) 오류/트러블슈팅

### `role "..." does not exist`
입력한 `-U` 사용자가 대상 DB에 존재하지 않거나 권한이 없는 경우입니다.

```bash
psql -h <host> -p <port> -U <user> -d <dbname> -c "select current_user, current_database();"
```

### 연결 실패
- host/port/dbname/user/password 확인
- 방화벽/보안그룹 확인
- `--connect-timeout` 값을 늘려 재시도

### 권한 부족으로 일부 조회 실패
진단 계정에 카탈로그/메타데이터 조회 권한이 있는지 확인하세요.

### 테이블 생성 시 `DEFAULT sysdate` 오류
- 원인: PostgreSQL은 `sysdate`를 컬럼 참조처럼 해석할 수 있어 기본값 식에서 오류 발생
- 조치: 이관 전/중에 `DEFAULT sysdate`를 `DEFAULT now()` 또는 `DEFAULT CURRENT_TIMESTAMP`로 치환

### `language "edbspl" does not exist` 오류
- 원인: 타깃 PostgreSQL에 EPAS SPL 언어가 없음
- 조치: 함수/프로시저를 PL/pgSQL로 재작성 후 배포

### `pg_stat_statements` view/function 충돌
- 원인: 확장 객체를 일반 스키마 객체처럼 재생성하려고 시도
- 조치: 타깃에서 extension(`CREATE EXTENSION pg_stat_statements`)만 관리하고 관련 view/function 생성은 제외

---

## 7) 권장 운영 방식

- 운영 DB에는 **읽기 전용 계정**으로 실행
- 비밀번호는 명령행 인자보다 `PGPASSWORD` 또는 `.pgpass` 사용
- 정기 실행 시 `90_count_summary.tsv`를 수집하여 변화 추적
