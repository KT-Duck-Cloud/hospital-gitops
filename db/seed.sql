-- 로컬 개발·테스트용 가상 데이터. 실제 환자 정보가 아니다. 운영(병원) DB 에서는 실행하지 않는다.
-- db/schema.sql 로 만든 빈 표에 한 번만 넣는다 (다시 실행하면 UNIQUE 오류로 멈춘다).
--
--   진료과 4개, 의사 8명, 환자 30명, 예약 100건(오늘 기준 -7일 ~ +7일, 일부 취소·접수), 영수증 30건
--   진료기록(medical_records)은 8단계에서 암호화해서 넣는다. 계정(users)은 scripts/seed_users.py 가 만든다.
-- 시각은 모두 UTC 로 넣는다. 진료 시간 KST 09:00~16:30 = UTC 00:00~07:30.

USE hospital;
SET NAMES utf8mb4;  -- 클라이언트 기본 문자셋(latin1 등)과 관계없이 한글이 깨지지 않도록

INSERT INTO departments (code, name) VALUES
    ('IM',  '내과'),
    ('OS',  '정형외과'),
    ('PD',  '소아과'),
    ('ADM', '원무과');

-- 의사 8명: 내과 3, 정형외과 3, 소아과 2 (원무과는 진료과가 아니라 의사 없음). user_id 는 seed_users.py 에서 연결
INSERT INTO doctors (department_id, name, room_no, is_active)
SELECT d.id, x.name, x.room_no, x.is_active
FROM (
              SELECT 'IM' AS code, '김내과' AS name, '101' AS room_no, TRUE AS is_active
    UNION ALL SELECT 'IM', '이내과', '102', TRUE
    UNION ALL SELECT 'IM', '박내과', '103', TRUE
    UNION ALL SELECT 'OS', '최정형', '201', TRUE
    UNION ALL SELECT 'OS', '정정형', '202', TRUE
    UNION ALL SELECT 'OS', '강정형', '203', TRUE
    UNION ALL SELECT 'PD', '조소아', '301', TRUE
    UNION ALL SELECT 'PD', '윤소아', '302', TRUE
) AS x
JOIN departments AS d ON d.code = x.code;

-- 환자 30명. 전화번호는 실제로 쓰이지 않는 010-0000-xxxx 형식
INSERT INTO patients (chart_no, name, birth_date, phone) VALUES
    ('C2026-0001', '김가상', '1985-03-12', '010-0000-0001'),
    ('C2026-0002', '이가상', '1990-07-25', '010-0000-0002'),
    ('C2026-0003', '박가상', '1978-11-02', '010-0000-0003'),
    ('C2026-0004', '최가상', '2015-05-30', '010-0000-0004'),
    ('C2026-0005', '정가상', '1962-01-18', '010-0000-0005'),
    ('C2026-0006', '강가상', '2001-09-09', '010-0000-0006'),
    ('C2026-0007', '조가상', '1995-12-24', '010-0000-0007'),
    ('C2026-0008', '윤가상', '2019-02-14', '010-0000-0008'),
    ('C2026-0009', '장가상', '1970-06-06', '010-0000-0009'),
    ('C2026-0010', '임가상', '1988-08-15', '010-0000-0010'),
    ('C2026-0011', '한가상', '1955-04-04', '010-0000-0011'),
    ('C2026-0012', '오가상', '2012-10-01', '010-0000-0012'),
    ('C2026-0013', '서가상', '1999-03-03', '010-0000-0013'),
    ('C2026-0014', '신가상', '1983-07-07', '010-0000-0014'),
    ('C2026-0015', '권가상', '1967-09-21', '010-0000-0015'),
    ('C2026-0016', '황가상', '2018-12-12', '010-0000-0016'),
    ('C2026-0017', '안가상', '1992-02-28', '010-0000-0017'),
    ('C2026-0018', '송가상', '1975-05-05', '010-0000-0018'),
    ('C2026-0019', '류가상', '2008-11-11', '010-0000-0019'),
    ('C2026-0020', '전가상', '1960-10-10', '010-0000-0020'),
    ('C2026-0021', '홍가상', '1987-01-01', '010-0000-0021'),
    ('C2026-0022', '고가상', '2016-06-16', '010-0000-0022'),
    ('C2026-0023', '문가상', '1993-04-19', '010-0000-0023'),
    ('C2026-0024', '양가상', '1972-08-08', '010-0000-0024'),
    ('C2026-0025', '손가상', '2004-03-27', '010-0000-0025'),
    ('C2026-0026', '배가상', '1958-12-31', '010-0000-0026'),
    ('C2026-0027', '백가상', '1981-09-17', '010-0000-0027'),
    ('C2026-0028', '허가상', '2020-07-04', '010-0000-0028'),
    ('C2026-0029', '남가상', '1997-11-23', '010-0000-0029'),
    ('C2026-0030', '노가상', '1969-02-02', '010-0000-0030');

