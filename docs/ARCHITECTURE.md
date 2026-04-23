# Project Ocean: Architecture & Component Reference

## System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        EXTERNAL TRAFFIC / INTERNET                      │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │ HTTP/HTTPS Traffic
                    ┌────────────▼──────────┐
                    │ Cloud Load Balancer   │
                    │ (AWS ELB, Azure LB,   │
                    │  GCP LB, or MetalLB)  │
                    └────────────┬──────────┘
                                 │
        ┌────────────────────────┴──────────────────────────┐
        │                                                   │
    ┌───▼───┐                                          ┌────▼────┐
    │ Ocean │◄────────── Service (ClusterIP) ──────────│ Ocean   │
    │ Pod-1 │ endpoint                                 │ Pod-2   │
    │ K8s   │                                          │ K8s     │
    └───┬───┘                                          └────┬────┘
        │                                                   │
        │  ┌─────────────────────┐                          │
        │  │ HorizontalPodAutosc │                          │
        │  │ aler (HPA)          │                          │
        │  │ Monitors: CPU >70%  │                          │
        │  │ Mem >80% → Scale    │                          │
        │  └─────────────────────┘                          │
        │                                                   │
        ├── Replicas: 2-10 (dynamic via HPA) ───────────────┤
        │                                                   │
    ┌───▼─────────────────────────────────────────────────▼────┐
    │         NGINX Reverse Proxy (High-Throughput)            │
    │                                                          │
    │  ┌─ Performance Tuning:                                  │
    │  │  • worker_processes auto (8+ cores typical)           │
    │  │  • worker_connections 20480 per worker                │
    │  │  • TCP tuning: fast open, nopush/nodelay              │
    │  │  • Keep-alive: 1000 reqs per connection               │
    │  │  • File descriptor cache: 200k entries                │
    │  └─ Expected: 50-100k req/sec per pod                    │
    │                                                          │
    │  ┌─ ModSecurity OWASP CRS:                               │
    │  │  • Engine: DetectionOnly (safe baseline)              │
    │  │  • Rules: 900+ covering XSS, SQLI, RFI, etc.          │
    │  │  • Audit log: /var/log/modsecurity/audit.log          │
    │  │  • Overhead: +10-15% CPU, +2-3ms latency              │
    │  └─ Status: Monitors threats (not blocking initially)    │
    │                                                          │
    │  ┌─ Health Checks:                                       │
    │  │  • /health → returns 200 OK                           │
    │  │  • Used by K8s liveness/readiness probes              │
    │  │  • Load balancer removes unresponsive pods            │
    │  └─ Graceful shutdown: 30s termination grace period      │
    │                                                          │
    └───┬───────────────────────────────────────────────────┬──┘
        │ HTTP/1.1 persistent upstreams                     │
        │                                                   │
    ┌───▼─────────────────────────┐              ┌──────────▼──────┐
    │  Kubernetes ConfigMap       │              │ Backend         │
    │  (Injected Config Files)    │              │ Application     │
    │                             │              │ Servers         │
    │ • nginx.conf                │              │ (Your app logic)│
    │ • default-site.conf         │              │                 │
    │ • modsec_default.conf       │              │ 10.0.0.0/8 net  │
    │ • crs-setup.conf            │              │                 │
    │                             │              │ (Sub-100ms      │
    │ mount: /etc/nginx/...       │              │  response time) │
    └─────────────────────────────┘              └─────────────────┘
        │
        │ Referenced by Pods at startup
        │ (Enables config changes without rebuild)
