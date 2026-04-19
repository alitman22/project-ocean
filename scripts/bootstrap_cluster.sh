#!/bin/bash
#
# Project Ocean: Corosync/Pacemaker Cluster Bootstrap (2-Node HA)
# Purpose: Initialize a 2-node NGINX HA cluster with floating VIP and CARP-style failover
# Target: Ubuntu 22.04 LTS (both nodes)
# Prerequisites: sudo, pcs/pacemaker packages installed on both nodes
# Run on: Either node as sudo (will coordinate with peer)
#

set -e

CLUSTER_NAME="ocean-cluster"
NODE1_HOSTNAME="${1:-ocean-node-01}"
NODE1_IP="${2:-192.168.1.100}"
NODE2_HOSTNAME="${3:-ocean-node-02}"
NODE2_IP="${4:-192.168.1.101}"
VIP="192.168.1.110"
VIP_NETMASK="255.255.255.0"

echo "=== Project Ocean: Corosync/Pacemaker Cluster Bootstrap ==="
echo ""
echo "Configuration:"
echo "  Cluster Name:        $CLUSTER_NAME"
echo "  Node 1:              $NODE1_HOSTNAME ($NODE1_IP)"
echo "  Node 2:              $NODE2_HOSTNAME ($NODE2_IP)"
echo "  Floating VIP:        $VIP"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (sudo)"
   exit 1
fi

# Verify prerequisites
echo "--- Checking Prerequisites ---"
for cmd in pcs corosync-cmapctl; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR: $cmd not found. Install pacemaker/corosync first:"
        echo "  sudo apt-get install pacemaker corosync pcs fence-agents -y"
        exit 1
    fi
done
echo "[✓] Pacemaker/Corosync packages found"

# Get local hostname and IP
LOCAL_HOSTNAME=$(hostname)
echo "[✓] Local hostname: $LOCAL_HOSTNAME"

# ============================================================================
# STEP 1: Authorize Cluster Nodes (hacluster user authentication)
# ============================================================================
echo ""
echo "--- Step 1: Authorizing Cluster Nodes ---"
echo "Authenticating nodes (you will be prompted for hacluster password on each node)"
echo ""

# pcs cluster auth <node1> <node2> ... -u hacluster -p <password>
# Establishes trust between nodes by exchanging hacluster user credentials
# Prompts for password interactively (stored securely in /var/lib/pcsd/pcs_settings.py)
pcs cluster auth $NODE1_HOSTNAME $NODE2_HOSTNAME -u hacluster
echo "[✓] Nodes authorized"

# ============================================================================
# STEP 2: Initialize 2-Node Cluster with Quorum Configuration
# ============================================================================
echo ""
echo "--- Step 2: Initializing 2-Node Cluster ---"

# pcs cluster setup <cluster-name> <node1> <node2> [options]
# Creates cluster.conf, starts corosync/pacemaker on all nodes
# For 2-node cluster, we must set two_node and auto_tie_breaker for proper quorum
pcs cluster setup \
    --name $CLUSTER_NAME \
    $NODE1_HOSTNAME \
    $NODE2_HOSTNAME \
    --token 5000 \
    --join 20000
echo "[✓] Cluster configuration created"

# ============================================================================
# STEP 3: Set Quorum Policy for 2-Node Clusters
# ============================================================================
echo ""
echo "--- Step 3: Configuring Quorum for 2-Node Cluster ---"

# For 2-node clusters, we use:
#   two_node: 1        (enable special 2-node mode)
#   auto_tie_breaker: 1 (allow cluster to remain up even if 1 node down)
# Without these, a 2-node cluster requires both nodes to form quorum (no fault tolerance)

pcs quorum expected-votes 2
pcs quorum device remove model net 2>/dev/null || true  # Remove any existing quorum device
pcs quorum device add model net algorithm=ffsplit host=$NODE1_IP

# Alternative simpler approach: declare quorum not_required (for testing)
# pcs property set no-quorum-policy=ignore

echo "[✓] Quorum policy configured for 2-node cluster (auto_tie_breaker enabled)"

# ============================================================================
# STEP 4: Start Cluster Services
# ============================================================================
echo ""
echo "--- Step 4: Starting Cluster Services ---"

