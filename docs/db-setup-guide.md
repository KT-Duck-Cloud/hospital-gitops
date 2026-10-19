# DB 처음 넣기 안내서 (온프레미스 담당용)

MySQL(vm2 도커)에 병원 예약 시스템 DB 를 **처음** 넣을 때, 화면을 같이 보면서 순서대로 따라 하는 문서입니다.

- 각 단계 밑에 **왜 하는지** 한 줄씩 적었습니다.
- `<비밀번호>`, `<VPN IP>` 같은 `< >` 는 자리표시입니다. 실제 값으로 바꿔 쓰되, **화면 공유 중에 비밀번호를 보이게 입력하지 마세요** (아래 방법을 쓰면 화면에 안 나옵니다).
- 파일 이름은 저장소 기준입니다: `db/schema.sql`, `db/grants.sql`, `db/seed.sql`, `db/migrate_002.sql`, `scripts/seed_users.py`, `scripts/seed_records.py`, `helm/reservation-app/`.
- 용어: **주 DB** = 평소에 쓰는 병원(운영) DB, **대기 DB** = 복제로 따라오는 DR 대기 DB.

---

## 1. 준비 (주 DB·대기 DB 둘 다)

### 1-1. 이미지 버전 고정: `mysql:8.4.11`

`latest` 나 `8.4` 가 아니라 **`mysql:8.4.11`** 처럼 끝까지 적습니다. (저장소의 `docker-compose.yml`, Helm `migrate.image` 와 같은 버전)

> 왜: 이미지가 몰래 바뀌어 주 DB 와 대기 DB 버전이 달라지는 일을 막습니다. 복제는 두 DB 버전이 맞아야 안전합니다.

### 1-2. 비밀번호 파일 만들기 (권한 600)

비밀번호는 명령어 줄에 쓰지 않고, **파일에 넣고 권한을 600(나만 읽기)** 으로 둡니다.

```bash
sudo mkdir -p /opt/mysql
sudo install -m 600 /dev/null /opt/mysql/mysql.env          # 빈 파일을 600 으로 만듦
sudo install -m 600 /dev/null /opt/mysql/app-passwords.env
sudo vi /opt/mysql/mysql.env
```

`/opt/mysql/mysql.env` 내용 (DB 관리자 비밀번호 1개):

```
MYSQL_ROOT_PASSWORD=<비밀번호>
```

`/opt/mysql/app-passwords.env` 내용 (앱 계정 3개 — 주 DB 에서 grants.sql 실행할 때만 씀):

```
APP_RUNTIME_PASSWORD=<비밀번호>
APP_READONLY_PASSWORD=<비밀번호>
APP_MIGRATE_PASSWORD=<비밀번호>
```

> 왜: 명령어에 직접 쓴 비밀번호는 `history`, `ps`, 화면 공유 녹화에 남습니다. 600 파일은 그 사용자만 읽습니다.
> 주의: 앱 계정 비밀번호는 **영문·숫자 16자 이상**으로 만드세요. `grants.sql` 의 자리표시를 `sed` 로 바꾸는데, 특수문자가 있으면 깨집니다 (`db/init/02-grants.sh` 와 같은 규칙).

### 1-3. my.cnf 만들기 (기본은 쓰기 불가)

`/opt/mysql/my.cnf`:

```ini
[mysqld]
default-time-zone        = +00:00            # 시간 칸을 UTC 로 저장 (schema.sql 이 전제)
character-set-server     = utf8mb4
collation-server         = utf8mb4_0900_ai_ci
require_secure_transport = ON                # TCP 접속은 TLS 만 허용
read_only                = ON                # 기본은 쓰기 불가
super_read_only          = ON                # 관리자(root)도 쓰기 불가
# 복제용 설정(server-id, log-bin 등)은 복제 담당이 값과 함께 추가한다.
```

> 왜 read_only·super_read_only: **DB 가 어느 사이트에서 켜지든 일단 쓰기 불가로 시작**하게 해서, 주 DB 가 둘이 되는 사고(두 곳에 서로 다른 데이터가 쌓임)를 막습니다.
> 왜 time-zone: 모든 시간이 UTC 로 저장된다는 약속입니다. 다르면 시각이 9시간 어긋납니다.
>
> **주의 (반드시 읽기): 데이터 폴더가 비어 있는 첫 부팅은 `read_only`·`super_read_only` 가 켜진 채로는 실패합니다.**
> 이미지가 내부 초기화에서 root 비밀번호 설정 등을 위해 쓰기를 하는데, `super_read_only` 때문에 `ERROR 1290 ... --super-read-only option` 으로 멈추고 컨테이너가 종료됩니다 (직접 확인함).
> 그래서 **첫 한 번만** 두 줄을 `#` 로 주석 처리한 채로 1-4 의 컨테이너를 띄우고, 초기화가 끝나면 주석을 풀고 재시작합니다 (1-4 의 "처음 한 번만" 순서).

