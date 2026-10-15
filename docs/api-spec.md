# API 명세 — 병원 예약 시스템 (FastAPI 3개, DB 1개)

## 1. 서비스 구성

| 서비스 | 컨테이너 포트 | 맡는 주소 (인그레스 경로) |
|---|---|---|
| 인증 서비스 `auth` | 8000 | `/api/v1/auth/*`, `/api/v1/admin/*` |
| 예약 서비스 `reservation` | 8000 | `/api/v1/reservations*`, `/api/v1/queue`, `/api/v1/patients*`, `/api/v1/departments`, `/api/v1/doctors`, `/api/v1/doctor/*`, `/api/v1/me/*`, `/api/v1/slots`, `/api/v1/staff`, `/api/v1/contacts` |
| 현황 서비스 `stats` | 8000 | `/api/v1/stats/*`, `/api/v1/system/*` |

- DB는 MySQL 1대(`hospital` 스키마 1개). 표 주인은 `erd.md` 참고.
- 서비스끼리 서로 호출하지 않는다 (예외: 현황 서비스의 `/system/status`가 다른 서비스의 `/readyz`를 확인).
- 화면(React)은 별도. 환자 화면 `/`, 직원 화면 `/workspace`, 원무 화면 `/manage`.

## 2. 공통 규칙

### 인증
- 로그인하면 **JWT 출입증(access token)** 을 준다. 알고리즘 HS256. `iss`·`exp`·`jti`를 검사한다.
- 서버 세션 표 `sessions`로 만료를 관리한다 (보안 DEV3): 일반 유휴 30분/최대 8시간, ADMIN·DIRECTOR 유휴 15분/최대 4시간. 로그아웃·비활성화·역할 변경 시 세션을 끊어 이전 토큰은 401.
- 로그인 제한 (DEV2): 계정 기준 15분 안 5회 실패 → 15분 잠금, IP별 요청 제한 별도. 오류 문구는 항상 같다.
- 권한 표(`shared/permissions.py`)에 없는 API는 기본 403.
- 요청 헤더: `Authorization: Bearer <token>`
- 토큰 안의 정보: `sub`(user id), `role`, `department_id`, `patient_id`, `jti`
- 세 서비스가 같은 서명 키(`JWT_SECRET`, Secret으로 주입)로 **각자 검증**하고, 같은 DB의 `sessions`를 조회해 끊긴 세션인지 확인한다. 인증 서비스를 호출하지는 않는다.

### 역할 코드
`PATIENT`(환자), `NURSE`(간호사), `DOCTOR`(의사), `MANAGER`(원무과장), `ADMIN`(관리자), `DEPT_HEAD`(부서장), `DIRECTOR`(원장/마스터, 모든 권한), `DEVELOPER`(개발자), `TESTER`(테스터)

### 쓰기 차단 (READ_ONLY_MODE)
- 환경변수 `READ_ONLY_MODE=true`이면 세 서비스 모두 **쓰기 요청(POST·PATCH·DELETE)을 503**으로 거절한다.
  - 로그인(`POST /auth/login`)도 세션을 DB에 써야 해서 503으로 막는다. DR 대기 사이트에서는 로그인할 수 없고, 전환 후 다시 로그인한다.
- 응답: `503 {"code":"WRITE_DISABLED","message":"..."}`
- 사이트별 값: 병원 `false`, 국내 DR·AWS `true` (장애 전환 때 `false`로 바꿈). 세 서비스가 Helm 값 하나를 함께 쓴다.

### 중복 방지 (X-Request-ID)
- 예약 생성 `POST /reservations`는 헤더 `X-Request-ID`(UUID 권장, 최대 64자) **필수**.
- 같은 값이 다시 오면 새로 만들지 않고 기존 예약을 `200`으로 돌려준다. 처음이면 `201`.
- 그 값으로 이미 저장된 예약이 **요청한 사람의 범위 밖**(다른 환자·다른 부서)이면 `409 CONFLICT`. 남의 예약 내용은 돌려주지 않는다.

### 시간
- 저장·응답 모두 UTC, 응답은 `2026-10-13T01:30:00Z` 형식.
- 단, **날짜만 받는 값은 병원 기준 KST 날짜**로 해석한다. 하루 = KST 00:00 ~ 다음 날 00:00 (= UTC 전날 15:00 ~ 당일 15:00).
  - R2 목록의 `date_from`·`date_to`
  - R5 접수 대기번호(`queue_no`)의 "날짜별" (예약 시각의 KST 날짜. 그 날짜가 `queue_date` 로 저장된다)
- 저장되는 시각 값(`reserved_at`, `checked_in_at` 등)은 그대로 UTC 다.

