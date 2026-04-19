# Project Ocean: SSL Certificate Management Guide

## Overview

This guide explains how to manage SSL certificates in a Project Ocean cluster with automatic failover support. The `manage_cluster_ssl.sh` script handles:

- **VIP + WebServer Resources:** Automatic creation of Pacemaker resources for the floating IP and NGINX
- **Certificate Distribution:** Sync SSL certificates across all cluster nodes
- **Zero-Downtime Updates:** Update certificates without service interruption
- **Expiration Monitoring:** Automatic alerts for expiring certificates
- **Failover Coordination:** Certificates always available on whichever node holds the VIP

---

## Architecture

### Certificate Storage & Synchronization Flow

![Certificate Sync Flow](../diagrams/certificate-sync-flow.svg)

---

## Setup: Quick Start

### 1. Initialize Resources (Run Once)

```bash
# On any cluster node (preferably primary/node-1)
sudo bash scripts/manage_cluster_ssl.sh init-resources \
  --vip 192.168.1.110 \
  --cert-dir /etc/nginx/certs
```

**What happens:**
- Creates `/etc/nginx/certs/{private,public,archive}` directories
- Generates sample self-signed certificate for testing
- Creates VIP (IPaddr2) resource: `ocean-vip`
- Creates NGINX (systemd) resource: `ocean-nginx`
- Enforces co-location constraint (both on same node)
- Sets resource ordering (VIP starts before NGINX)

**Verify:**
```bash
pcs resource status
# Output should show:
#   ocean-vip           Stopped
#   ocean-nginx         Stopped
```

### 2. Provide Real SSL Certificates

```bash
# Generate or obtain certificates
# Example: self-signed for testing
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/ocean.key \
  -out /tmp/ocean.crt \
  -subj "/C=US/ST=State/L=City/O=Ocean/CN=ocean.example.com"

# Or obtain from Let's Encrypt
# certbot certonly --standalone -d ocean.example.com
```

### 3. Deploy Certificates to Cluster

```bash
# Update certificate on primary node and sync to all
sudo bash scripts/manage_cluster_ssl.sh update-cert \
  --cert-file /tmp/ocean.crt \
  --key-file /tmp/ocean.key
```

**What happens:**
- Verifies both files (certificate and key)
- Archives old certificate with timestamp
- Places new cert/key in correct directories with proper permissions
- Rsync to all other cluster nodes
- Gracefully reloads NGINX on all nodes

**Output:**
```
[SUCCESS] New certificate staged locally
[INFO] Syncing certificates from ocean-node-01 to all cluster nodes...
[INFO] Syncing to ocean-node-02...
[SUCCESS] Certificates synced to ocean-node-02
[INFO] Reloading NGINX configuration on all cluster nodes...
[SUCCESS] NGINX reloaded on ocean-node-01
[SUCCESS] NGINX reloaded on ocean-node-02
[SUCCESS] Certificate updated across cluster with zero downtime
```

### 4. Verify Certificates on All Nodes

```bash
# Check primary node
sudo bash scripts/manage_cluster_ssl.sh verify-certs --node ocean-node-01

# Check secondary
sudo bash scripts/manage_cluster_ssl.sh verify-certs --node ocean-node-02

# Output:
# [INFO] OK: /etc/nginx/certs/public/ocean.crt (expires in 364 days)
# [SUCCESS] All 1 certificates verified on ocean-node-01
```

### 5. Start Certificate Monitoring

```bash
# Enable background expiration monitoring (on each node or via cluster-wide service)
sudo bash scripts/manage_cluster_ssl.sh monitor-certs --check-interval 3600
```

**What happens:**
- Creates systemd service: `ocean-cert-monitor.service`
- Checks certificates every hour
- Logs expiration warnings to `/var/log/ocean/cert-sync.log`
- Alerts 30 days before expiration
- Auto-restarts if service fails

---

## Common Tasks

### Task 1: Manual Certificate Sync (After Copying Certs)

```bash
# Copy certs to certificate directory manually
sudo cp new-cert.pem /etc/nginx/certs/public/ocean.crt
sudo cp new-key.pem /etc/nginx/certs/private/ocean.key
sudo chmod 600 /etc/nginx/certs/private/ocean.key

# Sync to all other nodes
sudo bash scripts/manage_cluster_ssl.sh sync-certs --source-node ocean-node-01

# Reload NGINX
sudo systemctl reload nginx
```

### Task 2: Check Certificate Expiration on All Nodes

