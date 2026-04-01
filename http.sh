#!/usr/bin/env bash
# run_containers.sh
# Runs N FastAPI containers, each in its own namespace + cgroup + overlay filesystem,
# connected to the host via a veth pair.
# Can be run multiple times concurrently — each run picks up where the last left off.
# Usage: sudo bash run_containers.sh [count] [debian|alpine|all]
# Default: 1 container per runtime (debian + alpine)

set -euo pipefail

COUNT="${1:-1}"
IMAGE="${2:-all}"
BASE_IP="10.200.0"      # Containers get 10.200.0.2, .3, .4 ...
HOST_IP="10.200.0.1"    # Host-side veth IP (bridge/gateway)
CGROUP_ROOT="/sys/fs/cgroup"
CGROUP_BASE="fastapi"
BRIDGE="br-fastapi"
PORT=8000
APP_DIR="$(mktemp -d)"
LOG_DIR="/var/log/fastapi-containers"
CONTAINERS_DIR="/var/lib/containers/instances"
PIDS=()
MY_INDICES=()

# ── Validate image ────────────────────────────────────────────────────────────
if [[ "$IMAGE" != "debian" && "$IMAGE" != "alpine" && "$IMAGE" != "all" ]]; then
  echo "Error: image must be 'debian', 'alpine', or 'all'"
  exit 1
fi

# ── Expand 'all' to both runtimes ─────────────────────────────────────────────
if [[ "$IMAGE" == "all" ]]; then
  IMAGES=("debian" "alpine")
else
  IMAGES=("$IMAGE")
fi

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
  echo "[*] Removing this run's interfaces, cgroups, and overlays..."
  for i in "${MY_INDICES[@]}"; do
    ip link del "veth-h${i}" 2>/dev/null || true
    ip netns del "ns${i}" 2>/dev/null || true
    CG_PATH="${CGROUP_ROOT}/${CGROUP_BASE}_${i}"
    if [[ -d "$CG_PATH" ]]; then
      cat "${CG_PATH}/cgroup.procs" 2>/dev/null | xargs -r kill 2>/dev/null || true
      sleep 0.2
      rmdir "$CG_PATH" 2>/dev/null || true
    fi
    MERGED="${CONTAINERS_DIR}/${i}/merged"
    umount -l "${MERGED}/dev" 2>/dev/null || true
    umount -l "${MERGED}/proc" 2>/dev/null || true
    umount -l "${MERGED}/sys" 2>/dev/null || true
    umount -l "$MERGED" 2>/dev/null || true
    for attempt in $(seq 1 10); do
      rm -rf "${CONTAINERS_DIR}/${i}" 2>/dev/null && break
      echo "[*] Waiting for overlay to release (attempt ${attempt}/10)..."
      sleep 1
    done
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
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 curl debootstrap wget

# ── Create base rootfs (once per image type) ──────────────────────────────────
for IMG in "${IMAGES[@]}"; do
  BASE_ROOTFS="/var/lib/containers/base/${IMG}"
  mkdir -p "$BASE_ROOTFS"

  if [[ "$IMG" == "debian" ]]; then
    if [[ ! -d "${BASE_ROOTFS}/usr" ]]; then
      echo "[*] Creating Debian base rootfs — this will take a few minutes..."
      debootstrap --variant=minbase bookworm "$BASE_ROOTFS"
      echo "[*] Installing Python + FastAPI into Debian rootfs..."
      chroot "$BASE_ROOTFS" apt-get install -y -qq python3 python3-pip
      chroot "$BASE_ROOTFS" pip3 install fastapi uvicorn --break-system-packages --quiet
    else
      echo "[*] Debian base rootfs already exists, skipping."
    fi

  elif [[ "$IMG" == "alpine" ]]; then
    if [[ ! -f "${BASE_ROOTFS}/etc/alpine-release" ]]; then
      echo "[*] Creating Alpine base rootfs..."
      ALPINE_VERSION="3.19"
      ALPINE_ARCH="$(uname -m)"
      ALPINE_TAR="/tmp/alpine-minirootfs.tar.gz"
      wget -q "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz" \
        -O "$ALPINE_TAR"
      tar -xzf "$ALPINE_TAR" -C "$BASE_ROOTFS"
      rm -f "$ALPINE_TAR"
      echo "[*] Installing Python + FastAPI into Alpine rootfs..."
      cp /etc/resolv.conf "${BASE_ROOTFS}/etc/resolv.conf"
      chroot "$BASE_ROOTFS" /bin/sh -c "apk add --no-cache python3 py3-pip && pip3 install fastapi uvicorn --break-system-packages --quiet"
    else
      echo "[*] Alpine base rootfs already exists, skipping."
    fi
  fi
done

# ── Clean up any leftover state from crashed previous runs ───────────────────
echo "[*] Cleaning up any leftover state..."
for NS in $(ip netns list 2>/dev/null | awk '{print $1}' | grep '^ns[0-9]*$'); do
  idx="${NS#ns}"
  ip link del "veth-h${idx}" 2>/dev/null || true
  ip netns del "$NS" 2>/dev/null || true
  CG_PATH="${CGROUP_ROOT}/${CGROUP_BASE}_${idx}"
  if [[ -d "$CG_PATH" ]]; then
    cat "${CG_PATH}/cgroup.procs" 2>/dev/null | xargs -r kill 2>/dev/null || true
    sleep 0.1
    rmdir "$CG_PATH" 2>/dev/null || true
  fi
  MERGED="${CONTAINERS_DIR}/${idx}/merged"
  umount -l "${MERGED}/dev" 2>/dev/null || true
  umount -l "${MERGED}/proc" 2>/dev/null || true
  umount -l "${MERGED}/sys" 2>/dev/null || true
  umount -l "$MERGED" 2>/dev/null || true
  rm -rf "${CONTAINERS_DIR}/${idx}"
