# Project Ocean: Performance Baselines & Tuning Guide

## Executive Summary

**Project Ocean** achieves extreme throughput via aggressive OS/NGINX tuning + Kubernetes auto-scaling:
- **Targets:** >100k req/sec per pod, <10ms p99 latency
- **Scale:** 2-10 pods (manual scaling: 1-50+)
- **Cost:** Efficient compute utilization via HPA

This document provides performance expectations, benchmarking methodology, and tuning recommendations for production deployments.

---

## Hardware Assumptions

### Visual Performance Overview

![Performance Scaling Diagram](../diagrams/performance-scaling.svg)

### Hardware Specifications

These baselines assume:

| Component | Spec | Notes |
|-----------|------|-------|
| **CPU** | Modern Intel/AMD Xeon (8+ cores) | Per node or pod limits |
| **Memory** | 16GB+ | System + NGINX overhead ~2GB, rest for buffers |
| **Network** | 10Gbps+ fiber | High-throughput datacenter |
| **Storage** | SSD (for logs) | Optional, not in critical path for proxy |
| **Backend** | Sub-100ms response time | App servers, databases, upstream services |

**If hardware lower:** Reduce expected throughput proportionally. E.g., 4-core, 8GB RAM ≈ 25-50k req/sec.

---

## Baseline Performance Metrics

### Single-Pod Performance (Optimized)

**Workload:** HTTP GET, small responses (100-500 bytes), keep-alive enabled

| Metric | Value | Notes |
|--------|-------|-------|
| **Throughput** | 50-100k req/sec | Depends on response size, backend latency |
| **Latency (p50)** | 1-3ms | Sub-millisecond perception |
| **Latency (p95)** | 5-8ms | Good user experience |
| **Latency (p99)** | 10-20ms | Some occasional delays (acceptable) |
| **CPU/Pod** | 1000-1500m | Request processing, NGINX worker overhead |
| **Memory/Pod** | 150-250Mi | Connection buffers + caches |
| **Concurrency** | 10k-20k | Concurrent connections per pod |

**Conditions:**
- NGINX running on dedicated core (no contention)
- Backend latency: 10ms (typical application server)
- Response size: 500 bytes + headers
- Protocols: HTTP/1.1 with keep-alive
- ModSecurity: DetectionOnly mode (logging without blocking)

### Multi-Pod Performance (With HPA)

**Workload:** Same as above, but scaled via HPA

| Pods | Total Throughput | Linear Scaling | Notes |
|------|------------------|-----------------|-------|
| 2 | 100-200k req/sec | 100% | Baseline HA setup |
| 4 | 200-400k req/sec | 100% | Auto-scale on CPU spike |
| 6 | 300-600k req/sec | 100% | Sustained high load |
| 10 | 500-1000k req/sec | 100% | Peak capacity (max replicas) |

**HPA Scaling Behavior:**
- **Scale-up latency:** 15-30 seconds (metrics collection + pod startup)
- **Scale-down latency:** 300-360 seconds (stabilization window + pod termination)
- **Pod startup:** ~3-5 seconds (kernel networking + NGINX initialization)
- **Efficiency:** 70-80% CPU utilization maintained (HPA target)

---

## Benchmarking Methodology

### Test 1: Baseline Throughput (No Upstream)

**Objective:** Measure NGINX reverse proxy throughput with minimal backend latency

**Setup:**
```bash
# Create simple backend (mock app server)
docker run -d -p 8000:8080 --name backend \
  kennethreitz/httpbin

# Kill real backend, use null route (measures NGINX only)
# Or use NGINX echo module for <1ms response
```

**Test Command:**
```bash
# Using wrk (recommend: https://github.com/wg/wrk)
wrk -t4 -c100 -d60s --latency http://<EXTERNAL-IP>/

# Parameters:
#   -t4       = 4 threads (match CPU cores/2)
#   -c100     = 100 concurrent connections
#   -d60s     = Duration 60 seconds
#   --latency = Report latency percentiles
```

