## EPAS 샘플 데이터 적재 가이드

테스트를 빠르게 진행할 수 있도록 `demo` 스키마에 고객/주문 샘플 데이터를 넣는 스크립트를 추가했습니다.

### 파일 구성
- `insert_sample_data.sql`: 샘플 테이블 생성 + 데이터 삽입 SQL
- `load_sample_data.sh`: EPAS 접속 정보를 환경변수로 받아 SQL 실행

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
SELECT * FROM demo.customers;
SELECT * FROM demo.orders;
```

### 참고
- `ON CONFLICT`와 `NOT EXISTS`를 사용해서 스크립트를 여러 번 실행해도 중복 데이터가 생기지 않게 했습니다.
- 기본 포트는 `5444`로 설정되어 있으며, 필요 시 `EPAS_PORT`를 변경하세요.
