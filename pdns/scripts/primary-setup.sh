#!/usr/bin/env bash
# =============================================================================
# PowerDNS Primary Node Setup
# Installs PowerDNS Authoritative Server with SQLite3 backend
# Zone replication to secondaries is performed via native AXFR/NOTIFY.
# Tested on Ubuntu 24.04 LTS
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Variables – override via environment or Morpheus custom options
# ---------------------------------------------------------------------------
PDNS_API_KEY="${pdns_api_key:-changeme_api}"
ENABLE_RECURSOR="${pdns_recursor_enable:-false}"

PRIMARY_IP="$(hostname -I | awk '{print $1}')"
PDNS_DB=/var/lib/powerdns/pdns.db

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System preparation
# ---------------------------------------------------------------------------
apt-get update -y
apt-get upgrade -y
apt-get install -y curl gnupg lsb-release software-properties-common ufw sqlite3

# ---------------------------------------------------------------------------
# Install PowerDNS Authoritative Server
# ---------------------------------------------------------------------------
# Disable systemd-resolved stub listener to free port 53
sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
systemctl restart systemd-resolved

apt-get install -y pdns-server pdns-backend-sqlite3

# ---------------------------------------------------------------------------
# Initialise the PowerDNS SQLite3 schema
# ---------------------------------------------------------------------------
install -d -o pdns -g pdns -m 750 /var/lib/powerdns
sqlite3 "${PDNS_DB}" < /usr/share/doc/pdns-backend-sqlite3/schema.sqlite3.sql
chown pdns:pdns "${PDNS_DB}"
chmod 640 "${PDNS_DB}"

# ---------------------------------------------------------------------------
# Configure PowerDNS
# ---------------------------------------------------------------------------
cat > /etc/powerdns/pdns.conf <<PDNS_CONF
# PowerDNS Authoritative Server – Primary Node
setuid=pdns
setgid=pdns

# Listeners
local-address=0.0.0.0
local-port=53

# API
api=yes
api-key=${PDNS_API_KEY}
webserver=yes
webserver-address=0.0.0.0
webserver-port=8081
webserver-allow-from=127.0.0.0/8,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16

# SQLite3 backend
launch=gsqlite3
gsqlite3-database=${PDNS_DB}
gsqlite3-dnssec=yes

# Replication – primary sends NOTIFY; secondaries pull via AXFR
# allow-axfr-ips covers all RFC1918 ranges so cluster secondaries can transfer.
# Set also-notify to secondary IPs post-deploy, or rely on NS-record-based NOTIFY.
primary=yes
secondary=no
allow-axfr-ips=127.0.0.0/8,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16

# Misc
log-dns-queries=no
loglevel=4
distributor-threads=3
receiver-threads=1
PDNS_CONF

# Remove any drop-in backend configs that may conflict
rm -f /etc/powerdns/pdns.d/*.conf

systemctl enable pdns
systemctl restart pdns

# ---------------------------------------------------------------------------
# Optional: PowerDNS Recursor
# ---------------------------------------------------------------------------
if [[ "${ENABLE_RECURSOR}" == "true" || "${ENABLE_RECURSOR}" == "on" ]]; then
  apt-get install -y pdns-recursor
  cat > /etc/powerdns/recursor.conf <<REC_CONF
local-address=127.0.0.1
local-port=5300
forward-zones-recurse=.=8.8.8.8;8.8.4.4
REC_CONF
  systemctl enable pdns-recursor
  systemctl restart pdns-recursor
fi

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
ufw allow 22/tcp   comment "SSH"
ufw allow 53/tcp   comment "DNS TCP"
ufw allow 53/udp   comment "DNS UDP"
ufw allow 8081/tcp comment "PowerDNS API"
ufw --force enable

# ---------------------------------------------------------------------------
# CIS Level 1 Hardening
# Must run after all services are installed and configured so that
# legitimate daemons are not masked before they exist.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/cis-hardening.sh" ]]; then
  bash "${SCRIPT_DIR}/cis-hardening.sh"
else
  echo "WARNING: cis-hardening.sh not found alongside this script; skipping CIS hardening."
fi

echo "==> Primary node setup complete."
echo "==> SQLite3 database: ${PDNS_DB}"
echo "==> PowerDNS API available at http://${PRIMARY_IP}:8081"
echo "==> Post-deploy: set 'also-notify' in pdns.conf with secondary IPs to trigger automatic zone transfers."
echo "==> Reboot recommended to fully apply CIS hardening (bootloader + audit rules)."