### 1-4. 컨테이너 띄우기, 3306 은 VPN IP 로만

```bash
docker run -d --name mysql --restart unless-stopped \
  --env-file /opt/mysql/mysql.env \
  -p <VPN IP>:3306:3306 \
  -v /opt/mysql/data:/var/lib/mysql \
  -v /opt/mysql/my.cnf:/etc/mysql/conf.d/my.cnf:ro \
  mysql:8.4.11
```

`-p <VPN IP>:3306:3306` 처럼 **VPN 쪽 IP 를 앞에 붙입니다**. (`-p 3306:3306` 만 쓰면 모든 곳에 열립니다.)

> 왜: 도커는 방화벽(ufw 등) 규칙을 건너뛰고 포트를 열 수 있어서, 포트를 연결하는 **그 자리에서** IP 를 좁혀야 합니다. DB 는 VPN 안의 앱 노드만 접속해야 합니다.

**처음 한 번만 (데이터 폴더가 비어 있을 때): 쓰기 불가 두 줄을 끄고 초기화 → 켜고 재시작**

```bash
# 1) /opt/mysql/my.cnf 에서 두 줄을 주석 처리한다
#      # read_only       = ON
#      # super_read_only = ON
# 2) 위 docker run 으로 컨테이너를 띄우고, 초기화가 끝날 때까지 기다린다 (몇십 초)
docker exec mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h127.0.0.1 -uroot -N -e "SELECT 1"'   # 1 이 나오면 초기화 끝
# 3) my.cnf 의 두 줄 주석을 푼다 (read_only = ON, super_read_only = ON)
# 4) 재시작해서 쓰기 불가로 올린다
docker restart mysql
docker exec mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h127.0.0.1 -uroot -N -e "SELECT @@read_only, @@super_read_only"'   # 1  1
```

> 왜: 초기화는 쓰기가 필요합니다. 그 뒤부터는 두 줄이 켜진 채로 정상 기동합니다. 이 순서는 **데이터 폴더가 이미 있는 재시작·복구에는 필요 없습니다.**

확인:

```bash
docker ps --format '{{.Names}} {{.Ports}}'     # <VPN IP>:3306->3306/tcp 로 보여야 함 (0.0.0.0 이면 안 됨)
docker exec mysql mysqld --version             # 8.4.11 이어야 함
```

---

## 2. 넣는 순서

**주 DB 에서만, 이 순서대로 한 번씩** 합니다.

```
① 쓰기 잠깐 풀기 → ② 앱 계정 3개 (grants.sql) → ③ 테이블 (schema.sql 또는 Helm migrate Job)
   → ④ 시연 데이터 (필요할 때만)
```

**대기 DB 에는 아무것도 직접 넣지 않습니다.** 복제로 알아서 따라옵니다.

> 왜 대기 DB 에 직접 넣지 않나: 대기 DB 는 쓰기 불가이기도 하고, 직접 넣으면 복제 데이터와 어긋나 복제가 멈춥니다.

### ① 주 DB 쓰기 잠깐 풀기

my.cnf 는 쓰기 불가(ON)이므로, **주 DB 에서만** 실행 중인 서버에 대해 풉니다.

```bash
docker exec -it mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' <<'SQL'
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;
SQL
```

> 왜: 쓰기 불가 상태에서는 계정도 표도 못 만듭니다. `SET GLOBAL` 은 **지금 켜져 있는 서버에만** 적용되고 my.cnf 는 바뀌지 않아서, 재시작하면 다시 쓰기 불가로 돌아옵니다 (4장의 안전장치).

### ② 앱 계정 3개 만들기 (`db/grants.sql`)

`grants.sql` 안의 `__APP_..._PASSWORD__` 자리표시를 파일 값으로 바꿔 root 로 실행합니다. **비밀번호가 화면에 나오지 않습니다.**

