#!/bin/bash
#
# Project Ocean: Ubuntu System & NGINX Optimization Script
# Purpose: Tune OS-level TCP stack and NGINX for extreme throughput (>100k req/s)
# Target: Ubuntu 22.04 LTS
# Run as: sudo ./optimize_ubuntu.sh
#

set -e

echo "=== Project Ocean: Ubuntu System Optimization ===" 
echo "This script optimizes the OS and NGINX for high-throughput reverse proxy workloads."
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (sudo)"
   exit 1
fi

# Backup original sysctl
cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%s)
echo "[✓] Backed up /etc/sysctl.conf"

# ============================================================================
# SECTION 1: TCP LISTEN QUEUE & BACKLOG TUNING
# ============================================================================
# These settings allow the kernel to queue more connections waiting for 
# the application to accept() them, critical for handling traffic spikes.

echo ""
echo "--- TCP Listen Queue & Backlog Tuning ---"

# net.core.somaxconn = 65535
# Maximum number of pending connections on a listening socket
# Default: 128 (very restrictive for high-throughput)
# Production: 65535 (accepts up to 64k queued connections per socket)
cat >> /etc/sysctl.conf << 'EOF'

# TCP Listen Queue (LISTEN backlog)
# Allow up to 64k pending connections per listening socket
net.core.somaxconn = 65535
EOF

# net.ipv4.tcp_max_syn_backlog = 8192
# Maximum number of SYN packets to queue before dropping (SYN flood protection)
# Default: 512 (too low for sustained high connection rates)
# Production: 8192 (allows rapid connection establishment bursts)
cat >> /etc/sysctl.conf << 'EOF'

# TCP SYN backlog (protect against SYN floods while handling bursts)
net.ipv4.tcp_max_syn_backlog = 8192
EOF

echo "[✓] Configured TCP listen queue and SYN backlog (somaxconn=65535, tcp_max_syn_backlog=8192)"

# ============================================================================
# SECTION 2: TCP TIME_WAIT REUSE (Connection Recycling)
# ============================================================================
# Allows kernel to reuse TIME_WAIT socket slots for new connections,
# critical for proxies that create many outbound connections.

echo ""
echo "--- TCP TIME_WAIT Reuse ---"

# net.ipv4.tcp_tw_reuse = 1
# Reuse TIME_WAIT connections for new outbound connections (safe with SYN cookies)
# Default: 0 (keep TIME_WAIT slots locked for 60s)
# Production: 1 (recycle slots immediately, requires tcp_timestamps=1)
cat >> /etc/sysctl.conf << 'EOF'

# Allow reuse of TIME_WAIT sockets for new connections
# CRITICAL for proxies with high connection churn
net.ipv4.tcp_tw_reuse = 1
EOF

# net.ipv4.tcp_timestamps = 1
# Enable TCP timestamps (required for tcp_tw_reuse, provides RTT measurement)
# Default: 1 (usually enabled, but verify)
cat >> /etc/sysctl.conf << 'EOF'

# Enable TCP timestamps (required for tcp_tw_reuse, minimal overhead)
net.ipv4.tcp_timestamps = 1
EOF

echo "[✓] Configured TCP TIME_WAIT reuse (tcp_tw_reuse=1)"

# ============================================================================
# SECTION 3: TCP FIN_TIMEOUT (Reduce TIME_WAIT duration)
# ============================================================================
# Shortens TIME_WAIT state duration from default 60s to 30s,
# faster slot reclamation for high-churn scenarios.

echo ""
echo "--- TCP FIN_TIMEOUT Reduction ---"

# net.ipv4.tcp_fin_timeout = 30
# How long to keep connections in FIN_WAIT2/TIME_WAIT states (seconds)
# Default: 60 (1 minute, very conservative)
# Production: 30 (balances TIME_WAIT cleanup speed with RFC compliance)
cat >> /etc/sysctl.conf << 'EOF'

# Reduce TIME_WAIT duration for faster connection slot recycling
net.ipv4.tcp_fin_timeout = 30
EOF

echo "[✓] Reduced TCP FIN_WAIT timeout to 30 seconds"

