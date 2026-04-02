# [DOC-2] DB · 유저 · 권한 이관 계획서 (DB, User, and Auth Migration Plan)

> **DB명**: SAMPLE_DB  
> **분석 기준**: `pg_roles`, `edb_profile`, `edb_resource_group` 기반 분석 결과

---

## 1. 개요
EDB EPAS에서 운영 중인 사용자 계정, 권한 체계, 보안 정책(Profile) 및 리소스 관리 정책을 PostgreSQL 환경으로 안전하게 이관하기 위한 절차를 정의합니다.

---

## 2. 사용자 및 데이터베이스 현황

### 2.1 이관 대상 데이터베이스
- **DB명**: `SAMPLE_DB`
- **Encoding**: `UTF-8`
- **Locale**: `C` (Recommended for performance or as per existing setting)

### 2.2 이관 대상 사용자 (Roles)
분석 결과 식별된 주요 사용자 목록 및 이관 전략입니다.

| 사용자명 | 권한 수준 | 이관 전략 | 비고 |
| :--- | :--- | :--- | :--- |
| `kim` | Normal | DDL 생성 시 포함 | `P2` 프로파일 적용 중 |
| `testuser` | Normal | DDL 생성 시 포함 | `P2` 프로파일 적용 중 |
| `t1` | Normal | DDL 생성 시 포함 | `PROF_MIG_01` 적용 중 |
| `dsg_user` | Normal | DDL 생성 시 포함 | `rg_test_50` 리소스 그룹 적용 중 |
| `enterprisedb` | Superuser | 제외 (PG 기본 superuser 사용) | 시스템 계정 |

---

## 3. 보안 정책(Profile) 이관 계획 (`04_policy_edb_profile.tsv`)

EDB 전용 프로파일 기능을 PostgreSQL의 운영 정책이나 확장 모듈로 매핑합니다.

| EDB Profile | 주요 설정 (평균치) | PostgreSQL 대응 방안 |
| :--- | :--- | :--- |
| `P2` | `FAILED_LOGIN_ATTEMPTS: 2`, `PASSWORD_LIFE_TIME: 1` | `auth_delay` 확장 사용 및 OS 스크립트로 잠계 처리 |
| `PROF_MIG_01` | `FAILED_LOGIN_ATTEMPTS: 3` | 운영 거버넌스 가이드에 따른 수동 제어 |
| `TEST_MIG_PROFILE` | `PASSWORD_LIFE_TIME: 90` | `pg_password_check` 확장 기능 검토 |

---

## 4. 리소스 관리 정책 이관 (`04_policy_edb_resource_group.tsv`)

| EDB Resource Group | 설정값 (CPU %) | PostgreSQL 대응 방안 |
| :--- | :--- | :--- |
| `rg_mig_10` | 100% | 기본 스케줄러 사용 (제한 불필요 시) |
| `rg_test_50` | 50% | `Linux Cgroups` 연계 또는 `pgrca` 확장 검토 |

---

## 5. 권한(Grant/Revoke) 이관 방안

### 5.1 스키마/테이블 권한
- `public`, `sc_crypto`, `sc_redact` 스키마에 대한 `USAGE`, `CREATE` 권한을 스크립트화하여 재적용합니다.
- 특정 테이블(`tb_datatype_test` 등)에 부여된 개별 권한을 전수 추출하여 이관합니다.

### 5.2 암호 처리 절차
1. PG 환경에서 사용자 Role 생성 (Nologin/NoPassword 상태)
2. 초기 임시 패스워드 설정 후 `ALTER ROLE` 수행
3. 사용자의 최초 접속 시 비밀번호 변경 강제화 정책(PG 16+ `ALTER ROLE ... PASSWORD '...' EXPIRE`) 적용 검토

---

## 6. 특이사항 및 주의사항
- **Superuser 권한**: EDB의 `enterprisedb` 계정만 가능한 작업들이 PG에서는 `postgres` 계정 또는 특정 사전정의 롤(`pg_monitor` 등)로 분산되어야 할 수 있습니다.
- **감사(Audit)**: `edb_audit`을 활용 중인 경우, `pgAudit` 확장 모듈 설치 및 로깅 레벨 설정을 DOC-2의 부속 작업으로 수행해야 합니다.
- **연결 제한**: 각 사용자별 `CONNECTION LIMIT`은 서비스 용량 산정 결과에 따라 재조정될 수 있습니다.
