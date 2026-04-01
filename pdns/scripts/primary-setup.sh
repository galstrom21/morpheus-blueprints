#!/usr/bin/env bash
# =============================================================================
# PowerDNS Primary Node Setup
# Installs MariaDB (backend) + PowerDNS Authoritative Server
# Tested on Ubuntu 24.04 LTS
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Variables – override via environment or Morpheus custom options
# ---------------------------------------------------------------------------
DB_ROOT_PASSWORD="${db_root_password:-changeme_root}"
DB_PDNS_PASSWORD="${db_pdns_password:-changeme_pdns}"
PDNS_API_KEY="${pdns_api_key:-changeme_api}"
ENABLE_RECURSOR="${pdns_recursor_enable:-false}"

PRIMARY_IP="$(hostname -I | awk '{print $1}')"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System preparation
# ---------------------------------------------------------------------------
apt-get update -y
apt-get upgrade -y
apt-get install -y curl gnupg lsb-release software-properties-common ufw

# ---------------------------------------------------------------------------
# Install MariaDB
# ---------------------------------------------------------------------------
apt-get install -y mariadb-server

systemctl enable mariadb
systemctl start mariadb

# Secure MariaDB and create PowerDNS database
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS pdns CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'pdns'@'%' IDENTIFIED BY '${DB_PDNS_PASSWORD}';
GRANT ALL PRIVILEGES ON pdns.* TO 'pdns'@'%';
FLUSH PRIVILEGES;
EOF

# Allow remote connections from the cluster subnet
sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mariadb

# ---------------------------------------------------------------------------
# Install PowerDNS Authoritative Server
# ---------------------------------------------------------------------------
# Disable systemd-resolved stub listener to free port 53
sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
systemctl restart systemd-resolved

apt-get install -y pdns-server pdns-backend-mysql

# ---------------------------------------------------------------------------
# Initialise the PowerDNS schema
# ---------------------------------------------------------------------------
mysql -u root -p"${DB_ROOT_PASSWORD}" pdns < /usr/share/doc/pdns-backend-mysql/schema.mysql.sql

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

# MySQL backend
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=pdns
gmysql-user=pdns
gmysql-password=${DB_PDNS_PASSWORD}
gmysql-dnssec=yes

# Replication / AXFR (allow secondaries to transfer zones)
allow-axfr-ips=127.0.0.1,::1
master=yes
slave=no

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
ufw allow 3306/tcp comment "MariaDB (cluster)"
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
  # Fallback: download from Morpheus file store / bootstrap location
  echo "WARNING: cis-hardening.sh not found alongside this script; skipping CIS hardening."
fi

echo "==> Primary node setup complete. MariaDB is listening on ${PRIMARY_IP}:3306"
echo "==> PowerDNS API available at http://${PRIMARY_IP}:8081"
echo "==> Reboot recommended to fully apply CIS hardening (bootloader + audit rules)."