### 입력 검사
- 요청 본문과 조회 조건은 **정해진 칸만** 받는다. 그 밖의 칸(`role`, `user_id`, `created_by` 등)이 있으면 무시하지 않고 `422`로 거절하며 아무것도 저장하지 않는다.
- 사용자 id·역할·소속은 요청 값이 아니라 토큰·세션 값만 쓴다. 헤더(`X-Role` 등)로 보내도 쓰지 않는다.
- `422` 응답에는 보낸 값(input)을 되돌려 주지 않는다.

### 오류 응답 형식
```json
{"code": "FORBIDDEN", "message": "권한이 없습니다", "request_id": "..."}
```

| 코드 | 상황 |
|---|---|
| 400 `BAD_REQUEST` | 필수 헤더 없음 등 |
| 401 `UNAUTHORIZED` | 토큰 없음·만료·위조 |
| 403 `FORBIDDEN` | 역할 권한 없음, 남의 데이터 접근 |
| 404 `NOT_FOUND` | |
| 409 `CONFLICT` | 취소된 예약 접수 등 상태 충돌, 범위 밖 사람이 이미 쓴 X-Request-ID, 같은 의사의 같은 시간 예약, 이미 있는 차트번호·아이디 |
| 422 | 입력값 형식 오류, 허용되지 않은 칸, 과거 시각 예약 (FastAPI 기본 모양 `{"detail": [...]}`, 보낸 값은 빼고 응답) |
| 503 `WRITE_DISABLED` | 쓰기 차단: `READ_ONLY_MODE=true`, 또는 DB 가 쓰기를 거부 (read_only·super_read_only, MySQL 1290·1836·1792) |
| 503 `DB_UNAVAILABLE` | DB 연결 불가·끊김·계정 잠김·접근 거부, **교착(1213)·잠금 대기 시간 초과(1205)** — 잠시 뒤 다시 시도 |
| 503 `RECORD_UNAVAILABLE` | 진료기록을 복호화할 수 없음 (키 없음·형식 오류, 인증 태그 불일치). 평문은 한 건도 돌려주지 않고 이유도 밝히지 않는다 |
| 500 `INTERNAL_ERROR` | 그 밖의 서버 오류 (내부 오류 문구·SQL 은 응답에 넣지 않음) |

### 운영 주소 (세 서비스 모두, 인증 없음)
| 주소 | 용도 |
|---|---|
| `GET /healthz` | 프로세스 살아 있음. DB 확인 안 함. liveness·startup probe용. 응답에 `service`, `version`(APP_VERSION) |
| `GET /readyz` | DB `SELECT 1`(1초 제한) 성공 시 200, 실패 시 503. readiness probe·모니터링 생존 확인·장애 판단용 (모니터링 담당과 합의한 주소) |
| `GET /metrics` | Prometheus 지표. NodePort 30800(예약)·30801(인증)·30802(현황)으로 노출 예정 |

## 3. API 목록과 우선순위

우선순위: **P1** = 10/13 단독 배포 테스트까지, **P2** = 10/16까지, **P3** = 시간이 되면 (안 되면 화면에 샘플 데이터)

### 인증 서비스 `auth`
| ID | 메서드·주소 | 설명 | 허용 역할 | 우선 |
|---|---|---|---|---|
| A1 | `POST /api/v1/auth/login` | 로그인, 토큰과 이동할 화면 경로 반환 | 모두 (인증 없음) | P1 |
| A2 | `GET /api/v1/auth/me` | 내 정보 | 로그인한 모두 | P1 |
| A7 | `POST /api/v1/auth/logout` | 로그아웃 (세션 끊기) | 로그인한 모두 | P1 |
| A3 | `GET /api/v1/admin/users` | 직원 계정 목록 (역할·부서 필터) | ADMIN, DIRECTOR, TESTER | P2 |
| A4 | `POST /api/v1/admin/users` | 계정 만들기 | ADMIN, DIRECTOR | P2 |
| A5 | `PATCH /api/v1/admin/users/{id}` | 역할·부서·활성 변경 | ADMIN, DIRECTOR | P2 |
| A6 | `GET /api/v1/admin/audit-logs` | 감사 로그 조회 (기간·사용자·행위 필터) | ADMIN, DIRECTOR | P2 |

