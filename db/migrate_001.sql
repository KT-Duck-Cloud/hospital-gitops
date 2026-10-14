-- migrate_001: 1단계의 옛 reservations 표 → docs/erd.md 의 새 표 구조로 옮긴다.
--
-- 언제 쓰나: 1단계 db/schema.sql(옛 reservations 표 1개)로 이미 데이터가 들어간 DB 만. 새 DB 는 schema.sql 만 실행하면 된다.
--
-- 바뀌는 칸 (옛 → 새)
--   patient_id VARCHAR(32)        → patient_id BIGINT FK(patients.id)   옛 값마다 '이관' 환자 1명을 만들어 연결
--   appointment_time DATETIME(3)  → reserved_at DATETIME(6)
--   status BOOKED/CANCELED        → 그대로 (ENUM). 그 밖의 값이 있으면 INSERT 가 오류로 멈춘다
--   checkin_status WAITING        → NOT_CHECKED_IN,  CHECKED_IN → CHECKED_IN
--   (없음)                         → department_id: 'LEGACY'(미지정·이관) 부서, visit_type: FIRST(옛 데이터에 정보 없음)
--   (없음)                         → checked_in_at / canceled_at: 옛 updated_at 으로 채움 (정확한 시각은 옛 표에 없음)
--   id, request_id, created_at, updated_at → 그대로
--
-- 실행 계정: DB 관리자(root 등). RENAME·INSERT 가 필요해서 app_migrate(표 구조 권한만)로는 실행할 수 없다.
-- 실행 위치: 저장소 루트 (아래 SOURCE 가 db/schema.sql 을 상대 경로로 읽는다). 먼저 백업을 받는다.
--   mysqldump ... hospital reservations > backup_reservations_before_001.sql
--   mysql -h <host> -u <관리자> -p hospital < db/migrate_001.sql
-- 옛 표는 reservations_v0 로 이름만 바꿔 남겨 둔다. 확인이 끝나면 DB 담당이 직접 DROP 한다.

USE hospital;
SET NAMES utf8mb4;  -- 클라이언트 기본 문자셋(latin1 등)과 관계없이 한글이 깨지지 않도록

-- 0) 옛 모양인지 확인. appointment_time 칸이 없으면(이미 옮겼거나 새 DB) 여기서 오류로 멈춘다.
SELECT appointment_time, patient_id FROM reservations LIMIT 0;

-- 1) 옛 표를 비켜 두고 새 표 9개를 만든다.
RENAME TABLE reservations TO reservations_v0;
SOURCE db/schema.sql;

-- 2) 데이터 옮기기 (한 트랜잭션)
START TRANSACTION;

INSERT INTO departments (code, name) VALUES ('LEGACY', '미지정(이관)');

-- 옛 patient_id 값마다 이관 환자 1명. 차트번호 LEGACY-000001 …, 이름에 옛 값을 남겨 추적할 수 있게 한다.
-- 생년월일은 옛 데이터에 없어 1900-01-01 로 둔다 (원무과가 실제 환자와 맞춰 고친다).
INSERT INTO patients (chart_no, name, birth_date, phone, created_at, updated_at)
SELECT CONCAT('LEGACY-', LPAD(ROW_NUMBER() OVER (ORDER BY v.patient_id), 6, '0')),
       CONCAT('이관 ', v.patient_id),
       '1900-01-01',
       NULL,
       v.first_created_at,
       v.first_created_at
FROM (SELECT patient_id, MIN(created_at) AS first_created_at
      FROM reservations_v0
      GROUP BY patient_id) AS v;

INSERT INTO reservations
    (id, request_id, patient_id, department_id, doctor_id, queue_no, reserved_at, visit_type,
     status, checkin_status, checked_in_at, memo, created_by, canceled_at, created_at, updated_at)
SELECT o.id,
       o.request_id,
       p.id,
       d.id,
       NULL,
       NULL,
       o.appointment_time,
       'FIRST',
       o.status,
       CASE o.checkin_status WHEN 'CHECKED_IN' THEN 'CHECKED_IN' ELSE 'NOT_CHECKED_IN' END,
       CASE WHEN o.checkin_status = 'CHECKED_IN' THEN o.updated_at END,
       '[migrate_001] 1단계 데이터 이관',
       NULL,
       CASE WHEN o.status = 'CANCELED' THEN o.updated_at END,
       o.created_at,
       o.updated_at
FROM reservations_v0 AS o
JOIN patients AS p ON p.name = CONCAT('이관 ', o.patient_id) AND p.chart_no LIKE 'LEGACY-%'
JOIN departments AS d ON d.code = 'LEGACY'
ORDER BY o.id;

COMMIT;

-- 3) 확인: 두 숫자가 같아야 한다.
SELECT (SELECT COUNT(*) FROM reservations_v0) AS old_rows,
       (SELECT COUNT(*) FROM reservations)    AS new_rows;
