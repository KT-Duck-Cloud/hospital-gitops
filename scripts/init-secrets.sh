#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# init-secrets.sh
# 1조(홍석 t3, 혜미 t5) 온프레미스 노드용 K8s Secret 및 db-service 자동 구성 스크립트
#
# 사용법:
#   bash scripts/init-secrets.sh          # 호스트명(t3-vm1, t5-vm1 등)에서 슬롯 자동 감지
#   bash scripts/init-secrets.sh 3        # 슬롯 3번(t3: 홍석) 명시적 지정
#   bash scripts/init-secrets.sh 5        # 슬롯 5번(t5: 혜미) 명시적 지정
# ==============================================================================

TARGET_SLOT="${1:-}"

if [ -z "$TARGET_SLOT" ]; then
  DETECTED_SLOT=$(hostname | grep -o -E '[0-9]+' | head -1 || true)
  if [ -n "$DETECTED_SLOT" ]; then
    TARGET_SLOT="$DETECTED_SLOT"
    echo ">>> 호스트명($(hostname))에서 슬롯 ${TARGET_SLOT}번을 자동 감지했습니다."
  else
    TARGET_SLOT="3"
    echo ">>> 슬롯 번호를 감지하지 못해 기본값 3번(홍석)을 사용합니다."
  fi
fi

DB_HOST="100.64.0.${TARGET_SLOT}2"
DB_PORT="3306"
DB_PASSWORD="${DB_PASSWORD:-duckpass}"
JWT_SECRET="${JWT_SECRET:-super-secret-jwt-key-duckcloud-hospital-32bytes!}"
MEDICAL_KEY="${MEDICAL_KEY:-dXNlcmtleWZvcm1lZGljYWxyZWNvcmRzMzJieXRlIQ==}"

echo "================================================================="
echo " [DuckCloud 1조] K8s 인프라 Secret & db-service 프로비저닝"
echo " - 적용 슬롯   : Slot ${TARGET_SLOT}"
echo " - 로컬 DB 타겟: ${DB_HOST}:${DB_PORT} (vm2)"
echo "================================================================="

# 1. db-service (Service + Endpoints) 등록
echo "[1/2] db-service 엔드포인트 생성 중 (${DB_HOST}:${DB_PORT})..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: db-service
  namespace: default
spec:
  ports:
    - port: ${DB_PORT}
      targetPort: ${DB_PORT}
---
apiVersion: v1
kind: Endpoints
metadata:
  name: db-service
  namespace: default
subsets:
  - addresses:
      - ip: ${DB_HOST}
    ports:
      - port: ${DB_PORT}
EOF

# 2. 필수 Secret 4종 등록
echo "[2/2] K8s 필수 Secret 4종 생성 중..."
kubectl create secret generic reservation-app-db-runtime \
  --from-literal=DB_USERNAME=app_runtime \
  --from-literal=DB_PASSWORD="${DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic reservation-app-db-readonly \
  --from-literal=DB_USERNAME=app_readonly \
  --from-literal=DB_PASSWORD="${DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic reservation-app-jwt \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic reservation-app-medical-key \
  --from-literal=MEDICAL_KEY="${MEDICAL_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "================================================================="
echo ">>> 모든 인프라 시크릿 및 db-service 설정이 완료되었습니다! 🎉"
echo "================================================================="
