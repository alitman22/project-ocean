# Project Ocean: Production Deployment Guide

## Overview

This guide walks through deploying Project Ocean (NGINX + ModSecurity + Kubernetes auto-scaling) across four phases:
1. **OS & NGINX Optimization** (bare-metal Ubuntu servers)
2. **Cluster Setup & Scaling** (Corosync/Pacemaker for HA)
3. **Containerization** (Docker image build)
4. **Kubernetes Deployment** (HPA auto-scaling on self-hosted cluster)

## Prerequisites

### Phase 1-2 (Bare-Metal)
- **Ubuntu 22.04 LTS** (3 nodes minimum for full HA)
  - Node 1: ocean-node-01 (192.168.1.100)
  - Node 2: ocean-node-02 (192.168.1.101)
  - Node 3: ocean-node-03 (192.168.1.102) [add later]
- **Network connectivity**: SSH access between all nodes
- **Floating VIP**: 192.168.1.110 (reserved, not assigned to any single node)
- **sudo access** on all nodes
- **Packages**: pacemaker, corosync, pcs, fence-agents (installed during script)

### Phase 3 (Docker)
- **Docker** installed on build machine
- **Docker daemon** running (sudo systemctl start docker)
- **Internet access** for downloading base images and packages

### Phase 4 (Kubernetes)
- **Self-hosted Kubernetes cluster** (kubeadm, Kubespray, or similar)
- **kubectl** access with admin privileges
- **Metrics Server** installed: `kubectl get deployment metrics-server -n kube-system`
- **Container runtime** (containerd/docker) with ocean:latest image available

---

## Phase 1: OS & NGINX Optimization (Bare-Metal Ubuntu)

### Step 1.1: Download Optimization Script
```bash
# On each Ubuntu node
cd /opt
sudo wget https://<your-repo>/scripts/optimize_ubuntu.sh
sudo chmod +x optimize_ubuntu.sh
```

### Step 1.2: Run Optimization Script
```bash
# On each node (node-01, node-02, node-03)
sudo ./optimize_ubuntu.sh
```

**What it does:**
- Appends tuning parameters to `/etc/sysctl.conf`
  - `net.core.somaxconn=65535` (listen backlog)
  - `net.ipv4.tcp_tw_reuse=1` (connection recycling)
  - `net.ipv4.tcp_fin_timeout=30` (time_wait cleanup)
  - `net.ipv4.tcp_rmem/wmem` (socket buffers)
  - And 10+ more TCP stack optimizations
- Creates `/etc/systemd/system/nginx.service.d/override.conf` for systemd limits
- Loads new sysctl settings immediately (`sysctl -p`)
- Verifies critical parameters applied

**Verification:**
```bash
# Check sysctl values
sysctl net.core.somaxconn
# Expected: 65535

# Check file descriptor limits
ulimit -n
# Expected: 65536 (after reload/re-ssh)
```

**Estimated Time:** 2-3 minutes per node

**Expected Outcome:**
- Network stack optimized for high throughput
- System ready for NGINX with >100k req/s capacity
- No service restarts required

---

## Phase 2: Corosync/Pacemaker Cluster Setup & Scaling

### Step 2.1: Install Pacemaker/Corosync Packages (All Nodes)
```bash
# On all 3 nodes
sudo apt-get update && sudo apt-get install -y \
    pacemaker corosync pcs fence-agents
```

### Step 2.2: Bootstrap 2-Node Cluster
```bash
# Run on node-01 (primary)
cd /opt
sudo chmod +x bootstrap_cluster.sh
sudo ./bootstrap_cluster.sh ocean-node-01 192.168.1.100 \
                             ocean-node-02 192.168.1.101
```

**Interactive prompts:**
- Enter hacluster password (same on all nodes)
- Wait for cluster to form (~10 seconds)

**What it does:**
- Authorizes nodes (exchanges hacluster credentials)
- Creates cluster configuration (Corosync)
- Starts Corosync/Pacemaker services
- Creates floating VIP (192.168.1.110) as IPaddr2 resource
- Creates systemd NGINX resource (monitored by Pacemaker)
- Groups them together (VIP + NGINX migrate as unit)
- Disables STONITH (fencing) for lab/testing mode