**Expected Results:**
```
Running 1m test @ http://10.0.0.1/
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     5.32ms    2.10ms  45.23ms   85.43%
    Req/Sec    23.41k     1.45k   25.89k    71.43%

  Latency Distribution
     50%    4.05ms
     75%    6.34ms
     90%    8.92ms
     95%   10.21ms
     99%   15.43ms

  5609345 requests in 1.00m, 1.23GB read
  Requests/sec:  93424.08
  Transfer/sec:  20.50MB
```

**Analysis:**
- **93k req/sec** = Good throughput on single pod
- **p99 latency 15ms** = Acceptable for reverse proxy
- **Total throughput / threads = 93k/4 = 23k per thread**

### Test 2: Sustained Load with HPA

**Objective:** Measure scaling behavior and sustained performance

**Setup:**
```bash
# Customize HPA targets for testing (optional):
# - Temporarily lower threshold to 50% for faster scaling
# - kubectl patch hpa ocean-hpa -p '{"spec":{"metrics":[...]}}'

# Monitor in parallel windows:
# Terminal 1: Load generator
# Terminal 2: Pod scaling
# Terminal 3: Metrics (CPU/Memory)
```

**Load Ramp Test:**
```bash
# Phase 1: Baseline (30s)
wrk -t4 -c50 -d30s http://<EXTERNAL-IP>/

# Phase 2: Ramp (120s, gradually increase connections)
wrk -t4 -c200 -d120s http://<EXTERNAL-IP>/

# Phase 3: Sustained Peak (180s)
wrk -t8 -c500 -d180s http://<EXTERNAL-IP>/

# Phase 4: Cooldown (120s, scale-down observation)
wrk -t4 -c50 -d120s http://<EXTERNAL-IP>/
```

**Monitoring Commands (Run in Parallel):**
```bash
# Monitor pods
kubectl get pods -l app=ocean -w

# Monitor HPA
kubectl describe hpa ocean-hpa

# Monitor metrics (every 10s)
watch -n 10 'kubectl top pods -l app=ocean && echo "---" && kubectl top nodes'
```

**Expected Timeline:**
```
T=0s     : 2 pods running, CPU 30%, Memory 60%
T=30s    : Load increases, CPU 65%, Memory 70%
T=60s    : CPU > 70%, HPA triggers scale-up -> 4 pods
T=70s    : 2 new pods starting, request distribution uneven
T=90s    : 4 pods ready, load balanced, CPU 65%, Memory 65%
T=180s   : Sustained load, 4-6 pods running (HPA fine-tuning)
T=240s   : Load drops, CPU 50%, Memory 55%
T=300s   : Scale-down begins, HPA removes 1 pod
T=360s   : 1 pod removed per minute, back to 2 pods
```

### Test 3: P99 Latency Under Load

**Objective:** Verify latency SLA maintained during high throughput

**Setup:**
```bash
# Use Apache Bench with continuous requests
ab -t 120 -c 200 -n 50000 http://<EXTERNAL-IP>/

# Or taurus (more advanced):
# https://gettaurus.org/
```

**Expected Results:**
```
Percentage of requests served within a certain time (ms):
  50%  5
  90%  9
  95%  11
  99%  15  <- P99 target: <20ms acceptable
  100% 45  <- Max outlier (rare)
```

**Success Criteria:**
- P99 < 20ms (or your SLA requirement)
- Max latency < 50ms (outliers acceptable)
- No errors (HTTP 5xx rate = 0%)

### Test 4: Connection Reuse

**Objective:** Measure keep-alive effectiveness

**Before (keep-alive disabled):**
```bash
ab -t 30 -c 1 -k http://<EXTERNAL-IP>/  # -k = no keep-alive
# Expected: ~100 requests/sec
```

**After (keep-alive enabled):**
```bash
ab -t 30 -c 1 http://<EXTERNAL-IP>/  # Default: keep-alive enabled
# Expected: ~1000+ requests/sec (10x improvement)
```

---

