# EDBtoPG: EPAS to PostgreSQL Migration Precheck Tool

<p align="center">
  <img src="./assets/images/main_illustration.png" alt="Main Illustration" width="400">
</p>

## 개요
**EDBtoPG**는 EPAS(EnterpriseDB Advanced Server) 환경에서 PostgreSQL로 이관하기 전에 Oracle/EDB 특화 요소를 자동으로 점검하는 도구입니다. 이 도구는 마이그레이션 중 발생할 수 있는 잠재적인 호환성 이슈를 사전에 탐지하여 분석용 TSV와 리뷰용 HTML 보고서를 생성합니다.

## 주요 기능
- **파라미터 점검**: 핵심 파라미터 및 기본값 대비 변경된 설정 확인
- **Oracle/EDB 특화 기능 탐지**: `ROWNUM`, `ROWID`, `DUAL`, `MINUS`, `CONNECT BY` 등 호환되지 않는 키워드 추출
- **데이터 타입 및 객체 점검**: `CLOB`, `BFILE`, `RAW` 등 오라클 전용 타입 사용 현황 파악
- **고급 객체 점검**: Synonym, RLS(Row Level Security), Profile, Resource Group, DB Link 등 점검
- **시각화 보고서**: 객체별 원문 코드 하이라이트 및 이관 난이도(불가, 높음, 낮음) 자동 판정 배지 제공

## 요구 사항
- **OS**: Ubuntu 20.04+, Rocky Linux 8.x, RHEL 6+ (Bash 호환)
- **Database**: `psql` 클라이언트 설치 필요
- **Python (선택)**: `python3` 설치 시 더 높은 품질의 코드 하이라이팅 지원

## 사용 방법
### 기본 실행 (`-o` 옵션 필수)
```bash
# EPAS_PRECHECK 디렉터리 내부의 스크립트를 실행합니다.
bash EPAS_PRECHECK/generate_epas_migration_report.sh -d <DBNAME> -U <USER> -o ./out
```

### 압축 옵션 사용 (tar/gz)
```bash
# 점검 결과물을 즉시 압축 파일로 생성할 수 있습니다.
bash EPAS_PRECHECK/generate_epas_migration_report.sh -d <DBNAME> -U <USER> -o ./out -c gz
```

## 옵션 가이드
| 옵션 | 설명 | 비고 |
| --- | --- | --- |
| `-d, --dbname` | 점검할 DB 이름 | 필수 |
| `-U, --user` | DB 접속 사용자 | 필수 |
| `-o, --output` | 결과물 저장 디렉터리 | 필수 |
| `-W, --password` | DB 접속 비밀번호 | 환경변수(PGPASSWORD) 권장 |
| `-h, --host` | DB 호스트 주소 | 기본값: localhost |
| `-p, --port` | DB 포트 번호 | 기본값: 5444 |

## 출력물 안내
결과물 디렉터리 내에 다음과 같은 파일이 생성됩니다.
- `<DBNAME>.html`: 요약 및 상세 분석 결과 대시보드
- `<DBNAME>_source.html`: 객체별 소스 코드 인덱스 페이지
- `*.tsv`: 상세 데이터 분석을 위한 탭 구분 파일들

---
*본 도구는 데이터베이스 현대화 및 오픈소스 전환 가이드를 위해 제작되었습니다.*

## Issue #23 Updated Runtime (Prototype Integrated)

- New script: `EPAS_PRECHECK/epas_precheck_v2.0.sh`
- New SQL: `EPAS_PRECHECK/epas_precheck_v2.0.sql`
- Purpose: Prototype-based USER_CREATED visualization + progress logging + encoding-safe output strings.

### Run

```bash
bash EPAS_PRECHECK/epas_precheck_v2.0.sh -d <DBNAME> -U <USER> -o ./out
```

### Notes

- The new script defaults to the new SQL file automatically.
- Keep old file names for legacy runs, and use new names for Issue #23 integrated output.
