# DIY Containers with FastAPI

Run multiple isolated FastAPI servers using only Linux kernel primitives — no Docker, no Kubernetes.

Each "container" gets its own network namespace, a virtual ethernet connection to a shared bridge, and cgroup v2 resource limits (CPU + memory).

## How it works

```
Host bridge (br-fastapi) 10.200.0.1
  ├── veth-h1 ↔ veth-c1 → ns1  10.200.0.2:8000  (container-1)
  ├── veth-h2 ↔ veth-c2 → ns2  10.200.0.3:8000  (container-2)
  └── veth-hN ↔ veth-cN → nsN  10.200.0.N+1:8000
```

Each container is isolated at the network level — it can only see its own loopback and veth interface, not the host's. The host routes traffic to each container through the bridge, the same way Docker uses `docker0`.

Resource limits are enforced via cgroup v2:
- 50% CPU (quota: 50000us per 100000us period)
- 256MB RAM

## Requirements

- Linux with cgroup v2 (Ubuntu 22.04+)
- Must run as root (`sudo`)
- Python 3 (fastapi + uvicorn installed automatically)

## Files

| File | Description |
|------|-------------|
| `http.sh` | Launches N containers |
| `curl_containers.sh` | Checks all running containers |
| `NOTES.md` | Additional notes and troubleshooting |
| `SESSION.md` | Summary of the build session |

## Usage

### Start containers

```bash
sudo bash http.sh        # start 3 (default)
sudo bash http.sh 5      # start 5
sudo bash http.sh 1      # start 1
```

You can run the script multiple times concurrently — each run detects existing containers and starts from the next available index:

```bash
sudo bash http.sh 1   # starts container 1
sudo bash http.sh 1   # starts container 2
sudo bash http.sh 1   # starts container 3
```

### Check containers

In a second terminal:

```bash
bash curl_containers.sh        # auto-discovers all running containers
bash curl_containers.sh 8080   # custom port
```

This hits both endpoints (`/` and `/health`) and prints the stdout/stderr logs for each container.

### Stop

Press `Ctrl+C` in the `http.sh` terminal. Cleanup runs automatically — namespaces, veths, cgroups, and the bridge (if no containers remain) are all removed.

## Endpoints

| Endpoint | Response |
|----------|----------|
| `GET /` | `{"message": "Hello from container", "container": "container-N"}` |
| `GET /health` | `{"status": "ok", "container": "container-N"}` |

## Logs

Each container writes to append-mode log files:

```
/var/log/fastapi-containers/container-N.stdout.log
/var/log/fastapi-containers/container-N.stderr.log
```

Tail logs in real time:

```bash
tail -f /var/log/fastapi-containers/container-1.stdout.log
tail -f /var/log/fastapi-containers/container-*.stderr.log
```

## Troubleshooting

**Namespace already exists**
Leftover from a crashed run. The script cleans these up automatically on startup, but you can also do it manually:
```bash
for i in 1 2 3; do
  sudo ip netns del ns${i} 2>/dev/null
  sudo ip link del veth-h${i} 2>/dev/null
done
sudo ip link del br-fastapi 2>/dev/null
```

**cgroup v1 errors**
This script requires cgroup v2. Verify with:
```bash
mount | grep cgroup
# should show: cgroup2 on /sys/fs/cgroup
```
