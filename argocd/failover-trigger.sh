#!/usr/bin/env bash
# ⚠ 사용 중지 (2026-10-22) — 전환 판단 · DB 는 DR(duck-hsagent), 배포는 사이트별 Application(rsv-*). argocd/README-dr.md
echo "사용 중지: argocd/README-dr.md 참고 (DR 이 전환)" >&2; exit 2
set -euo pipefail

# Failover execution script called by dr-control
# Usage:
#   ./failover-trigger.sh <TARGET_K8S_IP>
# Example:
#   ./failover-trigger.sh 100.64.0.51

TARGET_IP="${1:-}"

if [ -z "$TARGET_IP" ]; then
  echo "Error: TARGET_IP is required."
  echo "Usage: $0 <TARGET_K8S_IP>"
  exit 1
fi

APP_NAME="reservation-app"
ARGOCD_NAMESPACE="argocd"
TARGET_SERVER="https://${TARGET_IP}:6443"

echo "[1/2] Patching ArgoCD Application destination to ${TARGET_SERVER}..."
kubectl patch application "${APP_NAME}" -n "${ARGOCD_NAMESPACE}" --type merge -p "{
  \"spec\": {
    \"destination\": {
      \"server\": \"${TARGET_SERVER}\"
    }
  }
}"

echo "[2/2] Triggering ArgoCD sync..."
if command -v argocd &>/dev/null; then
  argocd app sync "${APP_NAME}" --prune
else
  kubectl patch application "${APP_NAME}" -n "${ARGOCD_NAMESPACE}" --type merge -p '{
    "operation": {
      "sync": {
        "prune": true,
        "syncStrategy": {
          "hook": {}
        }
      }
    }
  }'
fi

echo "Failover sync triggered successfully for ${TARGET_SERVER}."
