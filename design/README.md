# USER_CREATED 디자인 시안 (v2.0)

- 기준 레퍼런스: `../reference/report_17_260326111240/ds1.html`
- 프로토타입: `epas_precheck_v2.0_prototype.html` (`ds1.html` 기준 동기화)

## 열기

```powershell
start design/epas_precheck_v2.0_prototype.html
```

## 포함 내용

- 객체 유형 선택 칩: `PACKAGE`, `FUNCTION`, `PROCEDURE`, `VIEW`, `TABLE`
- 1) 객체 유형별 건수
- 2) 키워드 상위 10개
- 3) 영향도 퍼센트
- 4) 리포트 임베드용 이미지 경로 미리보기
- 5) USER_CREATED 객체 없음 예외 상태
- Details 섹션(파라미터/호환성 객체/데이터타입/표현식/정책 등 전체 테이블)

## 연동 스크립트

- `../EPAS_PRECHECK/epas_precheck_v2.0.sh`
- `../EPAS_PRECHECK/epas_precheck_v2.0.sql`

## 실행

```bash
bash EPAS_PRECHECK/epas_precheck_v2.0.sh -d <DBNAME> -U <USER> -o ./out
```