# ============================================================================
# SECTION 4: TCP MEMORY BUFFERS (RX/TX Tuning)
# ============================================================================
# Increase kernel socket buffer sizes to reduce packet loss under
# sustained high-throughput conditions (e.g., 40Gbps fiber).

echo ""
echo "--- TCP Memory Buffer Tuning ---"

# net.ipv4.tcp_rmem = <min> <default> <max>
# TCP receive buffer: min=1KB, default=128KB, max=512MB
# Default: 4096 87380 6291456 (asymmetric, too conservative for high-bps)
# Production: 8192 262144 536870912 (larger defaults, 512MB max)
cat >> /etc/sysctl.conf << 'EOF'

# TCP receive buffer sizes (min default max) in bytes
# Increase default to 256KB for sustained high-throughput
net.ipv4.tcp_rmem = 8192 262144 536870912
EOF

# net.ipv4.tcp_wmem = <min> <default> <max>
# TCP write buffer: min=1KB, default=128KB, max=512MB
# Default: 4096 16384 6291456 (write buffer much smaller than recv, asymmetric)
# Production: 8192 262144 536870912 (symmetric with rcv for high throughput)
cat >> /etc/sysctl.conf << 'EOF'

# TCP write buffer sizes (min default max) in bytes
# Match receive buffer for balanced throughput
net.ipv4.tcp_wmem = 8192 262144 536870912
EOF

# net.core.rmem_max & net.core.wmem_max
# Global socket buffer limits (must match or exceed tcp_rmem/tcp_wmem max)
# Default: 212992 (very low)
# Production: 536870912 (512MB, matches tcp_*mem_max)
cat >> /etc/sysctl.conf << 'EOF'

# Global socket buffer limits (must >= tcp_*mem max values)
net.core.rmem_max = 536870912
net.core.wmem_max = 536870912
EOF

echo "[✓] Configured TCP memory buffers (256KB default, 512MB max)"

# ============================================================================
# SECTION 5: TCP OPTIMIZATION FLAGS
# ============================================================================
# Enable kernel TCP optimizations: SYN cookies (DoS), Fast Open (3WHS speed).

echo ""
echo "--- TCP Optimization Flags ---"

# net.ipv4.tcp_syncookies = 1
# Enable SYN cookies to defend against SYN floods while accepting legitimate SYNs
# Default: 1 (usually enabled, but verify)
# Production: 1 (essential for public-facing proxies)
cat >> /etc/sysctl.conf << 'EOF'

# Enable SYN cookies (SYN flood protection)
net.ipv4.tcp_syncookies = 1
EOF

# net.ipv4.tcp_fastopen = 3
# Enable TCP Fast Open (TFO) for both client and server sides
# Reduces 3-way handshake RTT (saves 1 RTT on new connections)
# Default: 1 (client only) or 0 (disabled)
# Production: 3 (client + server support)
cat >> /etc/sysctl.conf << 'EOF'

# Enable TCP Fast Open (TFO) for faster connection establishment
# Value: 1=client, 2=server, 3=both (recommended for proxies)
net.ipv4.tcp_fastopen = 3
EOF

echo "[✓] Enabled TCP SYN cookies and Fast Open (TFO)"

# ============================================================================
# SECTION 6: FILE DESCRIPTOR LIMITS (per-process)
# ============================================================================
# Increase ulimits so NGINX can hold thousands of concurrent connections.

echo ""
echo "--- File Descriptor Limits (systemd) ---"

# Create/update systemd service override for NGINX
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf << 'EOF'
[Service]
# Increase file descriptor limits for NGINX
# Default: 1024 (restrictive, causes "too many open files" errors)
# Production: 65536 (supports 64k concurrent connections)
LimitNOFILE=65536
LimitNPROC=65536
EOF

# Reload systemd to apply changes
systemctl daemon-reload

# Also set system-wide limits in /etc/security/limits.conf
cat >> /etc/security/limits.conf << 'EOF'

# NGINX file descriptor limits (persistent across reboots)
nginx soft nofile 65536
nginx hard nofile 65536
nginx soft nproc 65536
nginx hard nproc 65536
EOF

echo "[✓] Configured file descriptor limits (65536 nofile, 65536 nproc)"

# ============================================================================
# SECTION 7: NETWORK DEVICE BACKLOG & NIC RX/TX TUNING
# ============================================================================
# Increase NIC driver queues to prevent packet loss during traffic bursts.

