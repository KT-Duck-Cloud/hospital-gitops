-- migrate_002: 진료 진행 상태 · 대기번호 중복 방지 · 예약-진료기록/영수증 환자 일치 · 전화번호 칸 (docs/erd.md)
--
-- 언제 쓰나: db/schema.sql 의 이 변경 전 버전으로 이미 만든 DB 만. 새 DB 는 schema.sql 만 실행하면 된다.
-- 다시 실행해도 된다: 칸·키·외래키가 이미 있으면 그 단계만 건너뛴다 (일부만 적용된 DB 도 나머지만 채운다).
--
-- 바뀌는 것
--   reservations.checkin_status  ENUM 에 IN_TREATMENT(진료중), COMPLETED(진료완료) 추가 (기존 값은 그대로)
--   reservations.queue_date      DATE NULL 칸 추가. 이미 대기번호가 있는 예약은 KST 예약 날짜로 채운다
--   reservations                 UNIQUE(department_id, queue_date, queue_no), UNIQUE(id, patient_id) 추가
--   medical_records, receipts    reservation_id 단독 외래키 → (reservation_id, patient_id) 복합 외래키
--                                (예약의 환자와 다른 환자의 기록·영수증은 저장 거부)
--   (medical_records.reservation_id, receipts.reservation_id 의 UNIQUE 는 이미 있어 바꾸지 않는다)
--   departments.phone            VARCHAR(20) NULL 추가: 부서 대표 번호
--   users.work_phone             VARCHAR(20) NULL 추가: 직원 업무용 연락처 (환자 계정은 NULL)
--                                (기존 행은 NULL 로 남는다. 번호 공개 범위는 shared/phone.py)
--
-- 실행 계정: DB 관리자(root 등). 채우기(UPDATE)가 필요해서 app_migrate(표 구조 권한만)로는 실행할 수 없다.
-- 실행 위치: 저장소 루트. 먼저 백업을 받는다.
--   mysqldump ... hospital > backup_before_002.sql
--   mysql -h <host> -u <관리자> -p hospital < db/migrate_002.sql
--
-- 아래 확인 쿼리가 1건이라도 돌려주면 그 데이터를 먼저 고쳐야 한다 (안 고치면 UNIQUE·외래키 추가가 오류로 멈춘다).
--   -- 같은 진료과·같은 날 대기번호가 겹친 예약 (옛 동시 접수 경합으로 생길 수 있음)
--   SELECT department_id, DATE(reserved_at + INTERVAL 9 HOUR) AS queue_date, queue_no, COUNT(*)
--     FROM reservations WHERE queue_no IS NOT NULL GROUP BY 1, 2, 3 HAVING COUNT(*) > 1;
--   -- 예약의 환자와 환자가 다른 진료기록·영수증
--   SELECT m.id FROM medical_records m JOIN reservations r ON r.id = m.reservation_id WHERE r.patient_id <> m.patient_id;
--   SELECT c.id FROM receipts c JOIN reservations r ON r.id = c.reservation_id WHERE r.patient_id <> c.patient_id;

USE hospital;
SET NAMES utf8mb4;

-- 이 파일 안에서만 쓰는 도우미: p_do 가 참일 때만 p_sql 을 실행한다 (끝에서 지운다).
-- MySQL 8.4 의 ALTER TABLE 에는 ADD COLUMN IF NOT EXISTS 가 없어서, information_schema 로 확인한 결과를 넘긴다.
DROP PROCEDURE IF EXISTS migrate_002_step;
DELIMITER $$
CREATE PROCEDURE migrate_002_step(IN p_do BOOLEAN, IN p_sql TEXT)
BEGIN
    IF p_do THEN
        SET @migrate_002_sql = p_sql;
        PREPARE migrate_002_stmt FROM @migrate_002_sql;
        EXECUTE migrate_002_stmt;
        DEALLOCATE PREPARE migrate_002_stmt;
    END IF;
END$$
DELIMITER ;

-- 1) 칸 추가 · 상태 값 늘리기
SELECT COUNT(*) = 0 INTO @do FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reservations' AND COLUMN_NAME = 'checkin_status'
   AND COLUMN_TYPE LIKE '%''COMPLETED''%';