### 예약 서비스 `reservation`
| ID | 메서드·주소 | 설명 | 허용 역할 | 우선 |
|---|---|---|---|---|
| R1 | `POST /api/v1/reservations` | 예약 만들기 (X-Request-ID 필수) | PATIENT(본인만), NURSE, DIRECTOR, TESTER | P1 |
| R2 | `GET /api/v1/reservations` | 예약 목록 (역할별 범위 자동 적용, 필터·페이지) | PATIENT(본인), NURSE·DEPT_HEAD(자기 부서), MANAGER·DIRECTOR·TESTER(전체) | P1 |
| R3 | `GET /api/v1/reservations/{id}` | 예약 상세 | R2와 같은 범위 | P1 |
| R4 | `DELETE /api/v1/reservations/{id}` | 예약 취소 (행 유지, status=CANCELED) | PATIENT(본인), NURSE(자기 부서), MANAGER·DIRECTOR·TESTER(전체) | P1 |
| R5 | `POST /api/v1/reservations/{id}/checkin` | 현장 접수 (취소된 예약은 409) | NURSE(자기 부서), MANAGER·DIRECTOR·TESTER(전체) | P1 |
| R6 | `GET /api/v1/departments` | 진료과 목록 (예약 화면 선택용, 대표 번호 `phone`은 역할별 공개 범위 적용) | 로그인한 모두 | P1 |
| R7 | `GET /api/v1/doctors?department_id=` | 의사 목록 | 로그인한 모두 | P1 |
| R8 | `GET /api/v1/queue?date=` | 오늘 대기열 (자기 부서, 접수 순. 진료대기·진료중·진료완료 상태 포함) | NURSE, DEPT_HEAD, DIRECTOR, TESTER | P2 |
| R9 | `GET /api/v1/patients?q=` | 환자 검색 (이름·차트번호) | NURSE, MANAGER, DIRECTOR, TESTER | P2 |
| R10 | `GET /api/v1/patients/{id}` | 환자 상세 + 최근 예약 | PATIENT(본인), NURSE, MANAGER, DIRECTOR, TESTER | P2 |
| R11 | `GET /api/v1/me/records` | 내 진료기록 | PATIENT | P3 |
| R12 | `GET /api/v1/me/receipts` | 내 영수증 | PATIENT | P3 |
| R13 | `GET /api/v1/slots?doctor_id=&date=` | 의사의 그날 30분 단위 예약 가능 시간 (추가) | 로그인한 모두 | P2 |
| R14 | `POST /api/v1/patients` | 환자 등록 (추가) | NURSE, ADMIN, DIRECTOR, TESTER | P2 |
| R15 | `POST /api/v1/reservations/{id}/start-treatment` | 진료 시작 (CHECKED_IN → IN_TREATMENT, 추가) | DOCTOR (그 예약의 담당 의사만) | P2 |
| R16 | `POST /api/v1/reservations/{id}/complete-treatment` | 진료 완료 (IN_TREATMENT → COMPLETED, 추가) | DOCTOR (그 예약의 담당 의사만) | P2 |
| R17 | `GET /api/v1/doctor/queue?date=` | 내 진료 대기열 (담당 접수 예약만, 의사 화면용, 추가) | DOCTOR | P2 |
| R18 | `GET /api/v1/staff` | 직원 업무용 연락처 (추가) | NURSE(자기 부서 직원), MANAGER(전체) | P2 |
| R19 | `GET /api/v1/contacts` | 연락처 화면: 병원 대표 번호 + 진료과 대표 번호 + 역할별 직원 연락처 (추가) | 로그인한 모두 (직원 목록 범위는 역할별) | P2 |

### 현황 서비스 `stats` (DB 조회 전용 계정)
| ID | 메서드·주소 | 설명 | 허용 역할 | 우선 |
|---|---|---|---|---|
| S1 | `GET /api/v1/system/status` | 세 서비스 `/readyz` 결과, 사이트 이름, READ_ONLY_MODE, 앱 버전 | DIRECTOR, DEVELOPER, TESTER | P1 |
| S2 | `GET /api/v1/stats/departments?date_from=&date_to=` | 부서별 예약·취소·접수 건수 | DEPT_HEAD(자기 부서), DIRECTOR | P2 |
| S3 | `GET /api/v1/stats/doctors?department_id=&date_from=&date_to=` | 의사별 실적 | DEPT_HEAD(자기 부서), DIRECTOR | P2 |
| S4 | `GET /api/v1/stats/hospital?date=` | 병원 전체 현황 (오늘 예약·접수·취소, 부서별 대기 수) | DIRECTOR | P3 |

합계: 업무 API 30개 (P1 11개, P2 16개, P3 3개) + 서비스별 운영 주소 4개. (R13 `/slots`, R14 `POST /patients` 는 7단계, R15~R17 은 진료 진행 상태와 함께, R18 은 전화번호 공개 범위와 함께, R19 는 연락처 화면과 함께 추가)

## 4. 주요 API 상세