# pcs cluster start --all
# Starts Corosync (networking/membership) and Pacemaker (resource management) on all nodes
pcs cluster start --all
echo "[✓] Cluster services started on all nodes"

# Wait for cluster to stabilize
sleep 5

# Verify cluster status
echo ""
echo "--- Cluster Status ---"
pcs cluster status
echo ""

# ============================================================================
# STEP 5: Create Floating VIP Resource
# ============================================================================
echo ""
echo "--- Step 5: Creating Floating VIP Resource ---"

# Create an IPaddr2 resource (floating IP) that will migrate to whichever node is active
# pcs resource create <name> IPaddr2 ip=<vip> cidr_netmask=<netmask> [options]
# This resource will use ARP to announce the VIP on the network
# If node fails, Pacemaker migrates the resource (and VIP) to the other node

pcs resource create ocean-vip IPaddr2 \
    ip=$VIP \
    cidr_netmask="$VIP_NETMASK" \
    op monitor interval=30s \
    --force

echo "[✓] Created IPaddr2 floating VIP resource: $VIP"

# ============================================================================
# STEP 6: Create NGINX Service Resource (Stone Head Monitor)
# ============================================================================
echo ""
echo "--- Step 6: Creating NGINX Service Resource ---"

# Create an LSB (Linux Standard Base) systemd resource for NGINX
# Pacemaker will monitor nginx process, restart if dead, migrate to peer on repeated failures
pcs resource create ocean-nginx systemd:nginx \
    op monitor interval=30s timeout=20s \
    op start timeout=60s \
    op stop timeout=60s \
    --force

echo "[✓] Created systemd NGINX resource"

# ============================================================================
# STEP 7: Create Resource Group (Colocate VIP + NGINX on same node)
# ============================================================================
echo ""
echo "--- Step 7: Grouping Resources ---"

# Group VIP and NGINX so they migrate together (VIP always follows NGINX process)
pcs resource group add ocean-group ocean-vip ocean-nginx
echo "[✓] Grouped ocean-vip and ocean-nginx into ocean-group"

# ============================================================================
# STEP 8: Configure Fencing (STONITH - Shoot The Other Node In The Head)
# ============================================================================
echo ""
echo "--- Step 8: Configuring Fencing ---"

# STONITH is mandatory in production: if a node becomes unresponsive,
# the peer must be able to forcefully shut it down to prevent "split-brain" scenario
# For lab/testing, you can disable with: pcs property set stonith-enabled=false
# For production, configure fencing device (fence-agents-ipmi, fence-agents-kvm, etc.)

# For this example, we disable STONITH (for lab environments)
# In production: replace with actual fence device (IPMI, AWS API, etc.)
echo "Fencing (STONITH) is disabled for lab/testing."
echo "For PRODUCTION, configure a fence device:"
echo "  pcs stonith create <fence-name> fence_ipmi ..."
echo ""
pcs property set stonith-enabled=false

echo "[✓] Fencing disabled (configure in production)"

# ============================================================================
# STEP 9: Verify Final Cluster Status
# ============================================================================
echo ""
echo "--- Final Cluster Status ---"
pcs status
echo ""

# ============================================================================
# STEP 10: Verify Resource Status
# ============================================================================
echo ""
echo "--- Resource Status ---"
pcs resource status
echo ""

echo "[✓] 2-Node Cluster Bootstrap Complete!"
echo ""
echo "Cluster Summary:"
echo "  - Nodes: $NODE1_HOSTNAME, $NODE2_HOSTNAME"
echo "  - VIP: $VIP (active on primary node)"
echo "  - NGINX: Monitored by Pacemaker (auto-restart on failure)"
echo "  - Quorum: auto_tie_breaker enabled (cluster survives 1 node failure)"
echo ""
echo "Next Steps:"
echo "  1. Verify VIP is active: ip addr show (check for $VIP on primary node)"
echo "  2. Verify NGINX is running on primary: systemctl status nginx"
echo "  3. Test failover: systemctl stop nginx (on primary), watch failover"
echo "  4. Check peer node gets VIP: ip addr show (secondary node should get VIP)"
echo "  5. Restore primary: systemctl start nginx (Pacemaker may migrate back)"
echo ""
echo "To add a 3rd node later, run: ./add_cluster_node.sh ocean-node-03 192.168.1.102"
echo ""