CALL migrate_002_step(@do, "ALTER TABLE reservations MODIFY COLUMN checkin_status
    ENUM('NOT_CHECKED_IN', 'CHECKED_IN', 'IN_TREATMENT', 'COMPLETED') NOT NULL DEFAULT 'NOT_CHECKED_IN'");

SELECT COUNT(*) = 0 INTO @do FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reservations' AND COLUMN_NAME = 'queue_date';
CALL migrate_002_step(@do, "ALTER TABLE reservations ADD COLUMN queue_date DATE NULL AFTER queue_no");

SELECT COUNT(*) = 0 INTO @do FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'departments' AND COLUMN_NAME = 'phone';
CALL migrate_002_step(@do, "ALTER TABLE departments ADD COLUMN phone VARCHAR(20) NULL AFTER name");

SELECT COUNT(*) = 0 INTO @do FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'work_phone';
CALL migrate_002_step(@do, "ALTER TABLE users ADD COLUMN work_phone VARCHAR(20) NULL AFTER name");

-- 2) 기존 대기번호의 날짜 채우기 (앱의 규칙과 같음: 예약 시각의 KST 날짜). 이미 채운 행은 건드리지 않는다.
UPDATE reservations SET queue_date = DATE(reserved_at + INTERVAL 9 HOUR)
 WHERE queue_no IS NOT NULL AND queue_date IS NULL;

-- 3) 예약 표: 대기번호 UNIQUE, (id, patient_id) UNIQUE
SELECT COUNT(*) = 0 INTO @do FROM information_schema.STATISTICS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reservations' AND INDEX_NAME = 'uq_reservations_queue';
CALL migrate_002_step(@do, "ALTER TABLE reservations
    ADD UNIQUE KEY uq_reservations_queue (department_id, queue_date, queue_no)");

SELECT COUNT(*) = 0 INTO @do FROM information_schema.STATISTICS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reservations' AND INDEX_NAME = 'uq_reservations_id_patient';
CALL migrate_002_step(@do, "ALTER TABLE reservations
    ADD UNIQUE KEY uq_reservations_id_patient (id, patient_id)");

-- 4) 진료기록 · 영수증: 예약과 환자가 함께 일치해야 저장
--    순서: 복합 키 추가 → 옛 외래키 삭제 → 새 복합 외래키 추가 (각 단계가 이미 끝났으면 건너뜀)
SELECT COUNT(*) = 0 INTO @do FROM information_schema.STATISTICS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'medical_records' AND INDEX_NAME = 'idx_medical_records_reservation_patient';
CALL migrate_002_step(@do, "ALTER TABLE medical_records
    ADD KEY idx_medical_records_reservation_patient (reservation_id, patient_id)");

SELECT COUNT(*) > 0 INTO @do FROM information_schema.TABLE_CONSTRAINTS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'medical_records'
   AND CONSTRAINT_NAME = 'fk_medical_records_reservation' AND CONSTRAINT_TYPE = 'FOREIGN KEY';
CALL migrate_002_step(@do, "ALTER TABLE medical_records DROP FOREIGN KEY fk_medical_records_reservation");

SELECT COUNT(*) = 0 INTO @do FROM information_schema.TABLE_CONSTRAINTS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'medical_records'
   AND CONSTRAINT_NAME = 'fk_medical_records_reservation_patient' AND CONSTRAINT_TYPE = 'FOREIGN KEY';
CALL migrate_002_step(@do, "ALTER TABLE medical_records
    ADD CONSTRAINT fk_medical_records_reservation_patient
        FOREIGN KEY (reservation_id, patient_id) REFERENCES reservations (id, patient_id)");

SELECT COUNT(*) = 0 INTO @do FROM information_schema.STATISTICS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'receipts' AND INDEX_NAME = 'idx_receipts_reservation_patient';
CALL migrate_002_step(@do, "ALTER TABLE receipts
    ADD KEY idx_receipts_reservation_patient (reservation_id, patient_id)");

SELECT COUNT(*) > 0 INTO @do FROM information_schema.TABLE_CONSTRAINTS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'receipts'
   AND CONSTRAINT_NAME = 'fk_receipts_reservation' AND CONSTRAINT_TYPE = 'FOREIGN KEY';
CALL migrate_002_step(@do, "ALTER TABLE receipts DROP FOREIGN KEY fk_receipts_reservation");

SELECT COUNT(*) = 0 INTO @do FROM information_schema.TABLE_CONSTRAINTS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'receipts'
   AND CONSTRAINT_NAME = 'fk_receipts_reservation_patient' AND CONSTRAINT_TYPE = 'FOREIGN KEY';
CALL migrate_002_step(@do, "ALTER TABLE receipts
    ADD CONSTRAINT fk_receipts_reservation_patient
        FOREIGN KEY (reservation_id, patient_id) REFERENCES reservations (id, patient_id)");

DROP PROCEDURE migrate_002_step;