## Performance Tuning Recommendations

### Tuning Level 1: Conservative (Production Safe)

Use default values in this deployment. Expected performance:
- **Throughput:** 50-80k req/sec per pod
- **Latency:** <20ms p99
- **Scaling:** Smooth, no thrashing

**Settings:**
- `worker_connections: 20480` (connections per worker)
- `tcp_max_syn_backlog: 8192`
- `cpu threshold: 70%`
- `memory threshold: 80%`

### Tuning Level 2: Aggressive (High Performance)

Increase resource requests and lower thresholds:

**Changes:**
```yaml
# In deployment.yaml
resources:
  requests:
    cpu: 1000m  # Doubled
    memory: 512Mi  # Doubled
  limits:
    cpu: 4000m  # Doubled
    memory: 1Gi  # Doubled

# In hpa.yaml
metrics:
  - resource:
      name: cpu
      target:
        averageUtilization: 60  # More aggressive (was 70%)
  - resource:
      name: memory
      target:
        averageUtilization: 70  # More aggressive (was 80%)
```

**Expected improvements:**
- **Throughput:** 100-150k req/sec per pod
- **Latency:** <10ms p99
- **Trade-off:** Higher compute cost (scales more pods)

### Tuning Level 3: Extreme (Data Center Single Pod)

For dedicated hardware or testing limits:

**Changes:**
```bash
# In nginx.conf
worker_processes 16;  # Match high core count
worker_connections 65536;  # Max typical
keepalive_requests 5000;  # High

# In sysctl:
net.core.somaxconn = 131072
net.ipv4.tcp_max_syn_backlog = 16384
```

**Expected improvements:**
- **Throughput:** 200-500k req/sec (single pod)
- **Latency:** 2-5ms p99
- **Trade-off:** Very aggressive, requires monitoring for errors

### ModSecurity Performance Impact

**DetectionOnly mode (current):**
- CPU overhead: +10-15% (rule evaluation)
- Latency overhead: +2-3ms per request
- No blocking (safe for baseline)

**On mode (after validation):**
- CPU overhead: +20-25% (additional rule actions)
- Latency overhead: +3-5ms per request
- May block requests (requires tuning)

**Recommendation:**
1. Run DetectionOnly for 1-2 weeks
2. Analyze audit log: `grep "Anomaly Score" /var/log/modsecurity/audit.log`
3. Review false positives: `SecRuleRemoveById <id>`
4. Switch to On mode after validation

---

## Monitoring & Alerting

### Key Metrics to Monitor

```bash
# 1. Pod Metrics (via metrics-server)
kubectl top pods -l app=ocean
# Monitor: CPU usage trending, Memory peaks

# 2. HPA Activity
kubectl describe hpa ocean-hpa
# Monitor: Scaling events, metric targets

# 3. Service Endpoints
kubectl get endpoints ocean-svc -w
# Monitor: Pod additions/removals from load balancer

# 4. Logs (ModSecurity detections)
kubectl logs -f -l app=ocean | grep "ModSecurity\|Anomaly"
# Monitor: False positives, legitimate attacks blocked
```

### Prometheus Metrics (If Available)

```
# NGINX metrics (via sidecar exporter)
nginx_http_requests_total  # Total requests served
nginx_http_request_duration_seconds  # Latency histogram

# HPA metrics
kube_hpa_status_desired_replicas  # Current desired replica count
kube_hpa_status_current_replicas  # Actual replica count
kube_hpa_status_*  # Various HPA status metrics
```

### Alerting Rules (Example)

```yaml
# Alert if HPA stuck at max replicas
- alert: HPAMaxedOut
  expr: kube_hpa_status_current_replicas >= kube_hpa_spec_max_replicas
  for: 5m

# Alert if pod restart rate high
- alert: PodRestarts
  expr: rate(kube_pod_container_status_restarts_total[5m]) > 0.1

# Alert if latency exceeds SLA
- alert: HighLatency
  expr: histogram_quantile(0.99, rate(nginx_http_request_duration_seconds[5m])) > 0.020
```

