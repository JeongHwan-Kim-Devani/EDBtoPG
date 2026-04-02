# [DOC-5] 프로그램 객체 튜닝 계획서 (Program Object Tuning Plan)

> **DB명**: SAMPLE_DB  
> **분석 기준**: `02_summary_packages_raw`, `03_detail_keywords`

---

## 1. 개요
EDB EPAS 전용 PL/SQL 구문(edbspl) 및 오라클 호환 내장 패키지를 사용하는 Function, Procedure, Package를 PostgreSQL의 `plpgsql` 표준으로 변환하기 위한 기술 가이드 및 재작성 대상을 정의합니다.

---

## 2. 주요 재작성 대상 객체 목록

분석 결과 위험도가 높은(🔴 HIGH) 객체들로, 수동 변환 작업이 필수적입니다.

| 스키마 | 객체명 | 타입 | 주요 비호환 요소 | 조치 방향 |
| :--- | :--- | :---: | :--- | :--- |
| `public` | `calc_emp_bonus` | Proc | `DBMS_OUTPUT`, `VARCHAR2`, `edbspl` | `RAISE NOTICE` 변환, `plpgsql` 전환 |
| `public` | `fn_encrypt` | Func | `dbms_crypto.encrypt`, `utl_raw` | `pgcrypto` 확장 모듈 함수로 대체 |
| `public` | `fn_decrypt` | Func | `dbms_crypto.decrypt`, `utl_raw` | `pgcrypto` 확장 모듈 함수로 대체 |
| `sc_crypto`| `proc_generate_crypto_data`| Proc | `RANDOMBYTES`, `HASH`, `ENCRYPT` | `pgcrypto` 기반 로직으로 전면 재작성 |
| `public` | `fn_migration_test`| Func | `user_tables`, `nvl`, `decode` | `information_schema` 및 `CASE`문 변환 |

---

## 3. 변환 가이드라인 (edbspl → plpgsql)

### 3.1 구문 및 언어 선언
- **변경**: `LANGUAGE edbspl` → `LANGUAGE plpgsql`
- **구조**: `DECLARE` 섹션과 `BEGIN...END;` 블록을 명확히 구분합니다.

### 3.2 내장 패키지 대체 매핑
| EDB/Oracle 패키지 | PostgreSQL 대응 (plpgsql) |
| :--- | :--- |
| `DBMS_OUTPUT.PUT_LINE(msg)` | `RAISE NOTICE '%', msg;` |
| `DBMS_CRYPTO.ENCRYPT(...)` | `pgcrypto.encrypt(...)` 또는 `encrypt_iv(...)` |
| `UTL_RAW.CAST_TO_RAW(str)` | `str::bytea` (캐스팅) |
| `UTL_RAW.CAST_TO_VARCHAR2(raw)`| `encode(raw, 'escape')` 또는 `convert_from` |
| `SYS_CONTEXT('USERENV', ...)` | `current_setting(...)` 또는 `current_user` |

### 3.3 제어 구문 및 예외 처리
- **EXCEPTIONS**: `WHEN NO_DATA_FOUND` → `EXCEPTION WHEN no_data_found` (plpgsql 표준 예외 명칭 사용)
- **SQLERRM**: `SQLERRM` 변수는 동일하게 사용 가능하나, 상세 오류 조회를 위해 `GET STACKED DIAGNOSTICS` 사용 권장

---

## 4. 뷰(View) 및 표현식 튜닝 (`v_epas_contract_info`)

비호환 함수가 포함된 뷰 정의를 PostgreSQL 표준 쿼리로 튜닝합니다.

**[Before - EPAS]**
```sql
SELECT nvl(commission, 0), add_months(contract_date, 12), systimestamp ...
```

**[After - PostgreSQL]**
```sql
SELECT 
    COALESCE(commission, 0), 
    contract_date + INTERVAL '12 months', 
    CURRENT_TIMESTAMP ...
```

---

## 5. 단계별 이관 전략
1. **1단계 (단순 변환)**: `VARCHAR2` → `VARCHAR` 등 기본 타입 명칭 변경
2. **2단계 (함수 대체)**: `NVL`, `DECODE`, `SYSDATE` 등 표준 SQL 함수로 치환
3. **3단계 (패키지 로직 재작성)**: `dbms_crypto` 등 시스템 패키지 의존 로직을 PG 확장 모듈 기반으로 재구현
4. **4단계 (검증)**: 원천 DB와 동일한 입력값에 대해 동일한 결과값(Out Parameter/Return)이 나오는지 단위 테스트 수행

---

## 6. 주의사항
- **Transaction 제어**: Procedure 내의 `COMMIT/ROLLBACK`은 PostgreSQL 11 이상부터 지원되나, 원자성 보장을 위해 호출부에서의 제어를 권장합니다.
- **Security Definer**: `AUTHID DEFINER` 사용 객체는 PG에서도 `SECURITY DEFINER` 옵션을 명시해야 권한 문제가 발생하지 않습니다.