### A1 로그인
`POST /api/v1/auth/login`
```json
요청 {"login_id": "nurse_im01", "password": "****"}
응답 200 {
  "access_token": "eyJ...", "token_type": "bearer", "expires_in": 28800,
  "user": {"id": 12, "name": "김간호", "role": "NURSE", "department_id": 1, "patient_id": null},
  "home_path": "/workspace"
}
```
- 실패 시 401 (아이디·비밀번호 중 무엇이 틀렸는지 알려 주지 않음). 실패·성공 모두 감사 로그.
- `expires_in`은 최대 시간(초)이다: 일반 28800(8시간), ADMIN·DIRECTOR 14400(4시간). 유휴 시간(30분/15분)이 지나면 그 전에도 401.
- `home_path`: PATIENT → `/`, DOCTOR·MANAGER·ADMIN·DIRECTOR → `/manage`, 나머지(NURSE·DEPT_HEAD·DEVELOPER·TESTER) → `/workspace`

### R1 예약 만들기
`POST /api/v1/reservations`  헤더 `X-Request-ID: 6f1c...`
```json
요청 {"patient_id": 3, "department_id": 1, "doctor_id": 2,
      "reserved_at": "2026-10-14T01:00:00Z", "visit_type": "FIRST", "memo": "기침"}
응답 201(새로 생성) / 200(같은 X-Request-ID 재요청) {
  "id": 101, "request_id": "6f1c...", "patient_id": 3, "patient_name": "김가상", "chart_no": "C2026-0003",
  "department_id": 1, "doctor_id": 2,
  "reserved_at": "2026-10-14T01:00:00Z", "visit_type": "FIRST",
  "status": "BOOKED", "checkin_status": "NOT_CHECKED_IN",
  "created_at": "2026-10-10T03:12:00Z"
}
```
- PATIENT는 `patient_id`를 보내지 않으면 토큰의 본인 값으로 채운다. 다른 사람 값이면 403.
- 허용 칸: `patient_id`, `department_id`, `doctor_id`, `reserved_at`, `visit_type`, `memo`. 그 밖의 칸(`role` 등)은 422.
- 예약 응답(R1~R5, R10 의 최근 예약)에는 화면 표시용 `patient_name`·`chart_no` 가 함께 온다 (역할별 범위 안의 예약만 보이므로 더 드러나는 정보는 없다).
- `reserved_at` 이 **지금보다 앞(과거)이면 422**. 지금과 같은 시각은 된다.
- 같은 X-Request-ID 가 범위 밖 사람의 예약에 이미 쓰였으면 409.
- **같은 의사·같은 시간 예약은 409.** 의사 한 명의 진료 한 칸은 30분이다. 새 예약 시각이 같은 의사의 `BOOKED` 예약과 30분 안으로 겹치면 거절한다 (예: 10:00 예약이 있으면 09:31~10:29 는 409, 09:30·10:30 은 됨). 취소된 예약은 자리를 비운다. `doctor_id` 가 없는 예약은 검사하지 않는다.
  - 같은 X-Request-ID 재요청은 409 가 아니라 기존 예약 200 이다.

### R2 예약 목록
`GET /api/v1/reservations?date_from=2026-10-14&date_to=2026-10-14&status=BOOKED&checkin_status=NOT_CHECKED_IN&department_id=1&doctor_id=2&page=1&size=20`
- 역할별 범위가 **자동으로** 걸린다: PATIENT는 본인 것만, NURSE·DEPT_HEAD는 자기 부서만 (다른 `department_id`를 보내면 403).
- `date_from`·`date_to`는 **KST 날짜** (예: `date_from=2026-10-14&date_to=2026-10-14` → UTC `2026-10-13T15:00:00Z` ~ `2026-10-14T15:00:00Z` 전). 정렬은 예약 시각 순.
- 정해진 조회 조건 외의 값(`role` 등)은 422. `size`는 1~100.
- 응답: `{"items": [...], "page": 1, "size": 20, "total": 57}`

### 진료 진행 상태 (`checkin_status`)
`NOT_CHECKED_IN`(접수 전) → `CHECKED_IN`(진료대기) → `IN_TREATMENT`(진료중) → `COMPLETED`(진료완료). **앞으로만** 간다.

| 요청 | 지금 상태 | 결과 |
|---|---|---|
| R5 접수 | `NOT_CHECKED_IN` | `CHECKED_IN` (대기번호 부여) |
| R15 진료 시작 | `CHECKED_IN` | `IN_TREATMENT` |
| R15 진료 시작 | `NOT_CHECKED_IN` (건너뜀), `COMPLETED` (되돌림) | 409 |
| R16 진료 완료 | `IN_TREATMENT` | `COMPLETED` |
| R16 진료 완료 | `NOT_CHECKED_IN`·`CHECKED_IN` (건너뜀) | 409 |
| R15·R16 | 이미 요청한 상태 | 그대로 200 (버튼을 두 번 눌러도 안전) |
| R4 취소 | `IN_TREATMENT`, `COMPLETED` | 409 (진료가 시작된 예약은 취소 불가) |

