# DIY Containers with FastAPI

Run multiple isolated FastAPI servers using only Linux kernel primitives — no Docker, no Kubernetes.

Each "container" gets its own network namespace, a virtual ethernet connection to a shared bridge, an overlay filesystem with its own rootfs (Debian or Alpine), and cgroup v2 resource limits (CPU + memory).

## How it works

```
Host bridge (br-fastapi) 10.200.0.1
  ├── veth-h1 ↔ veth-c1 → ns1  10.200.0.2:8000  (container-1, debian)
  ├── veth-h2 ↔ veth-c2 → ns2  10.200.0.3:8000  (container-2, alpine)
  └── veth-hN ↔ veth-cN → nsN  10.200.0.N+1:8000
```

Each container is isolated at the network level — it can only see its own loopback and veth interface, not the host's. The host routes traffic to each container through the bridge, the same way Docker uses `docker0`.

Filesystem isolation uses overlayfs — the same mechanism Docker uses:

```
/var/lib/containers/base/debian   (read-only, shared)
/var/lib/containers/base/alpine   (read-only, shared)
    ↓
per-container overlay (upperdir)  (writes isolated per container)
    ↓
merged view (chroot)              (what the container sees)
```

Resource limits are enforced via cgroup v2:
- 50% CPU (quota: 50000us per 100000us period)
- 256MB RAM

## Requirements

- Linux with cgroup v2 (Ubuntu 22.04+)
- Must run as root (`sudo`)
- Python 3, fastapi, uvicorn, debootstrap, wget (installed automatically)

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
sudo bash http.sh              # 1 debian + 1 alpine (default)
sudo bash http.sh 2            # 2 debian + 2 alpine
sudo bash http.sh 1 debian     # 1 debian only
sudo bash http.sh 1 alpine     # 1 alpine only
sudo bash http.sh 3 debian     # 3 debian only
```

You can run the script multiple times concurrently — each run detects existing containers and starts from the next available index:

```bash
sudo bash http.sh 1 debian   # starts container 1 (Debian)
sudo bash http.sh 1 alpine   # starts container 2 (Alpine)
sudo bash http.sh 1 debian   # starts container 3 (Debian)
```

### Base images

These are not scratch images — they are minimal OS rootfs environments:

| Image | Base | Package manager | Size |
|---|---|---|---|
| `debian` | Debian 12 Bookworm (via debootstrap) | apt | ~300MB |
| `alpine` | Alpine 3.19 minirootfs | apk | ~10MB |

Both have a shell, libc, and package manager. They are equivalent to `FROM debian:12-slim` and `FROM alpine:3.19` in Docker. Scratch images (empty, no OS) are not practical with Python as it requires a runtime and libc.

The base rootfs for each image is built once and reused. On first run, Debian takes a few minutes. Alpine is fast as it downloads a small tarball.

The rootfs persists between runs at:
```
/var/lib/containers/base/debian
/var/lib/containers/base/alpine
```

Subsequent runs skip the build entirely. To force a rebuild, delete the relevant directory:
```bash
sudo rm -rf /var/lib/containers/base/debian
sudo rm -rf /var/lib/containers/base/alpine
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

### Adding Kubernetes to the comparison

| Feature | This script | Docker | Kubernetes | VM |
|---|---|---|---|---|
| Network isolation | Yes (netns) | Yes | Yes | Yes |
| PID isolation | No | Yes | Yes | Yes |
| Filesystem isolation | No | Yes (overlay) | Yes | Yes |
| CPU/memory limits | Yes (cgroup v2) | Yes | Yes (requests/limits) | Yes |
| Capability dropping | No | Yes | Yes | N/A |
| Seccomp filtering | No | Yes | Yes | N/A |
| User namespace | No | Optional | Optional | Yes |
| Root = host root | Yes | No | No | No |
| Kernel shared with host | Yes | Yes | Yes | No |
| Network policies | No | No | Yes (NetworkPolicy) | Via firewall |
| RBAC | No | No | Yes | No |
| Secret management | No | Basic | Yes (Secrets API) | No |
| Multi-node | No | No | Yes | Yes |

