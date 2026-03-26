# 이슈 #23 디자인 프로토타입

- 파일: `issue-23-user-created-visual-prototype.html`
- 목적: USER_CREATED 객체 시각화(전체/키워드/영향도/경로/예외 상태) 디자인 시안

## 열기

```powershell
start design/issue-23-user-created-visual-prototype.html
```

## 상세 항목 분류

- 객체 유형 선택 칩
  - `PACKAGE`, `FUNCTION`, `PROCEDURE`, `VIEW`, `TABLE`
- 상세 분류 칩
  - `1) 전체 그래프`, `2) 키워드 상위 10개`, `3) 영향도 퍼센트`, `4) 이미지 경로`, `5) 예외 상태`
- 시각화 영역
  - 1) 전체 그래프: 객체 유형별 건수
  - 2) 키워드 상위 10개(선택 유형 기준)
  - 3) 영향도 퍼센트 도넛
  - 4) 리포트 임베드용 이미지 경로 프리뷰
  - 5) USER_CREATED 객체 없음 예외 상태

## 이슈 #23 연동 상태

- 프로토타입 베이스라인이 런타임 리포트 생성 흐름에 연결됨
- 런타임 스크립트 파일: `../EPAS_PRECHECK/epas_precheck_v2.0.sh`
- SQL 파일: `../EPAS_PRECHECK/epas_precheck_v2.0.sql`
- 진행 로그 및 인코딩 안전 텍스트 출력 보강

## 실행

```bash
bash EPAS_PRECHECK/epas_precheck_v2.0.sh -d <DBNAME> -U <USER> -o ./out
```