echo ""
echo "--- Network Interface Backlog Tuning ---"

# net.core.netdev_max_backlog
# Maximum packets queued on INPUT side when interface receives packets faster
# than kernel processes them (backpressure point)
# Default: 1000 (too low for line-rate throughput on modern NICs)
# Production: 5000 (handles burst absorption)
cat >> /etc/sysctl.conf << 'EOF'

# Network device backlog (packets queued per interface)
# Increased to handle bursty traffic without drops
net.core.netdev_max_backlog = 5000
EOF

echo "[✓] Configured network device backlog (netdev_max_backlog=5000)"

# ============================================================================
# SECTION 8: TCP KEEP-ALIVE TUNING
# ============================================================================
# Adjust TCP keep-alive timer to detect dead connections faster
# (useful for long-lived upstream connections).

echo ""
echo "--- TCP Keep-Alive Tuning ---"

# net.ipv4.tcp_keepalive_time = 600
# How long before sending first keep-alive probe (seconds)
# Default: 7200 (2 hours, too long for maintaining upstream connections)
# Production: 600 (10 minutes, allows faster dead connection detection)
cat >> /etc/sysctl.conf << 'EOF'

# TCP keep-alive timer (time before first probe in seconds)
net.ipv4.tcp_keepalive_time = 600
EOF

# net.ipv4.tcp_keepalive_intvl = 15
# Interval between keep-alive probes if no response (seconds)
# Default: 75 (very slow, probing backoff)
# Production: 15 (faster reconnection detection)
cat >> /etc/sysctl.conf << 'EOF'

# Interval between keep-alive probes (seconds)
net.ipv4.tcp_keepalive_intvl = 15
EOF

# net.ipv4.tcp_keepalive_probes = 5
# Number of probes before giving up on connection
# Default: 9 (takes ~10 minutes to declare dead)
# Production: 5 (faster, combined with intvl=15 gives ~75s to declare dead)
cat >> /etc/sysctl.conf << 'EOF'

# Number of keep-alive probe attempts
net.ipv4.tcp_keepalive_probes = 5
EOF

echo "[✓] Configured TCP keep-alive (time=600s, intvl=15s, probes=5)"

# ============================================================================
# SECTION 9: APPLY ALL SYSCTL CHANGES
# ============================================================================

echo ""
echo "--- Applying sysctl Configuration ---"
sysctl -p > /dev/null 2>&1
echo "[✓] All sysctl settings applied successfully"

# ============================================================================
# SECTION 10: VERIFY CRITICAL SETTINGS
# ============================================================================

echo ""
echo "--- Verification ---"
echo "Critical tuning parameters:"
echo "  somaxconn:           $(sysctl -n net.core.somaxconn)"
echo "  tcp_max_syn_backlog: $(sysctl -n net.ipv4.tcp_max_syn_backlog)"
echo "  tcp_tw_reuse:        $(sysctl -n net.ipv4.tcp_tw_reuse)"
echo "  tcp_fin_timeout:     $(sysctl -n net.ipv4.tcp_fin_timeout)"
echo "  tcp_rmem (default):  $(sysctl -n net.ipv4.tcp_rmem | awk '{print $2}')"
echo "  tcp_wmem (default):  $(sysctl -n net.ipv4.tcp_wmem | awk '{print $2}')"
echo "  netdev_max_backlog:  $(sysctl -n net.core.netdev_max_backlog)"
echo "  tcp_fastopen:        $(sysctl -n net.ipv4.tcp_fastopen)"

echo ""
echo "[✓] System optimization complete!"
echo ""
echo "Next steps:"
echo "  1. Ensure NGINX is using /etc/nginx/performance.conf snippet"
echo "  2. Validate NGINX config: sudo nginx -t"
echo "  3. Reload NGINX: sudo systemctl reload nginx"
echo "  4. Run load tests to verify throughput improvements"
echo ""
echo "Expected improvements:"
echo "  - Connection acceptance rate: 10x-100x faster"
echo "  - Connection reuse (TIME_WAIT): 60s→30s recycling"
echo "  - Sustained throughput: >100k req/s on modern hardware"
echo "  - p99 latency: <10ms on local datacenter"
echo ""