Kubernetes adds controls Docker doesn't have natively — NetworkPolicy enforces what containers can talk to on the network, RBAC controls who can deploy and modify containers, and Pod Security Standards enforce seccomp and capability dropping cluster-wide.

However, a default unhardened Kubernetes cluster can be more dangerous than plain Docker:
- API server may be exposed
- No NetworkPolicy enforced by default — all pods can talk to all pods
- Default service account permissions are too broad
- Pod Security Standards not enforced by default
- etcd not encrypted at rest by default

CIS benchmarks exist specifically because the defaults are not safe for production.

### Security ranking

**By isolation (technical):**
```
VM
> Kubernetes (CIS hardened, production)
> MicroK8s (CIS plugin + Calico NetworkPolicy)
> MicroK8s (CIS plugin, default CNI)
> Docker (CIS hardened)
> Kubernetes (default)
> Docker (default)
> This script
```

**By real-world misconfiguration risk:**
```
VM
> Kubernetes (CIS hardened, production)
> MicroK8s (CIS plugin + Calico NetworkPolicy)
> MicroK8s (CIS plugin, default CNI)
> Docker (CIS hardened)
> This script
> Docker (default)
> Kubernetes (default)
```

Default Kubernetes sits at the bottom of the second list because it provides the illusion of enterprise security while having more attack surface than plain Docker. MicroK8s with the CIS hardening plugin is a strong option — it automates the CIS benchmark remediations, supports multi-node clustering, and is close to a production CIS-hardened cluster. The remaining gaps are mainly embedded etcd vs a dedicated etcd cluster and any manual CIS remediations the plugin doesn't cover.

### A container is just a process

At the kernel level a container or pod is just a process (or group of processes). The kernel scheduler, OOM killer, and process table treat them like any other process. There is no special kernel object called a "container" — it is just:

- A process with certain **namespaces** applied (restricting its view of the system)
- A process assigned to a **cgroup** (limiting its resources)
- Optionally a process with a **seccomp filter** and reduced **capabilities**

All of those are standard Linux kernel features that predate Docker by years. This is exactly what `http.sh` proves — a "container" is built with two shell commands (`ip netns add` + `mkdir /sys/fs/cgroup/...`) and a regular `python3` process. No container runtime required.

The implications:

- `ps aux` on the host shows every container process
- The kernel OOM killer can kill a container process just like any other
- `strace`, `perf`, `lsof` all work on container processes from the host
- CrowdStrike sees them because it hooks the kernel, not Docker

The "magic" of Docker and Kubernetes is not in the kernel — it is in the tooling that sets up namespaces, cgroups, overlay filesystems, and networking consistently and repeatably. The kernel itself has no idea what a container is.

### How this script compares to containerd

Your script is essentially a minimal containerd — just without the image layer.

The full container stack looks like this:

```
Kubernetes
    ↓
containerd        ← manages images, snapshots, lifecycle
    ↓
runc              ← does exactly what this script does (namespaces, cgroups)
    ↓
Linux kernel
```

This script skips everything above `runc` and calls the kernel primitives directly. `runc` is essentially this script, written in Go, following the OCI spec.

**What containerd does that this script doesn't:**
- Pulls images from registries (Docker Hub, ECR, etc.)
- Manages a local image cache
- Sets up an overlay filesystem from image layers so each container gets its own copy of the filesystem
- OCI runtime spec compliance
- gRPC API so Kubernetes can talk to it
- Container lifecycle management (start, stop, pause, restart)

**What this script already does (same as containerd/runc):**
- Creates network namespaces
- Sets up veth pairs and bridge networking
- Creates and assigns cgroups
- Launches a process inside the namespace

The main thing missing is filesystem isolation — processes share the host filesystem. Everything else is functionally equivalent to what a real container runtime does.

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