```bash
# From primary node, check all cluster nodes
for node in $(pcs cluster nodes | awk '{print $1}'); do
  echo "=== $node ==="
  sudo bash scripts/manage_cluster_ssl.sh verify-certs --node $node
done
```

### Task 3: Emergency Certificate Rotation (When Current Cert Compromised)

```bash
# 1. Generate new emergency certificate
openssl req -x509 -nodes -days 90 -newkey rsa:4096 \
  -keyout /tmp/emergency.key \
  -out /tmp/emergency.crt

# 2. Update immediately (will sync to all nodes and reload nginx)
sudo bash scripts/manage_cluster_ssl.sh update-cert \
  --cert-file /tmp/emergency.crt \
  --key-file /tmp/emergency.key

# 3. Verify all nodes have new cert
sudo bash scripts/manage_cluster_ssl.sh verify-certs

# 4. Monitor logs for any issues
tail -f /var/log/ocean/cert-sync.log
```

### Task 4: List Current Resources and Constraints

```bash
sudo bash scripts/manage_cluster_ssl.sh list-resources

# Output example:
# Current Resources:
#   ocean-vip     (ocf:heartbeat:IPaddr2) - Started ocean-node-01
#   ocean-nginx   (systemd:nginx)         - Started ocean-node-01
#
# Current Constraints:
#   Colocation: ocean-nginx on ocean-vip (INFINITY)
#   Order: ocean-vip then ocean-nginx
```

### Task 5: Restore Certificate from Archive

```bash
# Find available backups
ls -la /etc/nginx/certs/archive/

# Output:
# ocean.crt.20260419-093000
# ocean.crt.20260419-120000
# ocean.key.20260419-093000
# ocean.key.20260419-120000

# Restore previous version
sudo cp /etc/nginx/certs/archive/ocean.crt.20260419-093000 /etc/nginx/certs/public/ocean.crt
sudo cp /etc/nginx/certs/archive/ocean.key.20260419-093000 /etc/nginx/certs/private/ocean.key

# Reload NGINX
sudo systemctl reload nginx

# Sync to cluster
sudo bash scripts/manage_cluster_ssl.sh sync-certs
```

---

## Let's Encrypt Integration

### Option 1: Certbot with Hook Script

```bash
#!/bin/bash
# /root/certbot-ocean-hook.sh - Runs after cert renewal

CERT_FILE="/etc/letsencrypt/live/ocean.example.com/fullchain.pem"
KEY_FILE="/etc/letsencrypt/live/ocean.example.com/privkey.pem"

# Update cluster with new cert
sudo bash /root/scripts/manage_cluster_ssl.sh update-cert \
  --cert-file "$CERT_FILE" \
  --key-file "$KEY_FILE"

# Send email notification
echo "Certificate updated: $(date)" | \
  mail -s "Ocean: Certificate Renewed" admin@example.com
```

**Configure Certbot renewal hook:**
```bash
# Add to Certbot config
echo 'renew_hook = /root/certbot-ocean-hook.sh' >> \
  /etc/letsencrypt/renewal/ocean.example.com.conf

# Or renew manually
sudo certbot renew --deploy-hook /root/certbot-ocean-hook.sh
```

### Option 2: Automated Renewal Cron

```bash
# /etc/cron.d/ocean-cert-renewal
# Daily certificate check and renewal

0 2 * * * root /usr/bin/certbot renew --quiet --deploy-hook /root/certbot-ocean-hook.sh
```

---

## Monitoring & Alerts

### Check Certificate Status

```bash
# View certificate expiration
openssl x509 -in /etc/nginx/certs/public/ocean.crt -noout -dates

# Output:
# notBefore=Apr 19 12:00:00 2026 GMT
# notAfter=Apr 19 12:00:00 2027 GMT

# Check days remaining
echo "Days until expiration:"
echo $(($(date -d "$(openssl x509 -in /etc/nginx/certs/public/ocean.crt -noout -enddate | cut -d= -f2)" +%s) - $(date +%s))) / 86400 | bc
```

### View Sync Logs

```bash
# Real-time monitoring
tail -f /var/log/ocean/cert-sync.log

# Search for errors
grep ERROR /var/log/ocean/cert-sync.log

# View recent updates
tail -n 50 /var/log/ocean/cert-sync.log
```

### Monitor systemd Service

