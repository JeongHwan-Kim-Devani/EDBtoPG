# Issue #23 Design Prototype

- File: `issue-23-user-created-visual-prototype.html`
- Purpose: USER_CREATED 객체 시각화(전체/키워드/영향도) 디자인 시안

## Open

```powershell
start design/issue-23-user-created-visual-prototype.html
```

## Included

- 객체 유형 선택 칩: `PACKAGE`, `FUNCTION`, `PROCEDURE`, `VIEW`, `TABLE`
- 전체 그래프 프로토타입(막대 전체=100% 전체 count, 주황 막대=n% 영향 count, 좌측 %/우측 개수 눈금)
- 검출 키워드 TOP 10 그래프 프로토타입
- 영향도 퍼센트 도넛 그래프 프로토타입
- 이미지 파일명 규칙 프리뷰
- `No USER_CREATED objects` 예외 상태 토글

## Issue #23 Integration Status

- Prototype baseline is now connected in runtime report generation.
- Runtime script file: `../EPAS_PRECHECK/epas_precheck_v2.0.sh`
- SQL file: `../EPAS_PRECHECK/epas_precheck_v2.0.sql`
- Added progress logs and encoding-safe text outputs.

## Execute

```bash
bash EPAS_PRECHECK/epas_precheck_v2.0.sh -d <DBNAME> -U <USER> -o ./out
```
