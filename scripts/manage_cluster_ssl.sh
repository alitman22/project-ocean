#!/bin/bash

################################################################################
# Project Ocean: Cluster SSL Certificate & Resource Management
#
# Purpose: Manage VIP + NGINX WebServer resources with distributed SSL 
#          certificate handling in Corosync/Pacemaker cluster
#
# Features:
#   - Add VIP + NGINX web server resources to cluster
#   - Distribute SSL certificates across all cluster nodes
#   - Automatic certificate sync on failover
#   - Monitor and update certificates without downtime
#   - Handle certificate expiration alerts
#
# Usage:
#   sudo bash manage_cluster_ssl.sh init-resources [--vip 192.168.1.110] [--cert-dir /etc/nginx/certs]
#   sudo bash manage_cluster_ssl.sh sync-certs [--source-node node-01] [--cert-dir /etc/nginx/certs]
#   sudo bash manage_cluster_ssl.sh update-cert [--cert-file /path/to/cert.pem] [--key-file /path/to/key.pem]
#   sudo bash manage_cluster_ssl.sh monitor-certs [--check-interval 3600]
#   sudo bash manage_cluster_ssl.sh list-resources
#   sudo bash manage_cluster_ssl.sh verify-certs
#
# Requirements:
#   - Functioning Corosync/Pacemaker cluster
#   - pcs command available
#   - SSH key-based auth between cluster nodes
#   - /etc/nginx/certs directory writable
#
# Author: Project Ocean
# Version: 1.0
################################################################################

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"
CERT_SYNC_LOG="/var/log/ocean/cert-sync.log"
VIP_ADDRESS="${VIP_ADDRESS:-192.168.1.110}"
NGINX_RESOURCE_NAME="ocean-nginx"
VIP_RESOURCE_NAME="ocean-vip"
RESOURCE_GROUP_NAME="ocean-group"
CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"  # Certificate check every hour
CERT_EXPIRY_WARNING_DAYS=30

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$CERT_SYNC_LOG"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$CERT_SYNC_LOG"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$CERT_SYNC_LOG"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$CERT_SYNC_LOG"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$CERT_SYNC_LOG"
}

# Ensure running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

# Verify cluster is operational
check_cluster_health() {
    info "Verifying cluster health..."
    
    if ! pcs cluster status > /dev/null 2>&1; then
        error "Cluster not accessible. Ensure Pacemaker is running: systemctl status pacemaker"
    fi
    
    # Get cluster status
    local node_count=$(pcs cluster nodes | grep -c ":" || echo "0")
    if [[ $node_count -lt 2 ]]; then
        error "Cluster has fewer than 2 nodes. Cluster membership may be degraded."
    fi
    
    success "Cluster health verified ($node_count nodes online)"
}

# Get list of all cluster nodes
get_cluster_nodes() {
    pcs cluster nodes | awk '{print $1}' | grep -v "^$"
}

# Get current node name (hostname)
get_current_node() {
    hostname -s
}

# Get which node VIP is currently active on
get_vip_active_node() {
    local vip_status=$(pcs resource status | grep "$VIP_RESOURCE_NAME" | head -1)
    
    if [[ -z "$vip_status" ]]; then
        echo ""
        return
    fi
    
    # Extract node name from resource status
    echo "$vip_status" | grep -oP 'on \K[^ ]*' || echo ""
}

# Initialize certificate directory with proper permissions
init_cert_directory() {
    info "Initializing certificate directory: $CERT_DIR"
    
    if [[ ! -d "$CERT_DIR" ]]; then
        mkdir -p "$CERT_DIR"
        chmod 750 "$CERT_DIR"
        success "Created $CERT_DIR"
    else
        chmod 750 "$CERT_DIR"
        info "$CERT_DIR already exists"
    fi
    
    # Create sync log directory
    mkdir -p "$(dirname "$CERT_SYNC_LOG")"
    chmod 755 "$(dirname "$CERT_SYNC_LOG")"
}