### R4 취소 / R5 접수
- R4: `status=CANCELED`, `canceled_at` 기록. 이미 취소면 그대로 200. **진료중·진료완료 예약은 409.**
- R5: `checkin_status=CHECKED_IN`, `checked_in_at` 기록. 취소된 예약이면 409, 이미 접수면(진료중·진료완료 포함) 상태를 바꾸지 않고 그대로 200.
  - `queue_no`·`queue_date`: 진료과별·**KST 날짜별**(예약 시각 기준) 1번부터. `queue_date` 에 그 KST 날짜를 함께 저장한다.
  - DB 가 `UNIQUE(department_id, queue_date, queue_no)` 로 중복을 막는다. 동시 접수가 같은 번호를 읽어 겹치면 한쪽이 취소되고 처음부터 다시 번호를 매긴다 (최대 5번). 그래도 안 되면 503 `DB_UNAVAILABLE` (다시 시도).

### R15 진료 시작 / R16 진료 완료 (추가)
`POST /api/v1/reservations/{id}/start-treatment`, `POST /api/v1/reservations/{id}/complete-treatment` (본문 없음) → 응답은 예약(`ReservationOut`).
- 허용 역할은 DOCTOR 만이고, 그 예약의 `doctor_id` 가 로그인 의사(`doctors.user_id` = 로그인 계정)와 같을 때만 된다. 다른 의사·다른 역할은 403 + 감사 로그 `ACCESS_DENIED`(DENIED).
- 없는 예약 404. 취소된 예약, 순서가 틀린 요청(건너뛰기·되돌리기)은 409.
- 성공하면 같은 트랜잭션으로 감사 로그 `TREATMENT_START`·`TREATMENT_COMPLETE`(SUCCESS) 를 남긴다.

### R17 내 진료 대기열 (추가)
`GET /api/v1/doctor/queue?date=2026-10-14` — R8 과 같은 응답 모양. 로그인한 의사가 담당인, 취소되지 않고 접수된 예약만 (`checkin_status` 가 진료대기·진료중·진료완료). `department_id` 를 넣으면 403. 의사 계정에 연결된 의사 정보가 없어도 403.

### R8 오늘 대기열
`GET /api/v1/queue?date=2026-10-14&department_id=1`
- 접수된(`CHECKED_IN`·`IN_TREATMENT`·`COMPLETED`) 예약 중 취소되지 않은 것을 진료과·대기번호 순으로. 항목의 `checkin_status` 로 진료대기·진료중·진료완료를 구분한다. `date` 는 KST 날짜, 없으면 오늘(KST).
- NURSE·DEPT_HEAD 는 자기 부서만 (다른 `department_id` 는 403). DIRECTOR·TESTER 는 `department_id` 로 고르고, 없으면 전체.
```json
{"date": "2026-10-14", "department_id": 1, "items": [
  {"reservation_id": 101, "queue_no": 1, "department_id": 1, "patient_id": 3, "patient_name": "김가상", "chart_no": "C2026-0003",
   "doctor_id": 2, "doctor_name": "이내과", "checkin_status": "CHECKED_IN",
   "reserved_at": "2026-10-14T01:00:00.000Z", "checked_in_at": "2026-10-14T00:52:00.000Z"}]}
```

### 전화번호 공개 범위 (R6·R9·R10·R14·R18, A3~A5)
보안 담당이 확정한 규칙이다. **화면이 아니라 서버 응답**에서 처리하므로, 공개 대상이 아니면 응답에 전체 번호가 아예 없다. 규칙 코드는 `shared/phone.py`.

| 역할 | 환자 번호 | 부서 대표 번호 | 직원 업무용 연락처 |
|---|---|---|---|
| PATIENT | 본인 것만 전체 | 전체 | — |
| MANAGER (원무과장) | 모든 환자 전체 | 가림 | 모든 직원 전체 |
| NURSE | 자기 부서에 예약(`BOOKED`)이 있는 환자만 전체, 나머지 가림 | 원무과(`ADM`)만 전체, 나머지 가림 | 자기 부서 직원만 전체 (자기 부서 부서장 포함, 다른 부서 부서장은 목록에 없음) |
| DOCTOR | 가림 | 가림 | **자기 부서 부서장만** 전체 (목록에도 부서장만 나온다) |
| DEPT_HEAD (부서장) | 가림 | 가림 | **자기 부서 직원** 전체 (본인 포함) |
| DIRECTOR (원장) | 가림 | 가림 | **부서장 범위(자기 부서 직원) + 모든 부서 부서장** 전체 |
| ADMIN, DEVELOPER, TESTER | 전부 가림 | 전부 가림 | (목록 없음) |