```

---

## Component Breakdown

### 1. OS-Level Optimization (Phase 1)

**Location:** `scripts/optimize_ubuntu.sh`

**Purpose:** Tune Ubuntu 22.04 TCP stack for maximum throughput

**Key Settings:**

| Parameter | Value | Effect |
|-----------|-------|--------|
| `net.core.somaxconn` | 65535 | Listen backlog: 64k queued connections per socket |
| `net.ipv4.tcp_max_syn_backlog` | 8192 | SYN flood protection: accept bursts of 8k new connections |
| `net.ipv4.tcp_tw_reuse` | 1 | Reuse TIME_WAIT slots for new connections (proxy benefit) |
| `net.ipv4.tcp_fin_timeout` | 30 | Close TIME_WAIT after 30s (vs 60s default) |
| `net.ipv4.tcp_rmem` | 8k/256k/512MB | Receive buffer: 256KB default, 512MB max |
| `net.ipv4.tcp_wmem` | 8k/256k/512MB | Send buffer: same as receive for balance |
| `net.ipv4.tcp_fastopen` | 3 | TCP Fast Open (TFO) on both sides |
| `net.core.netdev_max_backlog` | 5000 | NIC queue depth during traffic spikes |

**File Descriptors:**
- Systemd override: `LimitNOFILE=65536` (per-process limit)
- System-wide: `/etc/security/limits.conf` (persistent across reboots)

**Impact:**
- **Throughput:** 5-10x improvement over defaults
- **Connection Reuse:** TIME_WAIT cleanup 2x faster
- **Latency Stability:** Reduced jitter under spikes
- **Downside:** None (safe for production)

---

### 2. Cluster HA (Phase 2: Corosync/Pacemaker)

**Location:** `scripts/bootstrap_cluster.sh`, `scripts/add_cluster_node.sh`, `scripts/drain_remove_node.sh`

**Purpose:** Provide high availability via automatic failover

**Architecture:**

```
┌─────────────────────┐         ┌─────────────────────┐
│  Cluster Node 1     │         │  Cluster Node 2     │
│  ocean-node-01      │         │  ocean-node-02      │
│  192.168.1.100      │         │  192.168.1.101      │
│                     │         │                     │
│ • Corosync          │◄────────│ • Corosync          │
│   (networking)      │   mcast  │   (networking)      │
│ • Pacemaker         │   UDP 5405-6
│   (orchestration)   │◄────────│ • Pacemaker         │
│ • NGINX             │   sync   │ • NGINX             │
│ • etcd (optional)   │         │ • etcd (optional)   │
│                     │         │                     │
└──────────┬──────────┘         └──────────┬──────────┘
           │ floating or                    │ floating or
           │ active only                    │ passive only
           │                                │
           └────────────┬───────────────────┘
                        │
                   ┌────▼─────┐
                   │    VIP    │
                   │ 192.168.1.│
                   │   110     │
                   │           │
                   │ Lives on  │
                   │ primary   │
                   │ node only │
                   └───────────┘

       ┌──────────────────────────────────────────┐
       │  If primary dies:                        │
       │  1. Corosync cluster detects absence    │
       │  2. Pacemaker triggers failover         │
       │  3. VIP migrates to secondary via ARP   │
       │  4. NGINX continues serving via VIP     │
       │  Downtime: ~5-10 seconds                │
       └──────────────────────────────────────────┘
```

**Quorum & Cluster Formation:**

**2-Node Cluster:**
- Both nodes required for quorum (stalemate protection)
- If one node dies: cluster remains up (auto_tie_breaker mode)
- If both die: cluster stops (no quorum)

**3-Node Cluster:**
- Quorum: requires 2 of 3 nodes
- Any single node can fail, cluster survives
- **Recommended for production**

**Resource Management:**

| Resource | Type | Role |
|----------|------|------|
| `ocean-vip` | IPaddr2 | Floating IP (migrates between nodes) |
| `ocean-nginx` | systemd:nginx | NGINX process monitor (auto-restart) |
| `ocean-group` | group | Keeps VIP + NGINX together (cohabitation) |

**Failover Workflow:**

1. **Primary healthy:** VIP + NGINX on primary
2. **Primary NGINX stops:** Pacemaker restarts NGINX
3. **Primary NGINX restart fails 3x:** Pacemaker migrates to secondary
4. **Primary node network dies:** Corosync detects, triggers failover
5. **VIP appears on secondary via ARP:** Clients rerouted to secondary

---

### 3. Dockerization (Phase 3)

**Location:** `docker/Dockerfile.ubuntu`, `docker/nginx/performance.conf`, `docker/modsecurity/modsec_default.conf`

**Dockerfile Layers:**

| Layer | Purpose | Packages |
|-------|---------|----------|
| 1-2 | System updates | apt-get, GPG keys |
| 3-4 | NGINX official repo | nginx package signing |
| 5 | NGINX + ModSecurity | nginx, libnginx-mod-modsecurity |
| 6 | OWASP CRS | git clone coreruleset repo |
| 7 | Logs directory | /var/log/modsecurity (www-data ownership) |
| 8 | NGINX config | main nginx.conf (performance tuning) |
| 9 | Default site | SSL/TLS + upstream routing example |
| 10 | ModSecurity enable | Load module + configuration |
| 11 | Binary signature rewrite | `sed` to change "nginx" to "Ocean" |
| 12 | Health check script | /usr/local/bin/health-check.sh |

**Performance Tuning in Dockerfile:**

```dockerfile
# Baked into container image (immutable after build)
# - Worker processes: auto
# - Worker connections: 20480
# - TCP flags: nopush + nodelay
# - Keep-alive: 1000 requests per connection
# - File cache: 200k entries, 20s TTL