```bash
# Check status
systemctl status ocean-cert-monitor.service

# View logs
journalctl -u ocean-cert-monitor.service -n 20

# Follow logs
journalctl -u ocean-cert-monitor.service -f

# View all logs (including boot)
journalctl -u ocean-cert-monitor.service --all
```

---

## Troubleshooting

### Issue 1: Certificates Not Syncing to Other Nodes

**Symptom:**
```bash
$ sudo bash scripts/manage_cluster_ssl.sh sync-certs
[ERROR] Cannot connect to ocean-node-02 via SSH
```

**Cause:** SSH key-based authentication not configured

**Solution:**
```bash
# Setup SSH key-based auth on primary node
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

# Copy public key to all cluster nodes
for node in ocean-node-02 ocean-node-03; do
  ssh-copy-id -i ~/.ssh/id_rsa.pub root@$node
done

# Test SSH access
ssh root@ocean-node-02 "echo OK"
```

### Issue 2: NGINX Fails to Reload After Cert Update

**Symptom:**
```bash
[WARN] Could not reload NGINX on ocean-node-02 (will retry on next sync)
```

**Debug:**
```bash
# Check NGINX config syntax on affected node
ssh root@ocean-node-02 "nginx -t"

# View NGINX error log
ssh root@ocean-node-02 "tail -50 /var/log/nginx/error.log"

# Manually reload
ssh root@ocean-node-02 "systemctl reload nginx"

# Check service status
ssh root@ocean-node-02 "systemctl status nginx"
```

### Issue 3: Certificate Verification Fails

**Symptom:**
```bash
[ERROR] Invalid certificate format: /etc/nginx/certs/public/ocean.crt
```

**Debug:**
```bash
# Check certificate validity
openssl x509 -in /etc/nginx/certs/public/ocean.crt -noout -text

# Verify certificate chain
openssl verify -untrusted CA.pem /etc/nginx/certs/public/ocean.crt

# Check certificate against key
openssl x509 -noout -modulus -in /etc/nginx/certs/public/ocean.crt | openssl md5
openssl rsa -noout -modulus -in /etc/nginx/certs/private/ocean.key | openssl md5
# Both should produce same hash
```

### Issue 4: VIP Not Failing Over After Certificate Update

**Symptom:**
- Node-1 VIP active, Node-2 on standby
- After cert update, VIP doesn't migrate on Node-1 failure

**Cause:** Pacemaker doesn't know certificates updated on Node-2

**Solution:**
```bash
# Explicitly mark resources as updated
pcs resource refresh ocean-vip
pcs resource refresh ocean-nginx

# Verify constraints still in place
pcs constraint show

# Test failover manually
# On primary node: sudo systemctl stop nginx
# On secondary: pcs resource status
# VIP/NGINX should migrate within 10s
```

### Issue 5: Certificate Monitor Service Not Running

**Symptom:**
```bash
$ systemctl status ocean-cert-monitor.service
● ocean-cert-monitor.service - Loaded but not started
```

**Debug:**
```bash
# Check if script exists
ls -la /usr/local/bin/ocean-cert-monitor.sh

# Check service file
cat /etc/systemd/system/ocean-cert-monitor.service

# Start service manually
systemctl start ocean-cert-monitor.service

# Check logs
journalctl -u ocean-cert-monitor.service -n 30
```

---

## Best Practices

### 1. Certificate Lifecycle

```
Week 1-4:   New cert deployed (check for any issues)
Week 1-11:  Monitor expiration (currently valid)
Week 11-12: Final checks, renew process started
Week 12:    New cert ready and tested
Week 13:    Deploy to production (1 day before expiry)
```

### 2. Testing Before Production

```bash
# Always test with sample certificate first
sudo bash scripts/manage_cluster_ssl.sh update-cert \
  --cert-file /etc/nginx/certs/public/sample.crt \
  --key-file /etc/nginx/certs/private/sample.key

# Verify NGINX loads correctly
ssh root@ocean-node-01 "nginx -T | head -20"

# Check connectivity
curl -k https://192.168.1.110/  # Should work (self-signed warning ok)
```

### 3. Backup Before Updates

```bash
# Archive current certificates before update
tar -czf /backup/ocean-certs-backup-$(date +%Y%m%d).tar.gz \
  /etc/nginx/certs/

# Keep backups for 90 days
find /backup -name "ocean-certs-*.tar.gz" -mtime +90 -delete
```

### 4. Document Certificate Details

