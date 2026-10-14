"""데이터 검증 도구 (장애 전환·복구 훈련용). 표준 라이브러리 + SQLAlchemy·PyMySQL(requirements.txt)만 쓴다.

두 가지 모드
1) record : 서비스 주소로 예약 요청을 계속 보내고, 결과를 JSONL 로 한 줄씩 남긴다.
            역할별 테스트 계정을 돌아가며 쓰고, 요청마다 새 X-Request-ID(UUID)를 만든다 (재시도하지 않는다).
2) verify : JSONL 의 성공(2xx) 요청을 request_id 로 DB 에서 찾아 누락·중복·불일치 건수와 손실 시간(RPO)을 계산하고
            JSON 보고서와 사람이 읽는 보고서(Markdown)를 만든다. DB 는 조회 전용 계정(app_readonly)으로 읽는다.

접속 정보는 환경변수로만 받는다 (명령줄·파일에 쓰지 않는다. 출력·보고서에도 남기지 않는다)
  record : VERIFIER_BASE_URL   예약 API 주소 (예: http://localhost:8080 — web nginx 또는 Ingress)
           VERIFIER_AUTH_URL   로그인 API 주소. 없으면 VERIFIER_BASE_URL (compose 에서 포트가 다를 때만)
           VERIFIER_PASSWORD   테스트 계정 비밀번호 (scripts/seed_users.py 의 SEED_PASSWORD)
           VERIFIER_LOGIN_IDS  쓸 계정, 쉼표로 (기본: patient01,nurse_im01,director01,tester01 — 예약 생성 권한이 있는 역할)
  verify : VERIFIER_DB_URL       계정 없는 DB 주소 (예: mysql://호스트:3306/hospital)
           VERIFIER_DB_USERNAME  조회 전용 계정 (app_readonly)
           VERIFIER_DB_PASSWORD  그 비밀번호
           VERIFIER_DB_SSL_CA    DB TLS CA 파일 (없으면 TLS 암호화만, 서버 검증 안 함)

실행 예 (PowerShell, 저장소 루트)
  $env:VERIFIER_BASE_URL = "http://localhost:8080"
  $p = Read-Host "VERIFIER_PASSWORD" -AsSecureString
  $env:VERIFIER_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p))
  .venv\\Scripts\\python tools\\data_verifier.py record --out drill.jsonl --interval 0.5          # Ctrl+C 로 멈춤
  $env:VERIFIER_DB_URL = "mysql://127.0.0.1:3306/hospital"
  $env:VERIFIER_DB_USERNAME = "app_readonly"
  $d = Read-Host "VERIFIER_DB_PASSWORD" -AsSecureString
  $env:VERIFIER_DB_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($d))
  .venv\\Scripts\\python tools\\data_verifier.py verify --in drill.jsonl --report drill-report      # drill-report.json / .md

손실 시간(RPO) 계산
  성공 응답을 받았는데 DB 에 없는(누락) 요청들의 응답 시각 범위를 본다.
  RPO = 마지막 누락 요청의 응답 시각 - (첫 누락 직전에 DB 에 남아 있는 마지막 성공 요청의 응답 시각)
  첫 누락보다 앞선 성공 요청이 없으면 첫 누락 요청의 요청 시각을 기준으로 쓴다. 누락이 없으면 0.
"""
import argparse
import json
import os
import random
import signal
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

DEFAULT_LOGIN_IDS = "patient01,nurse_im01,director01,tester01"
HTTP_TIMEOUT_SECONDS = 10
SLOT = timedelta(minutes=30)
QUERY_CHUNK = 500


# ---------------------------------------------------------------- 공통

def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_utc(value) -> datetime | None:
    """'2026-10-20T01:00:00Z' · '2026-10-20 01:00:00' · datetime → 시간대 없는 UTC datetime (초 단위)"""
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        dt = value
    else:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt.replace(microsecond=0)


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"환경변수 {name} 가 필요합니다.")
    return value


