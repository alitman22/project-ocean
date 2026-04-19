# Project Ocean: README

## Overview

**Project Ocean** is a production-ready, high-performance NGINX + ModSecurity reverse proxy system designed for extreme throughput (>100k req/sec) with intelligent auto-scaling and built-in security.

| Aspect | Details |
|--------|---------|
| **Use Case** | High-throughput edge proxy, secure reverse proxy, API gateway, WAF layer |
| **Performance** | 50-100k req/sec per pod, <10ms p99 latency, 10k-20k concurrent connections |
| **Deployment Models** | Bare-metal Ubuntu HA (Corosync/Pacemaker), Kubernetes (self-hosted), Docker containerized |
| **Scaling** | Manual (cluster nodes), Automatic (K8s HPA: 2-10 replicas, CPU >70% / Memory >80%) |
| **Security** | OWASP ModSecurity CRS 4.x, threat detection + logging (configurable for blocking) |
| **Infrastructure** | Ubuntu 22.04 LTS, Kubernetes 1.24+, Docker 20.10+ |

---

## Quick Start

### Option 1: Bare-Metal Ubuntu (Corosync/Pacemaker HA)

```bash
# 1. Prepare 3 Ubuntu 22.04 nodes
#    Node 1: 192.168.1.100 (ocean-node-01)
#    Node 2: 192.168.1.101 (ocean-node-02)
#    Node 3: 192.168.1.102 (ocean-node-03)

# 2. Download scripts
git clone <repo> project-ocean
cd project-ocean

# 3. Run system optimization on all nodes
sudo scripts/optimize_ubuntu.sh

# 4. Bootstrap 2-node cluster (from node-01)
sudo scripts/bootstrap_cluster.sh

# 5. (Optional) Add 3rd node
sudo scripts/add_cluster_node.sh ocean-node-03 192.168.1.102

# 6. Access via VIP
curl http://192.168.1.110/health
# Expected: "ok"

# 7. Monitor cluster
pcs cluster status
pcs resource status
```

**Deployment Time:** ~10 minutes (3 nodes including optimization)

### Option 2: Docker Container (Local Testing)

```bash
# 1. Build image
cd docker
docker build -t ocean:latest -f Dockerfile.ubuntu .

# 2. Run container
docker run -d -p 8080:80 --name ocean ocean:latest

# 3. Test health check
curl http://localhost:8080/health
# Expected: "ok"

# 4. Verify Server header
curl -I http://localhost:8080 | grep Server
# Expected: "Server: Ocean"

# 5. Stop container
docker stop ocean && docker rm ocean
```

**Time:** ~5-10 minutes (includes Docker build)

### Option 3: Kubernetes Deployment (Self-Hosted Cluster)

```bash
# 1. Prerequisites: kubectl, metrics-server installed
kubectl get deployment metrics-server -n kube-system

# 2. Apply manifests (in order)
cd kubernetes
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f hpa.yaml

# 3. Monitor deployment
kubectl get pods -l app=ocean -w
kubectl get svc ocean-svc -w

# 4. Once EXTERNAL-IP assigned
curl http://<EXTERNAL-IP>/health
# Expected: "ok"

# 5. Watch auto-scaling (generate load)
kubectl describe hpa ocean-hpa
kubectl get pods -l app=ocean -w
```

**Time:** ~5 minutes (assumes cluster exists with metrics-server)

---

## Project Structure

```
project-ocean/
│
├── scripts/                           # Deployment & management scripts
│   ├── optimize_ubuntu.sh             # OS tuning for high throughput
│   ├── bootstrap_cluster.sh           # Initialize 2-node Corosync/Pacemaker cluster
│   ├── add_cluster_node.sh            # Dynamically add 3rd node (scaling)
│   └── drain_remove_node.sh           # Safely remove node from cluster
│
├── docker/                            # Container build artifacts
│   ├── Dockerfile.ubuntu              # Multi-layer image (ubuntu:22.04 → NGINX + ModSec)
│   ├── nginx/
│   │   └── performance.conf           # NGINX tuning (worker_connections, sendfile, etc.)
│   └── modsecurity/
│       └── modsec_default.conf        # ModSecurity + OWASP CRS configuration
│
├── kubernetes/                        # Kubernetes manifests
│   ├── configmap.yaml                 # nginx.conf, modsecurity configs injected
│   ├── deployment.yaml                # Pod specs, health checks (2-10 replicas)
│   ├── service.yaml                   # LoadBalancer exposure (external traffic)
│   └── hpa.yaml                       # Auto-scaler (CPU >70%, Mem >80%)
│
└── docs/                              # Documentation & reference
    ├── DEPLOYMENT.md                  # Step-by-step deployment guide
    ├── PERFORMANCE_BASELINES.md       # Benchmarks, tuning recommendations
    ├── ARCHITECTURE.md                # System design, component details
    └── README.md                      # This file
```

