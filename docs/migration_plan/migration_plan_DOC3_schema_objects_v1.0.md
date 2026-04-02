# [DOC-3] 스키마 객체 이관 계획서 (Schema Object Migration Plan)

> **DB명**: SAMPLE_DB  
> **분석 기준**: `raw_tables_columns`, `03_detail_datatypes_tables`, `03_detail_expr_keywords`

---

## 1. 개요
EDB EPAS에서 운영 중인 테이블, 인덱스, 뷰, 제약조건 등 주요 스키마 객체를 PostgreSQL 네이티브 구문으로 변환하여 이관하기 위한 가이드라인 및 대상 목록을 정의합니다.

---

## 2. 데이터타입 변환 계획 (`03_detail_datatypes_tables.tsv`)

### 2.1 주요 변환 대상 테이블
PostgreSQL에서 지원하지 않는 구형 EDB 타입(`CLOB`, `BFILE`)을 사용하는 테이블입니다.

| 스키마 | 테이블명 | 영향 컬럼 | 현재 타입 | 변환 타입 | 비고 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `public` | `clob_test` | `id` (clob) | `CLOB` | `TEXT` | |
| `public` | `t11`, `t12` | `c1` (bfile), `c5` (clob) | `BFILE`/`CLOB` | `TEXT`/`VARCHAR` | 파일 경로는 앱 처리 권장 |
| `public` | `tb_datatype_test`| `test_bfile`, `test_clob` | `BFILE`/`CLOB` | `VARCHAR`/`TEXT` | |
| `public` | `tb_employee_info`| `external_cert`, `resume_doc`| `BFILE`/`CLOB` | `VARCHAR`/`TEXT` | |

### 2.2 공통 데이터타입 매핑 기준
| 구분 | EDB/Oracle 타입 | PostgreSQL 타입 | 변환 권고 |
| :--- | :--- | :--- | :--- |
| 문자열 | `VARCHAR2(n)` | `VARCHAR(n)` or `TEXT` | `n`이 큰 경우 `TEXT` 권장 |
| 날짜 | `DATE` | `TIMESTAMP` | `edb_redwood_date=on` 기준 |
| 대용량 | `CLOB` | `TEXT` | 자동 매핑 지원 |
| 바이너리| `RAW(n)` | `BYTEA` | 16진수 입력 방식 확인 |

---

## 3. 표현식 및 제약조건 변환 계획 (`03_detail_expr_keywords.tsv`)

### 3.1 DEFAULT 제약조건 변환
| 테이블명 | 대상 컬럼 | 현재 표현식 | 변환 후 표현식 |
| :--- | :--- | :--- | :--- |
| `a5`, `tb_ddl_migration_test`| `reg_date`, `created_at` | `SYSDATE` | `CURRENT_TIMESTAMP` |
| `epas_emp_contracts` | `contract_date` | `SYSTIMESTAMP` | `CURRENT_TIMESTAMP` |
| `user_secure_data` | `created_at` | `SYSDATE` | `CURRENT_TIMESTAMP` |

### 3.2 CHECK 제약조건 변환
| 테이블명 | 제약조건명 | 비호환 구문 | 조치 방안 |
| :--- | :--- | :--- | :--- |
| `tb_ddl_migration_test`| `chk_emp_id_valid` | `NVL(col, val)` | `COALESCE(col, val)`로 재작성 |
| `tb_ddl_migration_test`| `chk_emp_status` | `DECODE(...)` | `CASE WHEN...END`로 재작성 |

---

## 4. 인덱스 및 기타 객체 변환 계획

### 4.1 함수 기반 인덱스 (Expression Index)
- **대상**: `tb_ddl_migration_test`의 `idx_created_at_add_months`
- **현재**: `ADD_MONTHS(created_at, 12)`
- **변환**: `(created_at + INTERVAL '12 months')`

### 4.2 시노님(Synonym) 대체 방안
분석 결과 식별된 시노님들은 다음 중 하나의 방안으로 대체합니다.
1. **Schema Search Path**: `SET search_path TO ...`를 통해 앱 레벨에서 탐색 경로 지정
2. **VIEW 생성**: 타 스키마 객체를 참조하는 동일 명칭의 VIEW 생성
3. **직접 매핑**: SQL 쿼리 내에서 `schema.object` 형식으로 Full-qualified name 변경

---

## 5. 이관 시 주의사항
- **대소문자 처리**: EDB Redwood 모드에서는 따옴표 없는 대문자 객체명이 소문자로 인식될 수 있으나, PostgreSQL은 소문자가 기본입니다. 이관 스크립트 작성 시 주의가 필요합니다.
- **Index 중복**: PG 네이티브 이관 툴 사용 시 PK 인덱스와 수동 생성 인덱스가 중복 생성되지 않도록 필터링이 필요합니다.
