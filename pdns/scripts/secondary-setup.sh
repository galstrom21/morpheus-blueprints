#!/usr/bin/env bash
# =============================================================================
# PowerDNS Secondary Node Setup
# Installs PowerDNS Authoritative Server with a local SQLite3 backend.
# Zones are replicated from the primary via AXFR/NOTIFY using the PowerDNS
# autosecondary (superslave) mechanism – no shared database required.
# Tested on Ubuntu 24.04 LTS
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Variables – override via environment or Morpheus custom options
# ---------------------------------------------------------------------------
PDNS_API_KEY="${pdns_api_key:-changeme_api}"
ENABLE_RECURSOR="${pdns_recursor_enable:-false}"

# Primary node IP injected by Morpheus via linked-tier variable.
PRIMARY_IP="${PRIMARY_IP:-<%=tiers['pdns-primary'].instances[0].externalIp%>}"

PDNS_DB=/var/lib/powerdns/pdns.db

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System preparation
# ---------------------------------------------------------------------------
apt-get update -y
apt-get upgrade -y
apt-get install -y curl gnupg lsb-release software-properties-common ufw sqlite3

# ---------------------------------------------------------------------------
# Disable systemd-resolved stub listener to free port 53
# ---------------------------------------------------------------------------
sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
systemctl restart systemd-resolved

# ---------------------------------------------------------------------------
# Install PowerDNS Authoritative Server
# ---------------------------------------------------------------------------
apt-get install -y pdns-server pdns-backend-sqlite3

# ---------------------------------------------------------------------------
# Initialise the PowerDNS SQLite3 schema
# ---------------------------------------------------------------------------
install -d -o pdns -g pdns -m 750 /var/lib/powerdns
sqlite3 "${PDNS_DB}" < /usr/share/doc/pdns-backend-sqlite3/schema.sqlite3.sql
chown pdns:pdns "${PDNS_DB}"
chmod 640 "${PDNS_DB}"

# ---------------------------------------------------------------------------
# Register the primary as a trusted supermaster
# When the primary sends a NOTIFY for a zone, this node will automatically
# create the zone record and perform an AXFR to pull the zone data.
# ---------------------------------------------------------------------------
sqlite3 "${PDNS_DB}" \
  "INSERT OR IGNORE INTO supermasters (ip, nameserver, account) VALUES ('${PRIMARY_IP}', 'primary', 'admin');"

# ---------------------------------------------------------------------------
# Configure PowerDNS
# ---------------------------------------------------------------------------
cat > /etc/powerdns/pdns.conf <<PDNS_CONF
# PowerDNS Authoritative Server – Secondary Node
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

# SQLite3 backend (local per-node database)
launch=gsqlite3
gsqlite3-database=${PDNS_DB}
gsqlite3-dnssec=yes

# Replication – pull zones from primary via AXFR on NOTIFY
primary=no
secondary=yes
autosecondary=yes
allow-notify-from=${PRIMARY_IP}

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

echo "==> Secondary node setup complete."
echo "==> SQLite3 database: ${PDNS_DB}"
echo "==> Supermaster (primary) registered as: ${PRIMARY_IP}"
echo "==> Zones will be automatically transferred when the primary sends NOTIFY."
echo "==> Reboot recommended to fully apply CIS hardening (bootloader + audit rules)."
