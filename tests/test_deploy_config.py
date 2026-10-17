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


def _hospital_phone_by_deployment(rendered: str) -> dict[str, str | None]:
    """렌더된 Deployment 마다 HOSPITAL_PHONE env 값 (없으면 None) → {Deployment 이름: 값}."""
    out = {}
    for doc in rendered.split("\n---\n"):
        m = re.search(r"kind: Deployment\nmetadata:\n\s+name: (\S+)", doc)
        if not m:
            continue
        v = re.search(r"- name: HOSPITAL_PHONE\n\s+value: \"([^\"]*)\"", doc)
        out[m.group(1)] = v.group(1) if v else None
    return out


@pytest.mark.skipif(not shutil.which("helm"), reason="helm 이 없음")
def test_helm_hospital_phone_env_only_in_reservation():
    """values.yaml 의 hospitalPhone(가짜 번호)이 예약 서비스 Deployment 의 HOSPITAL_PHONE 로만 들어간다."""
    got = _hospital_phone_by_deployment(_helm())
    assert len(got) == 4  # API 3개 + web
    with_phone = {name: v for name, v in got.items() if v is not None}
    assert len(with_phone) == 1
    (name, value), = with_phone.items()
    assert "reservation" in name and "auth" not in name and "stats" not in name
    assert value == "02-0000-0000"
    # 배포 담당이 --set 으로 운영 값을 넣을 수 있다
    assert list(v for v in _hospital_phone_by_deployment(_helm("--set=hospitalPhone=02-1234-5678")).values()
                if v) == ["02-1234-5678"]


def _env_by_deployment(rendered: str) -> dict[str, dict[str, str]]:
    """렌더된 API Deployment 마다 {env 이름: 'value:<값>' 또는 'secret:<Secret 이름>/<키>'}."""
    out = {}
    for doc in rendered.split("\n---\n"):
        m = re.search(r"kind: Deployment\nmetadata:\n\s+name: (\S+)", doc)
        if not m:
            continue
        env = {}
        for e in re.finditer(r"- name: (\w+)\n(\s+)(value: \"([^\"]*)\"|valueFrom:\n\s+secretKeyRef:\n\s+name: (\S+)\n\s+key: (\S+))", doc):
            env[e.group(1)] = f"value:{e.group(4)}" if e.group(4) is not None else f"secret:{e.group(5)}/{e.group(6)}"
        out[m.group(1)] = env
    return out


@pytest.mark.skipif(not shutil.which("helm"), reason="helm 이 없음")
def test_helm_db_username_is_plain_value_and_only_password_is_secret():
    got = _env_by_deployment(_helm())
    by_svc = {s: next(env for name, env in got.items() if name.endswith(s) or s in name) for s in SERVICES}
    assert by_svc["auth"]["DB_USERNAME"] == "value:app_runtime"
    assert by_svc["reservation"]["DB_USERNAME"] == "value:app_runtime"
    assert by_svc["stats"]["DB_USERNAME"] == "value:app_readonly"
    assert by_svc["auth"]["DB_PASSWORD"] == "secret:reservation-app-db-runtime/DB_PASSWORD"
    assert by_svc["reservation"]["DB_PASSWORD"] == "secret:reservation-app-db-runtime/DB_PASSWORD"
    assert by_svc["stats"]["DB_PASSWORD"] == "secret:reservation-app-db-readonly/DB_PASSWORD"
    # 계정 이름을 Secret 에서 읽지 않는다. 나머지 Secret(JWT·진료기록 키)은 그대로
    assert not any(v.endswith("/DB_USERNAME") for env in by_svc.values() for v in env.values())
    assert by_svc["auth"]["JWT_SECRET"].startswith("secret:reservation-app-jwt/")
    assert by_svc["reservation"]["MEDICAL_KEY"].startswith("secret:reservation-app-medical-key/")
    # --set 으로 계정 이름을 바꿀 수 있다
    got = _env_by_deployment(_helm("--set=services.stats.dbUsername=other_ro"))
    assert next(env for name, env in got.items() if "stats" in name)["DB_USERNAME"] == "value:other_ro"


@pytest.mark.skipif(not shutil.which("helm"), reason="helm 이 없음")
def test_helm_login_rate_limit_only_in_auth():
    def limits(*args):
        return {name: env.get("LOGIN_RATE_LIMIT_PER_MINUTE") for name, env in _env_by_deployment(_helm(*args)).items()}
    got = limits()
    assert [(n, v) for n, v in got.items() if v] == [(next(n for n in got if "auth" in n), "value:20")]
    assert [v for v in limits("--set=loginRateLimitPerMinute=5").values() if v] == ["value:5"]


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


# ---- Ingress 경로와 web nginx 경로가 같은 서비스로 나뉘는지 ----
def _nginx_routes() -> dict[str, str]:
    """web.conf.template 의 `location ~ ^/api/v1/(a|b)` 블록 → {경로: 서비스}."""
    text = (ROOT / "web" / "nginx" / "web.conf.template").read_text(encoding="utf-8")
    routes = {}
    for names, upstream in re.findall(r"location ~ \^/api/v1/\(([^)]*)\)\(/\|\$\) \{\s*proxy_pass \$(\w+)_upstream;", text):
        for name in names.split("|"):
            routes[f"/api/v1/{name}"] = upstream
    return routes


def _ingress_routes(*args: str) -> tuple[dict[str, str], dict]:
    docs = _helm(*args).split("\n---")
    ingress = next(d for d in docs if "kind: Ingress" in d)
    spec = ingress[ingress.index("spec:"):]
    routes = {}
    for path, service in re.findall(r"- path: (\S+)\n\s+pathType: Prefix\n\s+backend:\n\s+service:\n\s+name: (\S+)", spec):
        routes[path] = service
    return routes, {"class": re.search(r"ingressClassName: (\S+)", spec).group(1)}


