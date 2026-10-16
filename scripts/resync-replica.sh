#!/usr/bin/env bash
set -euo pipefail

SPECIFIED_MASTER="${1:-}"

if [ -n "$SPECIFIED_MASTER" ]; then
  MASTER_HOST="$SPECIFIED_MASTER"
else
  MY_SLOT=$(hostname | grep -o -E '[0-9]+' | head -1 || true)
  if [ "$MY_SLOT" = "3" ]; then
    PARTNER_SLOT="5"
  elif [ "$MY_SLOT" = "5" ]; then
    PARTNER_SLOT="3"
  else
    echo "Error: Slot number not detected from hostname: $(hostname)"
    echo "Usage: bash scripts/resync-replica.sh <MASTER_IP>"
    exit 1
  fi
  MASTER_HOST="100.64.0.${PARTNER_SLOT}2"
fi

MASTER_PORT="3306"
REPL_USER="repl_user"
REPL_PASS="${REPL_PASSWORD:-duckpass}"
ROOT_PASS="${DB_ROOT_PASSWORD:-duckpass}"

if ! nc -z -w 3 "$MASTER_HOST" "$MASTER_PORT" 2>/dev/null; then
  echo "Error: Cannot connect to ${MASTER_HOST}:${MASTER_PORT}"
  exit 1
fi

sudo docker exec -i hospital-mysql mysql -uroot -p"${ROOT_PASS}" <<EOF
STOP REPLICA;
SET GLOBAL read_only = ON;
SET GLOBAL super_read_only = ON;

CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${MASTER_HOST}',
  SOURCE_PORT=${MASTER_PORT},
  SOURCE_USER='${REPL_USER}',
  SOURCE_PASSWORD='${REPL_PASS}',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;

START REPLICA;
EOF

sleep 2

STATUS_OUTPUT=$(sudo docker exec -i hospital-mysql mysql -uroot -p"${ROOT_PASS}" -e "SHOW REPLICA STATUS\G")
IO_RUNNING=$(echo "$STATUS_OUTPUT" | grep "Replica_IO_Running:" | awk '{print $2}')
SQL_RUNNING=$(echo "$STATUS_OUTPUT" | grep "Replica_SQL_Running:" | awk '{print $2}')

if [ "${IO_RUNNING}" = "Yes" ] && [ "${SQL_RUNNING}" = "Yes" ]; then
  echo "Replication resync success: SOURCE_HOST=${MASTER_HOST}, read_only=ON"
else
  echo "Error: Replication failed"
  echo "$STATUS_OUTPUT" | grep -E "Error|Running|Source_Host"
  exit 1
fi