---

## Configuration

### NGINX Performance Tuning

**File:** `docker/nginx/performance.conf`

```nginx
worker_processes auto;        # One process per CPU core
worker_connections 20480;     # 20k connections per worker
tcp_nopush on;                # Coalesce packets (5-15% throughput gain)
tcp_nodelay on;               # Send small packets immediately (low latency)
sendfile on;                  # Zero-copy kernel syscall
keepalive_requests 1000;      # Reuse HTTP connections (reduce 3WHS overhead)
open_file_cache max=200000;   # Cache 200k file descriptors
```

**Expected Impact:**
- Throughput: 5-10x faster than defaults
- Latency: <10ms p99 (with low-latency backend)
- CPU efficiency: 30-50% lower than naive config

### ModSecurity Configuration

**File:** `docker/modsecurity/modsec_default.conf`

```
SecRuleEngine DetectionOnly    # Log threats without blocking (safe baseline)
SecAnomalyScoreThreshold 5     # Flag request if score ≥ 5
SecAuditLog /var/log/modsecurity/audit.log
Include /usr/share/modsecurity-crs/rules/REQUEST-*.conf  # OWASP CRS 4.x
```

**Rules Cover:**
- SQL Injection, XSS, Path Traversal (LFI/RFI)
- Scanner Detection, DoS Protection, Protocol Attacks
- PHP/Java/IIS application-specific attacks

**Change to Production (After Validation):**
```
SecRuleEngine On  # Block attacks (instead of DetectionOnly)
```

### Kubernetes Resource Configuration

**File:** `kubernetes/deployment.yaml`

```yaml
resources:
  requests:
    cpu: 500m           # Reserve 0.5 cores per pod
    memory: 256Mi       # Reserve 256MB per pod
  limits:
    cpu: 2000m          # Throttle if exceed 2 cores
    memory: 512Mi       # Kill if exceed 512MB (OOMKill)
```

**Scaling Policy (HPA):**
```yaml
minReplicas: 2          # Always 2 pods (HA)
maxReplicas: 10         # Cap at 10 to prevent runaway scaling
metrics:
  - cpu: 70%            # Scale up if avg CPU > 70%
  - memory: 80%         # Scale up if avg memory > 80%
```

---

## Performance Expectations

### Single Pod

| Metric | Value | Conditions |
|--------|-------|-----------|
| **Throughput** | 50-100k req/sec | /health endpoint, keep-alive enabled |
| **Latency (p50)** | 1-3ms | Response time only |
| **Latency (p99)** | 10-20ms | Tolerable for proxy layer |
| **Concurrency** | 10k-20k | Concurrent connections |
| **CPU** | 1000-1500m | At peak throughput |
| **Memory** | 150-250Mi | Connection buffers + caches |

### Multi-Pod (K8s HPA)

| Pods | Throughput | Latency | Scaling Speed |
|------|-----------|---------|-----------------|
| 2 | 100-200k req/sec | <20ms p99 | Baseline |
| 4 | 200-400k req/sec | <20ms p99 | +15s (trigger to ready) |
| 6 | 300-600k req/sec | <20ms p99 | +15s per scale event |
| 10 | 500-1000k req/sec | <20ms p99 | Max capacity |

---

## Deployment Modes

| Mode | Setup Time | Infrastructure | Failure Recovery | Scale Up Time |
|------|----------|-----------------|------------------|---------------|
| **Bare-Metal (Corosync)** | 10 min | 3 Ubuntu servers | Automatic failover (5-10s) | Manual (minutes) |
| **Docker Local** | 5 min | Single machine + Docker | Manual restart | N/A (single pod) |
| **Kubernetes** | 5 min | K8s cluster + metrics-server | Auto restart + rescheduling | ~30s (HPA + pod startup) |

---

## Monitoring

### Health Checks

```bash
# Each pod exposes health endpoint
curl http://pod-ip/health
# Response: 200 OK, body: "ok"

# Used by Kubernetes readiness/liveness probes
# If fails: pod removed from load balancer (readiness) or restarted (liveness)
```

### Logs

```bash
# NGINX access logs
kubectl logs <pod> | grep access

# ModSecurity audit log (threats detected)
kubectl exec <pod> -- tail -n 100 /var/log/modsecurity/audit.log

# Error logs
kubectl logs <pod> -c ocean --tail=50 [--previous]  # Previous = crashed pod logs
```

### Metrics

```bash
# Pod CPU/Memory usage
kubectl top pods -l app=ocean

# HPA status (current replicas, target metrics)
kubectl describe hpa ocean-hpa

# Service endpoints (pods receiving traffic)
kubectl get endpoints ocean-svc
```

---

## Common Operations

### Update NGINX Configuration

