# Argo CD 가 파드를 배포 — DR 과 함께 (2026-10-22)

## 흐름

```
DR(duck-hsagent, ktci5)                Argo CD (t4-vm2 :30443)                 사이트 클러스터
───────────────────────                ─────────────────────────               ──────────────────
1조 DB 판정 · DB 승격/복귀   ──값──▶   rsv-t3 · rsv-t5 · rsv-aws               t3 (100.64.0.31) ns default
 "지금 운영 = tN"                      parameters 바꾸기 → Sync         ──▶   t5 (100.64.0.51) ns default
                             ◀─상태──  Synced · Healthy 기다림 (240초)         AWS (100.64.0.81) ns hospital
 Argo 30초 무응답 · 실패 ──▶ helm 직접 (온프레미스와 같이 Argo 가 죽었을 때)
```

| 상황 | DR 이 하는 일 | Argo 값 |
|---|---|---|
| 평시 | — | t3 active · t5 warm · aws off |
| 1조 안 승격 (t3 → t5) | t5 DB 쓰기 | t5 active · t3 warm |
| 2조 AWS 승격 | AWS DB 쓰기 | aws active (Argo 안 되면 helm) |
| 복귀 (AWS → t3/t5) | t3/t5 를 AWS 데이터로 맞춤 · 전환 | tN active · aws off |

- `active` 쓰기 · 서비스마다 1개 / `warm` 읽기 전용 · 1개 / `off` 읽기 전용 · 0개
- DR 이 바꾸는 것은 Application 의 `readOnlyMode` · `services.*.replicaCount` 뿐. `dbPromote` · `dbResync` 는 늘 `false` (DB 는 DR 이)
- `argocd/application.yaml`(대상 하나를 바꾸는 방식) · `failover-trigger.sh` 는 이 방식으로 대신한다 — 둘 다 켜 두지 않는다

## IaC 담당이 할 일 (Argo CD, t4-vm2)

1. 클러스터 등록 — t3 · t5 는 이미 쓰던 등록. AWS 는 `duck-iac` kubeconfig 로 (네임스페이스 hospital · monitoring)
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
   이 Secret 은 Git 에 넣지 않는다 (`kubectl apply -f` 후 파일 삭제).
2. Application 3개
   ```bash
   kubectl -n argocd apply -f argocd/apps/
   kubectl -n argocd delete application reservation-app     # 예전 하나짜리 — 남기면 t3 에 두 번 배포
   ```
3. DR 계정 `duck-dr` (이 3개만 보고 · 값 바꾸고 · 동기화)
   ```bash
   kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"accounts.duck-dr":"apiKey"}}'
   kubectl -n argocd patch cm argocd-rbac-cm --type merge -p '{"data":{"policy.csv":"p, role:duck-dr, applications, get, default/rsv-*, allow\np, role:duck-dr, applications, update, default/rsv-*, allow\np, role:duck-dr, applications, sync, default/rsv-*, allow\ng, duck-dr, role:duck-dr\n"}}'
   argocd account generate-token --account duck-dr      # 출력된 토큰을 컨트롤 서버 관리자에게 (채팅 · Git 금지)
   ```
   `policy.csv` 에 이미 다른 줄이 있으면 덮어쓰지 말고 위 4줄을 더한다.
4. 컨트롤 서버 관리자: `sudo bash ~/duckcloud-infra/36_argo_token.sh` → 토큰 붙여 넣기 → `rsv-t3 · rsv-t5 · rsv-aws 볼 수 있음` 확인

## 주의

- Application 의 parameters 를 Git 에서 고쳐 다시 apply 하면 DR 이 정한 운영 사이트가 되돌아간다 — 처음 만들 때만 apply
- AWS 이미지는 노드에 미리 받아 둔 것(IfNotPresent)을 쓴다. 태그를 바꾸면 AWS 노드에도 미리 받아 둘 것 (Harbor 는 온프레미스)