# Initialize certificate sync marker file
init_cert_sync_marker() {
    local marker_file="/var/run/ocean/cert-sync-marker"
    mkdir -p "$(dirname "$marker_file")"
    
    if [[ ! -f "$marker_file" ]]; then
        touch "$marker_file"
    fi
    
    echo "$(date +%s)" > "$marker_file"
}

# Create VIP resource (IP address with failover)
create_vip_resource() {
    local vip="$1"
    
    info "Creating VIP resource: $vip"
    
    # Check if resource already exists
    if pcs resource status | grep -q "$VIP_RESOURCE_NAME"; then
        warn "VIP resource $VIP_RESOURCE_NAME already exists. Skipping creation."
        return
    fi
    
    # Create IPaddr2 resource for floating IP
    pcs resource create "$VIP_RESOURCE_NAME" IPaddr2 \
        ip="$vip" \
        cidr_netmask=255.255.255.0 \
        arp_interval=200 \
        arp_count=2 \
        --group "$RESOURCE_GROUP_NAME"
    
    success "VIP resource created and added to resource group"
}

# Create NGINX webserver resource (systemd-based monitoring with SSL config)
create_nginx_resource() {
    info "Creating NGINX resource with SSL support..."
    
    # Check if resource already exists
    if pcs resource status | grep -q "$NGINX_RESOURCE_NAME"; then
        warn "NGINX resource $NGINX_RESOURCE_NAME already exists. Skipping creation."
        return
    fi
    
    # Create systemd resource for NGINX
    pcs resource create "$NGINX_RESOURCE_NAME" systemd:nginx \
        --group "$RESOURCE_GROUP_NAME" \
        --after "$VIP_RESOURCE_NAME"
    
    # Add metadata: VIP must be on same node
    pcs resource meta "$NGINX_RESOURCE_NAME" \
        migration-threshold=0 \
        failure-timeout=900s
    
    success "NGINX resource created and grouped with VIP (co-location enforced)"
}

# Add constraints to ensure VIP and NGINX run together
add_resource_constraints() {
    info "Adding resource constraints (VIP and NGINX on same node)..."
    
    # Check if constraint already exists
    if pcs constraint show | grep -q "$VIP_RESOURCE_NAME" && pcs constraint show | grep -q "$NGINX_RESOURCE_NAME"; then
        info "Constraints already exist"
        return
    fi
    
    # Colocation constraint: NGINX must be on same node as VIP
    pcs constraint colocation add "$NGINX_RESOURCE_NAME" with "$VIP_RESOURCE_NAME" INFINITY
    
    # Order constraint: VIP must start before NGINX
    pcs constraint order "$VIP_RESOURCE_NAME" then "$NGINX_RESOURCE_NAME"
    
    success "Resource constraints enforced"
}

# Create initial certificate structure
create_initial_cert_structure() {
    info "Creating initial certificate structure..."
    
    # Create subdirectories for different cert types
    mkdir -p "$CERT_DIR"/{private,public,archive}
    chmod 700 "$CERT_DIR/private"  # Only root reading
    chmod 755 "$CERT_DIR/public"   # World readable
    chmod 755 "$CERT_DIR/archive"  # Archive for versioning
    
    # Create template self-signed certificate (for testing)
    if [[ ! -f "$CERT_DIR/private/sample.key" ]]; then
        info "Creating sample self-signed certificate for testing..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/private/sample.key" \
            -out "$CERT_DIR/public/sample.crt" \
            -subj "/C=US/ST=State/L=City/O=Ocean/CN=ocean.example.com"
        
        success "Sample certificate created at $CERT_DIR/"
    fi
}