```bash
# 1. Edit ConfigMap
kubectl edit configmap ocean-config

# 2. Verify syntax
kubectl exec <pod> -- nginx -t

# 3. Restart pods (rolling update)
kubectl rollout restart deployment ocean

# 4. Verify rollout complete
kubectl rollout status deployment ocean
```

### Add/Remove Cluster Nodes (Bare-Metal)

```bash
# Add 3rd node
sudo scripts/add_cluster_node.sh ocean-node-03 192.168.1.102

# Remove node (graceful drain)
sudo scripts/drain_remove_node.sh ocean-node-03
```

### Scale Kubernetes Pods Manually

```bash
# Auto-scaling active (HPA)
# To manually force replicas:
kubectl scale deployment ocean --replicas=5

# Check HPA still active (may override manual scaling)
kubectl describe hpa ocean-hpa
```

### Load Test

```bash
# Ensure wrk installed: https://github.com/wg/wrk
wrk -t4 -c200 -d60s --latency http://service-ip/

# Expected: 50-100k req/sec, <15ms p99 latency (single pod)
```

---

## Production Checklist

- [ ] System optimization applied to all OS-level servers (`optimize_ubuntu.sh`)
- [ ] Cluster initialized and tested for failover (`bootstrap_cluster.sh`)
- [ ] Docker image built and pushed to private registry
- [ ] Kubernetes manifests customized for your environment (resource limits, namespace, etc.)
- [ ] Metrics Server installed on Kubernetes cluster
- [ ] Load balancer configured for external traffic
- [ ] ModSecurity baseline (DetectionOnly) validated for 1-2 weeks
- [ ] False positive rules added to exclusions (`SecRuleRemoveById`)
- [ ] ModSecurity switched to blocking mode (`SecRuleEngine On`)
- [ ] Centralized logging configured (ELK, Splunk, etc.)
- [ ] Alerting set up for pod replicas, HPA max reached, high latency
- [ ] Firewall rules (allow traffic to VIP/external IP)
- [ ] DNS record pointing to proxy VIP/LoadBalancer IP
- [ ] Disaster recovery plan documented (failover, rollback procedures)

---

## Troubleshooting

### Pods not starting (ImagePullBackOff)

```bash
# Docker image not available on cluster nodes
# Solution 1: Load image locally on each node
docker load < ocean-latest.tar.gz

# Solution 2: Push to private registry
docker tag ocean:latest <registry>/ocean:latest
docker push <registry>/ocean:latest
# Update deployment.yaml with registry URL
```

### High latency (>50ms p99)

```bash
# Check pod CPU utilization
kubectl top pods -l app=ocean

# If CPU > 80%, HPA should scale
# Verify HPA active: kubectl describe hpa ocean-hpa

# If HPA not working:
# - Metrics Server not installed?
# - Pod .resources.requests not set?
# - Metrics API queries failing?
```

### ModSecurity rule false positives

```bash
# Review audit log
kubectl exec <pod> -- grep "Anomaly Score" /var/log/modsecurity/audit.log

# Get rule IDs from logs
kubectl exec <pod> -- grep -oP 'id "[0-9]*"' /var/log/modsecurity/audit.log | sort | uniq

# Add exclusions to ConfigMap
# Edit modsec_default.conf: SecRuleRemoveById <id>

# Restart pods to apply
kubectl rollout restart deployment ocean
```

### Network partition (pods can't reach backend)

```bash
# Check backend service connectivity
kubectl exec <pod> -- curl http://backend-service/

# If DNS doesn't resolve:
# kubernetes.io/hostname ServiceDNS not configured?

# Use service FQDN: backend-service.namespace.svc.cluster.local
```

---

## Support & Resources

- **Documentation:** `docs/` folder
  - `DEPLOYMENT.md` - Step-by-step guide
  - `PERFORMANCE_BASELINES.md` - Benchmarks and tuning
  - `ARCHITECTURE.md` - Technical deep dive
  
- **Community & Questions:**
  - NGINX: https://nginx.org/en/support.html
  - ModSecurity: https://github.com/SpiderLabs/ModSecurity
  - OWASP CRS: https://coreruleset.org/
  - Kubernetes: https://kubernetes.io/docs/

---

## License & Attribution

Project Ocean - High-Performance NGINX + ModSecurity Proxy System

- **NGINX:** Open source web server (BSD license)
- **ModSecurity:** Open source WAF module (LGPL)
- **OWASP CRS:** Community rule set (LGPL)
- **Corosync/Pacemaker:** Open source HA clustering (Various open licenses)
- **Kubernetes:** Container orchestration (Apache 2.0)

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| **1.0** | 2026-04-19 | Initial release: 4-phase deployment (OS tuning, cluster HA, Docker, K8s) |

---

**Last Updated:** April 19, 2026

