# EDB EPAS → PostgreSQL 이관 계획서 — 문서 구조 설계 초안

> **문서 버전**: v0.1-DRAFT  
> **작성 기준**: `epas_precheck_v3.0.sh` 수집 항목 및 출력 섹션 기반  
> **목적**: 이관 계획서 전체 문서 체계의 구조·형식·역할 정의  
> **상태**: 이해관계자 검토 전 초안

---

## 0. 문서 전체 구성 개요

```
이관 계획서 문서 셋
├── [DOC-1] 호환성 분석 보고서       ← precheck 스크립트 결과 해석
├── [DOC-2] DB·유저·권한 이관 계획서
├── [DOC-3] 스키마 객체 이관 계획서  ← 테이블/컬럼/인덱스/뷰/시퀀스
├── [DOC-4] 데이터 이관 계획서
└── [DOC-5] 프로그램 객체 튜닝 계획서  ← 우리 영역 아님 (DBA/개발팀 협의)
```

[DOC-1]의 분석 결과가 [DOC-2]~[DOC-5]의 **우선순위·범위 결정**의 입력값이 된다.

---

## DOC-1: 호환성 분석 보고서

> 근거: `sec_1_1_parameters`, `sec_2_1_*`, `sec_2_2_*`, `sec_2_3_*`, `sec_2_4_synonyms`, `sec_3_1~3_4`, `sec_4_1_dblink`

### 1.2 섹션 구성

| 섹션 | 제목 | 근거 TSV | 위험도 |
|------|------|----------|--------|
| 1.1 | EDB 전용 파라미터 분석 | `01_parameters.tsv` | HIGH/MEDIUM/LOW |
| 1.2 | 호환 불가 패키지 사용 현황 | `02_summary_packages.tsv` | HIGH/MEDIUM/LOW |
| 1.3 | EDB/Oracle 전용 키워드 사용 | `03_detail_keywords.tsv` | HIGH/MEDIUM/LOW |
| 1.4 | 비호환 데이터타입 (CLOB/BFILE/RAW) | `03_detail_datatypes_*.tsv` | MEDIUM |
| 1.5 | 표현식 내 비호환 키워드 | `03_detail_expr_keywords.tsv` | HIGH/MEDIUM |
| 1.6 | 시노님(Synonym) 현황 | `02_summary_synonyms.tsv` | MEDIUM |
| 1.7 | RLS 정책 현황 | `02_summary_policies.tsv` | MEDIUM |
| 1.8 | 데이터 Redaction 정책 | `02_summary_redaction.tsv` | HIGH |
| 1.9 | EDB 프로파일 현황 | `04_policy_edb_profile.tsv` | MEDIUM |
| 1.10 | 리소스 그룹 현황 | `04_policy_edb_resource_group.tsv` | MEDIUM |
| 1.11 | DBLink 현황 | `04_policy_edb_dblink.tsv` | HIGH |

### 1.3 요약 스코어카드 (문서 최상단 배치)

```
┌─────────────────────┬────────┬────────┬────────┬──────┐
│  항목                │ 전체   │ HIGH   │ MEDIUM │ LOW  │
├─────────────────────┼────────┼────────┼────────┼──────┤
│  파라미터            │        │        │        │      │
│  패키지/함수/프로시저 │        │        │        │      │
│  테이블/컬럼         │        │        │        │      │
│  뷰                 │        │        │        │      │
│  표현식              │        │        │        │      │
│  보안 정책           │        │        │        │      │
│  DBLink             │        │        │        │      │
└─────────────────────┴────────┴────────┴────────┴──────┘
```

### 1.4 위험도 정의표

| 위험도 | 판단 기준 | 예시 항목 |
|--------|-----------|-----------|
| 🔴 HIGH | PostgreSQL에서 동작 불가 또는 기능 자체 없음 | `edb_audit`, `edb_stmt_level_tx`, `ROWID`, `ROWNUM`, `DBLink`, `Redaction` |
| 🟡 MEDIUM | 동작하나 결과 차이 발생 가능 | `NVL`, `DECODE`, `SYSDATE`, `DBMS_*`, `edb_redwood_strings` |
| 🟢 LOW | 마이그레이션 후 재검토 권장 수준 | `timed_statistics`, `edb_dynatune` |

### 1.5 세부 항목 공통 작성 형식