# ---------------------------------------------------------------- record

class Api:
    """아주 작은 HTTP 클라이언트 (토큰은 메모리에만 둔다)."""

    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def call(self, method: str, path: str, token: str | None = None, body: dict | None = None,
             headers: dict | None = None) -> tuple[int | None, dict | None, str | None]:
        """(HTTP 상태, JSON 본문, 연결 오류 종류). 연결이 안 되면 상태는 None."""
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base_url + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as r:
                return r.status, _json_or_none(r.read()), None
        except urllib.error.HTTPError as e:
            return e.code, _json_or_none(e.read()), None
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            reason = getattr(e, "reason", e)
            return None, None, type(reason).__name__


def _json_or_none(raw: bytes):
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        return None


class Account:
    def __init__(self, login_id: str):
        self.login_id = login_id
        self.token: str | None = None
        self.role: str | None = None
        self.department_id: int | None = None
        self.patient_id: int | None = None


class Recorder:
    def __init__(self, api: Api, auth: Api, password: str, login_ids: list[str], run_id: str, out, rng: random.Random):
        self.api, self.auth, self.password = api, auth, password
        self.accounts = [Account(i) for i in login_ids]
        self.run_id, self.out, self.rng = run_id, out, rng
        self.department_ids: list[int] = []
        self.patient_ids: list[int] = []
        self.base_time = (utc_now() + timedelta(days=1)).replace(minute=0, second=0, microsecond=0)
        self.seq = 0

    def login(self, acc: Account) -> tuple[int | None, str | None]:
        status, body, conn_err = self.auth.call("POST", "/api/v1/auth/login",
                                                body={"login_id": acc.login_id, "password": self.password})
        if status == 200 and body:
            acc.token = body["access_token"]
            user = body.get("user") or {}
            acc.role, acc.department_id, acc.patient_id = user.get("role"), user.get("department_id"), user.get("patient_id")
            return status, None
        acc.token = None
        return status, (body or {}).get("code") or conn_err or "LOGIN_FAILED"

    def load_choices(self, acc: Account) -> None:
        """진료과(진료 중인 의사가 있는 곳)와 환자 목록. 직원 계정 토큰으로 한 번만 읽는다."""
        if not self.department_ids:
            status, doctors, _ = self.api.call("GET", "/api/v1/doctors", acc.token)
            if status == 200 and doctors:
                self.department_ids = sorted({d["department_id"] for d in doctors})
        if not self.patient_ids and acc.role in ("NURSE", "DIRECTOR", "TESTER"):
            q = urllib.parse.urlencode({"q": os.environ.get("VERIFIER_PATIENT_QUERY", "C"), "size": 50})
            status, page, _ = self.api.call("GET", f"/api/v1/patients?{q}", acc.token)
            if status == 200 and page:
                self.patient_ids = [p["id"] for p in page.get("items", [])]

    def payload(self, acc: Account) -> dict | None:
        if acc.role == "NURSE":
            department_id = acc.department_id  # 간호사는 자기 부서만 예약할 수 있다
        elif self.department_ids:
            department_id = self.rng.choice(self.department_ids)
        else:
            return None
        if acc.role == "PATIENT":
            patient_id = acc.patient_id
        elif self.patient_ids:
            patient_id = self.rng.choice(self.patient_ids)
        else:
            return None
        # 의사를 지정하지 않는다 (같은 의사·같은 시간 409 를 피해 저장 경로만 본다). 30분 칸을 차례로 쓴다.
        reserved_at = self.base_time + SLOT * (self.seq % (60 * 48))
        body = {"department_id": department_id, "reserved_at": iso(reserved_at).replace(".000Z", "Z"),
                "visit_type": "RETURN", "memo": f"data_verifier {self.run_id}"}
        if acc.role != "PATIENT":
            body["patient_id"] = patient_id
        return body

    def write(self, line: dict) -> None:
        self.out.write(json.dumps(line, ensure_ascii=False) + "\n")
        self.out.flush()

    def step(self) -> dict:
        """예약 요청 1번 (필요하면 먼저 로그인). JSONL 한 줄을 쓰고 돌려준다."""
        self.seq += 1
        acc = self.accounts[(self.seq - 1) % len(self.accounts)]
        base = {"run_id": self.run_id, "seq": self.seq, "login_id": acc.login_id}
        if acc.token is None:
            started = utc_now()
            status, err = self.login(acc)
            if acc.token is None:
                line = {**base, "stage": "login", "role": None, "request_id": None, "request_at": iso(started),
                        "response_at": iso(utc_now()), "http_status": status, "error": err}
                self.write(line)
                return line
            self.load_choices(acc)
        body = self.payload(acc)
        if body is None:
            self.load_choices(acc)
            body = self.payload(acc)
        request_id = str(uuid.uuid4())  # 매 요청 새 값
        started = utc_now()
        if body is None:
            status, out, err = None, None, "NO_TARGET"  # 진료과·환자를 아직 못 읽음 (다른 직원 계정이 읽으면 풀린다)
        else:
            status, out, err = self.api.call("POST", "/api/v1/reservations", acc.token, body,
                                             headers={"X-Request-ID": request_id})
        finished = utc_now()
        if status == 401:
            acc.token = None  # 세션 만료·DB 전환 뒤: 다음 차례에 다시 로그인
        ok = status is not None and 200 <= status < 300 and isinstance(out, dict)
        line = {
            **base, "stage": "reserve", "role": acc.role, "request_id": request_id,
            "request_at": iso(started), "response_at": iso(finished), "http_status": status,
            "reservation_id": out.get("id") if ok else None,
            "patient_id": out.get("patient_id") if ok else (body or {}).get("patient_id", acc.patient_id),
            "department_id": out.get("department_id") if ok else (body or {}).get("department_id"),
            "reserved_at": out.get("reserved_at") if ok else (body or {}).get("reserved_at"),
            "error": None if ok else ((out or {}).get("code") or err or f"HTTP_{status}"),
        }
        self.write(line)
        return line