Keep a record:
```
Certificate Details:
├─ Domain: ocean.example.com
├─ Issuer: Let's Encrypt / Internal CA
├─ Issued: 2026-04-19
├─ Expires: 2027-04-19 (364 days)
├─ Renewal Date (Target): 2027-03-20 (30 days before expiry)
├─ Key Size: RSA 2048
├─ Signature Algorithm: SHA256
└─ Notes: Renewed after security audit
```

### 5. Monitor Regularly

```bash
# Daily health check (add to cron)
daily_cert_check() {
  for node in $(pcs cluster nodes | awk '{print $1}'); do
    sudo bash scripts/manage_cluster_ssl.sh verify-certs --node $node
  done
}

# Weekly cluster status check
weekly_cluster_check() {
  pcs resource status
  pcs constraint show
  pcs quorum status
}
```

---

## Automation Examples

### Example 1: Automated Monthly Certificate Check

```bash
#!/bin/bash
# /root/monthly-cert-check.sh

CERT_FILE="/etc/nginx/certs/public/ocean.crt"
EXPIRY_DATE=$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)
DAYS_LEFT=$(( ($(date -d "$EXPIRY_DATE" +%s) - $(date +%s)) / 86400 ))

echo "Certificate expiry check:"
echo "  Domain: ocean.example.com"
echo "  Expires: $EXPIRY_DATE"
echo "  Days remaining: $DAYS_LEFT"

if [ $DAYS_LEFT -lt 30 ]; then
  echo "WARNING: Certificate expires in $DAYS_LEFT days"
  # Trigger renewal
  certbot renew --force-renewal
fi
```

**Cron job:**
```bash
# /etc/cron.d/ocean-monthly-cert-check
0 9 1 * * root /root/monthly-cert-check.sh | mail -s "Ocean Cert Check" admin@example.com
```

### Example 2: Automated Failover Certificate Verification

```bash
#!/bin/bash
# Run after failover to ensure certs synced

VIP_NODE=$(pcs resource status | grep ocean-vip | grep -oP 'on \K\w+')
OTHER_NODES=$(pcs cluster nodes | awk '{print $1}' | grep -v $VIP_NODE)

echo "VIP is active on: $VIP_NODE"
echo "Verifying certificates on VIP node..."

ssh root@$VIP_NODE "bash /root/scripts/manage_cluster_ssl.sh verify-certs"

if [ $? -eq 0 ]; then
  echo "SUCCESS: VIP node has valid certificates"
else
  echo "ERROR: VIP node certificate verification failed!"
  exit 1
fi
```

---

## Reference

### Directory Structure

```
/etc/nginx/certs/
├─ private/           # Private keys (chmod 700)
│  ├─ ocean.key
│  └─ sample.key
├─ public/            # Public certificates (chmod 755)
│  ├─ ocean.crt
│  └─ sample.crt
└─ archive/           # Timestamped backups
   ├─ ocean.crt.20260419-120000
   └─ ocean.key.20260419-120000

/var/log/ocean/
└─ cert-sync.log      # All certificate operations

/etc/systemd/system/
└─ ocean-cert-monitor.service
```

### Configuration Variables

```bash
CERT_DIR="/etc/nginx/certs"                 # Where to store certs
VIP_ADDRESS="192.168.1.110"                 # Floating IP
NGINX_RESOURCE_NAME="ocean-nginx"           # Pacemaker resource name
VIP_RESOURCE_NAME="ocean-vip"               # Pacemaker resource name
RESOURCE_GROUP_NAME="ocean-group"           # Pacemaker group
CHECK_INTERVAL=3600                         # Monitor check frequency (seconds)
CERT_EXPIRY_WARNING_DAYS=30                 # Days before warning
```

### Command Reference

| Command | Purpose | Example |
|---------|---------|---------|
| `init-resources` | Create VIP + NGINX resources | `--vip 192.168.1.110` |
| `sync-certs` | Distribute certs to all nodes | `--source-node ocean-node-01` |
| `update-cert` | Update cert on cluster | `--cert-file x.crt --key-file x.key` |
| `verify-certs` | Check cert validity | `--node ocean-node-01` |
| `monitor-certs` | Start background monitoring | `--check-interval 3600` |
| `list-resources` | Show resources & constraints | (none) |

---

## Support

For issues or questions:
1. Check logs: `tail -f /var/log/ocean/cert-sync.log`
2. Review troubleshooting section above
3. Test with sample certificate first
4. Verify SSH access between nodes: `ssh root@<node> "echo OK"`
5. Check cluster health: `pcs cluster status`

