"""배포 설정 확인: 세 서비스 이미지의 uvicorn 실행 줄과 Helm 의 FORWARDED_ALLOW_IPS.

실행: 저장소 루트에서  pytest tests
"""
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ["auth", "reservation", "stats"]
CHART = ROOT / "helm" / "reservation-app"


def dockerfile(service: str) -> Path:
    """reservation-app 은 services/<이름>/Dockerfile, hospital-gitops 는 옆 폴더 ../hospital-backend-<이름>/Dockerfile."""
    for path in (ROOT / "services" / service / "Dockerfile", ROOT.parent / f"hospital-backend-{service}" / "Dockerfile"):
        if path.is_file():
            return path
    pytest.skip(f"{service} Dockerfile 이 없음 (hospital-backend-{service} 를 옆 폴더에 clone 하면 확인한다)")


def cmd_of(service: str) -> list[str]:
    text = dockerfile(service).read_text(encoding="utf-8")
    line = [ln for ln in text.splitlines() if ln.startswith("CMD ")][-1]
    return json.loads(line[len("CMD "):])


@pytest.mark.parametrize("service", SERVICES)
def test_dockerfile_runs_uvicorn_with_proxy_headers(service):
    text = dockerfile(service).read_text(encoding="utf-8")
    assert re.search(r"^\s+FORWARDED_ALLOW_IPS=127\.0\.0\.1$", text, re.M)  # 이미지 기본값
    cmd = cmd_of(service)
    assert cmd[:2] == ["sh", "-c"]
    script = cmd[2]
    assert script.startswith("exec uvicorn ")  # exec: uvicorn 이 PID 1 로 SIGTERM 을 받는다
    assert "--proxy-headers" in script
    assert '--forwarded-allow-ips "${FORWARDED_ALLOW_IPS:-127.0.0.1}"' in script
    assert "--timeout-graceful-shutdown 20" in script


@pytest.mark.skipif(not shutil.which("sh"), reason="sh 가 없음")
@pytest.mark.parametrize("env_value, expected", [
    (None, "127.0.0.1"),                    # 환경변수 없음
    ("", "127.0.0.1"),                      # 비어 있음
    ("10.42.0.0/24,10.42.1.7", "10.42.0.0/24,10.42.1.7"),
    ("10.0.0.1; rm -rf /", "10.0.0.1; rm -rf /"),  # 따옴표 안이라 명령으로 실행되지 않고 값 하나로 넘어간다
])
def test_cmd_passes_forwarded_allow_ips_from_env(env_value, expected):
    """CMD 의 sh 스크립트를 그대로 돌리되 uvicorn 대신 인자를 출력하게 해서, 실제로 넘어가는 값을 본다."""
    script = cmd_of("auth")[2].replace("exec uvicorn ", "exec printf '%s\\n' ", 1)
    env = {k: v for k, v in os.environ.items() if k != "FORWARDED_ALLOW_IPS"}
    if env_value is not None:
        env["FORWARDED_ALLOW_IPS"] = env_value
    out = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True, encoding="utf-8",
                         check=True).stdout.splitlines()
    assert out[out.index("--forwarded-allow-ips") + 1] == expected
    assert "--proxy-headers" in out


def _helm(*args: str) -> str:
    tags = [f"--set=services.{s}.image.tag=t" for s in [*SERVICES, "web"]]  # web(화면)도 tag 가 필요하다
    return subprocess.run(["helm", "template", "rsv", str(CHART), "-f", str(CHART / "values-onprem.yaml"), *tags,
                           *args], capture_output=True, text=True, encoding="utf-8", check=True).stdout


def _forwarded_values(rendered: str) -> list[str]:
    return re.findall(r"- name: FORWARDED_ALLOW_IPS\n\s+value: \"([^\"]*)\"", rendered)


@pytest.mark.skipif(not shutil.which("helm"), reason="helm 이 없음")
def test_helm_forwarded_allow_ips_default_and_override():
    assert _forwarded_values(_helm()) == ["127.0.0.1"] * 3  # 세 서비스 모두 기본값
    assert _forwarded_values(_helm("--set=forwardedAllowIps=10.42.0.0/24")) == ["10.42.0.0/24"] * 3
    assert _forwarded_values(_helm("--set=forwardedAllowIps=")) == ["127.0.0.1"] * 3  # 비우면 기본값


GRACEFUL_SHUTDOWN_SECONDS = 20  # 서비스 Dockerfile 의 --timeout-graceful-shutdown


@pytest.mark.skipif(not shutil.which("helm"), reason="helm 이 없음")
@pytest.mark.parametrize("values", ["values-onprem.yaml", "values-aws.yaml"])
def test_helm_termination_grace_covers_graceful_shutdown(values):
    """preStop 대기 + uvicorn 종료 대기(20초) 가 terminationGracePeriodSeconds 안에 끝나야 처리 중 요청이 끊기지 않는다."""
    tags = [f"--set=services.{s}.image.tag=t" for s in [*SERVICES, "web"]]
    out = subprocess.run(["helm", "template", "rsv", str(CHART), "-f", str(CHART / values), *tags],
                         capture_output=True, text=True, encoding="utf-8", check=True).stdout
    graces = [int(v) for v in re.findall(r"terminationGracePeriodSeconds: (\d+)", out)]
    sleeps = [int(v) for v in re.findall(r'command: \["sleep", "(\d+)"\]', out)]
    assert len(graces) == len(sleeps) == 4  # API 3개 + web
    for grace, pre_stop in zip(graces, sleeps):
        assert pre_stop + GRACEFUL_SHUTDOWN_SECONDS < grace
    for name in ("DB_POOL_SIZE", "DB_MAX_OVERFLOW", "DB_POOL_TIMEOUT", "DB_POOL_RECYCLE"):
        assert len(re.findall(rf"- name: {name}\n", out)) == 3  # API 서비스 3개에만 (web 은 DB 를 쓰지 않는다)