def cmd_record(args) -> int:
    base_url = require_env("VERIFIER_BASE_URL")
    auth_url = os.environ.get("VERIFIER_AUTH_URL", "").strip() or base_url
    password = require_env("VERIFIER_PASSWORD")
    login_ids = [s.strip() for s in os.environ.get("VERIFIER_LOGIN_IDS", DEFAULT_LOGIN_IDS).split(",") if s.strip()]
    run_id = args.run_id or utc_now().strftime("run-%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:6]

    stop = {"flag": False}
    previous_handler = signal.signal(signal.SIGINT, lambda *_: stop.update(flag=True))  # Ctrl+C: 지금 요청을 마치고 멈춤
    deadline = time.monotonic() + args.duration if args.duration else None
    counts: dict[str, int] = {}
    try:
        _record_loop(args, base_url, auth_url, password, login_ids, run_id, stop, deadline, counts)
    finally:
        signal.signal(signal.SIGINT, previous_handler)
    return 0


def _record_loop(args, base_url, auth_url, password, login_ids, run_id, stop, deadline, counts) -> None:
    with open(args.out, "a", encoding="utf-8") as out:
        rec = Recorder(Api(base_url), Api(auth_url), password, login_ids, run_id, out, random.Random(args.seed))
        print(f"record: run_id={run_id} out={args.out} accounts={len(login_ids)} (Ctrl+C 로 멈춤)", file=sys.stderr)
        while not stop["flag"]:
            if args.count and rec.seq >= args.count:
                break
            if deadline and time.monotonic() >= deadline:
                break
            line = rec.step()
            key = str(line["http_status"])
            counts[key] = counts.get(key, 0) + 1
            time.sleep(args.interval)
    print(f"record 끝: {rec.seq}건, 상태별 {counts}", file=sys.stderr)


# ---------------------------------------------------------------- verify

def load_lines(paths: list[str], run_id: str | None) -> list[dict]:
    lines = []
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for n, raw in enumerate(f, 1):
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    line = json.loads(raw)
                except ValueError:
                    sys.exit(f"{path}:{n} JSON 형식이 아닙니다")
                if run_id and line.get("run_id") != run_id:
                    continue
                lines.append(line)
    return lines


def database_url(db_url: str, username: str, password: str):
    """계정 없는 주소 + 계정 → SQLAlchemy URL (str/repr 해도 비밀번호는 *** 로 가려진다). 오류에 값을 넣지 않는다."""
    from sqlalchemy import make_url
    from sqlalchemy.exc import ArgumentError

    try:
        url = make_url(db_url)
    except ArgumentError:
        sys.exit("VERIFIER_DB_URL 형식이 잘못되었습니다. 예) mysql://호스트:3306/hospital")
    if url.username or url.password:
        sys.exit("VERIFIER_DB_URL 에는 계정을 넣지 않습니다. VERIFIER_DB_USERNAME·VERIFIER_DB_PASSWORD 로 넣으세요.")
    backend = url.get_backend_name()
    if backend == "sqlite":  # 테스트용
        return url
    if backend != "mysql":
        sys.exit("VERIFIER_DB_URL 은 mysql:// 만 지원합니다.")
    if not username or not password:
        sys.exit("환경변수 VERIFIER_DB_USERNAME·VERIFIER_DB_PASSWORD 가 필요합니다.")
    return url.set(drivername="mysql+pymysql", username=username, password=password,
                   query={"charset": "utf8mb4", **url.query})


def make_engine(url):
    from sqlalchemy import create_engine
    from sqlalchemy.pool import NullPool

    connect_args = {}
    if url.get_backend_name() == "mysql":
        ca = os.environ.get("VERIFIER_DB_SSL_CA", "").strip()
        ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
        if not ca:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        connect_args = {"ssl": ctx, "init_command": "SET time_zone = '+00:00'"}
    return create_engine(url, connect_args=connect_args, poolclass=NullPool, hide_parameters=True)


def fetch_rows(engine, request_ids: list[str]) -> dict[str, list[dict]]:
    """request_id → DB 행 목록 (조회만)."""
    from sqlalchemy import bindparam, text

    stmt = text("SELECT id, request_id, patient_id, department_id, reserved_at, status FROM reservations "
                "WHERE request_id IN :ids").bindparams(bindparam("ids", expanding=True))
    found: dict[str, list[dict]] = {}
    with engine.connect() as conn:
        for i in range(0, len(request_ids), QUERY_CHUNK):
            for row in conn.execute(stmt, {"ids": request_ids[i:i + QUERY_CHUNK]}).mappings():
                found.setdefault(row["request_id"], []).append(dict(row))
    return found


def compare(line: dict, row: dict) -> list[str]:
    """기록과 DB 가 다른 칸 이름들"""
    diffs = []
    if line.get("reservation_id") is not None and int(row["id"]) != int(line["reservation_id"]):
        diffs.append("reservation_id")
    if line.get("patient_id") is not None and int(row["patient_id"]) != int(line["patient_id"]):
        diffs.append("patient_id")
    if line.get("department_id") is not None and int(row["department_id"]) != int(line["department_id"]):
        diffs.append("department_id")
    if line.get("reserved_at") and parse_utc(row["reserved_at"]) != parse_utc(line["reserved_at"]):
        diffs.append("reserved_at")
    return diffs


def build_report(lines: list[dict], found: dict[str, list[dict]]) -> dict:
    reserve = [ln for ln in lines if ln.get("stage", "reserve") == "reserve"]
    success = [ln for ln in reserve if ln.get("http_status") and 200 <= int(ln["http_status"]) < 300]
    success.sort(key=lambda ln: (ln["response_at"], ln.get("seq", 0)))
    missing, mismatched, duplicated = [], [], []
    for ln in success:
        rows = found.get(ln["request_id"], [])
        if not rows:
            missing.append(ln)
            continue
        if len(rows) > 1:
            duplicated.append({"request_id": ln["request_id"], "db_rows": len(rows)})
        diffs = compare(ln, rows[0])
        if diffs:
            mismatched.append({"request_id": ln["request_id"], "fields": diffs,
                               "recorded": {k: ln.get(k) for k in ("reservation_id", "patient_id", "department_id", "reserved_at")},
                               "db": {"reservation_id": rows[0]["id"], "patient_id": rows[0]["patient_id"],
                                      "department_id": rows[0]["department_id"],
                                      "reserved_at": str(parse_utc(rows[0]["reserved_at"]))}})
    # 응답은 실패·없음이었는데 DB 에는 저장된 요청 (연결 끊김 중 COMMIT 등). 누락은 아니지만 알려 준다.
    unacknowledged_saved = [ln["request_id"] for ln in reserve
                            if not (ln.get("http_status") and 200 <= int(ln["http_status"]) < 300)
                            and ln.get("request_id") in found]

    rpo_seconds, loss_window = 0.0, None
    if missing:
        missing_ids = {m["request_id"] for m in missing}
        first, last = missing[0], missing[-1]
        before = [ln for ln in success
                  if ln["request_id"] not in missing_ids and ln["response_at"] <= first["response_at"]]
        anchor = before[-1]["response_at"] if before else first["request_at"]
        rpo_seconds = round((parse_iso_full(last["response_at"]) - parse_iso_full(anchor)).total_seconds(), 3)
        loss_window = {"last_saved_before_loss": anchor, "first_lost": first["response_at"], "last_lost": last["response_at"]}

    statuses: dict[str, int] = {}
    for ln in reserve:
        key = str(ln.get("http_status"))
        statuses[key] = statuses.get(key, 0) + 1
    times = [ln["request_at"] for ln in reserve if ln.get("request_at")]
    return {
        "generated_at": iso(utc_now()),
        "run_ids": sorted({ln.get("run_id") for ln in lines if ln.get("run_id")}),
        "period": {"from": min(times) if times else None, "to": max(times) if times else None},
        "requests": len(reserve),
        "status_counts": statuses,
        "success": len(success),
        "found": len(success) - len(missing),
        "missing": len(missing),
        "duplicate": len(duplicated),
        "mismatch": len(mismatched),
        "unacknowledged_saved": len(unacknowledged_saved),
        "rpo_seconds": rpo_seconds,
        "loss_window": loss_window,
        "details": {
            "missing": [{k: m.get(k) for k in ("request_id", "seq", "login_id", "response_at", "reservation_id")} for m in missing],
            "duplicate": duplicated,
            "mismatch": mismatched,
            "unacknowledged_saved": unacknowledged_saved,
        },
        "ok": not missing and not duplicated and not mismatched,
    }


def parse_iso_full(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def render_text(report: dict) -> str:
    r = report
    lines = [
        "# 데이터 검증 보고서",
        "",
        f"- 만든 시각(UTC): {r['generated_at']}",
        f"- 회차: {', '.join(r['run_ids']) or '-'}",
        f"- 기간(UTC): {r['period']['from']} ~ {r['period']['to']}",
        f"- 결과: **{'이상 없음' if r['ok'] else '확인 필요'}**",
        "",
        "| 항목 | 건수 |",
        "|---|---|",
        f"| 예약 요청 | {r['requests']} |",
        f"| 성공 응답(2xx) | {r['success']} |",
        f"| DB 에서 찾음 | {r['found']} |",
        f"| 누락 (성공 응답인데 DB 에 없음) | {r['missing']} |",
        f"| 중복 (같은 request_id 가 여러 행) | {r['duplicate']} |",
        f"| 불일치 (DB 값이 응답과 다름) | {r['mismatch']} |",
        f"| 참고: 실패·무응답인데 DB 에 저장됨 | {r['unacknowledged_saved']} |",
        "",
        f"응답 상태별: {', '.join(f'{k}={v}' for k, v in sorted(r['status_counts'].items())) or '-'}",
        "",
        f"## 손실 시간 (RPO): {r['rpo_seconds']}초",
    ]
    if r["loss_window"]:
        w = r["loss_window"]
        lines += [f"- 손실 직전 마지막 저장 확인: {w['last_saved_before_loss']}",
                  f"- 첫 누락 응답: {w['first_lost']}", f"- 마지막 누락 응답: {w['last_lost']}"]
    if r["details"]["missing"]:
        lines += ["", "## 누락", ""] + [f"- {m['request_id']} (seq {m['seq']}, {m['login_id']}, 응답 {m['response_at']}, "
                                         f"예약번호 {m['reservation_id']})" for m in r["details"]["missing"]]
    if r["details"]["mismatch"]:
        lines += ["", "## 불일치", ""] + [f"- {m['request_id']}: {', '.join(m['fields'])} (기록 {m['recorded']} / DB {m['db']})"
                                          for m in r["details"]["mismatch"]]
    if r["details"]["duplicate"]:
        lines += ["", "## 중복", ""] + [f"- {d['request_id']}: DB {d['db_rows']}행" for d in r["details"]["duplicate"]]
    return "\n".join(lines) + "\n"


def cmd_verify(args) -> int:
    url = database_url(require_env("VERIFIER_DB_URL"), os.environ.get("VERIFIER_DB_USERNAME", "").strip(),
                       os.environ.get("VERIFIER_DB_PASSWORD", ""))
    lines = load_lines(args.inputs, args.run_id)
    request_ids = sorted({ln["request_id"] for ln in lines if ln.get("request_id")})
    engine = make_engine(url)
    try:
        found = fetch_rows(engine, request_ids)
    finally:
        engine.dispose()
    report = build_report(lines, found)
    text = render_text(report)
    if args.report:
        with open(args.report + ".json", "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        with open(args.report + ".md", "w", encoding="utf-8") as f:
            f.write(text)
    sys.stdout.write(text)
    return 0 if report["ok"] else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="예약 데이터 기록·검증 (접속 정보는 환경변수로만 받는다)")
    sub = parser.add_subparsers(dest="mode", required=True)
    rec = sub.add_parser("record", help="예약 요청을 보내며 JSONL 로 기록")
    rec.add_argument("--out", required=True, help="JSONL 파일 (이어 쓴다)")
    rec.add_argument("--run-id", help="회차 ID (기본: 시각+무작위)")
    rec.add_argument("--interval", type=float, default=0.5, help="요청 간격(초)")
    rec.add_argument("--count", type=int, default=0, help="이만큼 보내고 멈춤 (0=무제한)")
    rec.add_argument("--duration", type=float, default=0, help="이 시간(초) 뒤 멈춤 (0=무제한)")
    rec.add_argument("--seed", type=int, default=None, help="진료과·환자 선택 난수 시드")
    ver = sub.add_parser("verify", help="JSONL 과 DB 를 비교해 보고서 작성")
    ver.add_argument("--in", dest="inputs", nargs="+", required=True, help="JSONL 파일 (여러 개 가능)")
    ver.add_argument("--run-id", help="이 회차만 검증")
    ver.add_argument("--report", help="보고서 파일 이름 앞부분 (<이름>.json, <이름>.md)")
    args = parser.parse_args(argv)
    return cmd_record(args) if args.mode == "record" else cmd_verify(args)


if __name__ == "__main__":
    sys.exit(main())
