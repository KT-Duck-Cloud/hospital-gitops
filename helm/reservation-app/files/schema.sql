-- 병원 예약 시스템 표 정의 (MySQL 8.4, 스키마 1개 hospital). 기준 문서: docs/erd.md
--
-- 실행: app_migrate 계정으로 원본(병원) DB 에만 한 번 적용한다. 앱은 시작할 때 표를 만들지 않는다.
--   mysql -h <host> -u app_migrate -p < db/schema.sql
-- 빈 DB 용이다. 이미 표가 있으면 CREATE TABLE 이 오류로 멈춘다 (기존 표를 몰래 건너뛰지 않도록 IF NOT EXISTS 를 쓰지 않음).
-- 1단계의 옛 reservations 표가 있는 DB 는 db/migrate_001.sql 로 옮긴다.
--
-- 시간: 모든 시간 칸은 DATETIME(6), UTC. 기본값 CURRENT_TIMESTAMP 가 UTC 가 되도록
--       DB 서버의 time_zone 을 '+00:00' 으로 둔다 (앱 연결도 접속할 때 세션 time_zone 을 '+00:00' 으로 맞춘다).
-- 문자셋: utf8mb4. request_id 만 대소문자 구분을 위해 utf8mb4_bin.

SET NAMES utf8mb4;  -- 클라이언트 기본 문자셋(latin1 등)과 관계없이 한글이 깨지지 않도록
CREATE DATABASE IF NOT EXISTS hospital CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE hospital;

