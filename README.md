## EPAS 샘플 데이터 적재 가이드

테스트를 빠르게 진행할 수 있도록 `demo` 스키마에 **EPAS 전용(Oracle 호환)** 샘플 객체/데이터를 넣는 스크립트입니다.

### 파일 구성
- `insert_sample_data.sql`: EPAS 전용 객체 생성 + 샘플 데이터 삽입 SQL
- `load_sample_data.sh`: EPAS 접속 정보를 환경변수로 받아 SQL 실행

### 포함된 EPAS 전용 예시
- `PROFILE`, `SYNONYM`, `PACKAGE`
- `PROCEDURE`, `FUNCTION` (`LANGUAGE edbspl`)
- `DBMS_CRYPTO` 기반 컬럼 암호화 예시
- Oracle 호환 구문(`dual`, `sysdate`, `blob`, `clob`)
- `DBMS_RLS` 정책(Policy/VPD) 예시

### 실행 방법
```bash
chmod +x load_sample_data.sh

export EPAS_HOST=127.0.0.1
export EPAS_PORT=5444
export EPAS_DB=edb
export EPAS_USER=enterprisedb
export EPAS_PASSWORD='your_password'

./load_sample_data.sh
```

### 확인 쿼리
```sql
SELECT * FROM demo.customer_syn;
SELECT demo.fn_total_amount('minjun@example.com') FROM dual;
SELECT * FROM demo.customer_docs;
```

> 주의: 본 SQL은 EPAS 전용 기능을 포함하므로 일반 PostgreSQL에서는 동작하지 않습니다.
> 주의: IDENTITY 컬럼은 EPAS 제약에 맞춰 `BIGINT`로 정의했습니다 (`NUMBER IDENTITY`는 오류 발생).

> 주의: 일부 EPAS 환경에서는 `MERGE` 구문이 실패할 수 있어, 샘플 데이터 적재는 `INSERT ... WHERE NOT EXISTS` 방식으로 구성했습니다.