- 병원 대표 번호(`HOSPITAL_PHONE`)는 병원이 공개하는 번호라 **로그인한 모든 역할에 그대로** 보인다 (R19 `hospital_phone`, 설정이 없으면 `null`).

- 가린 모양: `010-1234-5678` → `010-****-5678`. 형식이 다르면 끝 4자리만 남긴다 (`01012345678` → `*******5678`).
- 응답의 번호 칸 옆에 `phone_is_masked`(직원은 `work_phone_is_masked`)가 `true` 이면 가린 값이다. 번호가 없으면(`null`) `false`.
- 감사 로그·앱 로그에는 번호를 남기지 않는다.

### R9 환자 검색 / R10 환자 상세
- R9 `GET /api/v1/patients?q=김&page=1&size=20`: 이름 일부 또는 차트번호 **앞부분**. `%`·`_` 는 글자 그대로 찾는다. 전화번호는 위 공개 범위대로 (`phone`, `phone_is_masked`).
  `{"items": [{"id", "chart_no", "name", "birth_date", "phone", "phone_is_masked"}], "page", "size", "total"}`
  (이전의 `phone_masked` 칸은 없어졌다. 화면은 `phone` 을 그대로 보여 주면 된다.)
- R10 `GET /api/v1/patients/{id}`: 환자 정보(`phone`, `phone_is_masked`) + `recent_reservations` 최근 예약 10건(예약 시각 최신순). NURSE 는 자기 부서 예약만 보인다. **PATIENT 는 본인 id 만** (다른 id 는 403 + 감사 로그 `ACCESS_DENIED`). **MANAGER 는 부서와 상관없이 전체 부서의 최근 예약이 보이지만 `memo` 는 항상 `null`** (진단·진료 메모는 어떤 역할의 응답에도 없다). 조회는 감사 로그 `PATIENT_VIEW` 로 남긴다.

### R13 예약 가능 시간 (추가)
`GET /api/v1/slots?doctor_id=2&date=2026-10-14`
- 그 의사의 그날(KST) 진료 시간 09:00~17:30 을 30분 칸으로 나눠(시작 09:00 … 17:00, 17칸), 같은 의사의 `BOOKED` 예약과 겹치는 칸을 뺀다 (R1 의 409 와 같은 기준).
- **지난 칸은 뺀다**: `date` 가 오늘(KST)이면 지금 시각(KST) 이전에 시작하는 칸을 빼고 (지금과 같은 시각에 시작하는 칸은 남음), 지난 날짜면 빈 목록 `[]` 이다. R1 도 과거 시각은 422 로 거절한다.
- 없는·진료하지 않는 의사는 404. `doctor_id`, `date` 둘 다 필수.
```json
{"doctor_id": 2, "date": "2026-10-14", "slot_minutes": 30,
 "available": ["2026-10-14T00:00:00.000Z", "2026-10-14T00:30:00.000Z", "..."]}
```
(`available` 은 UTC. `2026-10-14T00:00:00.000Z` = KST 09:00)

### R14 환자 등록 (추가)
`POST /api/v1/patients`
```json
요청 {"chart_no": "C2026-0031", "name": "새환자", "birth_date": "1980-05-05", "phone": "010-1234-5678"}
응답 201 {"id": 31, "chart_no": "C2026-0031", "name": "새환자", "birth_date": "1980-05-05", "phone": "010-****-5678", "phone_is_masked": true, "created_at": "..."}
```
- 응답의 `phone` 도 공개 범위를 따른다. 방금 등록한 환자는 어느 부서에도 예약이 없으므로 NURSE·ADMIN·DIRECTOR·TESTER 는 가린 값을 받는다 (저장된 값은 그대로).
- 차트번호는 영문·숫자·`-` 최대 20자, 이미 있으면 409. `phone` 은 선택(숫자·`-`). 등록은 감사 로그 `PATIENT_CREATE` 와 같은 트랜잭션.

### R6 진료과 목록 · R18 직원 연락처
- R6 응답 항목: `{"id", "code", "name", "phone", "phone_is_masked"}`. `phone` 은 부서 대표 번호 (공개 범위는 위 표).
- R18 `GET /api/v1/staff`: 활성 직원(환자 계정 제외)의 업무용 연락처. NURSE 는 자기 부서 직원만, MANAGER 는 전체. 그 밖의 역할은 403.
  `[{"id", "name", "role", "department_id", "work_phone", "work_phone_is_masked"}]`
- R19 `GET /api/v1/contacts`: 연락처 화면용 한 번에 응답. 직원 목록 범위: MANAGER 전체 / NURSE·DEPT_HEAD 자기 부서 직원 / DOCTOR 자기 부서 부서장 / DIRECTOR 자기 부서 직원 + 모든 부서 부서장 / 그 밖의 역할은 빈 목록.
  `{"hospital_phone": "02-0000-0000", "departments": [R6 항목], "staff": [R18 항목]}`

