-- DB 계정 3개 (보안 설정표 기준). 기준 문서: docs/erd.md "원칙"
--
--   app_runtime  : auth·reservation 이 함께 쓴다. hospital 데이터 작업(SELECT/INSERT/UPDATE/DELETE)만.
--                  GRANT OPTION·CREATE·ALTER·DROP 없음.
--   app_readonly : stats 와 검증 도구. SELECT 만.
--   app_migrate  : db/schema.sql 실행용 (표 생성·변경). 앱은 이 계정을 쓰지 않는다.
--
-- 비밀번호는 자리표시자(__APP_..._PASSWORD__)다. 실제 값을 이 파일에 쓰지 않는다.
--   - 로컬 docker compose: db/init/02-grants.sh 가 .env 의 값으로 바꿔 실행한다.
--   - 운영: DB 담당이 비밀 저장소의 값으로 바꿔 관리자 계정으로 실행한다 (바꾼 파일은 저장하지 않는다).
-- 호스트 '%' 는 로컬 개발용이다. 운영에서는 앱 노드 대역으로 좁힌다 (예: 'app_runtime'@'10.0.%').
-- 모든 계정은 TLS 연결만 허용한다 (REQUIRE SSL).

SET NAMES utf8mb4;

CREATE USER IF NOT EXISTS 'app_runtime'@'%'
    IDENTIFIED BY '__APP_RUNTIME_PASSWORD__'
    REQUIRE SSL;
GRANT SELECT, INSERT, UPDATE, DELETE ON hospital.* TO 'app_runtime'@'%';

CREATE USER IF NOT EXISTS 'app_readonly'@'%'
    IDENTIFIED BY '__APP_READONLY_PASSWORD__'
    REQUIRE SSL;
GRANT SELECT ON hospital.* TO 'app_readonly'@'%';

CREATE USER IF NOT EXISTS 'app_migrate'@'%'
    IDENTIFIED BY '__APP_MIGRATE_PASSWORD__'
    REQUIRE SSL;
GRANT CREATE, ALTER, DROP, INDEX, REFERENCES ON hospital.* TO 'app_migrate'@'%';