```bash
cd <저장소 위치>          # db/grants.sql 이 보이는 곳
set -a; . /opt/mysql/app-passwords.env; set +a

sed -e "s/__APP_RUNTIME_PASSWORD__/${APP_RUNTIME_PASSWORD}/" \
    -e "s/__APP_READONLY_PASSWORD__/${APP_READONLY_PASSWORD}/" \
    -e "s/__APP_MIGRATE_PASSWORD__/${APP_MIGRATE_PASSWORD}/" \
    db/grants.sql \
| docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot'
```

만들어지는 계정:

| 계정 | 쓰는 곳 | 권한 |
|---|---|---|
| `app_runtime` | auth, reservation 서비스 | `hospital` 안의 SELECT·INSERT·UPDATE·DELETE |
| `app_readonly` | stats 서비스, 검증 도구 | SELECT 만 |
| `app_migrate` | 표 만들기(schema.sql) 전용. 앱은 안 씀 | CREATE·ALTER·DROP·INDEX·REFERENCES |

> 왜 3개로 나누나: 앱이 뚫려도 표를 지우거나 바꾸지 못하게, **하는 일마다 권한을 최소로** 줍니다. 세 계정 모두 `REQUIRE SSL` (TLS 아니면 접속 거절).
> 알아둘 것: 파일의 호스트 `'%'` 는 개발용입니다. 운영에서는 앱 노드 대역으로 좁히세요 (파일 맨 위 주석 참고, 예: `'app_runtime'@'10.0.%'`). 바꾼 파일은 저장하지 마세요 (비밀번호가 들어 있음).
> 순서 이유: `grants.sql` 은 `hospital` 이 아직 없어도 실행됩니다. 계정을 먼저 만들어야 ③에서 `app_migrate` 를 쓸 수 있습니다.

### ③ 테이블 만들기 (둘 중 하나)

**방법 A. 손으로: `db/schema.sql`** (app_migrate 로 실행)

```bash
cd <저장소 위치>
mysql -h <주 DB 주소> -u app_migrate -p --ssl-mode=REQUIRED < db/schema.sql
# 비밀번호는 프롬프트에 입력 (입력 글자는 화면에 안 보임)
```

**방법 B. Helm migrate Job** (쿠버네티스에서 자동으로 같은 파일 실행)

```bash
helm upgrade --install rsv helm/reservation-app -n default \
  -f helm/reservation-app/values.yaml \
  --set migrate.enabled=true
```

Job 은 Secret `reservation-app-db-migrate` 의 `client.cnf` (아래 형식)를 읽어 `app_migrate` 로 접속합니다. 이 Secret 은 IaC·보안 담당이 만듭니다 (차트가 만들지 않음).

```ini
[client]
host=<주 DB 주소>
port=3306
user=app_migrate
password=<비밀번호>
```

> 왜 앱이 아니라 따로 만드나: **앱은 시작할 때 표를 만들지 않습니다.** 표 변경 권한(`app_migrate`)은 배포 때 한 번만 쓰고, 앱 Pod 에는 넣지 않습니다.
> 주의: `schema.sql` 은 **빈 DB 용**입니다. 표가 이미 있으면 `already exists` 오류로 멈춥니다 (일부러 `IF NOT EXISTS` 를 안 썼습니다). 첫 설치 후에는 `migrate.enabled` 를 켜지 않습니다. `helm/reservation-app/files/schema.sql` 은 `db/schema.sql` 의 복사본입니다.

**이미 옛 구조의 DB 가 있으면** (진료중·완료 상태, 대기번호 UNIQUE, 전화번호 칸 `departments.phone`·`users.work_phone` 등이 없는 버전): `schema.sql` 대신 **`db/migrate_002.sql`** 을 DB 관리자 계정으로 실행합니다.

```bash
# 먼저 백업
docker exec mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot hospital' > backup_before_002.sql
# 적용 (파일 맨 위 주석의 확인 쿼리가 0건인지 먼저 볼 것)
docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot hospital' < db/migrate_002.sql
```

> **다시 실행해도 됩니다.** 이미 있는 칸·키·외래키는 건너뛰므로, 일부만 적용된 DB 도 나머지만 채우고 이미 끝난 DB 는 아무것도 바꾸지 않습니다. (전화번호 칸은 `NULL` 로 생기므로 기존 행의 값은 비어 있습니다. 시연 데이터는 아래 ④의 두 스크립트가 채웁니다.)
> 왜: 빈 DB 가 아니라서 `schema.sql` 을 쓸 수 없고, 기존 데이터를 지우지 않고 칸·제약만 더해야 합니다. 값을 채우는 UPDATE 가 있어 `app_migrate` 로는 안 되고 관리자 계정이 필요합니다. 중복 대기번호 등이 있으면 UNIQUE 추가가 멈추므로 파일 맨 위의 확인 쿼리를 먼저 돌립니다.