@pytest.mark.skipif(not shutil.which("helm"), reason="helm 이 없음")
def test_ingress_routes_match_web_nginx():
    nginx = _nginx_routes()
    assert set(nginx.values()) == {"auth", "reservation", "stats"}
    ingress, _ = _ingress_routes()
    web = ingress.pop("/")
    assert web.endswith("-web")  # "/" 는 화면
    assert set(ingress) == set(nginx)  # 경로가 하나도 더하거나 빠지지 않는다
    for path, upstream in nginx.items():
        assert ingress[path].endswith(f"-{upstream}"), path


@pytest.mark.skipif(not shutil.which("helm"), reason="helm 이 없음")
def test_ingress_class_name_comes_from_values():
    assert _ingress_routes("--set=ingress.className=traefik")[1]["class"] == "traefik"
    assert _ingress_routes("--set=ingress.className=nginx")[1]["class"] == "nginx"


@pytest.mark.skipif(not shutil.which("helm"), reason="helm 이 없음")
@pytest.mark.parametrize("values", ["values-onprem.yaml", "values-aws.yaml"])
def test_ingress_class_is_traefik_in_site_values(values):
    """1조(MetalLB+Traefik), 2조(k3s 기본 Traefik) 모두 traefik. values.yaml 기본값(nginx)은 그대로 둔다."""
    tags = [f"--set=services.{s}.image.tag=t" for s in [*SERVICES, "web"]]
    out = subprocess.run(["helm", "template", "rsv", str(CHART), "-f", str(CHART / values), *tags],
                         capture_output=True, text=True, encoding="utf-8", check=True).stdout
    ingress = next(d for d in out.split("\n---") if "kind: Ingress" in d)
    assert re.search(r"ingressClassName: (\S+)", ingress).group(1) == "traefik"


def test_default_values_ingress_class_unchanged():
    text = (CHART / "values.yaml").read_text(encoding="utf-8")
    assert re.search(r"^ingress:\n(?:.*\n)*?\s+className: nginx\b", text, re.M)


@pytest.mark.skipif(not shutil.which("helm"), reason="helm 이 없음")
def test_metrics_node_ports():
    out = _helm()
    for service, port in {"reservation": 30800, "auth": 30801, "stats": 30802}.items():
        doc = next(d for d in out.split("\n---") if "kind: Service" in d and f"name: rsv-reservation-app-{service}\n" in d
                   or "kind: Service" in d and re.search(rf"name: \S*-{service}\n", d))
        assert f"nodePort: {port}" in doc, service


# ---- API 코드의 모든 경로가 web nginx 와 Helm ingress 에 등록돼 있는지 (새 경로를 빼먹으면 실패) ----
def _api_routes() -> dict[str, set[str]]:
    """services/<서비스>/app/*.py 의 `@router.get("/경로")` 를 읽어 {서비스: {첫 경로 조각}} (예: reservation → {"reservations", ...}).

    /api/v1 밖(/healthz, /metrics, 화면 "/")은 대상이 아니다. 라우터 prefix 는 `x = APIRouter(prefix="/api/v1/...")` 에서 읽는다.
    """
    services_dir = ROOT / "services"
    if not services_dir.is_dir():
        pytest.skip("services/ 폴더가 없음 (reservation-app 저장소에서만 확인한다)")
    found: dict[str, set[str]] = {}
    for service in SERVICES:
        for source in sorted((services_dir / service / "app").glob("*.py")):
            text = source.read_text(encoding="utf-8")
            prefixes = dict(re.findall(r'^(\w+)\s*=\s*APIRouter\(\s*prefix="([^"]*)"', text, re.M))
            for router, _method, path in re.findall(
                    r'^@(\w+)\.(get|post|put|patch|delete)\(\s*"([^"]*)"', text, re.M):
                if router not in prefixes:
                    continue
                full = prefixes[router].rstrip("/") + path
                if full.startswith("/api/v1/"):
                    found.setdefault(service, set()).add(full.split("/")[3])
    return found


def test_found_api_routes_sanity():
    routes = _api_routes()
    assert set(routes) == set(SERVICES)
    assert {"contacts", "staff", "reservations"} <= routes["reservation"]  # 읽는 방법이 깨지면 여기서 먼저 알린다
    assert {"auth", "admin"} <= routes["auth"] and {"stats", "system"} <= routes["stats"]


def test_every_api_path_is_in_web_nginx():
    nginx = _nginx_routes()
    missing = [f"{service}: /api/v1/{name}" for service, names in _api_routes().items() for name in sorted(names)
               if nginx.get(f"/api/v1/{name}") != service]
    assert not missing, f"web/nginx/web.conf.template 에 없거나 다른 서비스로 가는 경로: {missing}"


def test_every_api_path_is_in_helm_ingress():
    """helm 이 없어도 돌도록 ingress.yaml 의 경로 목록(서비스별 list)을 글자로 읽는다."""
    text = (CHART / "templates" / "ingress.yaml").read_text(encoding="utf-8")
    ingress: dict[str, str] = {}
    for service, paths in re.findall(r'\(dict "service" "(\w+)" "paths" \(list ([^)]*)\)\)', text):
        for path in re.findall(r'"(/api/v1/[^"]+)"', paths):
            ingress[path] = service
    assert ingress, "ingress.yaml 에서 경로를 읽지 못함"
    missing = [f"{service}: /api/v1/{name}" for service, names in _api_routes().items() for name in sorted(names)
               if ingress.get(f"/api/v1/{name}") != service]
    assert not missing, f"helm/reservation-app/templates/ingress.yaml 에 없거나 다른 서비스로 가는 경로: {missing}"