```
#### [섹션 번호] [항목명]
**개요**: (1~2문장)

**현황 분석 결과**:
| 스키마 | 객체명 | 감지 키워드 | 위험도 | 조치 내용 |

**검토 의견**: (결과 해석 및 조치 방향)
**권장 PostgreSQL 대안**: (대체 방법/확장)
```

---

## DOC-2: DB · 유저 · 권한 이관 계획서

> 근거: `sec_3_3_profiles`, `sec_3_4_resource_groups`, `pg_roles`

### 2.2 섹션 구성

| 섹션 | 제목 | 주요 내용 |
|------|------|----------|
| 2.1 | 이관 대상 DB 현황 | DB 목록, Encoding, Locale, Tablespace |
| 2.2 | 스키마 목록 및 소유자 | 이관 대상 스키마 (시스템 스키마 제외) |
| 2.3 | 사용자(Role) 이관 계획 | pg_roles 기반 사용자 목록, 패스워드 처리 |
| 2.4 | 권한 이관 계획 | GRANT/REVOKE DDL 재생성 |
| 2.5 | EDB 프로파일 → PG 대안 매핑 | `passwordcheck` 확장, 운영 정책 |
| 2.6 | 리소스 그룹 → PG 대안 매핑 | connection pooling 정책 |
| 2.7 | 감사(Audit) 정책 이관 | `edb_audit` → `pgAudit` 매핑 |

### 2.3 EDB 프로파일 → PG 대안 매핑 예시

| EDB Profile 항목 | EDB 값 | PG 대안 |
|-----------------|--------|---------|
| FAILED_LOGIN_ATTEMPTS | 5 | `auth_delay` 확장 또는 App 레벨 |
| PASSWORD_LIFE_TIME | 90일 | `pg_password_check` 또는 운영 정책 |
| PASSWORD_LOCK_TIME | 1일 | 운영 스크립트 처리 |

---

## DOC-3: 스키마 객체 이관 계획서 (테이블 · 컬럼 · 인덱스 · 뷰 · 시퀀스)

> 근거: `raw_tables_columns`, `raw_tables_objects`, `sec_2_2_datatypes_tables`, `sec_2_3_expr_keywords`, `sec_3_1_policies_pg`

### 3.2 섹션 구성

| 섹션 | 제목 | 주요 내용 |
|------|------|----------|
| 3.1 | 이관 대상 스키마/테이블 목록 | 전체 카운트, 스키마별 분류 |
| 3.2 | 비호환 데이터타입 변환 계획 | CLOB→TEXT, BFILE→외부처리, RAW→BYTEA |
| 3.3 | DEFAULT 값 표현식 변환 | SYSDATE→CURRENT_TIMESTAMP, NVL→COALESCE |
| 3.4 | CHECK 제약조건 변환 | 비호환 함수 포함 CHECK절 재작성 |
| 3.5 | 인덱스 변환 계획 | 함수기반 인덱스(ROWID, DECODE) 재작성 |
| 3.6 | 파티션 테이블 이관 | EPAS 파티션 → PG 네이티브 파티션 DDL |
| 3.7 | 시퀀스 이관 계획 | SEQUENCE DDL, CACHE, START VALUE |
| 3.8 | 뷰 이관 계획 | ROWNUM, MINUS, DUAL 포함 뷰 재작성 |
| 3.9 | 시노님 이관 계획 | 스키마 검색경로 또는 뷰로 대체 |
| 3.10 | RLS 정책 이관 계획 | EDB DBMS_RLS → PG Row Security Policy |

### 3.3 데이터타입 매핑 기준표

| EPAS/Oracle 타입 | PostgreSQL 대응 타입 | 비고 |
|-----------------|---------------------|------|
| `CLOB` | `TEXT` | 크기 제한 없음 |
| `NCLOB` | `TEXT` | 유니코드 동일 |
| `BFILE` | 외부 파일시스템 처리 | DB 외부 처리 권장 |
| `RAW(n)` | `BYTEA` | 헥스 표현 방식 차이 주의 |
| `DATE` (Oracle) | `TIMESTAMP` | `edb_redwood_date` 설정 확인 필수 |
| `NUMBER(p,s)` | `NUMERIC(p,s)` | 정밀도 동일 |
| `VARCHAR2(n)` | `VARCHAR(n)` | 최대 길이 재확인 |

---

## DOC-4: 데이터 이관 계획서

### 4.2 섹션 구성

