## EPAS 샘플 데이터 적재 가이드

`insert_sample_data.sql` + `load_sample_data.sh`로 `demo` 스키마에
**EPAS(Oracle 호환) 전용 샘플 객체/데이터**를 한 번에 적재합니다.

---

### 1) 파일 구성
- `insert_sample_data.sql`  
  EPAS 전용 객체 생성 + 샘플 데이터 적재 SQL
- `load_sample_data.sh`  
  환경변수를 받아 `psql`로 SQL 실행

### 2) 사전 준비
- EPAS 접속 가능 상태
- `psql` 클라이언트 설치
- 실행 계정에 `demo` 스키마/오브젝트 생성 권한

### 3) 빠른 실행
```bash
chmod +x load_sample_data.sh

export EPAS_HOST=127.0.0.1
export EPAS_PORT=5444
export EPAS_DB=edb
export EPAS_USER=enterprisedb
export EPAS_PASSWORD='your_password'

./load_sample_data.sh
```

### 4) 생성/적재되는 주요 내용

#### EPAS 전용 객체/문법 예시
- `PROFILE`, `SYNONYM`, `PACKAGE`
- `PROCEDURE`, `FUNCTION` (`LANGUAGE edbspl`)
- `DBMS_CRYPTO` 기반 암호화 예시
- `DBMS_RLS` 정책(Policy/VPD) 예시
- Oracle 호환 문법/타입: `dual`, `sysdate`, `CLOB`, `BLOB`, `VARCHAR2`, `NVARCHAR2`

#### 타입 샘플
- `demo.type_samples`에 10개 이상 타입 + 10건 샘플 데이터
- 포함 타입: `VARCHAR2`, `CHAR`, `NUMBER`, `INTEGER`, `DATE`, `TIMESTAMP`, `CLOB`, `BLOB`, `NVARCHAR2`, `INTERVAL`

#### 대용량 데이터(분산 적재)
- 총 약 **500MB+** 규모를 여러 테이블에 분산
  - `demo.customer_docs` (CLOB 중심)
  - `demo.large_text_chunks` (CLOB)
  - `demo.large_binary_chunks` (BLOB)

> 적재 SQL은 재실행 시 중복을 최소화하도록 idempotent 방식(`WHERE NOT EXISTS`, 누적 건수 보정)으로 구성되어 있습니다.

### 5) 검증 쿼리
```sql
-- 기본 확인
SELECT * FROM demo.customer_syn;
SELECT demo.fn_total_amount('minjun@example.com') FROM dual;
SELECT COUNT(*) FROM demo.type_samples;

-- 테이블별 물리 용량 확인
SELECT pg_size_pretty(pg_total_relation_size('demo.customer_docs'))       AS customer_docs_size;
SELECT pg_size_pretty(pg_total_relation_size('demo.large_text_chunks'))   AS large_text_chunks_size;
SELECT pg_size_pretty(pg_total_relation_size('demo.large_binary_chunks')) AS large_binary_chunks_size;

-- 논리 페이로드(행 데이터 길이) 확인
SELECT pg_size_pretty(SUM(OCTET_LENGTH(doc_text))::BIGINT)  AS customer_docs_payload FROM demo.customer_docs WHERE doc_name LIKE 'bulk_doc_%';
SELECT pg_size_pretty(SUM(OCTET_LENGTH(chunk_text))::BIGINT) AS large_text_payload   FROM demo.large_text_chunks WHERE chunk_name LIKE 'text_chunk_%';
SELECT pg_size_pretty(SUM(OCTET_LENGTH(chunk_bin))::BIGINT)  AS large_bin_payload    FROM demo.large_binary_chunks WHERE chunk_name LIKE 'bin_chunk_%';
```

### 6) 참고/주의사항
- 본 SQL은 **EPAS 전용 기능**을 포함하므로 일반 PostgreSQL에서는 동작하지 않습니다.
- EPAS 제약에 따라 `IDENTITY` 컬럼은 `BIGINT` 기반으로 정의했습니다.
- 일부 EPAS 환경에서 `MERGE` 구문 호환 이슈가 있어 데이터 적재는 `INSERT ... WHERE NOT EXISTS` 중심으로 작성했습니다.
- `UTL_I18N` 패키지가 없는 환경을 고려해 암호화 예시는 `HEXTORAW` 기반으로 구현했습니다.

- 물리 용량과 논리 페이로드가 비슷하게 보이도록, 주요 대용량 컬럼은 `SET STORAGE EXTERNAL`로 설정했습니다.