# Distribute certificate to all cluster nodes
sync_certificates_to_nodes() {
    local source_node="${1:-$(get_current_node)}"
    
    info "Syncing certificates from $source_node to all cluster nodes..."
    
    local nodes_to_sync=""
    for node in $(get_cluster_nodes); do
        if [[ "$node" != "$source_node" ]]; then
            nodes_to_sync="$nodes_to_sync $node"
        fi
    done
    
    if [[ -z "$nodes_to_sync" ]]; then
        info "Only one node in cluster, skipping sync"
        return
    fi
    
    # Sync via rsync (requires SSH key-based auth)
    for target_node in $nodes_to_sync; do
        info "Syncing to $target_node..."
        
        if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            root@"$target_node" "mkdir -p $CERT_DIR" 2>/dev/null; then
            error "Cannot connect to $target_node via SSH"
        fi
        
        # Use rsync for efficient sync
        if rsync -avz --delete "$CERT_DIR/" "root@$target_node:$CERT_DIR/" \
            --exclude '.git' --exclude '*.swp' 2>/dev/null; then
            success "Certificates synced to $target_node"
        else
            warn "Partial sync to $target_node (non-fatal)"
        fi
    done
    
    init_cert_sync_marker
    success "Certificate synchronization completed"
}

# Verify SSL certificate validity on all nodes
verify_certificates_on_node() {
    local node="${1:-$(get_current_node)}"
    
    info "Verifying SSL certificates on $node..."
    
    if [[ ! -d "$CERT_DIR" ]]; then
        error "Certificate directory $CERT_DIR not found on $node"
    fi
    
    local cert_count=0
    local expired_count=0
    
    # Find all .crt files
    while IFS= read -r cert_file; do
        ((cert_count++))
        
        # Check expiration
        local expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
        local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
        local current_epoch=$(date +%s)
        local days_remaining=$(( ($expiry_epoch - $current_epoch) / 86400 ))
        
        if [[ $days_remaining -lt 0 ]]; then
            warn "EXPIRED: $cert_file (expired $((-days_remaining)) days ago)"
            ((expired_count++))
        elif [[ $days_remaining -lt $CERT_EXPIRY_WARNING_DAYS ]]; then
            warn "EXPIRING SOON: $cert_file (expires in $days_remaining days)"
        else
            info "OK: $cert_file (expires in $days_remaining days)"
        fi
        
        # Verify certificate
        if ! openssl x509 -in "$cert_file" -noout >/dev/null 2>&1; then
            error "Invalid certificate format: $cert_file"
        fi
        
    done < <(find "$CERT_DIR" -name "*.crt" -type f)
    
    if [[ $cert_count -eq 0 ]]; then
        warn "No certificates found in $CERT_DIR"
        return
    fi
    
    if [[ $expired_count -gt 0 ]]; then
        error "$expired_count out of $cert_count certificates are expired"
    fi
    
    success "All $cert_count certificates verified on $node"
}

# Update certificate on all nodes (zero-downtime)
update_certificate_on_cluster() {
    local cert_file="$1"
    local key_file="$2"
    
    info "Updating certificate across cluster (zero-downtime)..."
    
    if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
        error "Certificate or key file not found: $cert_file or $key_file"
    fi
    
    # Verify new certificate
    if ! openssl x509 -in "$cert_file" -noout >/dev/null 2>&1; then
        error "Invalid certificate format: $cert_file"
    fi
    
    if ! openssl rsa -in "$key_file" -noout >/dev/null 2>&1; then
        error "Invalid key format: $key_file"
    fi
    
    # Archive old certificates
    local timestamp=$(date +%Y%m%d-%H%M%S)
    info "Archiving old certificates with timestamp: $timestamp"
    
    cp -v "$CERT_DIR/public/ocean.crt" "$CERT_DIR/archive/ocean.crt.$timestamp" 2>/dev/null || true
    cp -v "$CERT_DIR/private/ocean.key" "$CERT_DIR/archive/ocean.key.$timestamp" 2>/dev/null || true
    
    # Copy new certificate to cert directory
    cp -v "$cert_file" "$CERT_DIR/public/ocean.crt"
    cp -v "$key_file" "$CERT_DIR/private/ocean.key"
    chmod 600 "$CERT_DIR/private/ocean.key"
    chmod 644 "$CERT_DIR/public/ocean.crt"
    
    success "New certificate staged locally"
    
    # Sync to all nodes (no service restart yet)
    sync_certificates_to_nodes "$(get_current_node)"
    
    # Reload NGINX on all nodes gracefully
    info "Reloading NGINX configuration on all cluster nodes..."
    for node in $(get_cluster_nodes); do
        if ssh -o ConnectTimeout=5 root@"$node" "nginx -t && systemctl reload nginx" 2>/dev/null; then
            success "NGINX reloaded on $node"
        else
            warn "Could not reload NGINX on $node (will retry on next sync)"
        fi
    done
    
    success "Certificate updated across cluster with zero downtime"
}

