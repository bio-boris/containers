#!/usr/bin/env bash
# run_containers.sh
# Runs N FastAPI containers, each in its own namespace + cgroup,
# connected to the host via a veth pair.
# Can be run multiple times concurrently — each run picks up where the last left off.
# Usage: sudo bash run_containers.sh [count]
# Default: 3 containers

set -euo pipefail

COUNT="${1:-3}"
BASE_IP="10.200.0"      # Containers get 10.200.0.2, .3, .4 ...
HOST_IP="10.200.0.1"    # Host-side veth IP (bridge/gateway)
CGROUP_ROOT="/sys/fs/cgroup"
CGROUP_BASE="fastapi"
BRIDGE="br-fastapi"
PORT=8000
APP_DIR="$(mktemp -d)"
LOG_DIR="/var/log/fastapi-containers"
PIDS=()
MY_INDICES=()

# ── Find next available index ─────────────────────────────────────────────────
next_free_index() {
  local idx=1
  while ip netns list 2>/dev/null | grep -q "^ns${idx}"; do
    idx=$((idx + 1))
  done
  echo "$idx"
}

# ── Cleanup (only what this run created) ─────────────────────────────────────
cleanup() {
  echo ""
  echo "[*] Stopping containers..."
  for PID in "${PIDS[@]}"; do
    kill "$PID" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "[*] Removing this run's interfaces and cgroups..."
  for i in "${MY_INDICES[@]}"; do
    ip link del "veth-h${i}" 2>/dev/null || true
    ip netns del "ns${i}" 2>/dev/null || true
    CG_PATH="${CGROUP_ROOT}/${CGROUP_BASE}_${i}"
    if [[ -d "$CG_PATH" ]]; then
      cat "${CG_PATH}/cgroup.procs" 2>/dev/null | xargs -r kill 2>/dev/null || true
      sleep 0.2
      rmdir "$CG_PATH" 2>/dev/null || true
    fi
  done
  # Remove bridge only if no other namespaces remain
  if [[ -z "$(ip netns list 2>/dev/null)" ]]; then
    ip link del "$BRIDGE" 2>/dev/null || true
  fi
  rm -rf "${APP_DIR}"
  echo "[*] Done."
}
trap cleanup EXIT

# ── Install deps ─────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

echo "[*] Installing system dependencies..."
apt-get install -y -qq iproute2 curl

echo "[*] Installing FastAPI and uvicorn..."
pip install fastapi uvicorn --quiet --break-system-packages --ignore-installed

# ── Enable cgroup v2 controllers ─────────────────────────────────────────────
echo "[*] Enabling cgroup v2 cpu+memory controllers..."
echo "+cpu +memory" > "${CGROUP_ROOT}/cgroup.subtree_control"

# ── Create bridge (shared, reuse if exists) ───────────────────────────────────
if ! ip link show "$BRIDGE" &>/dev/null; then
  echo "[*] Creating bridge ${BRIDGE}..."
  ip link add "$BRIDGE" type bridge
  ip addr add "${HOST_IP}/24" dev "$BRIDGE"
  ip link set "$BRIDGE" up
else
  echo "[*] Bridge ${BRIDGE} already exists, reusing."
fi

# ── Write the FastAPI app ─────────────────────────────────────────────────────
cat > "${APP_DIR}/main.py" <<'EOF'
import os
from fastapi import FastAPI

app = FastAPI()
CONTAINER_ID = os.environ.get("CONTAINER_ID", "unknown")

@app.get("/")
def hello():
    return {"message": "Hello from container", "container": CONTAINER_ID}

@app.get("/health")
def health():
    return {"status": "ok", "container": CONTAINER_ID}
EOF

START=$(next_free_index)
echo "[*] Launching $COUNT containers (starting at index ${START})..."
echo ""

