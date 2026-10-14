# hospital-gitops

병원 예약 시스템의 배포 설정과 DB 스키마, 로컬 개발 환경.

## 구조

```
helm/reservation-app/   Helm 차트 (values-onprem / values-aws / values-dr-active)
db/                     schema.sql, grants.sql, seed.sql, 마이그레이션, MySQL 초기화 스크립트
docker-compose.yml      로컬 개발용 (MySQL + 서비스 3개 + 화면)
.env.example            로컬 환경변수 이름 목록 (값은 비어 있음)
scripts/make_env.ps1    .env.example 로 .env 를 만든다 (무작위 비밀번호·키)
docs/                   API 명세, ERD
tools/data_verifier.py  DR 훈련용 예약 기록·검증 도구
tests/                  배포 설정·검증 도구 테스트
```

## 로컬 개발 환경

`docker-compose.yml` 은 옆 폴더의 저장소를 빌드한다. 5개 저장소를 같은 폴더 아래에 나란히 clone 한다.

```
hospital-repos/
  hospital-frontend/  hospital-backend-auth/  hospital-backend-reservation/  hospital-backend-stats/  hospital-gitops/
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\make_env.ps1   # .env 생성 (Git 에 올리지 않는다)
docker compose up -d --build                                     # 화면 http://localhost:8080
```

## 테스트

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements-dev.txt
.venv\Scripts\python -m pytest tests
```

Dockerfile 검사는 옆 폴더의 `hospital-backend-*` 를, Helm 검사는 `helm` 명령을 쓴다 (없으면 건너뛴다).

## 환경변수 (.env, 로컬 compose)

| 이름 | 설명 |
|---|---|
| `MYSQL_ROOT_PASSWORD` | 로컬 MySQL 관리자 |
| `APP_RUNTIME_PASSWORD` | DB 계정 app_runtime (auth · reservation) |
| `APP_READONLY_PASSWORD` | DB 계정 app_readonly (stats) |
| `APP_MIGRATE_PASSWORD` | DB 계정 app_migrate (스키마 변경) |
| `JWT_SECRET` | JWT 서명 키 (세 서비스 같은 값) |
| `MEDICAL_KEY` · `MEDICAL_KEY_VERSION` | 진료기록 암호화 키 |

검증 도구: `VERIFIER_BASE_URL`, `VERIFIER_AUTH_URL`, `VERIFIER_LOGIN_IDS`, `VERIFIER_PASSWORD`, `VERIFIER_DATABASE_URL`, `VERIFIER_DB_SSL_CA`, `VERIFIER_PATIENT_QUERY` (사용법은 `tools/data_verifier.py` 맨 위 설명).

운영(Helm)에서는 비밀 값을 Kubernetes Secret 으로 주입한다. 값은 이 저장소에 넣지 않는다.

## 코드 원본

이 저장소의 코드는 `reservation-app` 에서 `scripts/sync_to_repos.ps1` 로 복사한다.
README.md · .gitignore · .gitattributes · .github/ 는 이 저장소에서 직접 관리한다 (복사 대상 아님).