| 섹션 | 제목 | 주요 내용 |
|------|------|----------|
| 4.1 | 이관 범위 및 데이터 볼륨 | 테이블별 건수/용량 현황 |
| 4.2 | 이관 방법론 선택 | Dump/Restore vs ETL vs CDC 비교 |
| 4.3 | 이관 도구 및 환경 구성 | `pg_dump`, `pgloader`, Debezium |
| 4.4 | 이관 순서 (의존성 고려) | FK 관계 기반 이관 순서 |
| 4.5 | CLOB/BFILE 데이터 처리 | 특수 타입 컬럼 별도 이관 절차 |
| 4.6 | 이관 전 사전 작업 | 제약조건 비활성화, FK DEFER 처리 |
| 4.7 | 이관 후 검증 계획 | 건수 비교, 샘플 검증, 체크섬 비교 |
| 4.8 | Cutover 계획 | 서비스 중단 시나리오, 롤백 플랜 |
| 4.9 | 이관 리허설 계획 | Dry-run 일정 및 체크리스트 |

### 4.3 이관 방법론 비교표

| 구분 | Dump/Restore | pgloader | CDC (Debezium) |
|------|-------------|----------|----------------|
| 서비스 중단 | 필요 | 최소화 가능 | 거의 없음 |
| 비호환 변환 | 수동 | 룰 정의 가능 | 별도 처리 필요 |
| 복잡도 | 낮음 | 중간 | 높음 |
| **권장** | 소규모/단순 | 타입 변환 多 | 무중단 필요 시 |

### 4.4 데이터 검증 기준

```
이관 완료 후 아래 기준을 모두 충족해야 이관 성공으로 판정:
1. 건수 검증   : 원천 COUNT(*) = 대상 COUNT(*), 허용 오차 0%
2. 샘플 검증   : 테이블당 랜덤 1,000건 값 비교, 허용 오차 0%
3. NULL 검증   : NOT NULL 컬럼의 NULL 데이터 없음
4. FK 검증     : 참조 무결성 위배 0건
5. 시퀀스 검증  : LAST_VALUE >= 원천 MAX(PK)
```

---

## DOC-5: 프로그램 객체 튜닝 계획서 (Function · Procedure · Package)

> 근거: `sec_2_1_packages_summary`, `sec_2_1_keywords`, Source Navigator 결과  
> **⚠️ 우리 영역 아님. DBA/개발팀에 전달할 기준 문서 역할.**

### 5.2 섹션 구성

| 섹션 | 제목 | 주요 내용 |
|------|------|----------|
| 5.1 | 프로그램 객체 현황 | Function/Procedure/Pkg 수 및 영향도 분류 |
| 5.2 | EDB SPL → PL/pgSQL 변환 가이드 | 언어 차이점 (edbspl → plpgsql) |
| 5.3 | HIGH 위험 객체 목록 | ROWNUM, ROWID, PRAGMA, RAISE_APPLICATION_ERROR |
| 5.4 | MEDIUM 위험 객체 목록 | DBMS_*, NVL, DECODE, SYSDATE |
| 5.5 | 패키지 호환성 분석 | DBMS_CRYPTO, DBMS_OUTPUT 등 PG 대안 |
| 5.6 | 작업 우선순위 및 예상 공수 | 위험도 기반 처리 순서 |

### 5.3 EDB SPL → PL/pgSQL 주요 변환 기준표

| EDB SPL / Oracle | PL/pgSQL 대안 | 비고 |
|-----------------|--------------|------|
| `RAISE_APPLICATION_ERROR` | `RAISE EXCEPTION USING ERRCODE=...` | 코드 체계 재설계 |
| `PRAGMA EXCEPTION_INIT` | `DECLARE` 블록 내 예외 처리 재설계 | |
| `SQLCODE` / `SQLERRM` | `SQLSTATE` / `SQLERRM` | 코드체계 다름 |
| `SYSDATE` | `CURRENT_TIMESTAMP` or `NOW()` | |
| `NVL(a, b)` | `COALESCE(a, b)` | |
| `DECODE(x, v1, r1, ...)` | `CASE WHEN ... END` | |
| `ROWNUM` | `ROW_NUMBER() OVER()` or `LIMIT` | |
| `ROWID` | `ctid` (의미 다름, 재설계 권장) | |
| `DBMS_OUTPUT.PUT_LINE` | `RAISE NOTICE` | |
| `DBMS_CRYPTO` | `pgcrypto` 확장 | |
| `UTL_FILE` | 외부 처리 | |
| `CONNECT BY` | `WITH RECURSIVE` | |
| `MINUS` | `EXCEPT` | |
| edbspl | plpgsql로 언어 변경 필수 | |