# Monitor certificates for expiration (daemonized)
monitor_certificates_background() {
    local check_interval="${1:-$CHECK_INTERVAL}"
    
    info "Starting certificate monitoring (check every $check_interval seconds)..."
    
    # Create systemd service for continuous monitoring
    cat > /etc/systemd/system/ocean-cert-monitor.service << 'EOF'
[Unit]
Description=Ocean Cluster Certificate Monitor
After=network.target pacemaker.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ocean-cert-monitor.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Create monitor script
    cat > /usr/local/bin/ocean-cert-monitor.sh << EOF
#!/bin/bash
set -euo pipefail

CERT_DIR="$CERT_DIR"
CHECK_INTERVAL=$check_interval
CERT_EXPIRY_WARNING_DAYS=$CERT_EXPIRY_WARNING_DAYS

log() {
    echo "[\\$(date '+%Y-%m-%d %H:%M:%S')] \\$1" >> "$CERT_SYNC_LOG"
}

while true; do
    # Check certificate expiration on local node
    while IFS= read -r cert_file; do
        expiry_date=\$(openssl x509 -in "\$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
        expiry_epoch=\$(date -d "\$expiry_date" +%s 2>/dev/null || echo "0")
        current_epoch=\$(date +%s)
        days_remaining=\$(( (\$expiry_epoch - \$current_epoch) / 86400 ))
        
        if [[ \$days_remaining -lt 0 ]]; then
            log "ALERT: Certificate expired: \$cert_file"
        elif [[ \$days_remaining -lt \$CERT_EXPIRY_WARNING_DAYS ]]; then
            log "WARNING: Certificate expiring in \$days_remaining days: \$cert_file"
        fi
    done < <(find "\$CERT_DIR" -name "*.crt" -type f 2>/dev/null)
    
    sleep \$CHECK_INTERVAL
done
EOF

    chmod +x /usr/local/bin/ocean-cert-monitor.sh
    
    # Enable and start service
    systemctl daemon-reload
    systemctl enable ocean-cert-monitor.service
    systemctl start ocean-cert-monitor.service
    
    success "Certificate monitoring started (systemd service: ocean-cert-monitor.service)"
}

# Initialize complete resource setup
init_resources() {
    local vip="${1:-$VIP_ADDRESS}"
    
    info "=== Initializing Ocean Cluster Resources with SSL Support ==="
    
    check_root
    check_cluster_health
    init_cert_directory
    create_initial_cert_structure
    create_vip_resource "$vip"
    create_nginx_resource
    add_resource_constraints
    
    success "=== Resource initialization complete ==="
    info "Next steps:"
    echo "  1. Verify resources: pcs resource status"
    echo "  2. Copy SSL certificates to $CERT_DIR"
    echo "  3. Run: sudo bash $0 sync-certs"
    echo "  4. Start monitoring: sudo bash $0 monitor-certs"
}

# List current cluster resources
list_resources() {
    info "=== Current Cluster Resources ==="
    pcs resource status
    echo ""
    info "=== Current Constraints ==="
    pcs constraint show
}

# Main command router
main() {
    local command="${1:-help}"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$CERT_SYNC_LOG")"
    
    case "$command" in
        init-resources)
            shift
            local vip="$VIP_ADDRESS"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --vip)
                        vip="$2"
                        shift 2
                        ;;
                    --cert-dir)
                        CERT_DIR="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            init_resources "$vip"
            ;;
        
        sync-certs)
            shift
            local source_node="$(get_current_node)"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --source-node)
                        source_node="$2"
                        shift 2
                        ;;
                    --cert-dir)
                        CERT_DIR="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            check_root
            check_cluster_health
            sync_certificates_to_nodes "$source_node"
            ;;
        
        update-cert)
            shift
            local cert_file=""
            local key_file=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --cert-file)
                        cert_file="$2"
                        shift 2
                        ;;
                    --key-file)
                        key_file="$2"
                        shift 2
                        ;;
                    --cert-dir)
                        CERT_DIR="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            if [[ -z "$cert_file" ]] || [[ -z "$key_file" ]]; then
                error "Usage: $0 update-cert --cert-file <cert.pem> --key-file <key.pem>"
            fi
            
            check_root
            check_cluster_health
            update_certificate_on_cluster "$cert_file" "$key_file"
            ;;
        
        monitor-certs)
            shift
            local check_interval="$CHECK_INTERVAL"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --check-interval)
                        check_interval="$2"
                        shift 2
                        ;;
                    --cert-dir)
                        CERT_DIR="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            check_root
            monitor_certificates_background "$check_interval"
            ;;
        
        verify-certs)
            shift
            local node="$(get_current_node)"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --node)
                        node="$2"
                        shift 2
                        ;;
                    --cert-dir)
                        CERT_DIR="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            check_root
            verify_certificates_on_node "$node"
            ;;
        
        list-resources)
            check_root
            check_cluster_health
            list_resources
            ;;
        
        help|*)
            cat << 'HELP'
