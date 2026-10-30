# hospital-gitops

병원 예약 시스템의 Helm 차트와 Argo CD Application — 1조(t3 · t5) · AWS(t8) 가 같은 차트로 배포된다.

## 저장소 구조

```
argocd/
  apps/rsv-t3.yaml · rsv-t5.yaml · rsv-aws.yaml   사이트별 Application (값 readOnlyMode · replicaCount 로 active · warm · off)
  README-dr.md                                    DR 과 Argo 의 역할 나눔
  application.yaml                               예전 방식 — 사용 중지
helm/reservation-app/   마이크로서비스 차트 (auth · reservation · stats · web)
  values.yaml           공통 값 (온프레미스 기준)
  values-aws.yaml       AWS(t8) 덮어쓰기 — 읽기 전용 · 0개
  templates/db-promote-job.yaml · db-resync-job.yaml   DB 승격 · 재동기화 훅 — 기본 꺼짐
db/                     MySQL 스키마 · 권한 · 마이그레이션
docs/                   API 명세 · ERD · 권한표 · DB 설정
tools/                  DR 훈련용 데이터 정합성 검증 (data_verifier.py)
tests/                  차트 · 배포 설정 시험
```

## 배포와 DR

- 배포는 Argo CD(t4-vm2)가 사이트별 Application 으로 한다.
- 전환 판단 · DB 승격 · 공개 입구 전환은 이 저장소 밖 DR(duck-hsagent)이 한다. DR 은 Application 의 값만 바꾸고, Argo 가 그 값대로 파드를 띄우고 내린다.
- `dbPromote` · `dbResync` 훅은 켜지 않는다 — 켜면 동기화마다 DB 역할이 바뀌어 쓰기 DB 가 둘이 될 수 있다.
- 사이트 역할(active · warm · off)은 DR 이 바꾸므로 여기 적지 않는다. 지금 상태는 상태 페이지에서 본다.

자세히: [`argocd/README-dr.md`](argocd/README-dr.md)