# ModSecurity rules: OWASP CRS v4.x
# - 900+ rules covering OWASP Top 10
# - Installed at image build time (no runtime download risk)
# - DetectionOnly mode by default (safe baseline)
```

**Server Header Obscuration:**

```dockerfile
# Single sed command to hide NGINX identity
RUN sed -i 's/Server: nginx/Server: Ocean/g' $(which nginx)
```

**Purpose:** Hide NGINX version from HTTP responses (security through obscuration)

**Result:**
```bash
# Client request
curl -I http://ocean-proxy/
# Response
Server: Ocean  # (vs "nginx/1.25.0")
```

---

### 4. Kubernetes Deployment (Phase 4)

**Location:** `kubernetes/configmap.yaml`, `kubernetes/deployment.yaml`, `kubernetes/service.yaml`, `kubernetes/hpa.yaml`

#### ConfigMap: Application Configuration

**File:** `configmap.yaml`

**Contains:**
- `nginx.conf` - Main NGINX configuration (performance tuning)
- `default-site.conf` - Virtual host (health check, upstream routing)
- `modsec_default.conf` - ModSecurity settings (DetectionOnly baseline)
- `crs-setup.conf` - CRS initialization

**Mounting Strategy:**
```yaml
volumeMounts:
  - name: nginx-config
    mountPath: /etc/nginx/nginx.conf
    subPath: nginx.conf
    readOnly: true
```

**Benefits:**
- Configurations live in ConfigMap (not container image)
- Changes can be applied via `kubectl edit cm ocean-config`
- No container rebuild needed (faster deployment)
- Rollback by reverting ConfigMap (git-style versioning)

#### Deployment: Pod Scheduling & Scaling

**File:** `deployment.yaml`

**Key Specifications:**

| Spec | Value | Purpose |
|------|-------|---------|
| Replicas | 2 | Initial pod count (HPA will auto-scale) |
| Strategy | RollingUpdate | No downtime during updates (1 old pod at a time) |
| Image | ocean:latest | Locally available or registry-hosted |
| Requests CPU | 500m | Kubernetes reserves 0.5 core per pod (for scheduling) |
| Requests Memory | 256Mi | Kubernetes reserves 256MB per pod (for OOM prevention) |
| Limits CPU | 2000m | Pod throttled if exceeds 2 cores (short bursts allowed) |
| Limits Memory | 512Mi | Pod killed (OOMKill) if exceeds 512MB |
| Liveness Probe | /health every 10s | Restart pod if endpoint returns non-200 |
| Readiness Probe | /health every 10s | Remove from load balancer if non-ready |
| Security Context | runAsNonRoot | Pod runs as www-data (uid 33), not root |

**Pod Anti-Affinity:**

```yaml
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - labelSelector: app=ocean
      topologyKey: kubernetes.io/hostname
```

**Effect:** Kubernetes prefers placing pods on different nodes

**Benefit:**
- If single node fails, not all replicas lost
- Load naturally distributed across nodes
- Better fault tolerance

**Scaling Notes:**

- **2 replicas minimum:** HA (survive 1 pod failure)
- **10 replicas maximum:** Prevents resource exhaustion
- **HPA controls actual replicas:** Responds to CPU/memory metrics

#### Service: Load Balancing

**File:** `service.yaml`

**Type: LoadBalancer**
- External clients connect to LoadBalancer EXTERNAL-IP
- Cloud provider (AWS/Azure/GCP) or MetalLB (on-prem) assigns IP
- Internal: Kube-proxy forwards to pod endpoints

**Endpoints:**
- Service dynamically discovers pods matching `app=ocean` label
- Only includes pods passing readinessProbe
- Removed if pod not ready (auto load balancer update)

**Traffic Flow:**
```
Client 203.0.113.50 → Load Balancer → Kube-proxy (iptables rules)
→ Service ClusterIP 10.x.x.x → Pod1 10.244.0.x
                           ↘ Pod2 10.244.1.x
                           ↘ Pod3 10.244.1.x (if scaled)