for j in $(seq 0 "$((COUNT - 1))"); do
  i=$((START + j))
  MY_INDICES+=("$i")

  CONTAINER_IP="${BASE_IP}.$((i + 1))"
  VETH_HOST="veth-h${i}"
  VETH_NS="veth-c${i}"
  NS="ns${i}"
  CG="${CGROUP_BASE}_${i}"
  CG_PATH="${CGROUP_ROOT}/${CG}"

  # Create named network namespace
  ip netns add "$NS"

  # Create veth pair: one end on host, one in namespace
  ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
  ip link set "$VETH_NS" netns "$NS"

  # Attach host-side veth to bridge
  ip link set "$VETH_HOST" master "$BRIDGE"
  ip link set "$VETH_HOST" up

  # Configure container side
  ip netns exec "$NS" ip addr add "${CONTAINER_IP}/24" dev "$VETH_NS"
  ip netns exec "$NS" ip link set "$VETH_NS" up
  ip netns exec "$NS" ip link set lo up
  ip netns exec "$NS" ip route add default via "$HOST_IP"

  # Create cgroup v2: 50% CPU, 256MB RAM per container
  mkdir -p "$CG_PATH"
  echo "50000 100000" > "${CG_PATH}/cpu.max"
  echo "268435456"    > "${CG_PATH}/memory.max"

  # Launch uvicorn inside namespace + cgroup, logging to files
  LOG_OUT="${LOG_DIR}/container-${i}.stdout.log"
  LOG_ERR="${LOG_DIR}/container-${i}.stderr.log"
  (
    echo $$ > "${CG_PATH}/cgroup.procs"
    exec ip netns exec "$NS" \
      env CONTAINER_ID="container-${i}" \
      python3 -m uvicorn main:app \
        --app-dir "${APP_DIR}" \
        --host "${CONTAINER_IP}" \
        --port "${PORT}" \
      >>"$LOG_OUT" 2>>"$LOG_ERR"
  ) &

  PIDS+=($!)

  echo "[*] Container ${i} started"
  echo "    IP:     ${CONTAINER_IP}"
  echo "    curl:   curl http://${CONTAINER_IP}:${PORT}"
  echo "    cgroup: ${CG_PATH} (50% CPU, 256MB RAM)"
  echo "    stdout: ${LOG_OUT}"
  echo "    stderr: ${LOG_ERR}"
  echo ""

  sleep 0.5
done

echo "─────────────────────────────────────────"
echo "All $COUNT containers running."
echo "─────────────────────────────────────────"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "[*] Verifying containers..."
echo ""
ALL_OK=true
for i in "${MY_INDICES[@]}"; do
  CONTAINER_IP="${BASE_IP}.$((i + 1))"
  NS="ns${i}"
  CG="${CGROUP_BASE}_${i}"
  CG_PATH="${CGROUP_ROOT}/${CG}"

  printf "Container %d (%s):\n" "$i" "$CONTAINER_IP"

  RESPONSE=$(curl -sf --max-time 3 "http://${CONTAINER_IP}:${PORT}/" 2>&1) && \
    printf "  HTTP /       OK  %s\n" "$RESPONSE" || \
    { printf "  HTTP /       FAIL\n"; ALL_OK=false; }

  HEALTH=$(curl -sf --max-time 3 "http://${CONTAINER_IP}:${PORT}/health" 2>&1) && \
    printf "  HTTP /health OK  %s\n" "$HEALTH" || \
    { printf "  HTTP /health FAIL\n"; ALL_OK=false; }

  IFACES=$(ip netns exec "$NS" ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')
  printf "  Interfaces:  %s\n" "$IFACES"

  CPU_MAX=$(cat "${CG_PATH}/cpu.max" 2>/dev/null || echo "?")
  MEM_MAX=$(cat "${CG_PATH}/memory.max" 2>/dev/null || echo "?")
  printf "  CPU max:     %s (quota period)\n" "$CPU_MAX"
  printf "  Mem max:     %s bytes\n" "$MEM_MAX"
  echo ""
done

if $ALL_OK; then
  echo "[+] All containers verified OK."
else
  echo "[!] Some containers failed verification."
fi
echo ""

# ── Log files ─────────────────────────────────────────────────────────────────
echo "Log files:"
for i in "${MY_INDICES[@]}"; do
  echo "  container-${i}  ${LOG_DIR}/container-${i}.stdout.log"
  echo "  container-${i}  ${LOG_DIR}/container-${i}.stderr.log"
done
echo ""
echo "Press Ctrl+C to stop all."
echo "─────────────────────────────────────────"

wait