-- 진료과·부서 (주인: 예약)
CREATE TABLE departments (
    id          INT          NOT NULL AUTO_INCREMENT,
    code        VARCHAR(20)  NOT NULL,                 -- 예: IM(내과), OS(정형외과), ADM(원무과)
    name        VARCHAR(50)  NOT NULL,
    created_at  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_departments_code (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 환자 (주인: 예약)
CREATE TABLE patients (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    chart_no    VARCHAR(20)  NOT NULL,                 -- 차트 번호
    name        VARCHAR(50)  NOT NULL,
    birth_date  DATE         NOT NULL,
    phone       VARCHAR(20)  NULL,                     -- 개인정보 (보안 담당과 마스킹·암호화 협의)
    created_at  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at  DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_patients_chart_no (chart_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 계정 (주인: 인증)
CREATE TABLE users (
    id                  BIGINT        NOT NULL AUTO_INCREMENT,
    login_id            VARCHAR(50)   NOT NULL,
    password_hash       VARCHAR(255)  NOT NULL,        -- bcrypt 해시 (원문 저장 금지)
    name                VARCHAR(50)   NOT NULL,
    role                ENUM('PATIENT', 'NURSE', 'DOCTOR', 'MANAGER', 'ADMIN',
                             'DEPT_HEAD', 'DIRECTOR', 'DEVELOPER', 'TESTER') NOT NULL,
    department_id       INT           NULL,            -- 직원만
    patient_id          BIGINT        NULL,            -- 환자 계정만
    is_active           BOOLEAN       NOT NULL DEFAULT TRUE,
    failed_login_count  INT           NOT NULL DEFAULT 0,   -- 15분 안 실패 횟수 (5회면 잠금)
    first_failed_at     DATETIME(6)   NULL,            -- 실패 횟수 세기 시작 시각
    locked_until        DATETIME(6)   NULL,            -- 잠금 해제 시각
    last_login_at       DATETIME(6)   NULL,
    created_at          DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at          DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_users_login_id (login_id),
    UNIQUE KEY uq_users_patient_id (patient_id),       -- 환자 1명에 계정 최대 1개 (ERD patients ||--o| users)
    CONSTRAINT fk_users_department FOREIGN KEY (department_id) REFERENCES departments (id),
    CONSTRAINT fk_users_patient    FOREIGN KEY (patient_id)    REFERENCES patients (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 로그인 세션 (주인: 인증, 보안 DEV3)
CREATE TABLE sessions (
    id                   VARCHAR(64)  NOT NULL,         -- JWT jti
    user_id              BIGINT       NOT NULL,
    last_seen_at         DATETIME(6)  NOT NULL,         -- 요청마다 갱신 (1분에 한 번만 UPDATE)
    idle_expires_at      DATETIME(6)  NOT NULL,         -- 일반 30분 / 관리 화면 15분
    absolute_expires_at  DATETIME(6)  NOT NULL,         -- 일반 8시간 / 관리 화면 4시간
    revoked_at           DATETIME(6)  NULL,             -- 로그아웃·비활성화·역할 변경 시 기록
    created_at           DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at           DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 의사 (주인: 예약)
CREATE TABLE doctors (
    id             INT          NOT NULL AUTO_INCREMENT,
    department_id  INT          NOT NULL,
    user_id        BIGINT       NULL,                   -- 의사 로그인 계정
    name           VARCHAR(50)  NOT NULL,
    room_no        VARCHAR(20)  NULL,                   -- 진료실
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at     DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_doctors_user_id (user_id),            -- 계정 1개에 의사 최대 1명 (ERD users ||--o| doctors)
    CONSTRAINT fk_doctors_department FOREIGN KEY (department_id) REFERENCES departments (id),
    CONSTRAINT fk_doctors_user       FOREIGN KEY (user_id)       REFERENCES users (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 예약 (주인: 예약) ★DR 검증 대상
CREATE TABLE reservations (
    id              BIGINT        NOT NULL AUTO_INCREMENT,
    -- X-Request-ID. "ABC"와 "abc"를 다른 값으로 취급하도록 utf8mb4_bin. 같은 값이면 1건만 저장
    request_id      VARCHAR(64)   CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    patient_id      BIGINT        NOT NULL,
    department_id   INT           NOT NULL,
    doctor_id       INT           NULL,
    queue_no        INT           NULL,                 -- 접수 시 부서별·날짜별 대기번호
    reserved_at     DATETIME(6)   NOT NULL,             -- 진료 예약 시각 (UTC)
    visit_type      ENUM('FIRST', 'RETURN')                 NOT NULL,                     -- 초진 / 재진
    status          ENUM('BOOKED', 'CANCELED')              NOT NULL DEFAULT 'BOOKED',    -- 취소해도 행은 남김
    checkin_status  ENUM('NOT_CHECKED_IN', 'CHECKED_IN')    NOT NULL DEFAULT 'NOT_CHECKED_IN',
    checked_in_at   DATETIME(6)   NULL,
    memo            VARCHAR(500)  NULL,
    created_by      BIGINT        NULL,                 -- 예약을 만든 계정
    canceled_at     DATETIME(6)   NULL,
    created_at      DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at      DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_reservations_request_id (request_id),
    KEY idx_reservations_department_reserved (department_id, reserved_at),
    KEY idx_reservations_patient_reserved    (patient_id, reserved_at),
    KEY idx_reservations_doctor_reserved     (doctor_id, reserved_at),
    CONSTRAINT fk_reservations_patient    FOREIGN KEY (patient_id)    REFERENCES patients (id),
    CONSTRAINT fk_reservations_department FOREIGN KEY (department_id) REFERENCES departments (id),
    CONSTRAINT fk_reservations_doctor     FOREIGN KEY (doctor_id)     REFERENCES doctors (id),
    CONSTRAINT fk_reservations_created_by FOREIGN KEY (created_by)    REFERENCES users (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 진료기록 (주인: 예약). 암호화·복호화는 shared/crypto.py 한 곳에서만 한다.
CREATE TABLE medical_records (
    id               BIGINT         NOT NULL AUTO_INCREMENT,
    patient_id       BIGINT         NOT NULL,
    reservation_id   BIGINT         NULL,
    doctor_id        INT            NOT NULL,
    diagnosis_enc    BLOB           NOT NULL,           -- AES-256-GCM 암호문 + 인증 태그
    note_enc         BLOB           NOT NULL,           -- AES-256-GCM 암호문 + 인증 태그
    diagnosis_nonce  VARBINARY(12)  NOT NULL,           -- 매번 새로 생성 (재사용 금지)
    note_nonce       VARBINARY(12)  NOT NULL,           -- 매번 새로 생성 (재사용 금지)
    key_version      INT            NOT NULL,           -- 키 교체 대비
    created_at       DATETIME(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at       DATETIME(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_medical_records_reservation_id (reservation_id),   -- 예약 1건에 기록 최대 1건 (ERD ||--o|)
    CONSTRAINT fk_medical_records_patient     FOREIGN KEY (patient_id)     REFERENCES patients (id),
    CONSTRAINT fk_medical_records_reservation FOREIGN KEY (reservation_id) REFERENCES reservations (id),
    CONSTRAINT fk_medical_records_doctor      FOREIGN KEY (doctor_id)      REFERENCES doctors (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 영수증 (주인: 예약)
CREATE TABLE receipts (
    id              BIGINT       NOT NULL AUTO_INCREMENT,
    patient_id      BIGINT       NOT NULL,
    reservation_id  BIGINT       NULL,
    amount          INT          NOT NULL,              -- 원 단위
    pay_status      ENUM('PAID', 'UNPAID', 'REFUNDED') NOT NULL DEFAULT 'UNPAID',
    paid_at         DATETIME(6)  NULL,
    created_at      DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at      DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_receipts_reservation_id (reservation_id),          -- 예약 1건에 영수증 최대 1건 (ERD ||--o|)
    CONSTRAINT fk_receipts_patient     FOREIGN KEY (patient_id)     REFERENCES patients (id),
    CONSTRAINT fk_receipts_reservation FOREIGN KEY (reservation_id) REFERENCES reservations (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 감사 로그 (주인: 인증, 모든 서비스 INSERT)
CREATE TABLE audit_logs (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    user_id      BIGINT       NULL,                     -- 로그인 실패는 NULL
    service      VARCHAR(20)  NOT NULL,                 -- auth / reservation / stats
    action       VARCHAR(50)  NOT NULL,                 -- 예: LOGIN, RESERVATION_CREATE, RECORD_VIEW
    target_type  VARCHAR(30)  NULL,
    target_id    VARCHAR(64)  NULL,
    request_id   VARCHAR(64)  NULL,
    client_ip    VARCHAR(45)  NULL,
    result       ENUM('SUCCESS', 'DENIED', 'FAIL') NOT NULL,
    created_at   DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at   DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    CONSTRAINT fk_audit_logs_user FOREIGN KEY (user_id) REFERENCES users (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
