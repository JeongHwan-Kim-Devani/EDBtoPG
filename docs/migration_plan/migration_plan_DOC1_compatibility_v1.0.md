# [DOC-1] 호환성 분석 보고서 (Compatibility Analysis Report)

> **DB명**: SAMPLE_DB  
> **점검 일시**: 2026-04-02  
> **분석 기준**: `epas_precheck_v3.0.sh` 결과 데이터 (`.result_sample`)

---

## 1. 종합 현황 요약 (Summary Scorecard)

이관 전 주요 지표에 대한 호환성 점검 결과 요약입니다.

| 항목 | 전체 건수 | 🔴 HIGH | 🟡 MEDIUM | 🟢 LOW |
| :--- | :---: | :---: | :---: | :---: |
| **파라미터** | 7 | 0 | 7 | 0 |
| **패밀리/패키지/객체** | 29 | 15 | 10 | 4 |
| **데이터타입 (테이블/컬럼)** | 8 | 0 | 8 | 0 |
| **표현식 (DEFAULT/INDEX)** | 12 | 5 | 7 | 0 |
| **보안 정책 (RLS/Redaction)** | 4 | 4 | 0 | 0 |
| **DBLink** | 3 | 1 | 2 | 0 |

> [!IMPORTANT]  
> **Redaction 정책** 및 **DBLink(Oracle 연동)** 항목에서 PostgreSQL 네이티브 기능으로 대체 불가능한 요소가 발견되었습니다. 해당 항목에 대한 별도의 아키텍처 설계가 필요합니다.

---

## 2. 주요 섹션별 세부 분석

### 2.1 EDB 전용 파라미터 분석 (`01_parameters.tsv`)
**위험도**: 🟡 MEDIUM
- **현황**: `db_dialect=redwood`, `edb_redwood_strings=on`, `edb_redwood_date=on` 등 오라클 호환 모드가 활성화되어 있습니다.
- **분석**: PostgreSQL 전환 시 기본 문자열 처리(NULL vs Empty) 및 날짜 타입 동작 방식의 차이로 인해 애플리케이션 로직 수정이 필요할 수 있습니다.
- **권장**: 단계적 `db_dialect=postgres` 전환 테스트를 권장합니다.

### 2.2 호환 불가 패키지 사용 현황 (`02_summary_packages.tsv`)
**위험도**: 🔴 HIGH
- **주요 발견**: `dbms_crypto`, `utl_raw`, `dbms_output` 등이 사용 중입니다.
- **분석**:
    - `dbms_crypto`: PostgreSQL의 `pgcrypto` 확장 모듈로 마이그레이션이 필요합니다.
    - `utl_raw`: `bytea` 타입 처리 함수로 변환이 필요합니다.
- **대상 객체**: `fn_decrypt`, `fn_encrypt`, `proc_generate_crypto_data` 등

### 2.3 비호환 데이터타입 (`03_detail_datatypes_tables.tsv`)
**위험도**: 🟡 MEDIUM
- **현황**: `bfile`, `clob` 타입을 사용하는 테이블 8개가 식별되었습니다.
- **분석**: PostgreSQL에서는 `bfile`을 지원하지 않으므로 파일 경로 문자열로 저장하고 앱에서 처리하거나, `clob`은 `text` 타입으로 변환해야 합니다.
- **대상**: `tb_employee_info`, `tb_datatype_test` 등

### 2.4 데이터 Redaction 정책 (`02_summary_redaction.tsv`)
**위험도**: 🔴 HIGH
- **현황**: `mask_phone_policy` 등 4개의 Redaction 정책이 `public` 및 `sc_redact` 스키마에 존재합니다.
- **분석**: PostgreSQL은 네이티브 Data Redaction 기능을 제공하지 않습니다. `VIEW` 또는 `App 레벨`에서 마스킹 처리를 수행하도록 재설계가 필수적입니다.

### 2.5 DBLink 현황 (`04_policy_edb_dblink.tsv`)
**위험도**: 🔴 HIGH
- **발견**: `oralink` (Oracle 연동), `pg16_link` (PostgreSQL 연동)
- **분석**: `oracle_fdw` 및 `postgres_fdw` 설치 및 설정이 필요합니다. 특히 Oracle 연동은 Oracle Client 라이브러리 설치 등 추가 작업이 수반됩니다.

---

## 3. 결론 및 권장 조치
1. **패키지 변환**: 암호화 관련 함수(`dbms_crypto`)의 재작성 공수가 높을 것으로 예상되므로 조기에 변환 가이드 배포가 필요합니다.
2. **보안 재설계**: Redaction 정책을 사용하는 테이블(`tb_redaction_test`)에 대해 마스킹 전용 뷰 생성을 검토하십시오.
3. **데이터타입**: `bfile` 컬럼의 실데이터 존재 여부 및 외부 파일 관리 방식에 대한 실사가 필요합니다.
