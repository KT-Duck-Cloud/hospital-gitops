#!/usr/bin/env bash
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