**Verification:**
```bash
# Check cluster status
pcs cluster status

# Expected output:
# Cluster name: ocean-cluster
# Status: ONLINE
# Cluster Summary:
#   * Quorum: ONLINE

# Check resource status
pcs resource status

# Expected: ocean-group with ocean-vip and ocean-nginx RUNNING
```

**Estimated Time:** 3-5 minutes

### Step 2.3: Test Failover (Verify HA Works)
```bash
# Simulate primary node NGINX crash
sudo systemctl stop nginx

# On secondary node, check if VIP migrated
ip addr show  # Should see 192.168.1.110

# On primary node, NGINX should auto-restart (after Pacemaker restarts it)
sudo systemctl status nginx  # After ~30 seconds

# Restart primary NGINX to migrate VIP back
sudo systemctl start nginx

# Verify VIP returns to primary
ip addr show
```

### Step 2.4: Add 3rd Node (Scale Cluster)
```bash
# Prepare node-03 first
# - Install pacemaker/corosync/pcs (same as Step 2.1)
# - Run optimize_ubuntu.sh (same as Phase 1)

# Then, run from node-01:
cd /opt
sudo chmod +x add_cluster_node.sh
sudo ./add_cluster_node.sh ocean-node-03 192.168.1.102
```

**What it does:**
- Authorizes new node
- Adds to cluster membership
- Starts services on new node
- Updates quorum for 3-node cluster
- Waits for node to join

**Verification:**
```bash
pcs cluster nodes
# Expected: 3 nodes listed
# ocean-node-01
# ocean-node-02
# ocean-node-03
```

**Estimated Time:** 2-3 minutes

### Step 2.5: Node Removal (if needed)
```bash
# To safely remove node-03:
cd /opt
sudo chmod +x drain_remove_node.sh
sudo ./drain_remove_node.sh ocean-node-03
```

**What it does:**
- Sets node to standby (no new resources)
- Waits for resources to migrate to other nodes
- Stops services gracefully
- Removes from cluster config
- Updates quorum back to 2-node mode

---

## Phase 3: Containerization (Docker Build)

### Step 3.1: Prepare Docker Build Environment
```bash
# On build machine (can be any machine with Docker)
mkdir -p /tmp/ocean-build
cd /tmp/ocean-build

# Copy Dockerfile and configs
cp scripts/docker/Dockerfile.ubuntu .
cp scripts/docker/nginx/performance.conf .
cp scripts/docker/modsecurity/modsec_default.conf .
```

### Step 3.2: Build Ocean Docker Image
```bash
# Build image (tagged as ocean:latest)
docker build -t ocean:latest -f Dockerfile.ubuntu .

# Expected output:
# Step X/12 : FROM ubuntu:22.04
# ...
# Successfully tagged ocean:latest
```

**Build Time:** 5-10 minutes (depends on network, downloading packages)

### Step 3.3: Verify Image
```bash
# Check image was created
docker images | grep ocean

# Test image runs
docker run -d -p 8080:80 --name ocean-test ocean:latest

# Check /health endpoint
curl http://localhost:8080/health
# Expected: "ok"

# Verify Server header is rewritten to "Ocean"
curl -I http://localhost:8080 | grep Server
# Expected: Server: Ocean

# Stop test container
docker stop ocean-test && docker rm ocean-test
```

### Step 3.4: Push to Container Registry (Optional, for Multi-Node Clusters)
```bash
# For self-hosted cluster, push to private registry or load image on each node

# Option A: Push to private Docker registry
docker tag ocean:latest <registry-ip>:5000/ocean:latest
docker push <registry-ip>:5000/ocean:latest

# Option B: Export and load on each node
docker save ocean:latest | gzip > ocean-latest.tar.gz
scp ocean-latest.tar.gz <node>:/tmp/
ssh <node> "docker load < /tmp/ocean-latest.tar.gz"
```

---

## Phase 4: Kubernetes Deployment & Auto-Scaling

