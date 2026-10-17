# hospital-gitops

병원 예약 시스템의 GitOps 배포 매니페스트 및 DR 절체 자동화 설정 저장소.

## 저장소 구조

```
argocd/                 ArgoCD Application 매니페스트 및 dr-control 연동 트리거 스크립트
helm/reservation-app/   병원 마이크로서비스 Helm 차트 (auth, reservation, stats, web)
  templates/
    db-promote-job.yaml  ArgoCD PreSync Hook: DR 절체 시 Replica DB를 Master로 자동 승격
  values.yaml           단일 통합 배포 설정 (온프레미스/AWS 공통)
db/                     MySQL 초기 스키마 및 마이그레이션 SQL
docs/                   API 명세 및 아키텍처 문서
tools/                  DR 훈련용 데이터 정합성 검증 스크립트 (data_verifier.py)
tests/                  Helm 차트 및 설정 테스트
```

## 재해복구(DR) 페일오버 아키텍처

1. **감시 및 판단 (mon & dr-control)**
   - 모니터링 서버가 각 사이트(`/readyz`) 헬스체크 실패 감지.
   - `dr-control`이 새 운영 타겟 IP(예: `100.64.0.51`)를 결정하고 트래픽 라우팅을 갱신.

2. **ArgoCD 연동 절체 (dr-control -> ArgoCD)**
   - `dr-control`이 ArgoCD Application의 배포 대상 목적지를 새 클러스터로 지정하고 Sync를 트리거.
   ```bash
   ./argocd/failover-trigger.sh 100.64.0.51
   ```

3. **DB 마스터 자동 승격 (PreSync Hook)**
   - `db-promote-job`이 앱 파드 기동 전 타겟 노드의 MySQL에 접속하여 복제 중단 및 쓰기 활성화 실행.
   ```sql
   STOP REPLICA;
   SET GLOBAL read_only = OFF;
   SET GLOBAL super_read_only = OFF;
   ```

4. **애플리케이션 기동 (Main Sync)**
   - 병원 마이크로서비스 파드 4개(`auth`, `reservation`, `stats`, `web`) 기동 및 서비스 개시.

5. **장애 복구 후 재동기화 (Failback)**
   - 복구된 이전 노드는 `dbResync.enabled: true` 설정을 통해 현재 활성 마스터의 Replica로 자동 재구성.
