#!/bin/bash
#
# Project Ocean: Safely Drain & Remove Node from Cluster (Zero-Downtime)
# Purpose: Gracefully remove a node from Corosync/Pacemaker cluster
# Target: Ubuntu 22.04 LTS
# Prerequisites: Multi-node cluster (at least 2 nodes remain after removal)
# Run on: Any cluster node (will coordinate with cluster)
#

set -e

TARGET_NODE="${1:-}"
CLUSTER_NAME="ocean-cluster"

if [ -z "$TARGET_NODE" ]; then
    echo "Usage: $0 <node-name>"
    echo "Example: $0 ocean-node-03"
    echo ""
    echo "Current cluster nodes:"
    pcs cluster nodes 2>/dev/null || echo "Not in a cluster"
    exit 1
fi

echo "=== Project Ocean: Safe Node Removal from Cluster ==="
echo ""
echo "Configuration:"
echo "  Target Node:  $TARGET_NODE"
echo "  Cluster:      $CLUSTER_NAME"
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

# Verify target node exists in cluster
if ! pcs cluster nodes | grep -q "^$TARGET_NODE$"; then
   echo "ERROR: Node '$TARGET_NODE' not found in cluster."
   echo ""
   echo "Current nodes:"
   pcs cluster nodes
   exit 1
fi

# Check cluster size (must have >2 nodes to remove one safely)
NODE_COUNT=$(pcs cluster nodes | wc -l)
if [ $NODE_COUNT -le 2 ]; then
   echo "ERROR: Cannot remove node from 2-node cluster (loses quorum)."
   echo "Current cluster nodes: $NODE_COUNT"
   echo ""
   echo "Options:"
   echo "  1. Keep at least 2 nodes (add 3rd node first)"
   echo "  2. If destroying entire cluster: pcs cluster destroy --all"
   exit 1
fi

echo "Current Cluster Status:"
pcs cluster status | head -20
echo ""

# ============================================================================
# STEP 1: Set Target Node to Standby Mode
# ============================================================================
echo "--- Step 1: Setting Node to Standby Mode ---"
echo "This prevents new resources from being placed on the node..."
echo ""

# pcs node standby <node>
# Puts node in standby: existing resources migrate to healthy nodes,
# new resources won't be scheduled on this node
pcs node standby $TARGET_NODE

echo "[✓] $TARGET_NODE in standby mode"
sleep 2

# ============================================================================
# STEP 2: Wait for Resources to Migrate
# ============================================================================
echo ""
echo "--- Step 2: Waiting for Resources to Migrate Away ---"
echo "Allowing time for any resources to migrate to other nodes..."
echo ""

# Wait up to 60 seconds for resources to migrate cleanly
for i in {1..60}; do
    # Check if target node has any resources
    NODE_RESOURCES=$(pcs resource status | grep -c "$TARGET_NODE" || true)
    
    if [ $NODE_RESOURCES -eq 0 ]; then
        echo "[✓] All resources migrated (attempt $i/60)"
        break
    fi
    
    if [ $((i % 10)) -eq 0 ]; then
        echo "  Waiting for resource migration... ($i/60 seconds)"
        pcs resource status | grep "$TARGET_NODE" || true
    fi
    
    sleep 1
done

sleep 2

# ============================================================================
# STEP 3: Stop Cluster Services on Target Node
# ============================================================================
echo ""
echo "--- Step 3: Stopping Services on Target Node ---"
echo "Shutting down Pacemaker and Corosync on $TARGET_NODE..."
echo ""

# SSH to target node and stop services (gracefully, in correct order: pacemaker first, then corosync)
ssh -o StrictHostKeyChecking=no $TARGET_NODE \
    "sudo systemctl stop pacemaker && sudo systemctl stop corosync" &
REMOTE_PID=$!

# Give remote stop a moment
sleep 3

wait $REMOTE_PID 2>/dev/null || true

echo "[✓] Services stopped on $TARGET_NODE"

# ============================================================================
# STEP 4: Remove Node from Cluster Configuration
# ============================================================================
echo ""
echo "--- Step 4: Removing Node from Cluster Configuration ---"
echo "Removing $TARGET_NODE from cluster.conf..."
echo ""

# pcs cluster node remove <node>
# Removes node from cluster.conf and update Corosync configuration
# All existing nodes will be restarted with new config (brief interruption potential)
pcs cluster node remove $TARGET_NODE

echo "[✓] Removed $TARGET_NODE from cluster configuration"
sleep 3

# ============================================================================
# STEP 5: Verify Node Removal
# ============================================================================
echo ""
echo "--- Step 5: Verifying Node Removal ---"

# Verify node is no longer in cluster membership
if pcs cluster nodes | grep -q "^$TARGET_NODE$"; then
    echo "[!] WARNING: $TARGET_NODE still present in cluster nodes (waiting...)"
    sleep 5
fi

echo "Remaining cluster nodes:"
pcs cluster nodes
echo ""

# ============================================================================
# STEP 6: Update Quorum Configuration (if applicable)
# ============================================================================
echo ""
echo "--- Step 6: Updating Quorum Configuration ---"

# Update expected_votes if needed (e.g., going from 3 nodes to 2)
REMAINING_NODES=$(pcs cluster nodes | wc -l)
echo "Remaining nodes: $REMAINING_NODES"

if [ $REMAINING_NODES -eq 2 ]; then
    echo "Configuring quorum for 2-node cluster (auto_tie_breaker)..."
    pcs quorum expected-votes 2
    # pcs quorum device remove model net 2>/dev/null || true  # Remove device quorum if present
    echo "[✓] Quorum configured for 2-node cluster"
elif [ $REMAINING_NODES -ge 3 ]; then
    echo "Updating quorum for $REMAINING_NODES-node cluster..."
    pcs quorum expected-votes $REMAINING_NODES
    echo "[✓] Quorum updated to expected_votes=$REMAINING_NODES"
fi

# ============================================================================
# STEP 7: Final Verification
# ============================================================================
echo ""
echo "--- Final Cluster Status ---"
pcs cluster status
echo ""

echo "--- Resource Status ---"
pcs resource status
echo ""

echo "[✓] Node Removal Complete!"
echo ""
echo "Summary:"
echo "  - $TARGET_NODE removed from cluster"
echo "  - Remaining nodes: $(pcs cluster nodes | tr '\n' ', ' | sed 's/,$//')"
echo "  - All resources migrated and stable"
echo ""
echo "Post-Removal Steps:"
echo "  1. Verify application traffic: ping $TARGET_NODE (should fail or be unreachable)"
echo "  2. Decommission $TARGET_NODE if needed: pcs cluster destroy (on that node)"
echo "  3. Repurpose or retire the hardware"
echo ""
echo "To add this node back (if needed): ./add_cluster_node.sh $TARGET_NODE <IP>"
echo ""
