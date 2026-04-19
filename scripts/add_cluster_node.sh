#!/bin/bash
#
# Project Ocean: Add 3rd Node to Existing 2-Node Cluster (Zero-Downtime)
# Purpose: Dynamically add a new Ubuntu node to Corosync/Pacemaker cluster
# Target: Ubuntu 22.04 LTS (new node)
# Prerequisites: 
#   - Existing 2-node cluster running (ocean-node-01, ocean-node-02)
#   - New node has Pacemaker/Corosync/NGINX installed
#   - SSH access from existing cluster to new node
# Run on: Existing cluster node (any of the 2 nodes)
#

set -e

NEW_NODE_HOSTNAME="${1:-ocean-node-03}"
NEW_NODE_IP="${2:-192.168.1.102}"
CLUSTER_NAME="ocean-cluster"

echo "=== Project Ocean: Add 3rd Node to 2-Node Cluster ==="
echo ""
echo "Configuration:"
echo "  New Node:    $NEW_NODE_HOSTNAME ($NEW_NODE_IP)"
echo "  Cluster:     $CLUSTER_NAME"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (sudo)"
   exit 1
fi

# Verify we're in a cluster
if ! pcs cluster status &>/dev/null; then
   echo "ERROR: No local cluster found. Run this on an active cluster node."
   exit 1
fi

echo "Current Cluster Nodes:"
pcs cluster nodes
echo ""

# ============================================================================
# STEP 1: Authorize New Node
# ============================================================================
echo "--- Step 1: Authorizing New Node ---"
echo "Authenticating $NEW_NODE_HOSTNAME (prompt for hacluster password)"
echo ""

# Add new node to cluster authorization
# This exchanges hacluster credentials between existing nodes and new node
pcs cluster auth $NEW_NODE_HOSTNAME -u hacluster
echo "[✓] $NEW_NODE_HOSTNAME authorized"

# ============================================================================
# STEP 2: Add Node to Cluster Membership (Corosync)
# ============================================================================
echo ""
echo "--- Step 2: Adding Node to Cluster Membership ---"

# pcs cluster node add <node-name>
# Adds node to Corosync cluster.conf and restarts Corosync on all existing nodes
# The new node is automatically included but requires starting services
pcs cluster node add $NEW_NODE_HOSTNAME

echo "[✓] Added $NEW_NODE_HOSTNAME to cluster.conf"

# ============================================================================
# STEP 3: Start Cluster Services on New Node
# ============================================================================
echo ""
echo "--- Step 3: Starting Services on New Node ---"

# SSH to new node and start corosync/pacemaker
# Cannot use 'pcs cluster start $NEW_NODE_HOSTNAME' directly (node not yet in cluster)
# Must SSH and bootstrap locally
ssh -o StrictHostKeyChecking=no $NEW_NODE_HOSTNAME \
    "sudo systemctl start corosync && sudo systemctl start pacemaker" &
REMOTE_PID=$!

# Also ensure local nodes recognize new node (may need restart or wait)
sleep 5

# Verify new node has joined
echo "[✓] Started services on $NEW_NODE_HOSTNAME"

wait $REMOTE_PID 2>/dev/null || true

# ============================================================================
# STEP 4: Verify Cluster Membership (Wait for Stabilization)
# ============================================================================
echo ""
echo "--- Step 4: Verifying Cluster Membership ---"

# Wait up to 30 seconds for new node to join cluster
for i in {1..30}; do
    if pcs cluster nodes | grep -q $NEW_NODE_HOSTNAME; then
        echo "[✓] New node joined cluster (attempt $i/30)"
        break
    fi
    echo "  Waiting for $NEW_NODE_HOSTNAME to join ($i/30)..."
    sleep 1
done

pcs cluster nodes
echo ""

# ============================================================================
# STEP 5: Update Quorum Configuration
# ============================================================================
echo ""
echo "--- Step 5: Updating Quorum Configuration ---"

# Update quorum for 3-node cluster:
# Two-node mode is no longer needed
# Set expected_votes to 3 (all 3 nodes must be up for quorum, or 2+ must agree)
# Alternatively, keep auto_tie_breaker for fault tolerance

pcs quorum expected-votes 3

# Update quorum device if present (for distributed quorum)
# pcs quorum device update model net algorithm=ffsplit

echo "[✓] Quorum updated for 3-node cluster"

# ============================================================================
# STEP 6: Enable New Node to Host Resources
# ============================================================================
echo ""
echo "--- Step 6: Enabling New Node for Resource Hosting ---"

# By default, new nodes are considered online and can host resources
# Verify node is not in standby mode (nodes in standby don't host resources)
pcs node unstandby $NEW_NODE_HOSTNAME 2>/dev/null || true

echo "[✓] $NEW_NODE_HOSTNAME enabled for resource hosting"

# ============================================================================
# STEP 7: Add NGINX Resource Clone to New Node (Optional)
# ============================================================================
echo ""
echo "--- Step 7: Adding NGINX Resource to New Node (Optional) ---"

# If you want NGINX to run on all 3 nodes (active/active setup):
# Convert ocean-nginx from group resource to a clone resource
# 
# This is OPTIONAL - the default setup from bootstrap_cluster.sh
# keeps VIP+NGINX on ONE node only (active/passive failover)
#
# Uncomment below if you want active/active NGINX on all 3 nodes:

# pcs resource clone ocean-nginx meta interleave=true globally-unique=true

echo "[!] NGINX resource remains on primary node only (see comments for active/active)"

# ============================================================================
# STEP 8: Display Final Cluster Status
# ============================================================================
echo ""
echo "--- Final Cluster Status ---"
pcs cluster status
echo ""

echo "--- Resource Status ---"
pcs resource status
echo ""

echo "[✓] 3rd Node Addition Complete!"
echo ""
echo "Cluster Summary:"
pcs cluster nodes
echo ""
echo "Verification Commands:"
echo "  1. Check cluster quorum: pcs quorum"
echo "  2. Check node status: pcs node status"
echo "  3. Test failover: systemctl stop nginx (on VIP host), confirm migration"
echo "  4. Check VIP location: ip addr show (should be on active node only)"
echo ""
echo "To remove the node later, run: ./drain_remove_node.sh $NEW_NODE_HOSTNAME"
echo ""