### ④ 시연 데이터 (시연·테스트용일 때만)

가상 데이터입니다. 실제 환자 정보가 아닙니다. 순서대로 실행합니다.

```bash
# 1) 진료과(부서 대표 번호 포함)·의사·환자(가짜 번호 포함)·예약·영수증 (root 로, 다시 실행하면 UNIQUE 오류)
docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' < db/seed.sql
```

```powershell
# 2) 로그인 계정 (PC 의 저장소 루트에서. DB_URL 은 주 DB 주소)
$env:DB_URL = "mysql://<주 DB 주소>:3306/hospital"
$env:DB_USERNAME = "app_runtime"
# DB_PASSWORD 는 프롬프트로 입력해 환경변수에 넣는다 (화면에 안 보이게). SEED_PASSWORD 도 같은 방식 (파일 안 주석 참고)
.venv\Scripts\python scripts\seed_users.py

# 3) 샘플 진료기록 (앱과 같은 MEDICAL_KEY 필요)
.venv\Scripts\python scripts\seed_records.py
```

> 가짜 번호: 부서 대표 번호 `02-0000-01xx`, 환자 `010-0000-00xx`, 직원 업무용 연락처 `02-0000-02xx` (실제로 쓰이지 않는 형식). 직원 번호(`users.work_phone`)는 2번(`seed_users.py`)이 **비어 있는 계정에만** 채웁니다. 역할별로 어떤 번호가 보이는지는 `docs/api-spec.md` 의 "전화번호 공개 범위"를 보세요.
> 왜 이 순서: 2번은 1번의 진료과·환자가 있어야 계정을 연결하고, 3번은 2번의 계정에 연결된 환자·의사가 있어야 데이터를 만듭니다. 2·3번은 다시 실행해도 쌓이지 않습니다.
> 주의: `db/seed.sql` 첫 줄 주석대로 **실제 운영 데이터가 들어갈 DB 에는 넣지 않는 것**이 원칙입니다. 시연 환경에서만 사용하세요.

### ⑤ (선택) 쓰기 다시 잠그기?

주 DB 는 **쓰기 가능으로 둡니다** (앱이 써야 하므로). 컨테이너가 재시작되면 my.cnf 때문에 다시 쓰기 불가가 되므로, 재시작 후에는 ①의 두 줄을 다시 실행해야 앱이 동작합니다 (이 부분은 운영 절차에 넣어 두세요).

---

## 3. 확인표

모두 통과해야 "넣기 끝"입니다. 아래 `mysql` 명령은 관리자 접속을 줄여 쓴 것입니다.

```bash
# 관리자 셸 (이후 SQL 을 여기에 입력)
docker exec -it mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot'
```

| # | 확인 | 실행 (어디서) | 기대 결과 |
|---|---|---|---|
| 1 | 테이블 9개 | 주 DB `SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='hospital' AND table_type='BASE TABLE';` | `9` (departments, patients, users, sessions, doctors, reservations, medical_records, receipts, audit_logs) |
| 2 | 계정 3개 | 주 DB `SELECT user, host FROM mysql.user WHERE user IN ('app_runtime','app_readonly','app_migrate');` | 3줄: `app_runtime`, `app_readonly`, `app_migrate` |
| 3 | 조회용 계정은 쓰기 거부 | 아무 PC (VPN 안) `mysql -h <주 DB 주소> -u app_readonly -p --ssl-mode=REQUIRED hospital -e "INSERT INTO departments (code,name) VALUES ('ZZ','x');"` | `ERROR 1142 ... INSERT command denied to user 'app_readonly'` |
| 4 | 대기 DB 는 쓰기 불가 | 대기 DB `SELECT @@super_read_only, @@read_only;` | `1, 1` |
| 5 | 복제 확인 (아래) | 주 DB 에 1건 쓰고 대기 DB 에서 조회 | 대기 DB 에 같은 1건이 보임 |
| 6 | 앱이 DB 에 닿음 | `curl -s -o /dev/null -w '%{http_code}\n' http://<서비스 주소>:8000/readyz` (서비스 이름은 `kubectl -n hospital get svc`) | `200` (503 이면 DB 접속 실패) |