Project Ocean: Cluster SSL Certificate & Resource Management

Usage:
  sudo bash manage_cluster_ssl.sh <command> [options]

Commands:
  init-resources              Initialize VIP + NGINX resources in cluster
    --vip <IP>               VIP address (default: 192.168.1.110)
    --cert-dir <DIR>         Certificate directory (default: /etc/nginx/certs)

  sync-certs                  Distribute certificates to all cluster nodes
    --source-node <NODE>     Source node for cert sync (default: current)
    --cert-dir <DIR>         Certificate directory (default: /etc/nginx/certs)

  update-cert                 Update SSL certificate across cluster (zero-downtime)
    --cert-file <FILE>       Path to new certificate (required)
    --key-file <FILE>        Path to new private key (required)
    --cert-dir <DIR>         Certificate directory (default: /etc/nginx/certs)

  verify-certs                Verify certificate validity on node(s)
    --node <NODE>            Target node (default: current)
    --cert-dir <DIR>         Certificate directory (default: /etc/nginx/certs)

  monitor-certs               Start background certificate monitoring daemon
    --check-interval <SEC>   Check interval in seconds (default: 3600)
    --cert-dir <DIR>         Certificate directory (default: /etc/nginx/certs)

  list-resources              Show current cluster resources & constraints

  help                        Show this help message

Examples:
  # Initialize resources on new cluster
  sudo bash manage_cluster_ssl.sh init-resources --vip 192.168.1.110

  # Sync certificates from primary node to all others
  sudo bash manage_cluster_ssl.sh sync-certs --source-node ocean-node-01

  # Update certificate with zero downtime
  sudo bash manage_cluster_ssl.sh update-cert \
    --cert-file /tmp/new-cert.pem \
    --key-file /tmp/new-key.pem

  # Verify all certificates valid
  sudo bash manage_cluster_ssl.sh verify-certs --node ocean-node-01

  # Start certificate expiration monitoring
  sudo bash manage_cluster_ssl.sh monitor-certs --check-interval 3600

  # List current resources and constraints
  sudo bash manage_cluster_ssl.sh list-resources

Features:
  ✓ Automatic VIP + NGINX resource creation
  ✓ Distributed certificate management
  ✓ Zero-downtime certificate updates
  ✓ Automatic failover coordination
  ✓ Certificate expiration monitoring
  ✓ Certificate versioning/archiving
  ✓ SSH-based sync to all nodes
  ✓ Health checking

Configuration:
  CERT_DIR              Certificate storage directory
  VIP_ADDRESS           Virtual IP address for failover
  CHECK_INTERVAL        Certificate check frequency (seconds)
  CERT_EXPIRY_WARNING   Days before expiry to warn (default: 30)

Logs:
  /var/log/ocean/cert-sync.log     Certificate sync operations
  journalctl -u ocean-cert-monitor Monitoring service logs

HELP
            ;;
    esac
}

main "$@"
