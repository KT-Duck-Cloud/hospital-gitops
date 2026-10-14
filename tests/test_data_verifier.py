"""tools/data_verifier.py verify: 일부러 1건 지우고 1건 바꾼 DB 에서 누락 1, 불일치 1 이 나와야 한다.

DB 는 임시 SQLite (reservations 표의 검증에 쓰는 칸만). 접속 주소는 환경변수 VERIFIER_DB_URL 로만 넘긴다.
"""
import importlib.util
import json
import sqlite3
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("data_verifier", ROOT / "tools" / "data_verifier.py")
dv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dv)

N = 6


def record_line(i: int, status: int = 201) -> dict:
    ok = 200 <= status < 300
    return {
        "run_id": "run-test", "seq": i, "login_id": "director01", "stage": "reserve", "role": "DIRECTOR",
        "request_id": f"req-{i}", "request_at": f"2026-10-15T01:00:{i:02d}.000Z",
        "response_at": f"2026-10-15T01:00:{i:02d}.200Z", "http_status": status,
        "reservation_id": 100 + i if ok else None, "patient_id": 1, "department_id": 2,
        "reserved_at": f"2026-10-20T0{i % 9}:00:00Z", "error": None if ok else "DB_UNAVAILABLE",
    }


@pytest.fixture()
def drill(tmp_path, monkeypatch):
    """성공 6건 + 503 1건을 기록하고, 성공 6건을 DB 에 넣어 둔다."""
    lines = [record_line(i) for i in range(1, N + 1)] + [record_line(N + 1, status=503)]
    jsonl = tmp_path / "drill.jsonl"
    jsonl.write_text("".join(json.dumps(ln) + "\n" for ln in lines), encoding="utf-8")
    db = tmp_path / "db.sqlite"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE reservations (id INTEGER PRIMARY KEY, request_id VARCHAR(64) UNIQUE, patient_id INT, "
                "department_id INT, reserved_at DATETIME, status VARCHAR(20))")
    for ln in lines[:N]:
        con.execute("INSERT INTO reservations VALUES (?,?,?,?,?, 'BOOKED')",
                    (ln["reservation_id"], ln["request_id"], 1, 2, ln["reserved_at"].replace("T", " ").rstrip("Z")))
    con.commit()
    monkeypatch.setenv("VERIFIER_DB_URL", f"sqlite:///{db}")
    yield jsonl, con, tmp_path
    con.close()


def run_verify(jsonl, report):
    code = dv.main(["verify", "--in", str(jsonl), "--report", str(report)])
    return code, json.loads(Path(str(report) + ".json").read_text(encoding="utf-8"))


def test_clean_db_has_no_loss(drill):
    jsonl, _, tmp = drill
    code, r = run_verify(jsonl, tmp / "clean")
    assert code == 0 and r["ok"]
    assert (r["success"], r["found"], r["missing"], r["duplicate"], r["mismatch"], r["rpo_seconds"]) == (N, N, 0, 0, 0, 0)
    assert r["requests"] == N + 1 and r["status_counts"] == {"201": N, "503": 1}


def test_one_deleted_one_changed(drill):
    jsonl, con, tmp = drill
    con.execute("DELETE FROM reservations WHERE request_id = 'req-4'")                                # 누락
    con.execute("UPDATE reservations SET reserved_at = '2026-11-01 05:00:00' WHERE request_id = 'req-2'")  # 불일치
    con.commit()

    code, r = run_verify(jsonl, tmp / "broken")
    assert code == 1 and not r["ok"]
    assert (r["missing"], r["mismatch"], r["duplicate"]) == (1, 1, 0)
    assert r["details"]["missing"][0]["request_id"] == "req-4"
    assert r["details"]["mismatch"][0]["request_id"] == "req-2"
    assert r["details"]["mismatch"][0]["fields"] == ["reserved_at"]
    # RPO: 마지막 누락 응답(req-4, 01:00:04.200) - 그 직전 DB 에 남은 성공(req-3, 01:00:03.200) = 1초
    assert r["rpo_seconds"] == 1.0
    assert r["loss_window"]["last_saved_before_loss"] == "2026-10-15T01:00:03.200Z"

    text = (tmp / "broken.md").read_text(encoding="utf-8")
    assert "누락 (성공 응답인데 DB 에 없음) | 1" in text and "불일치 (DB 값이 응답과 다름) | 1" in text
    assert "sqlite:///" not in text and "sqlite:///" not in json.dumps(r)  # 접속 정보는 보고서에 없다


def test_unacknowledged_but_saved_is_reported(drill):
    """503 을 받았지만 실제로는 저장된 요청: 누락이 아니라 참고 건수로 센다."""
    jsonl, con, tmp = drill
    con.execute("INSERT INTO reservations VALUES (999, 'req-7', 1, 2, '2026-10-20 07:00:00', 'BOOKED')")
    con.commit()
    code, r = run_verify(jsonl, tmp / "ghost")
    assert code == 0 and r["unacknowledged_saved"] == 1


def test_verify_requires_db_url_env(drill, monkeypatch):
    jsonl, _, tmp = drill
    monkeypatch.delenv("VERIFIER_DB_URL")
    with pytest.raises(SystemExit):
        dv.main(["verify", "--in", str(jsonl)])