> 왜 이 표인가: 1·2 는 **넣은 것**, 3·4 는 **막아 둔 것(권한·쓰기 불가)**, 5 는 **복제**, 6 은 **앱이 실제로 쓸 수 있는지**를 봅니다. 3 은 일부러 실패해야 정상입니다.

### 5번 복제 확인

```sql
-- 주 DB
INSERT INTO hospital.departments (code, name) VALUES ('ZZTEST', '복제확인');

-- 대기 DB (몇 초 뒤)
SELECT code, name FROM hospital.departments WHERE code = 'ZZTEST';   -- 1줄이 보여야 함

-- 확인 끝나면 주 DB 에서 지움
DELETE FROM hospital.departments WHERE code = 'ZZTEST';
```

> 왜: 계정·표·데이터가 대기 DB 까지 실제로 따라오는지는 1건을 써 봐야 알 수 있습니다. 테스트 행은 반드시 지웁니다.

---

## 4. DR(장애 전환) 때 DB 에서 하는 일

**대기 DB 를 새 주 DB 로 올리는 것**이 DB 담당의 일입니다. 앱(Helm)은 별도 단계입니다.

### 4-1. 승격 (대기 DB 에서)

```sql
STOP REPLICA;                      -- 복제 끊기 (복제 담당과 순서 합의)
SET GLOBAL super_read_only = OFF;  -- 쓰기 불가 풀기
SET GLOBAL read_only = OFF;
```

확인: `SELECT @@super_read_only, @@read_only;` → `0, 0`

> 왜: 대기 DB 는 쓰기 불가라 그대로는 앱이 예약을 저장할 수 없습니다. 복제를 먼저 끊어야 옛 주 DB 의 늦은 변경이 섞이지 않습니다.

그 뒤 앱을 켭니다 (`helm upgrade rsv helm/reservation-app -n hospital --reuse-values -f values-dr-active.yaml`, `readOnlyMode: false`). 앱이 쓰기를 허용하려면 **DB 와 앱 양쪽이 모두 풀려야** 합니다.

### 4-2. 옛 주 DB 가 다시 켜져도 쓰기 불가로 뜨는 이유

옛 주 DB 컨테이너가 장애에서 복구돼 다시 켜지면, my.cnf 에 `read_only=ON`, `super_read_only=ON` 이 있으므로 **자동으로 쓰기 불가로 시작**합니다. (`SET GLOBAL` 로 푼 것은 재시작하면 사라집니다.)

> 왜 중요한가: 옛 주 DB 가 쓰기 가능으로 켜지면, 새 주 DB 와 옛 주 DB 에 **서로 다른 데이터가 동시에 쌓입니다** (스플릿 브레인). 쓰기 불가로 뜨면 앱이 잘못 붙어도 저장이 거절되어(503 `WRITE_DISABLED`) 데이터가 갈라지지 않습니다.

### 4-3. 복귀(원래 사이트로 돌아가기) 전 재동기화

옛 주 DB 에는 **장애 이후 데이터가 없습니다.** 그대로 주 DB 로 올리면 그동안의 예약·진료기록이 사라집니다.

1. 옛 주 DB 를 **쓰기 불가 상태 그대로** 새 주 DB(현재 운영)의 대기 DB 로 다시 연결해 데이터를 따라잡게 합니다 (복제 재설정 또는 덤프 복원, 복제 담당과 진행).
2. 따라잡은 것을 확인합니다 (3장 5번과 같은 방식, 또는 표별 건수 비교).
3. 복귀 시점에 현재 운영 DB 를 쓰기 불가로 돌리고(`SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;`), 원래 DB 를 4-1 처럼 승격합니다. 앱도 같은 순서로 바꿉니다.

> 왜: 데이터는 항상 **한 방향(주 → 대기)** 으로만 흘러야 합니다. 방향을 바꿀 때는 뒤처진 쪽을 먼저 따라잡게 해야 데이터가 안 사라집니다.

---

## 5. 앱이 받는 값

앱(세 서비스)은 환경변수 세 개로 DB 에 붙습니다. Helm 에서는 `dbUrl`(values) + Secret 으로 들어갑니다.

