# [DOC-4] 데이터 이관 계획서 (Data Migration Plan)

> **DB명**: SAMPLE_DB  
> **분석 기준**: `raw_tables_objects`, `pg_stat_user_tables` (추정치)

---

## 1. 개요
EDB EPAS 서버의 실데이터를 PostgreSQL 운영 환경으로 적기에, 데이터 유실 없이 이관하기 위한 전략 및 검증 방안을 수립합니다.

---

## 2. 이관 대상 및 예상 데이터 볼륨

전체 약 50여 개의 테이블 중 주요 대용량 대상 및 특수 타입 포함 테이블 현황입니다.

| 스키마 | 테이블명 | 예상 건수(T) | 예상 용량 | 특이사항 |
| :--- | :--- | :---: | :---: | :--- |
| `public` | `t_bulk_data` | 1,000,000 | 500 MB | 테스트용 벌크 데이터 |
| `public` | `pgbench_accounts`| 100,000 | 15 MB | pgbench 표준 테이블 |
| `public` | `tb_employee_info`| 5,000 | 2 GB | `CLOB`, `BFILE` 포함 (LOB 데이터) |
| `sc_crypto`| `user_secure_data`| 10,000 | 50 MB | `BYTEA` 암호화 데이터 |
| `public` | 기타 소형 테이블 | < 1,000 | < 1 MB | `emp`, `dept`, `a1~a5` 등 |

---

## 3. 이관 방법론 및 도구 선정

본 프로젝트의 환경(타입 변환 및 LOB 데이터 포함)을 고려하여 다음과 같은 도구를 혼합 사용합니다.

### 3.1 도구 선정
- **pgloader**: `VARCHAR2` → `VARCHAR`, `CLOB` → `TEXT` 등 자동 타입 변환 및 벌크 인서트 속도 확보를 위해 주 도구로 사용합니다.
- **pg_dump / pg_restore**: 순수 PostgreSQL 호환 객체 및 구조 이관 시 보조적으로 사용합니다.
- **Python Custom Script**: `BFILE` 타입의 외부 파일 경로 정규화 및 데이터 마이그레이션이 필요한 경우 사용합니다.

---

## 4. 이관 절차 (Migration Workflow)

1. **사전 준비 (Pre-migration)**
    - 대상 DB 파라미터 최적화 (`max_wal_size`, `maintenance_work_mem` 증설)
    - 타겟 스키마 생성 및 사용자 권한 할당 (DOC-2 참조)
2. **스키마 생성 (Schema-only)**
    - 제약조건(FK) 및 트리거를 제외한 테이블 구조 생성 (DOC-3 참조)
3. **데이터 이관 (Data-only Load)**
    - `pgloader`를 활용한 병렬 데이터 로딩 수행
    - LOB 데이터(CLOB)가 포함된 `tb_employee_info` 등은 별도 세션으로 실행
4. **후속 처리 (Post-migration)**
    - 인덱스 생성, 제약조건(FK) 활성화, 트리거 생성
    - `ANALYZE` 수행을 통한 통계 정보 갱신
    - 시퀀스(Sequence) 현재값 동기화

---

## 5. 데이터 정합성 검증 방안

| 검증 단계 | 방법 | 성공 판정 기준 |
| :--- | :--- | :--- |
| **건수 검증** | `SELECT COUNT(*)` 비교 | 원천/대상 DB 건수 일치 (0 건 차이) |
| **값 검증** | `MIN/MAX/SUM` 비교 | 주요 숫자형 컬럼(salary 등) 합계 일치 |
| **샘플 검증** | 상위/하위 100건 데이터 비교 | 주요 텍스트/바이너리 값 육안/해시 비교 일치 |
| **LOB 검증** | `LENGTH(text_col)` 확인 | CLOB → TEXT 변환 후 글자 수 일치 여부 |

---

## 6. 장애 대응 및 롤백 계획
- **이관 실패 시**: 타겟 DB 스키마 `DROP` 후 재수행
- **정합성 오류 시**: 오류 테이블 데이터 `TRUNCATE` 후 해당 테이블만 재이관 (`pgloader` 특정 테이블 모드)
- **시간 초과 시**: 인덱스 생성 병렬화(`max_parallel_maintenance_workers`) 수치 상향 조정
