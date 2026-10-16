# 역할별 권한 표 (permissions matrix)

기준 코드: `shared/permissions.py`(API 허용 역할), `shared/phone.py`(전화번호 공개 범위). 이 문서는 두 파일과 같게 유지한다.
API 별 상세는 `docs/api-spec.md`. 권한 표에 없는 API 는 기본 403 이고, 거부는 감사 로그 `ACCESS_DENIED`(DENIED) 로 남는다.

역할: PATIENT(환자), NURSE(간호사), DOCTOR(의사), MANAGER(원무과장), ADMIN(관리자), DEPT_HEAD(부서장), DIRECTOR(원장), DEVELOPER(개발자), TESTER(테스터)

범례: ● 허용 · ◐ 범위 제한 허용(아래 주석) · — 거부(403)

## 1. API × 역할

| API | PATIENT | NURSE | DOCTOR | MANAGER | ADMIN | DEPT_HEAD | DIRECTOR | DEVELOPER | TESTER |
|---|---|---|---|---|---|---|---|---|---|
| A1 `POST /auth/login` | 공개 | 공개 | 공개 | 공개 | 공개 | 공개 | 공개 | 공개 | 공개 |
| A2 `GET /auth/me`, A7 `POST /auth/logout` | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| A3 `GET /admin/users` | — | — | — | — | ● | — | ● | — | ● |
| A4 `POST /admin/users`, A5 `PATCH /admin/users/{id}` | — | — | — | — | ● | — | ● | — | — |
| A6 `GET /admin/audit-logs` | — | — | — | — | ● | — | ● | — | — |
| R1 `POST /reservations` | ◐ 본인 | ◐ 자기 부서 | — | — | — | — | ● | — | ● |
| R2 `GET /reservations`, R3 `GET /reservations/{id}` | ◐ 본인 | ◐ 자기 부서 | — | **● 전체 (메모 비움)** | — | ◐ 자기 부서 | ● | — | ● |
| R4 `DELETE /reservations/{id}` | ◐ 본인 | ◐ 자기 부서 | — | **● 전체** | — | — | ● | — | ● |
| R5 `POST /reservations/{id}/checkin` | — | ◐ 자기 부서 | — | **● 전체** | — | — | ● | — | ● |
| R15·R16 진료 시작·완료 | — | — | ◐ 담당 의사만 | — | — | — | — | — | — |
| R17 `GET /doctor/queue` | — | — | ● (본인 담당) | — | — | — | — | — | — |
| R6 `GET /departments`, R7 `GET /doctors`, R13 `GET /slots` | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| R8 `GET /queue` | — | ◐ 자기 부서 | — | — | — | ◐ 자기 부서 | ● | — | ● |
| R9 `GET /patients?q=` | — | ● | — | **●** | — | — | ● | — | ● |
| R10 `GET /patients/{id}` | ◐ 본인 | ● | — | **● (예약 메모 비움)** | — | — | ● | — | ● |
| R14 `POST /patients` | — | ● | — | — | ● | — | ● | — | ● |
| R11 `GET /me/records`, R12 `GET /me/receipts` | ◐ 본인 | — | — | — | — | — | — | — | — |
| R18 `GET /staff` | — | ◐ 자기 부서 | — | ● | — | — | — | — | — |
| R19 `GET /contacts` | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| S1 `GET /system/status` | — | — | — | — | — | — | ● | ● | ● |
| S2·S3 `GET /stats/departments`, `/stats/doctors` | — | — | — | — | — | ◐ 자기 부서 | ● | — | — |
| S4 `GET /stats/hospital` | — | — | — | — | — | — | ● | — | — |

굵은 글씨는 이번에 바뀐 부분(원무과장 권한 승인).

## 2. 원무과장(MANAGER) — 보안 담당 승인 내용

