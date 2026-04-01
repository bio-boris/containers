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

## Security comparison: this script vs Docker vs VM

This script demonstrates the core building blocks Docker is built on, but Docker layers significant security hardening on top. Here's how they compare:

| Feature | This script | Docker | VM |
|---|---|---|---|
| Network isolation | Yes (netns) | Yes | Yes |
| PID isolation | No | Yes | Yes |
| Filesystem isolation | No | Yes (overlay) | Yes |
| CPU/memory limits | Yes (cgroup v2) | Yes | Yes |
| Capability dropping | No | Yes | N/A |
| Seccomp filtering | No | Yes | N/A |
| User namespace | No | Optional | Yes |
| Root = host root | Yes | No (remapped) | No |
| Kernel shared with host | Yes | Yes | No |

### Why IT policies often allow VMs but not Docker

The key concern is **network access**. Code running in a container — whether Docker or this script — can reach anything the host can reach: internal services, infrastructure, other machines on the network.

VMs are easier for IT to control at the network level because they appear as distinct machines with their own MAC/IP and can be placed in firewalled segments. Containers share the host's network stack and are harder to isolate at the infrastructure level.

However, if your organisation runs CrowdStrike Falcon and Tenable/Nessus, both tools cover containers as well as the host:

- **CrowdStrike** operates at the kernel level and sees all processes and network connections regardless of namespaces — containers are not hidden from it
- **Tenable** has container scanning built in and any network traffic from a container passes through the host stack where it is visible and scannable

From a monitoring perspective, code running in these containers is no more or less visible than code running directly on the host. The existing tooling covers it automatically.

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
