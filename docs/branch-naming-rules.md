# 브랜치 네이밍 규칙

## 목적
작업 목적이 한눈에 보이도록 브랜치 이름을 통일한다.

## 기본 규칙
형식:

<type>/<short-description>

예시:
- feature/home-weather-card
- feature/settings-ad-remove
- fix/location-permission-crash
- docs/project-bootstrap
- chore/github-template-setup

## type 규칙
- feature: 신규 기능 개발
- fix: 버그 수정
- docs: 문서 작업
- chore: 설정, 의존성, CI/CD, 빌드 환경 등
- refactor: 기능 변경 없는 구조 개선
- test: 테스트 코드 추가/수정
- hotfix: 운영 이슈 긴급 수정

## 작성 규칙
- 전부 소문자 사용
- 공백 대신 하이픈(-) 사용
- 너무 길지 않게 작성
- 하나의 브랜치에는 하나의 목적만 담기
- 이슈 번호를 같이 쓰고 싶다면 앞에 붙이기

예시:
- feature/12-home-ui
- fix/27-null-location-state
- chore/31-github-actions-setup

## 권장 브랜치 전략
- main: 항상 배포 가능한 안정 상태 유지
- 작업은 main에서 분기
- 작업 완료 후 Pull Request 생성
- merge 방식은 squash merge 권장

## 작업 흐름
1. main 최신화
2. 새 브랜치 생성
3. 작업 및 로컬 테스트
4. push
5. PR 생성
6. 리뷰/체크 후 main에 merge

## 명령어 예시
```bash
git checkout main
git pull origin main
git checkout -b feature/settings-ad-remove