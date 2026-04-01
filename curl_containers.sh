#!/usr/bin/env bash
# curl_containers.sh
# Auto-discovers all running fastapi containers from active network namespaces.
# Usage: bash curl_containers.sh [port]

PORT="${1:-8000}"
BASE_IP="10.200.0"
LOG_DIR="/var/log/fastapi-containers"

NAMESPACES=$(ip netns list 2>/dev/null | awk '{print $1}' | grep '^ns[0-9]*$' | sort -V)

if [[ -z "$NAMESPACES" ]]; then
  echo "No containers found. Run: sudo bash http.sh"
  exit 1
fi

for NS in $NAMESPACES; do
  i="${NS#ns}"
  IP="${BASE_IP}.$((i + 1))"
  echo "── Container ${i} (${IP}:${PORT}) ──────────────────"
  echo -n "  GET /       → "
  curl -sf --max-time 3 "http://${IP}:${PORT}/" && echo || echo "FAIL"
  echo -n "  GET /health → "
  curl -sf --max-time 3 "http://${IP}:${PORT}/health" && echo || echo "FAIL"

  echo "  stdout:"
  if [[ -f "${LOG_DIR}/container-${i}.stdout.log" ]]; then
    sed 's/^/    /' "${LOG_DIR}/container-${i}.stdout.log"
  else
    echo "    (no log file)"
  fi

  echo "  stderr:"
  if [[ -f "${LOG_DIR}/container-${i}.stderr.log" ]]; then
    sed 's/^/    /' "${LOG_DIR}/container-${i}.stderr.log"
  else
    echo "    (no log file)"
  fi
  echo ""
done