| 이름 | 예 | 설명 |
|---|---|---|
| `DB_URL` | `mysql://<주 DB 주소>:3306/hospital` | **계정이 없는 주소.** `user:password@` 를 넣으면 앱이 시작하지 않습니다 |
| `DB_USERNAME` | `app_runtime` / `app_readonly` | 서비스별 계정 이름. 비밀이 아니라 values 의 일반 값 (`services.<이름>.dbUsername`) |
| `DB_PASSWORD` | `<비밀번호>` | 위 계정의 비밀번호 (Secret). 로그·응답에 나오지 않음 |

서비스별 계정:

| 서비스 | 계정 (`dbUsername`) | 비밀번호가 든 Helm Secret 이름 |
|---|---|---|
| auth, reservation | `app_runtime` | `reservation-app-db-runtime` |
| stats | `app_readonly` | `reservation-app-db-readonly` |

두 Secret 모두 키는 `DB_PASSWORD` 하나만 있으면 됩니다 (`DB_USERNAME` 키는 더 이상 쓰지 않음). DB 접속 주소는 `values.yaml` 의 `dbUrl:` 에 있습니다 (K8s 내부 `db-service` 주소). TLS 서버 검증을 쓰려면 CA 인증서 Secret 을 `secrets.dbCa` 에 지정합니다 (없으면 암호화만 하고 서버 검증은 안 함).

> 왜 계정을 주소와 분리했나: 주소는 사이트마다 달라지고 비밀이 아니며, 비밀번호는 Secret 으로만 다뤄야 합니다. 합쳐서 쓰면 로그·설정 파일에 비밀번호가 남습니다.

### `localhost` 를 쓰면 안 되는 이유

`DB_URL` 에 `localhost` 나 `127.0.0.1` 을 넣으면 **앱 Pod 자기 자신**을 가리킵니다. DB 는 vm2 에 있으므로 접속이 실패합니다 (`/readyz` 503). 반드시 **vm2 의 VPN 쪽 IP(또는 DNS 이름)** 를 씁니다.

> 예외: 개발자 PC 의 docker compose 는 `mysql://mysql:3306/hospital` (컨테이너 이름) 을 씁니다. 그 값은 운영에 쓰지 않습니다.

---

## 6. 자주 나는 오류와 원인

| 증상 | 원인 | 확인·해결 |
|---|---|---|
| API 가 **500** (로그에 `1146 Table 'hospital.xxx' doesn't exist`) | 2장 ③을 안 했거나 **다른 DB(대기 DB)에 넣음** | 3장 1번 쿼리로 표 9개 확인. 표는 주 DB 에서 `schema.sql` 로 |
| **1142** `... command denied to user ...` | 그 계정에 그 권한이 없음. 보통 `app_readonly` 로 쓰기를 하거나, `grants.sql` 을 안 돌림 | `SHOW GRANTS FOR 'app_runtime'@'%';` 확인. stats 는 원래 조회만 가능 |
| **503** `WRITE_DISABLED` | ① 앱의 `READ_ONLY_MODE=true` (Helm `readOnlyMode`), 또는 ② DB 가 쓰기를 거부 (`read_only`/`super_read_only`, MySQL 1290·1836·1792) | `SELECT @@super_read_only, @@read_only;` 가 `1` 이면 DB 쪽. 재시작 뒤라면 2장 ① 다시. 대기 DB 에 붙은 것이 아닌지 `DB_URL` 확인 |
| `/readyz` **503** | DB 에 못 붙음 (주소·방화벽·VPN IP·비밀번호) | `DB_URL` 이 `localhost` 인지, 3306 이 VPN IP 로 열렸는지 확인 |
| **1045** Access denied | 비밀번호 틀림 / 계정 호스트가 안 맞음 (`'%'` 대신 좁혔는데 앱 노드 대역 밖) | Secret 값과 `SELECT user, host FROM mysql.user;` 비교 |
| **3159** / **1045** / TLS 오류 | 계정은 TLS 만 허용 (`REQUIRE SSL`). TLS 없이 접속하면 비밀번호가 맞아도 1045 로 거절될 수 있음 | 클라이언트에 `--ssl-mode=REQUIRED`. 앱은 자동으로 TLS 사용 |
| 앱이 시작하지 않음 (`DB_URL 에는 계정을 넣지 않습니다`) | `DB_URL` 에 `user:password@` 가 들어감 | 주소만 남기고 계정은 Secret 으로 |
| `schema.sql` 이 `already exists` 로 멈춤 | 이미 표가 있는 DB | 옛 구조면 `migrate_002.sql`, 정상 설치된 DB 면 다시 실행하지 않음 |