### Step 4.1: Verify Kubernetes Cluster & Metrics Server
```bash
# Check cluster healthy
kubectl cluster-info
# Expected: Kubernetes master is running

# Check metrics-server installed
kubectl get deployment metrics-server -n kube-system
# Expected: metrics-server running (1 replica)

# If missing, install:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Verify metrics available (wait ~1 minute)
kubectl top nodes
# Expected: Node CPU/Memory shown
```

### Step 4.2: Create Kubernetes Manifests Locally
```bash
# Copy manifests from project-ocean repository
cd ~/project-ocean/kubernetes
ls -la
# configmap.yaml deployment.yaml service.yaml hpa.yaml

# Review and customize if needed:
# - configmap.yaml: NGINX + ModSecurity configs
# - deployment.yaml: Pod specs, health checks, resource requests
# - service.yaml: LoadBalancer/ClusterIP exposure
# - hpa.yaml: Auto-scaling (CPU >70%, Memory >80%)
```

### Step 4.3: Apply ConfigMap (Configurations)
```bash
# Create ConfigMap from predefined YAML
kubectl apply -f configmap.yaml

# Verify ConfigMap created
kubectl get configmap ocean-config
kubectl describe cm ocean-config

# Expected: Shows nginx.conf, default-site.conf, modsec_default.conf
```

### Step 4.4: Apply Deployment
```bash
# Deploy Ocean pods
kubectl apply -f deployment.yaml

# Watch rollout
kubectl rollout status deployment/ocean -w
# Expected: "deployment "ocean" successfully rolled out"

# Check pods running
kubectl get pods -l app=ocean -w
# Expected: 2 pods in Running state

# Watch logs
kubectl logs -f -l app=ocean
```

**Troubleshooting Common Issues:**

```bash
# Pod status: "ImagePullBackOff"
# Cause: Docker image not available on cluster

# Solution:
#   1. If using private registry: update .imagePullSecrets in deployment
#   2. If using local image: load via docker load on each node

# Pod status: "CrashLoopBackOff"
# Check logs:
kubectl logs <pod-name>

# Common causes:
# - NGINX config syntax error: kubectl exec <pod> -- nginx -t
# - ModSecurity issues: check audit.log in pod
```

### Step 4.5: Apply Service (Exposure)
```bash
# Expose pods via LoadBalancer service
kubectl apply -f service.yaml

# Check service status
kubectl get svc ocean-svc

# Expected output:
# NAME        TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)
# ocean-svc   LoadBalancer   10.x.x.x        <pending> or IP   80:30123/TCP

# Wait for EXTERNAL-IP (may take 1-2 minutes for cloud providers)
kubectl get svc ocean-svc -w

# Once EXTERNAL-IP assigned:
# Curl the service
curl http://<EXTERNAL-IP>/health
# Expected: "ok"
```

### Step 4.6: Apply HorizontalPodAutoscaler
```bash
# Enable auto-scaling
kubectl apply -f hpa.yaml

# Check HPA status
kubectl get hpa ocean-hpa

# Expected:
# NAME        REFERENCE             TARGETS           MINPODS MAXPODS REPLICAS
# ocean-hpa   Deployment/ocean      65%/70%, 60%/80%  2       10      2
```

### Step 4.7: Load Test (Verify Scaling Works)
```bash
# Generate load using wrk or Apache Bench
# Install wrk: https://github.com/wg/wrk

# Terminal 1: Run load test (generates load for 60 seconds)
wrk -t4 -c100 -d60s http://<EXTERNAL-IP>/

# Terminal 2: Watch pods scale up
kubectl get pods -l app=ocean -w

# Expected:
# - While load running: pods increase (e.g., 2 -> 4 -> 6)
# - Metric: kubectl top pods -l app=ocean (watch CPU%)
# - HPA logs: kubectl describe hpa ocean-hpa

# Terminal 3: Watch HPA activity
kubectl get hpa ocean-hpa -w

# Expected:
# - REPLICAS column increases
# - TARGETS shows CPU% increasing
# - When load stops: gradual scale-down (over 250-300 seconds)
```

**Expected Load Test Results:**

