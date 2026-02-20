# EPAS Precheck

`epas_precheck.sh`는 **EPAS(EDB Postgres Advanced Server) → PostgreSQL 마이그레이션 사전진단**을 위한 Bash 스크립트입니다.

데이터베이스에 접속해서 확장/객체/루틴/권한/타입 핫스팟/시퀀스 등의 기본 인벤토리를 수집하고,
요약 리포트(`summary.md`), 머신 파싱용 카운트(`count_summary.tsv`),
그리고 가독성 중심의 마이그레이션 가이드(`migration_guide_report.md`)를 생성합니다.

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
./epas_precheck.sh -h localhost -p 5444 -d mydb -U dsadmin -o ./precheck.out
```

비밀번호를 옵션으로 전달하지 않고 환경변수로 주는 것을 권장합니다.

```bash
export PGPASSWORD='your-password'
./epas_precheck.sh -h localhost -p 5444 -d mydb -U dsadmin -o ./precheck.out
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
./epas_precheck.sh -h 10.0.0.10 -p 5444 -d appdb -U dsadmin -o ./precheck.appdb
```

### 특정 스키마만 진단

```bash
./epas_precheck.sh -h 10.0.0.10 -p 5444 -d appdb -U dsadmin -s app -o ./precheck.app
```

### Oracle 호환 패턴 검사 포함

```bash
./epas_precheck.sh -h 10.0.0.10 -p 5444 -d appdb -U dsadmin --oracle-checks -o ./precheck.oracle
```

---

## 5) 결과물 설명

출력 디렉터리(`-o`) 아래에 주요 파일이 생성됩니다.

- `version.txt`: DB 버전
- `instance_settings.tsv`: 인코딩/Collation/Timezone
- `extensions.tsv`: 확장 목록
- `objects.tsv`: 스키마 객체 목록
- `object_kind_counts.tsv`: 객체 kind별 집계
- `routines.tsv`: 함수/프로시저 목록
- `routine_kind_counts.tsv`: 루틴 kind별 집계
- `table_grants.tsv`: 테이블 권한 목록
- `type_hotspots.tsv`: 마이그레이션 민감 타입 컬럼 목록
- `sequences.tsv`: 시퀀스 목록
- `edb_extension_hits.txt`: `edb%` 확장 히트
- `edb_function_name_hits.txt`: `edb%` 함수명 히트
- `epas_feature_hits.tsv`: EPAS/Oracle 특화 패턴 히트 (예: `SYS_CONTEXT`, `AUTHID`, `NVL`, `SYSDATE`, `DBMS_RLS`, `CLOB` 등)
- `oracle_keyword_hits.tsv`: Oracle 키워드 히트 (`--oracle-checks` 사용 시)
- `count_summary.tsv`: `metric<TAB>count` 집계
- `summary.md`: 사람 읽기용 요약
- `migration_guide_report.md`: 호환성/대체기능/수동수정 필요 여부 + 덤프 기반 추가 체크리스트를 정리한 가이드 리포트

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

---

## 7) 권장 운영 방식

- 운영 DB에는 **읽기 전용 계정**으로 실행
- 비밀번호는 명령행 인자보다 `PGPASSWORD` 또는 `.pgpass` 사용
- 정기 실행 시 `count_summary.tsv`를 수집하여 변화 추적
