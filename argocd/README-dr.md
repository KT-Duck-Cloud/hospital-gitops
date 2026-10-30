# Argo CD 와 DR — 판단은 DR, 배포는 Argo (2026-10-22 정리)

## 원칙

| 역할 | 누가 | 하는 일 |
|---|---|---|
| **판단** | DR (ktci5 `duck-hsagent`) 하나 | 1조 쓰기 DB · 웹 · 앱 응답 · 복제 · 증인 → "지금 운영 사이트 = t3 / t5 / AWS" |
| **DB** | DR | 승격 · 복귀 · 쓰기 막기 · 다시 채우기 · 복제 원본 옮기기 |
| **배포** | Argo CD (t4-vm2 :30443, 중앙) | DR 이 정한 값대로 사이트별 Application 의 파드를 띄우고 내림 |
| **입구** | DR | 공개 입구 · `db/ops.duck.internal` 을 운영 사이트로 |

- Argo 는 배포 방법일 뿐 DR 판단을 하지 않는다. dr-control(1조)은 상태 보고만 하고 직접 전환하지 않는다 — 판단하는 곳이 둘이면 서로 다른 사이트를 운영으로 만든다
- Argo 는 DB 를 바꾸지 않는다 — `dbPromote` · `dbResync` 훅은 Argo 에서 늘 `false`
- Argo 는 온프레미스(t4-vm2)에 있다. 온프레미스가 모두 죽으면(= AWS 로 넘어갈 때) Argo 도 죽을 수 있어 DR 은 30초 무응답이면 helm 으로 AWS 를 직접 띄운다

## 흐름

```
DR 판단 ─▶ DB 승격 · 복귀 (DR) ─▶ Argo: rsv-t3 · rsv-t5 · rsv-aws 값 (active · warm · off) + Sync ─▶ Synced · Healthy
                                   └ Argo 30초 무응답 · 실패 → helm 직접 (AWS)
```

| 상황 | DR 판단 | DB (DR) | Argo 값 |
|---|---|---|---|
| 평시 | 1조 정상 | — | t3 active · t5 warm · aws off |
| 1조 안 승격 | 쓰기 DB 없음 1분 · 대기 복제 정상 | 대기를 쓰기로 | 새 쓰기 active · 나머지 1조 warm |
| AWS 승격 | 1조 온전한 구성원 없음 5분 · 증인 | AWS 쓰기 · 1조 앱 계정 잠금 | aws active |
| 복귀 | 1조 구성원 DB · 웹 응답 3분 (t3 → t5 순) | AWS 데이터로 다시 채운 뒤 전환 | 그 사이트 active · aws off |
| 옛 쓰기 DB 돌아옴 | 쓰기 DB 둘 | 옛 쪽 잠금 · 읽기 전용 · 새 쪽 따르게 | — |

`active` 쓰기 · 1개 / `warm` 읽기 전용 · 1개 / `off` 읽기 전용 · 0개. DR 이 바꾸는 것은 `readOnlyMode` · `services.*.replicaCount` 뿐 (다른 parameters 는 그대로 둔다)

## 예전 방식과 바꾼 것

| 예전 (1조 · 노션 2차 테스트) | 문제 | 지금 |
|---|---|---|
| `reservation-app` 하나의 `destination` 을 바꿈 (`failover-trigger.sh`, `failover-argocd.sh`) | 옮기면 예전 사이트 파드가 관리 밖에 남음 · AWS(ns hospital · AWS 값) 못 다룸 | 사이트마다 Application (`argocd/apps/rsv-*.yaml`), 대상은 고정 |
| Sync 때 `dbPromote` 훅 (10-23 부터 차트 기본 꺼짐) | 대상 DB 승격 + `dbClusterNodes`(t3 · t5 · **AWS**)를 읽기 전용 · 복제본으로 — AWS 가 운영 중이면 데이터를 맞추지 않고 AWS 를 멈춤. 새 버전 배포 때마다 DB 역할을 다시 바꿈 | 훅 끔, DB 는 DR |
| `resync-argocd.sh` — 운영 앱을 복구 사이트로 옮기고 `dbResync` 훅 | 운영 앱이 복구 중 사이트로 감 · parameters 를 통째로 덮어 이미지 태그 등이 사라짐 | DR 복귀가 다시 채우기 · 전환까지 (`provision.failback_sync`). 갈라진 대기 DB 다시 채우기는 DR 이 판단해 부르는 작업으로 |
| `curl -s … > /dev/null` | 401 · 500 이어도 성공으로 끝남 · Healthy 를 기다리지 않음 | DR 이 응답 코드 확인 · Synced · Healthy 240초 기다림 · 실패면 helm |
| 토큰을 스크립트 · 노션에 그대로 | 노션을 보는 사람 누구나 Argo admin | ktci5 `secrets.json`(root 600)에만 (`36_argo_token.sh`). 스크립트 · 노션에서 지움 |