```

#### HorizontalPodAutoscaler: Dynamic Scaling

**File:** `hpa.yaml`

**Metrics:**

1. **CPU Metric (70% threshold)**
   - Calculation: (actual CPU / requested CPU) × 100
   - Example: 350m actual / 500m requested = 70%
   - Trigger: Scale up when pod uses >350m (0.35 cores)

2. **Memory Metric (80% threshold)**
   - Calculation: (actual memory / requested memory) × 100
   - Example: 205Mi actual / 256Mi requested = 80%
   - Trigger: Scale up when pod uses >205MB

**Scaling Policies:**

**Scale-Up (Aggressive):**
- Wait 15 seconds after scale-up (allow metrics stabilization)
- Scale by max(50%, 2 pods)
- Example: CPU spike at 2 pods → scale to 4 pods (50% increase)

**Scale-Down (Conservative):**
- Wait 300 seconds after scale-down (avoid thrashing)
- Scale by 1 pod per event
- Example: At 4 pods, load drops → wait 5 min → remove 1 pod

---

## Data Flows

### Request Processing Flow

```
1. Client request arrives
   ↓
2. Load Balancer forwards to available pod IP
   ↓
3. Kube-proxy (iptables) routes to NGINX container
   ↓
4. NGINX accept() establishes connection
   ↓
5. Parse HTTP headers (ModSecurity checks)
   ↓
6. Check /health (readiness probe) → return 200
   ↓
7. Route request body through ModSecurity rules
   ↓
8. Proxy to upstream backend (if not health check)
   ↓
9. Wait for backend response
   ↓
10. RewriteResponse headers
   ↓
11. Write response body to client
   ↓
12. If keep-alive enabled: await next request on same connection
    Otherwise: close connection
```

### Auto-Scaling Flow

```
1. Metrics Server collects container metrics (CPU, memory)
   (30-second intervals from kubelet)
   ↓
2. HPA queries Metrics API
   (15-second intervals)
   ↓
3. Calculate average CPU%: sum(pod CPU) / sum(pod requests) / pods
   ↓
4. Compare vs. threshold (70% for CPU)
   ↓
5. If threshold exceeded for stabilization window (15s scale-up):
      Calculate desired replicas: current × (actual% / target%)
      Example: 2 pods at 85% CPU→desired = 2 × (85/70) = 2.43 → 3 pods
      ↓
      Apply scaling policy (add up to 2 pods or 50%)
      → Scale to 4 pods (max of policies)
   ↓
6. If below threshold for cooldown (300s scale-down):
      Remove 1 pod per event
   ↓
7. Kubernetes scheduler places new pods on available nodes
   ↓
8. New pods start (image pull ~5-10s, container startup ~3-5s)
   ↓
9. Once ready, load balancer adds to endpoints
   ↓
10. Traffic naturally distributes to new pods
```

---

## Performance Characteristics

### Single Pod Performance

```
Request arrival rate (req/s):
  NGINX accepts → connection backlog (somaxconn=65535)
  ↓
  Worker processes (auto, typically 8 on 8-core server)
  ↓
  Each worker processes ~5k-12k req/s
  ↓
  Total throughput: 50-100k req/sec per pod (typical)

Connection handling (concurrency):
  worker_connections = 20480 per process
  8 processes × 20480 = ~160k connections
  ↓
  Typical modern client keeps 1-2 connections
  Thus: 160k / 2 = ~80k concurrent clients
```

### Throughput Scaling (Multiple Pods)

```
Load increases → CPU metric > 70%
↓
HPA triggers after 15s stabilization → Add 2-4 pods
↓
New pods ready in ~5-10 seconds
↓
Throughput increases linearly with pod count
2 pods: 100-200k req/sec
4 pods: 200-400k req/sec
6 pods: 300-600k req/sec
10 pods: 500-1000k req/sec
```

### Latency Characteristics

```
Simple health check (/health) latency:
  Kernel scheduling: <1ms
  + Network (localhost): <1ms
  + NGINX parsing: <1ms
  Total: 1-3ms (p50), 5-8ms (p95), 10-20ms (p99)