-- 예약 100건 (n = 1..100)
--   날짜: 오늘(UTC) 기준 (n % 15) - 7 일 → -7 ~ +7 일
--   시각: 30분 단위 16칸 중 하나 (UTC 00:00 ~ 07:30)
--   의사: 8명을 차례로, 진료과는 그 의사의 진료과. 환자: 30명 중 (n*7 % 30) 번째
--   취소: n 이 10의 배수 (10건)
--   접수: 지난 날짜 예약 중 취소가 아니고 n 이 4의 배수가 아닌 것 (33건). 대기번호는 진료과·KST 날짜별 1번부터
INSERT INTO reservations
    (request_id, patient_id, department_id, doctor_id, queue_no, reserved_at, visit_type,
     status, checkin_status, checked_in_at, memo, created_by, canceled_at, created_at, updated_at)
WITH RECURSIVE seq (n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 100
),
doc AS (
    SELECT id, department_id, ROW_NUMBER() OVER (ORDER BY id) AS rn FROM doctors
),
pat AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn FROM patients
),
base AS (
    SELECT s.n,
           doc.id            AS doctor_id,
           doc.department_id AS department_id,
           pat.id            AS patient_id,
           TIMESTAMP(UTC_DATE()) + INTERVAL ((s.n % 15) - 7) DAY
                                 + INTERVAL (((s.n * 7) % 16) * 30) MINUTE AS reserved_at,
           (s.n % 10 = 0)                                            AS is_canceled,
           (s.n % 10 <> 0 AND (s.n % 15) - 7 < 0 AND s.n % 4 <> 0)  AS is_checked_in
    FROM seq AS s
    JOIN doc ON doc.rn = ((s.n - 1) % 8) + 1
    JOIN pat ON pat.rn = ((s.n * 7) % 30) + 1
),
timed AS (
    SELECT b.*,
           LEAST(b.reserved_at - INTERVAL 3 DAY, UTC_TIMESTAMP(6) - INTERVAL (b.n % 48) HOUR) AS created_at
    FROM base AS b
)
SELECT CONCAT('seed-', LPAD(t.n, 4, '0')),
       t.patient_id,
       t.department_id,
       t.doctor_id,
       CASE WHEN t.is_checked_in THEN
           ROW_NUMBER() OVER (PARTITION BY t.department_id, DATE(t.reserved_at + INTERVAL 9 HOUR), t.is_checked_in
                              ORDER BY t.reserved_at, t.n)
       END,
       t.reserved_at,
       IF(t.n % 4 = 1, 'FIRST', 'RETURN'),
       IF(t.is_canceled, 'CANCELED', 'BOOKED'),
       IF(t.is_checked_in, 'CHECKED_IN', 'NOT_CHECKED_IN'),
       IF(t.is_checked_in, t.reserved_at - INTERVAL 10 MINUTE, NULL),
       ELT((t.n % 5) + 1, NULL, '기침·발열', '정기 검진', '통증 재진', NULL),
       NULL,
       IF(t.is_canceled, t.created_at + INTERVAL 1 HOUR, NULL),
       t.created_at,
       CASE
           WHEN t.is_canceled   THEN t.created_at + INTERVAL 1 HOUR
           WHEN t.is_checked_in THEN t.reserved_at - INTERVAL 10 MINUTE
           ELSE t.created_at
       END
FROM timed AS t
ORDER BY t.n;

-- 영수증 30건: 접수된 예약 앞에서부터 30건. 대부분 PAID, 일부 UNPAID·REFUNDED
INSERT INTO receipts (patient_id, reservation_id, amount, pay_status, paid_at, created_at, updated_at)
SELECT r.patient_id,
       r.id,
       5000 + (r.rn * 1700) % 30000,
       CASE WHEN r.rn % 10 = 0 THEN 'REFUNDED' WHEN r.rn % 7 = 0 THEN 'UNPAID' ELSE 'PAID' END,
       CASE WHEN r.rn % 7 = 0 AND r.rn % 10 <> 0 THEN NULL ELSE r.checked_in_at + INTERVAL 40 MINUTE END,
       r.checked_in_at + INTERVAL 40 MINUTE,
       r.checked_in_at + INTERVAL 40 MINUTE
FROM (
    SELECT id, patient_id, checked_in_at, ROW_NUMBER() OVER (ORDER BY id) AS rn
    FROM reservations
    WHERE checkin_status = 'CHECKED_IN'
    ORDER BY id
    LIMIT 30
) AS r;