---

## 부록 A: 문서 작성 가이드라인

### A.1 담당자 역할 정의

| 문서 | 작성 주체 | 검토 | 승인 |
|------|---------|------|------|
| DOC-1 호환성 분석 | DB마이그레이션팀 | 프로젝트 리더 | PM |
| DOC-2 DB/유저/권한 | DBA팀 | 보안팀 | PM |
| DOC-3 스키마 객체 | DB마이그레이션팀 | DBA팀 | PM |
| DOC-4 데이터 이관 | DB마이그레이션팀 | QA팀 | PM |
| DOC-5 프로그램 튜닝 | **개발팀/DBA팀** | DB마이그레이션팀 | PM |

> DOC-5는 개발팀/DBA팀 주체로, 우리 팀은 입력 데이터 및 기준 제공 역할만 수행

### A.2 문서 파일명 규칙

```
migration_plan_[DOC번호]_[영문약칭]_v[버전]_[YYYYMMDD].md
예시:
  migration_plan_DOC1_compatibility_v1.0_20260402.md
  migration_plan_DOC2_db_user_auth_v1.0_20260402.md
  migration_plan_DOC3_schema_objects_v1.0_20260402.md
  migration_plan_DOC4_data_migration_v1.0_20260402.md
  migration_plan_DOC5_plsql_tuning_v1.0_20260402.md
```

### A.3 precheck TSV ↔ 문서 섹션 매핑

| precheck 수집 항목 | 출력 TSV | 문서 섹션 |
|-------------------|----------|----------|
| EDB 전용 파라미터 | `01_parameters.tsv` | DOC-1 §1.1 |
| 패키지 호환성 | `02_summary_packages.tsv` | DOC-1 §1.2, DOC-5 §5.5 |
| 시노님 | `02_summary_synonyms.tsv` | DOC-1 §1.6, DOC-3 §3.9 |
| RLS 정책 | `02_summary_policies.tsv` | DOC-1 §1.7, DOC-3 §3.10 |
| Redaction 정책 | `02_summary_redaction.tsv` | DOC-1 §1.8 |
| EDB 키워드 | `03_detail_keywords.tsv` | DOC-1 §1.3, DOC-5 §5.3~5.4 |
| 비호환 데이터타입 | `03_detail_datatypes_*.tsv` | DOC-1 §1.4, DOC-3 §3.2 |
| 표현식 내 키워드 | `03_detail_expr_keywords.tsv` | DOC-1 §1.5, DOC-3 §3.3~3.5 |
| EDB 프로파일 | `04_policy_edb_profile.tsv` | DOC-1 §1.9, DOC-2 §2.5 |
| 리소스 그룹 | `04_policy_edb_resource_group.tsv` | DOC-1 §1.10, DOC-2 §2.6 |
| DBLink | `04_policy_edb_dblink.tsv` | DOC-1 §1.11 |
| 소스 코드 덤프 | `*_raw.tsv` | DOC-5 §5.3~5.4 |
| 테이블/컬럼 카탈로그 | `raw_tables_columns.tsv` | DOC-3 §3.1~3.2 |
| 테이블 전체 구조 | `raw_tables_objects.tsv` | DOC-3 §3.4~3.6 |

---

## 부록 B: 이관 전체 단계 구조 (예시)

```
Phase 0: 사전준비   ── precheck 실행 및 DOC-1 작성
Phase 1: 설계       ── DOC-2 ~ DOC-5 초안 작성 및 검토
Phase 2: 환경구성   ── 대상 PG 환경 구성, 계정/권한 이관
Phase 3: 스키마이관 ── DDL 변환 및 적용 (DOC-3 기반)
Phase 4: 데이터이관 ── 데이터 복제 및 검증 (DOC-4 기반)
Phase 5: 검증       ── 정합성 검증, 성능 테스트, UAT
Phase 6: Cutover    ── 실제 전환 및 롤백 플랜 실행
Phase 7: 안정화     ── 전환 후 모니터링 (2~4주)
```

*이 문서는 초안(DRAFT)이며, 실제 precheck 결과 분석 후 각 항목의 실행 계획으로 구체화 예정입니다.*