### 원무과장(MANAGER) 권한 (보안 담당 승인)
- 부서와 상관없이 **예약 조회(R2·R3)·접수(R5)·취소(R4)**, **환자 검색·상세(R9·R10)** 를 쓸 수 있다.
- 예약 만들기(R1), 대기열(R8), 진료 시작·완료(R15·R16), 내 진료기록·영수증(R11·R12), 환자 등록(R14)은 403 (감사 로그 `ACCESS_DENIED`).
- 진단·진료 메모(`medical_records`)는 원무과장 응답에 없다. 예약 `memo` 도 `null` 로 비워 보낸다 (환자 상세의 `recent_reservations` 포함).
- 접수·취소·환자 조회는 사용자 id 와 함께 감사 로그 `RESERVATION_CHECKIN`·`RESERVATION_CANCEL`·`PATIENT_VIEW` 로 남는다.

### R5 대기번호
- 접수(R5) 때 진료과별·KST 날짜별(예약 시각 기준) 다음 번호를 `reservations.queue_no` 에, 그 KST 날짜를 `reservations.queue_date` 에 저장한다.
- 같은 (진료과, 날짜, 번호)는 DB 가 한 번만 허용한다 (`uq_reservations_queue`). 접수 전에는 둘 다 NULL.

### A3~A6 관리
- A3 `GET /api/v1/admin/users?role=&department_id=&is_active=&q=&page=&size=`: **직원 계정만** (PATIENT 제외). `q` 는 아이디·이름 일부. 비밀번호 해시는 내보내지 않는다. 업무용 연락처 `work_phone` 은 호출 역할(ADMIN·DIRECTOR·TESTER)이 모두 가림 대상이라 항상 `010-****-1234` 모양 (A4·A5 응답도 같다).
- A4 `POST /api/v1/admin/users` `{"login_id", "name", "role", "department_id", "patient_id", "password"}`
  - 처음 비밀번호 10자 이상(72바이트 이하), bcrypt 해시만 저장. 같은 아이디·이미 계정이 있는 환자면 409.
  - 역할별 소속: PATIENT 는 `patient_id` 필수·부서 없음, NURSE·DOCTOR·MANAGER·DEPT_HEAD 는 `department_id` 필수, 그 밖의 역할은 `patient_id` 없음 (어기면 400).
- A5 `PATCH /api/v1/admin/users/{id}` `{"role", "department_id", "is_active"}` 중 보낸 칸만 바꾼다.
  - 하나라도 바뀌면 그 사용자의 **세션을 모두 끊는다** (이전 토큰 401, 다시 로그인). 응답에 끊은 세션 수 `revoked_sessions`.
  - 자기 계정은 바꿀 수 없다 (400).
- A4·A5 공통: DIRECTOR 역할을 주거나 DIRECTOR 계정을 바꾸는 것은 DIRECTOR 만 (ADMIN 은 403).
- A6 `GET /api/v1/admin/audit-logs?date_from=&date_to=&user_id=&action=&result=&service=&page=&size=`: 최신순. 날짜는 KST. 조회도 `AUDIT_LOG_VIEW` 로 남긴다. **감사 로그 수정·삭제 API 는 없다.**
- 감사 로그 행위: `USER_CREATE`, `USER_UPDATE` (변경과 같은 트랜잭션).

### R11 내 진료기록 / R12 내 영수증 (샘플 데이터 조회만)
- PATIENT 만, **본인 것만** (토큰의 `patient_id`). 진료(의사 EMR)·수납 기능은 없고 샘플 데이터를 조회한다.
- R11 `GET /api/v1/me/records` → 최신순
  `[{"id", "reservation_id", "doctor_id", "doctor_name", "diagnosis", "note", "created_at"}]`
  - `diagnosis`·`note` 는 DB 에 AES-256-GCM 암호문으로만 있다. 복호화는 `shared/crypto.py` 한 곳에서, 권한 검사를 통과한 뒤에만 한다.
  - 키가 없거나 한 건이라도 인증 태그가 틀리면 **503 `RECORD_UNAVAILABLE`**, 평문은 한 건도 돌려주지 않는다.
  - 조회는 성공·실패 모두 감사 로그 `RECORD_VIEW` (target: patient).
- R12 `GET /api/v1/me/receipts` → 최신순 `[{"id", "reservation_id", "amount", "pay_status", "paid_at", "created_at"}]`

### S2 부서별 / S3 의사별 / S4 병원 전체 현황
`reservations` 를 세어서 만든다 (현황 서비스, 조회 전용 계정). 기간은 `reserved_at` 기준, 날짜는 KST.