With ModSecurity (DetectionOnly) overhead:
  + Rule evaluation: +2-3ms
  Total: 3-6ms (p50), 8-11ms (p95), 12-25ms (p99)

With complex backend (100ms response):
  + Backend latency: 100ms
  Total: 100-105ms (p50), 100-110ms (p95), 100-120ms (p99)
  (proxy latency amortized across large backend latency)
```

---

## Failure Modes & Recovery

### Scenario 1: Pod Crash

```
Pod runs NGINX
  ↓
NGINX process crashes (OOMKill, signal, etc.)
  ↓
Container exits (non-zero exit code)
  ↓
Kubernetes detects pod failure (within 5-10 seconds)
  ↓
Liveness probe returns failure 3 times → Kubelet restarts pod
  ↓
Pod re-enters Ready state (readiness probe passes)
  ↓
Load balancer adds back to endpoints
  ↓
Traffic resumes
```

**Recovery Time:** 5-15 seconds (typical)

### Scenario 2: Node Failure

```
Entire Kubernetes node dies (hardware, power loss, kernel panic)
  ↓
Kubelet unreachable from Kube-API server (wait 40 seconds default)
  ↓
Kubernetes marks all node pods as Unknown
  ↓
After 5min default, Kubernetes evicts pods from dead node
  ↓
Pods reschedule on healthy nodes
  ↓
New pods start, ready probe passes
  ↓
Load balancer includes new pods
  ↓
Traffic resumes (from other pods on live nodes)
```

**Recovery Time:** 5-10 minutes (worst case)

**Mitigation:** Use pod anti-affinity (prefer different nodes), ensures 2+ pods on different nodes

### Scenario 3: Network Partition

```
Pod network disconnected (NIC failure, switch issue, VLAN down)
  ↓
Kubelet → Kube-API comms fail
  ↓
Node status → NotReady (after 40s no heartbeat)
  ↓
Pods on that node still running (local)
  ↓
Load balancer removes endpoints (pods invisible to service)
  ↓
If >1 pod on other nodes: traffic continues
  ↓
If ALL pods on isolated node: complete outage (no replicas)
```

**Mitigation:** Minimum 2 pods (better: 3+), on separate nodes (anti-affinity)

### Scenario 4: ConfigMap Update

```
kubectl edit configmap ocean-config
  ↓
ConfigMap updated in etcd
  ↓
Pod's mounted config files reflect new values
  ↓
NGINX keeps running (hasn't reloaded yet)
  ↓
kubectl rollout restart deployment ocean
  ↓
Pods gracefully shutdown (30s timeout), drain connections
  ↓
New pods start with fresh NGINX process
  ↓
New config loaded automatically (mounted from updated ConfigMap)
  ↓
Rolling restart: one pod at a time (service stays up)
```

**Downtime:** 0 seconds (load balancer switches between old/new pods smoothly)

---

## Summary Table

| Component | Technology | Purpose | Failure Impact |
|-----------|-----------|---------|-----------------|
| **OS Tuning** | sysctl + systemd | Extreme throughput, >100k req/sec | Low: gradual performance degradation |
| **Corosync** | UDP 5405-5406 | Cluster networking, membership | Medium: VIP failover (5-10s downtime) |
| **Pacemaker** | Corosync plugin | Resource orchestration, failover | Medium: NGINX restart/migration |
| **NGINX** | Reverse proxy | HTTP/HTTPS termination, ModSecurity | High: traffic loss if all pods down |
| **ModSecurity** | NGINX module | WAF, threat detection logging | Low: logging overhead only (DetectionOnly) |
| **OWASP CRS** | Rule set | Attack pattern matching | Low: processing overhead (+2-3ms) |
| **Docker Image** | Container | Portable application delivery | Medium: requires rebuild/redeploy |
| **Kubernetes** | Orchestration | Pod scheduling, load balancing, scaling | Medium: complicates failure scenarios |
| **ConfigMap** | Config injection | Runtime config management | Low: can cause application errors if malformed |
| **HPA** | Auto-scaler | Dynamic replica adjustment | Low: scaling delays if metrics lag |
| **Load Balancer** | Cloud provider | External traffic distribution | High: if LB fails, no external access |