```
Baseline (2 pods, low load):
  - Throughput: ~5k-10k req/s per pod = 10k-20k total
  - Latency: <10ms p99
  - CPU: ~40-50% per pod

Under Load > 70% CPU:
  - Pods scale up: 2 -> 4 -> 6 (depending on load)
  - New pods ready in ~5-10 seconds
  - Total throughput scales linearly
  - Latency maintained <10ms p99 (because resources scale)

After Load Stops:
  - Scale-down: 6 -> 5 -> 4 -> 3 -> 2 pods
  - One pod removed per minute (conservative)
  - Takes ~240 seconds to return to 2 pods
```

---

## Post-Deployment Verification

### Checklist

```bash
# 1. Verify all pods running
kubectl get pods -l app=ocean
# Expected: 2 Running

# 2. Verify endpoints (pods receiving traffic)
kubectl get endpoints ocean-svc
# Expected: 2 endpoints listed with pod IPs

# 3. Verify HPA tracking metrics
kubectl describe hpa ocean-hpa
# Expected: "Metrics: <some value>% / 70%"

# 4. Verify service external IP
kubectl get svc ocean-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Expected: IP address

# 5. Test health check
curl http://<EXTERNAL-IP>/health
# Expected: "ok"

# 6. View logs (no errors)
kubectl logs -l app=ocean --tail=100
# Expected: NGINX startup messages, no errors

# 7. Check ModSecurity detection
kubectl exec <pod> -- cat /var/log/modsecurity/audit.log | head -20
# Expected: May show scans/attacks detected (if detecting scanning behavior)
```

### Performance Baseline

Run sustained load test to establish baseline:

```bash
# 5-minute sustained load test
wrk -t8 -c500 -d300s --latency http://<EXTERNAL-IP>/

# Record metrics:
# - Requests/sec
# - Latency (avg, p50, p95, p99)
# - Pod count (should remain stable if load <= 70% CPU)
# - CPU/Memory per pod
```

---

## Troubleshooting Guide

| Issue | Cause | Solution |
|-------|-------|----------|
| Pods not starting (ImagePullBackOff) | Docker image not available | Load image on nodes or push to registry |
| Readiness probe failing | /health endpoint returning non-200 | Check NGINX config, verify container networking |
| HPA not scaling | Metrics Server not installed or metrics unavailable | Install/restart metrics-server, verify .resources.requests set |
| High latency when scaling | Network overhead during pod startup | Normal during first ~5 seconds, should stabilize |
| Cluster VIP not responding | Corosync/Pacemaker not running | `systemctl status pacemaker corosync` on all nodes |

---

## Production Recommendations

1. **Enable STONITH (Fencing):** Replace `stonith-enabled=false` with actual fence device for production

2. **Enable ModSecurity Blocking:** Change `SecRuleEngine DetectionOnly` to `SecRuleEngine On` after 2-week baseline

3. **Set Up Centralized Logging:** Send audit logs to ELK stack or Splunk for investigation

4. **Configure Ingress:** Use Kubernetes Ingress for path-based routing, SSL termination

5. **Add Persistent Logging:** Store ModSecurity audit logs in PersistentVolume for compliance

6. **Scale Beyond 10 Replicas:** If load exceeds 10 pods capacity, upgrade cluster or add custom metrics

7. **Monitor Metrics:** Set up Prometheus scraping for custom alarms on anomaly scores

---

## Cleanup (If Needed)

```bash
# Delete Kubernetes deployment
kubectl delete deployment ocean
kubectl delete svc ocean-svc
kubectl delete configmap ocean-config
kubectl delete hpa ocean-hpa

# Delete bare-metal cluster
pcs cluster destroy --all

# Remove Corosync/Pacemaker packages
sudo apt-get purge pacemaker corosync pcs
```

---

## Support & Questions

- **NGINX Optimization:** Review `docker/nginx/performance.conf` for tuning explanation
- **ModSecurity:** Check `docker/modsecurity/modsec_default.conf` for rule management
- **Cluster:** Review bootstrap/add/drain scripts for operation details
- **Kubernetes:** See inline comments in `kubernetes/*.yaml` manifests