done
ip link del "$BRIDGE" 2>/dev/null || true

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
TOTAL=$(( COUNT * ${#IMAGES[@]} ))
echo "[*] Launching $TOTAL containers ($COUNT per runtime: ${IMAGES[*]}) starting at index ${START}..."
echo ""

IDX=$START
for IMG in "${IMAGES[@]}"; do
  BASE_ROOTFS="/var/lib/containers/base/${IMG}"
  for j in $(seq 0 "$((COUNT - 1))"); do
    i=$IDX
    IDX=$((IDX + 1))
    MY_INDICES+=("$i")

    CONTAINER_IP="${BASE_IP}.$((i + 1))"
    VETH_HOST="veth-h${i}"
    VETH_NS="veth-c${i}"
    NS="ns${i}"
    CG="${CGROUP_BASE}_${i}"
    CG_PATH="${CGROUP_ROOT}/${CG}"

    # ── Overlay filesystem ─────────────────────────────────────────────────────
    UPPER="${CONTAINERS_DIR}/${i}/upper"
    WORK="${CONTAINERS_DIR}/${i}/work"
    MERGED="${CONTAINERS_DIR}/${i}/merged"
    mkdir -p "$UPPER" "$WORK" "$MERGED"

    mount -t overlay overlay \
      -o lowerdir="$BASE_ROOTFS",upperdir="$UPPER",workdir="$WORK" \
      "$MERGED"

    mkdir -p "${MERGED}/proc" "${MERGED}/sys" "${MERGED}/dev"
    mount -t proc     proc      "${MERGED}/proc"
    mount -t sysfs    sysfs     "${MERGED}/sys"
    mount -t devtmpfs devtmpfs  "${MERGED}/dev"

    mkdir -p "${MERGED}/app"
    cp "${APP_DIR}/main.py" "${MERGED}/app/main.py"

    # ── Network namespace ──────────────────────────────────────────────────────
    ip netns add "$NS"
    ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
    ip link set "$VETH_NS" netns "$NS"
    ip link set "$VETH_HOST" master "$BRIDGE"
    ip link set "$VETH_HOST" up
    ip netns exec "$NS" ip addr add "${CONTAINER_IP}/24" dev "$VETH_NS"
    ip netns exec "$NS" ip link set "$VETH_NS" up
    ip netns exec "$NS" ip link set lo up
    ip netns exec "$NS" ip route add default via "$HOST_IP"

    # ── cgroup v2: 50% CPU, 256MB RAM ─────────────────────────────────────────
    mkdir -p "$CG_PATH"
    echo "50000 100000" > "${CG_PATH}/cpu.max"
    echo "268435456"    > "${CG_PATH}/memory.max"

    # ── Launch uvicorn inside overlay + namespace + cgroup ─────────────────────
    LOG_OUT="${LOG_DIR}/container-${i}.stdout.log"
    LOG_ERR="${LOG_DIR}/container-${i}.stderr.log"
    (
      echo $$ > "${CG_PATH}/cgroup.procs"
      exec ip netns exec "$NS" \
        chroot "$MERGED" \
        env CONTAINER_ID="container-${i}" \
        python3 -m uvicorn main:app \
          --app-dir /app \
          --host "${CONTAINER_IP}" \
          --port "${PORT}" \
        >>"$LOG_OUT" 2>>"$LOG_ERR"
    ) &

    PIDS+=($!)

    echo "[*] Container ${i} started (${IMG})"
    echo "    IP:      ${CONTAINER_IP}"
    echo "    rootfs:  ${MERGED}"
    echo "    curl:    curl http://${CONTAINER_IP}:${PORT}"
    echo "    cgroup:  ${CG_PATH} (50% CPU, 256MB RAM)"
    echo "    stdout:  ${LOG_OUT}"
    echo "    stderr:  ${LOG_ERR}"
    echo ""

    sleep 0.5
  done
done

echo "─────────────────────────────────────────"
echo "All $TOTAL containers running."
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

  # Wait up to 10s for container to be ready
  READY=false
  for attempt in $(seq 1 20); do
    if curl -sf --max-time 1 "http://${CONTAINER_IP}:${PORT}/" &>/dev/null; then
      READY=true
      break
    fi
    sleep 0.5
  done

  if $READY; then
    RESPONSE=$(curl -sf --max-time 3 "http://${CONTAINER_IP}:${PORT}/" 2>&1)
    printf "  HTTP /       OK  %s\n" "$RESPONSE"
    HEALTH=$(curl -sf --max-time 3 "http://${CONTAINER_IP}:${PORT}/health" 2>&1) && \
      printf "  HTTP /health OK  %s\n" "$HEALTH" || \
      { printf "  HTTP /health FAIL\n"; ALL_OK=false; }
  else
    printf "  HTTP /       FAIL (timed out after 10s)\n"
    printf "  HTTP /health FAIL\n"
    ALL_OK=false
  fi

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