---

## Performance Troubleshooting

### Issue: Throughput Not Reaching Expected Levels

**Check:**
1. Pod CPU utilization (should be 60-80% under sustained load)
2. Backend response time (if >100ms, bottleneck is backend, not NGINX)
3. Network saturation (check NIC utilization)

**Solutions:**
- Increase `worker_connections` (if CPU available)
- Increase pod resource requests (if scheduler has room)
- Optimize backend application (improve response time)

### Issue: High Latency (P99 > 20ms)

**Check:**
1. Pod CPU utilization (if >90%, needs scaling or tuning)
2. GC pauses (if app language has garbage collection)
3. Network latency to backend (tcpdump latency)

**Solutions:**
- Lower HPA CPU threshold to scale sooner
- Disable ModSecurity or run in DetectionOnly mode
- Add reverse proxy caching for repeated requests

### Issue: HPA Scaling Too Slow

**Symptoms:**
- Traffic spike takes > 60 seconds to handle with new pods
- Customers see timeout errors before scaling

**Solutions:**
- Lower stabilization window: `scaleUp.stabilizationWindowSeconds: 10`
- Pre-scale for predictable patterns (time-of-day)
- Use custom metrics (requests/sec) instead of CPU%

---

## Load Testing Best Practices

1. **Ramp gradually:** Start at 10% load, increase by 10% every minute
   - Avoids connection queue overflow
   - Allows system to stabilize at each level

2. **Use persistent connections:** Enable keep-alive (default in wrk)
   - More realistic (modern browsers use persistent)
   - Measures true reverse proxy behavior

3. **Vary response sizes:** Test multiple payloads
   - Small (100B): Network limited
   - Medium (1KB): CPU limited
   - Large (100KB): Bandwidth limited

4. **Test with realistic backends:** Don't use localhost:8000
   - Network latency affects results
   - Use actual application servers if possible

5. **Monitor system:** Watch CPU, memory, network during tests
   - Helps identify bottlenecks
   - Validates tuning changes

---

## Production SLA Targets

Recommended performance thresholds for production:

| SLA | Target | Notes |
|-----|--------|-------|
| **Availability** | 99.95% | <22 minutes downtime/month |
| **P50 Latency** | <5ms | Median user experience |
| **P95 Latency** | <10ms | Good user experience |
| **P99 Latency** | <20ms | Rare exceptions allowed |
| **Error Rate** | <0.1% | 1 in 1000 requests max |
| **Throughput** | >100k req/sec | Per pod minimum |

**If SLAs not being met:**
1. Verify tuning applied correctly (sysctl, NGINX config)
2. Check backend response time (not NGINX's problem if backend slow)
3. Analyze bottleneck: CPU, memory, network, disk
4. Consider caching layer (Redis, Varnish)
5. Add edge caching (CDN for static assets)

---

## Reference Configurations

### High-Throughput (100k+ req/sec)
```nginx
worker_processes auto;
worker_connections 20480;
tcp_nopush on;
tcp_nodelay on;
keepalive_requests 1000;
```

### Low-Latency (<5ms p99)
```nginx
tcp_nodelay on;
sendfile on;
tcp_nopush on;
keepalive_timeout 65;
proxy_buffering off;  # For streaming responses
```

### High-Concurrency (10k+ connections)
```nginx
worker_rlimit_nofile 65536;
worker_connections 20480;
net.core.somaxconn 65535;
net.ipv4.tcp_max_syn_backlog 8192;
```

---

## Conclusion

**Project Ocean** delivers:
- **Throughput:** >100k req/sec per pod (aggregate >500k with 10 pods)
- **Latency:** <10ms p99 (with proper backend)
- **Scalability:** Linear scaling 2-10 pods via HPA
- **Reliability:** HA via Corosync/Pacemaker (bare-metal) or Kubernetes replica distribution

Use this guide to establish performance baselines, tune for your workload, and monitor production deployments.