`argocd/application.yaml` 은 사용 중지 (`failover-trigger.sh` 는 삭제됨) (아래 3번에서 `reservation-app` 삭제). 노션의 `failover-argocd.sh` · `resync-argocd.sh` 도 쓰지 않는다

## IaC 담당이 할 일 (Argo CD, t4-vm2)

1. AWS 클러스터 등록 — `duck-iac` kubeconfig 값으로 (네임스페이스 hospital · monitoring). 이 Secret 은 Git 에 넣지 않는다
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata: {name: duck-aws, namespace: argocd, labels: {argocd.argoproj.io/secret-type: cluster}}
   stringData:
     name: duck-aws
     server: https://100.64.0.81:6443
     namespaces: hospital,monitoring
     config: '{"bearerToken":"<kubeconfig 의 token>","tlsClientConfig":{"caData":"<certificate-authority-data>"}}'
   ```
2. Application 3개 — **처음 한 번만** apply (다시 apply 하면 DR 이 정한 운영 사이트가 Git 값으로 되돌아감)
   ```bash
   kubectl -n argocd apply -f argocd/apps/
   kubectl -n argocd delete application reservation-app     # 남기면 t3 에 두 번 배포 · Sync 때 훅이 DB 를 바꿈
   ```
3. DR 토큰 — 지금(10-22 ~ 2주)은 admin 로그인 토큰(11-19 만료)을 임시로 쓴다. 2주 안에 DR 전용 API 키 계정으로
   ```bash
   kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"accounts.duck-dr":"apiKey"}}'
   # argocd-rbac-cm policy.csv 에 더하기 (기존 줄은 그대로)
   #   p, role:duck-dr, applications, get, default/rsv-*, allow
   #   p, role:duck-dr, applications, update, default/rsv-*, allow
   #   p, role:duck-dr, applications, sync, default/rsv-*, allow
   #   g, duck-dr, role:duck-dr
   argocd account generate-token --account duck-dr      # 파일로 전달 (채팅 · 노션 금지)
   ```
   채팅 · 노션에 올라간 admin 토큰은 노출된 것으로 보고 admin 비밀번호 변경
4. 컨트롤 서버 관리자: `sudo bash ~/duckcloud-infra/36_argo_token.sh` → `--check` 로 rsv-t3 · rsv-t5 · rsv-aws 볼 수 있음

## 시험 (2차) — 시작 전

- dr-control 의 자동 전환 · 노션 스크립트를 멈춰 둔다 (시험 중 `reservation-app` Sync → 훅이 AWS DB 를 읽기 전용으로)
- Argo 에 `reservation-app` 이 남아 있으면 지우거나 자동 동기화를 끈다
- 순서 · 기대: 관리 사이트 `/sim` (시나리오 19개) · `35_dr_drill.sh watch`

## 주의

- AWS 이미지는 노드에 미리 받아 둔 것(IfNotPresent)을 쓴다. 태그를 바꾸면 AWS 노드에도 미리 받아 둘 것 (Harbor 는 온프레미스)
- Application parameters 를 Git 에서 고쳐 다시 apply 하지 않는다 — 운영 중 값은 DR 이 정한다