| 칸 | 세는 것 |
|---|---|
| `total` | 예약 전체 (취소 포함) |
| `booked` | `status=BOOKED` |
| `canceled` | `status=CANCELED` (접수 후 취소도 여기만) |
| `checked_in` | BOOKED 이면서 접수됨 (`CHECKED_IN`·`IN_TREATMENT`·`COMPLETED` 모두) |
| `not_checked_in` | BOOKED 이면서 아직 접수 안 됨 |
| `waiting` (S4) | 부서별 진료대기 수 = BOOKED 이면서 `CHECKED_IN` 인 예약 (진료중·진료완료는 뺀다) |

- S2 `GET /api/v1/stats/departments?date_from=&date_to=&department_id=` → `{"date_from", "date_to", "items": [{"department_id", "code", "name", 위 칸들}]}`. 예약이 없는 부서도 0 으로 나온다.
- S3 `GET /api/v1/stats/doctors?department_id=&date_from=&date_to=` → `{"date_from", "date_to", "department_id", "items": [{"doctor_id", "doctor_name", "department_id", 위 칸들}]}`. 의사 미지정 예약은 S3 에서 빠지고 S2 에는 들어간다.
- S4 `GET /api/v1/stats/hospital?date=` → `{"date", "totals": {위 칸들}, "departments": [{..., "waiting"}]}`. DIRECTOR 만.
- `date_from`·`date_to`·`date` 가 없으면 오늘(KST). 기간은 최대 366일, `date_from > date_to` 는 422.
- DEPT_HEAD 는 **자기 부서로 고정** (다른 `department_id` 는 403 + 감사 로그 DENIED). DIRECTOR 는 `department_id` 로 고르고, 없으면 전체.

### S1 시스템 상태
```json
{"site": "hospital", "read_only_mode": false, "version": "a1b2c3d",
 "services": {"auth": "ok", "reservation": "ok", "stats": "ok"},
 "db": "ok", "checked_at": "2026-10-10T03:12:00Z"}
```

## 5. 환경변수 (세 서비스 공통)
| 이름 | 예 | 설명 |
|---|---|---|
| `DB_URL` | `mysql://호스트:3306/hospital` | 계정 없는 DB 주소 (`user:password@` 를 넣으면 시작하지 않음). 드라이버(`mysql+pymysql`)·`charset=utf8mb4` 는 앱이 붙인다. Helm `dbUrl` (values) |
| `DB_USERNAME` | Secret | DB 계정. auth·reservation은 `app_runtime`, stats는 `app_readonly`. Helm `secrets.<runtimeDatabase/readonlyDatabase>` |
| `DB_PASSWORD` | Secret | 위 계정의 비밀번호. 로그·오류 메시지·응답(S1 등)에 나오지 않는다 |
| `DB_SSL_CA` | 파일 경로 | DB TLS CA 인증서 (서버 이름 검증) |
| `MEDICAL_KEY` | Secret (예약 서비스만) | 진료기록 AES-256 키, base64 32바이트. 없으면 R11 만 503, 나머지는 동작. KMS 로 옮길 때는 `shared/crypto.py` 만 바꾼다 (`KMS_KEY_ID`) |
| `MEDICAL_KEY_VERSION` | `1` | 지금 키 버전 (새로 암호화할 때 씀). 키를 바꾸면 올리고, 옛 키는 `MEDICAL_KEY_V<버전>` 으로 남긴다 |
| `JWT_SECRET` | Secret | 세 서비스 동일 |
| `READ_ONLY_MODE` | `false` | 사이트별 |
| `SITE_NAME` | `hospital` / `krdr` / `aws` | 시스템 상태 표시용 |
| `APP_VERSION` | Git 커밋 값 | 이미지 태그와 동일 |
| `SERVICE_URLS` | stats 전용 | 다른 서비스 `/readyz` 주소 |
| `FORWARDED_ALLOW_IPS` | `127.0.0.1` (기본) | X-Forwarded-For 를 믿을 프록시(인그레스 컨트롤러) 주소·대역, 쉼표 구분. 여기서 온 요청만 실제 클라이언트 IP 를 감사 로그 `client_ip`·로그인 IP 제한에 쓴다. 그 밖에서 온 X-Forwarded-For 는 무시. `*` 금지. Helm `forwardedAllowIps` |

## 6. 테스트 계정 (보안·부하 테스트용, 가상 데이터)
역할별 1개 이상: `patient01`, `nurse_im01`(내과), `nurse_os01`(정형외과), `admin01`, `office01`(원무과), `head_im01`, `director01`, `dev01`, `tester01`. 비밀번호는 Git에 넣지 않고 따로 전달.