| 항목 | 내용 |
|---|---|
| 허용 | 부서와 상관없이 예약 조회(R2·R3)·접수(R5)·취소(R4), 환자 검색·상세(R9·R10) |
| 거부 | 예약 만들기(R1), 대기열(R8), 진료 시작·완료(R15·R16), 내 진료기록·영수증(R11·R12), 환자 등록(R14), 계정·감사 로그·현황 |
| 응답에 넣지 않는 것 | 진단·진료 메모(`medical_records`는 R11 PATIENT 본인 응답에만 있음). 예약 `memo` 는 `null` 로 비움 (환자 상세의 `recent_reservations` 포함) |
| 감사 로그 | 접수 `RESERVATION_CHECKIN`, 취소 `RESERVATION_CANCEL`, 환자 상세 `PATIENT_VIEW` (SUCCESS, 사용자 id 포함). 거부는 `ACCESS_DENIED` (DENIED) |
| 화면 | 현장 접수(예약 등록 버튼 없음), 환자 검색(등록 없음), 수납("준비 중"), 연락처 |
| 테스트 | `services/reservation/tests/test_manager_front_desk.py` |

## 3. 전화번호 공개 범위 (`shared/phone.py`, 보안 담당 확정)

| 역할 | 환자 번호 | 진료과 대표 번호 | 직원 업무용 연락처 | 병원 대표 번호 |
|---|---|---|---|---|
| PATIENT | 본인 것만 전체 | 전체 | 목록 없음 | 전체 |
| NURSE | 자기 부서에 예약(`BOOKED`)이 있는 환자만 전체 | 원무과(`ADM`)만 전체 | 자기 부서 직원만 전체 (자기 부서 부서장 포함) | 전체 |
| DOCTOR | 가림 | 가림 | **자기 부서 부서장만** 전체 | 전체 |
| MANAGER | 모든 환자 전체 | 가림 | 모든 직원 전체 | 전체 |
| DEPT_HEAD | 가림 | 가림 | **자기 부서 직원** 전체 (본인 포함) | 전체 |
| DIRECTOR | 가림 | 가림 | **부서장 범위(자기 부서 직원) + 모든 부서 부서장** 전체 | 전체 |
| ADMIN, DEVELOPER, TESTER | 가림 | 가림 | 목록 없음 | 전체 |

- 가린 모양 `010-****-1234`. 응답의 `phone_is_masked`·`work_phone_is_masked` 로 구분한다.
- 원장에게 소속 부서가 없으면 "부서장 범위"는 비어 있어 모든 부서 부서장만 보인다.
- 병원 대표 번호는 `HOSPITAL_PHONE` 환경변수 (로컬 docker-compose 와 Helm `values.yaml` 의 `hospitalPhone` 은 가짜 번호 `02-0000-0000`, 운영 값은 배포 담당이 바꾼다). 설정이 없으면 `null`.
- 테스트: `test_phone_visibility.py`, `test_contacts.py`.

## 4. 화면 메뉴 × 역할 (`web/src`, 권한은 서버가 API 마다 다시 검사한다)

| 역할 | 메뉴 |
|---|---|
| PATIENT | 예약하기, 내 예약, 진료기록·영수증, 연락처 |
| NURSE | 오늘 대기열, 현장 접수, 환자 검색(등록 가능), 연락처 |
| DOCTOR | 진료(EMR: 내 진료 대기열·시작·완료), 연락처 |
| MANAGER | 현장 접수, 환자 검색, 수납(준비 중), 연락처 |
| ADMIN | 환자 관리(등록만), 계정·감사 로그, 연락처 |
| DEPT_HEAD | 오늘 대기열, 부서 현황, 연락처(자기 부서 직원) |
| DIRECTOR | 대기열·접수, 환자 관리, 계정·감사 로그, 현황, 진료(EMR, 준비 중 예시), 수납(준비 중), 연락처 |
| DEVELOPER | 시스템 상태, 연락처 |
| TESTER | 오늘 대기열, 현장 접수, 환자 검색, 시스템 상태, 연락처 |

## 5. 경로 등록 확인

API 경로를 새로 만들면 web nginx(`web/nginx/web.conf.template`)와 Helm ingress(`helm/reservation-app/templates/ingress.yaml`)에도 첫 경로 조각을 넣어야 한다.
`tests/test_deploy_config.py` 의 `test_every_api_path_is_in_web_nginx`, `test_every_api_path_is_in_helm_ingress` 가 빠진 경로를 실패로 알려 준다.
