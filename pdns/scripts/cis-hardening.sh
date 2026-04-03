#!/usr/bin/env bash
# =============================================================================
# CIS Ubuntu 24.04 LTS – Level 1 Server Hardening
# Based on CIS Benchmark for Ubuntu Linux 24.04 LTS
#
# IMPORTANT: Run AFTER all application packages are installed so that
# legitimate services are not masked before they are created.
#
# Controls that require physical/BIOS access or are environment-specific
# (e.g. GRUB password, UEFI Secure Boot) are noted but not automated.
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> [CIS] Starting Level 1 hardening for Ubuntu 24.04..."

# =============================================================================
# 1. FILESYSTEM CONFIGURATION
# =============================================================================

# -- 1.1.1 Disable unused/unnecessary filesystems --
echo "==> [CIS 1.1.1] Disabling unused filesystems..."
MODPROBE_CONF=/etc/modprobe.d/cis-disable-filesystems.conf
cat >"${MODPROBE_CONF}" <<'MODS'
install cramfs   /bin/false
blacklist cramfs
install freevxfs /bin/false
blacklist freevxfs
install jffs2    /bin/false
blacklist jffs2
install hfs      /bin/false
blacklist hfs
install hfsplus  /bin/false
blacklist hfsplus
install squashfs /bin/false
blacklist squashfs
install udf      /bin/false
blacklist udf
install dccp     /bin/false
blacklist dccp
install sctp     /bin/false
blacklist sctp
install rds      /bin/false
blacklist rds
install tipc     /bin/false
blacklist tipc
MODS

# -- 1.1.2 /tmp: enforce nodev, nosuid, noexec --
echo "==> [CIS 1.1.2] Hardening /tmp mount options..."
if ! grep -q "^tmpfs /tmp " /etc/fstab; then
  echo "tmpfs /tmp tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0" >>/etc/fstab
fi
mount -o remount,nodev,nosuid,noexec /tmp 2>/dev/null || true

# -- 1.1.3 /dev/shm: enforce nodev, nosuid, noexec --
echo "==> [CIS 1.1.3] Hardening /dev/shm mount options..."
if grep -q "^tmpfs /dev/shm" /etc/fstab; then
  sed -i 's|^\(tmpfs /dev/shm.*\)defaults|\1defaults,nodev,nosuid,noexec|' /etc/fstab
else
  echo "tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0" >>/etc/fstab
fi
mount -o remount,nodev,nosuid,noexec /dev/shm 2>/dev/null || true

# -- 1.1.4 Sticky bit on all world-writable directories --
echo "==> [CIS 1.1.4] Setting sticky bit on world-writable directories..."
df --local -P | awk 'NR!=1 {print $6}' | xargs -I '{}' find '{}' -xdev -type d \( -perm -0002 -a ! -perm -1000 \) 2>/dev/null |
  xargs chmod a+t 2>/dev/null || true

# =============================================================================
# 2. SOFTWARE UPDATES
# =============================================================================

# -- 1.9 Ensure updates and security patches are applied --
echo "==> [CIS 1.9] Configuring automatic security updates..."
apt-get install -y unattended-upgrades apt-listchanges
cat >/etc/apt/apt.conf.d/50unattended-upgrades <<'APT_CONF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APT_CONF

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'APT_CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT_CONF

systemctl enable unattended-upgrades
systemctl start unattended-upgrades

# =============================================================================
# 3. FILESYSTEM INTEGRITY (AIDE)
# =============================================================================

# -- 1.3.1-2 Install AIDE and schedule daily check --
echo "==> [CIS 1.3] Installing and configuring AIDE..."
apt-get install -y aide aide-common

# Exclude the PowerDNS SQLite3 database from AIDE monitoring.
# This file is written on every DNS query/zone change; monitoring it would
# generate constant false positives and obscure genuine integrity alerts.
cat >>/etc/aide/aide.conf <<'AIDE_EXCL'

# PowerDNS SQLite3 backend – excluded because it changes on every DNS write
!/var/lib/powerdns/pdns\.db.*
AIDE_EXCL

# Initialise the database (runs in background – can take a few minutes)
aideinit --yes 2>/dev/null &

# Daily integrity check via cron
cat >/etc/cron.daily/aide-check <<'CRON'
#!/bin/sh
/usr/bin/aide --config=/etc/aide/aide.conf --check 2>&1 | logger -t aide
CRON
chmod 700 /etc/cron.daily/aide-check

# =============================================================================
# 4. SECURE BOOT / BOOTLOADER
# =============================================================================

# -- 1.4.2 Restrict bootloader config permissions --
echo "==> [CIS 1.4.2] Securing bootloader configuration..."
[ -f /boot/grub/grub.cfg ] && chmod og-rwx /boot/grub/grub.cfg

# -- 1.4.1 GRUB password (optional – set via Morpheus cis_grub_password_hash option) --
GRUB_PW_HASH="${cis_grub_password_hash:-}"
if [[ -n "${GRUB_PW_HASH}" ]]; then
  cat >/etc/grub.d/40_custom_cis_password <<GRUBPW
#!/bin/sh
exec tail -n +3 \$0
set superusers="root"
password_pbkdf2 root ${GRUB_PW_HASH}
GRUBPW
  chmod 755 /etc/grub.d/40_custom_cis_password
  update-grub 2>/dev/null || true
  echo "==> [CIS 1.4.1] GRUB bootloader password configured."
else
  echo "==> [CIS 1.4.1] SKIPPED – no GRUB password hash provided (cis_grub_password_hash not set)."
fi

# =============================================================================
# 5. PROCESS HARDENING
# =============================================================================

echo "==> [CIS 1.5] Configuring process hardening..."

# -- 1.5.1 Restrict core dumps --
cat >/etc/security/limits.d/cis-core-dumps.conf <<'LIMITS'
*    hard    core    0
LIMITS

# -- 1.5.3 Enable ASLR --
# -- sysctl applied in bulk in Section 9 --

# -- 1.5.4 Ensure prelink is disabled --
apt-get purge -y prelink 2>/dev/null || true

# =============================================================================
# 6. MANDATORY ACCESS CONTROL (AppArmor)
# =============================================================================

echo "==> [CIS 1.6] Configuring AppArmor..."
apt-get install -y apparmor apparmor-utils

# Enable AppArmor in the bootloader
if grep -q "^GRUB_CMDLINE_LINUX=" /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 apparmor=1 security=apparmor"/' /etc/default/grub
  # Deduplicate in case it was already present
  sed -i 's/\(apparmor=1 security=apparmor\)\( apparmor=1 security=apparmor\)*/\1/' /etc/default/grub
fi
update-grub 2>/dev/null || true

systemctl enable apparmor
systemctl start apparmor

# Set all profiles to enforce mode
aa-enforce /etc/apparmor.d/* 2>/dev/null || true

# =============================================================================
# 7. LOGIN WARNING BANNERS
# =============================================================================

echo "==> [CIS 1.7] Configuring login banners..."
BANNER_TEXT="Authorized uses only. All activity may be monitored and reported."

printf '%s\n' "${BANNER_TEXT}" >/etc/motd
printf '%s\n' "${BANNER_TEXT}" >/etc/issue
printf '%s\n' "${BANNER_TEXT}" >/etc/issue.net

chmod 644 /etc/motd /etc/issue /etc/issue.net

# =============================================================================
# 8. DISABLE UNNECESSARY SERVICES
# =============================================================================

echo "==> [CIS 2.x] Disabling unnecessary services..."

UNWANTED_SERVICES=(
  avahi-daemon
  cups
  isc-dhcp-server
  isc-dhcp-server6
  slapd
  nfs-server
  rpcbind
  named # CIS says disable; our pdns-server handles DNS instead
  vsftpd
  apache2
  nginx
  httpd
  dovecot
  smbd
  squid
  snmpd
  rsync
  nis
  rsh-server
  talk
  telnet-server
  xserver-xorg-core
)

for svc in "${UNWANTED_SERVICES[@]}"; do
  if systemctl list-unit-files --type=service | grep -q "^${svc}\.service"; then
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
    systemctl mask "${svc}" 2>/dev/null || true
  fi
done

UNWANTED_PKGS=(
  telnet
  nis
  rsh-client
  rsh-redone-client
  talk
  ldap-utils
  ftp
  mariadb-server
  mariadb-client
)
for pkg in "${UNWANTED_PKGS[@]}"; do
  apt-get purge -y "${pkg}" 2>/dev/null || true
done

# -- 2.2.1 Ensure time synchronization is in use --
apt-get install -y chrony
systemctl enable chrony
systemctl restart chrony

# Configure MTA for local-only (CIS 2.2.15)
if systemctl list-unit-files | grep -q "^postfix"; then
  postconf -e "inet_interfaces = loopback-only" 2>/dev/null || true
  systemctl restart postfix 2>/dev/null || true
fi

# =============================================================================
# 9. NETWORK HARDENING (sysctl)
# =============================================================================

echo "==> [CIS 3.x] Applying network sysctl hardening..."
cat >/etc/sysctl.d/99-cis-hardening.conf <<'SYSCTL'
# --- CIS 3.1: Disable IP forwarding (DNS servers are not routers) ---
net.ipv4.ip_forward                    = 0
net.ipv6.conf.all.forwarding           = 0

# --- CIS 3.2: Packet redirect sending ---
net.ipv4.conf.all.send_redirects       = 0
net.ipv4.conf.default.send_redirects   = 0

# --- CIS 3.3: Source routing & redirects ---
net.ipv4.conf.all.accept_source_route    = 0
net.ipv4.conf.default.accept_source_route= 0
net.ipv6.conf.all.accept_source_route    = 0
net.ipv6.conf.default.accept_source_route= 0

net.ipv4.conf.all.accept_redirects       = 0
net.ipv4.conf.default.accept_redirects   = 0
net.ipv6.conf.all.accept_redirects       = 0
net.ipv6.conf.default.accept_redirects   = 0

net.ipv4.conf.all.secure_redirects       = 0
net.ipv4.conf.default.secure_redirects   = 0

# --- CIS 3.3: Log suspicious packets ---
net.ipv4.conf.all.log_martians           = 1
net.ipv4.conf.default.log_martians       = 1

# --- CIS 3.3: ICMP broadcast & bogus error ignore ---
net.ipv4.icmp_echo_ignore_broadcasts     = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# --- CIS 3.3: Reverse path filtering ---
net.ipv4.conf.all.rp_filter              = 1
net.ipv4.conf.default.rp_filter          = 1

# --- CIS 3.3: TCP SYN cookies ---
net.ipv4.tcp_syncookies                  = 1

# --- CIS 3.3: IPv6 router advertisements ---
net.ipv6.conf.all.accept_ra              = 0
net.ipv6.conf.default.accept_ra          = 0

# --- CIS 1.5.3: ASLR ---
kernel.randomize_va_space                = 2

# --- CIS 1.5.1: Core dump restriction ---
fs.suid_dumpable                         = 0

# --- Additional hardening ---
kernel.dmesg_restrict                    = 1
kernel.kptr_restrict                     = 2
net.ipv4.tcp_timestamps                  = 0
SYSCTL

sysctl --system

# =============================================================================
# 10. AUDIT DAEMON (auditd)
# =============================================================================

echo "==> [CIS 4.1] Configuring auditd..."
apt-get install -y auditd audispd-plugins

cat >/etc/audit/rules.d/cis-level1.rules <<'AUDIT'
# Delete all existing rules
-D

# Set buffer size large enough for a busy system
-b 8192

# --- Time changes (CIS 4.1.3) ---
-a always,exit -F arch=b64 -S adjtimex,settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex,settimeofday,stime -k time-change
-a always,exit -F arch=b64 -S clock_settime -k time-change
-a always,exit -F arch=b32 -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

# --- User / group changes (CIS 4.1.4) ---
-w /etc/group  -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# --- Network environment changes (CIS 4.1.5) ---
-a always,exit -F arch=b64 -S sethostname,setdomainname -k system-locale
-a always,exit -F arch=b32 -S sethostname,setdomainname -k system-locale
-w /etc/issue     -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts     -p wa -k system-locale
-w /etc/network   -p wa -k system-locale

# --- Mandatory Access Controls (CIS 4.1.6) ---
-w /etc/apparmor/       -p wa -k MAC-policy
-w /etc/apparmor.d/     -p wa -k MAC-policy

# --- Login / logout events (CIS 4.1.7) ---
-w /var/log/faillog  -p wa -k logins
-w /var/log/lastlog  -p wa -k logins
-w /var/log/tallylog -p wa -k logins

# --- Session initiation (CIS 4.1.8) ---
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k logins
-w /var/log/btmp -p wa -k logins

# --- Permission changes (CIS 4.1.9) ---
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod

# --- Unsuccessful unauthorised file access (CIS 4.1.10) ---
-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access
-a always,exit -F arch=b32 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access
-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=unset -k access
-a always,exit -F arch=b32 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=unset -k access

# --- Privileged command execution (CIS 4.1.11) ---
-a always,exit -F path=/usr/bin/sudo    -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/su      -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/newgrp  -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/chsh    -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/chfn    -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/passwd  -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/bin/su          -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/sbin/useradd -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/sbin/usermod -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/sbin/userdel -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/sbin/groupadd -F perm=x -F auid>=1000 -F auid!=unset -k privileged

# --- Successful filesystem mounts (CIS 4.1.12) ---
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=unset -k mounts
-a always,exit -F arch=b32 -S mount -F auid>=1000 -F auid!=unset -k mounts

# --- File deletions (CIS 4.1.13) ---
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=unset -k delete
-a always,exit -F arch=b32 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=unset -k delete

# --- Sudoers changes (CIS 4.1.14) ---
-w /etc/sudoers      -p wa -k scope
-w /etc/sudoers.d/   -p wa -k scope

# --- Sudo log file (CIS 4.1.15) ---
-w /var/log/sudo.log -p wa -k actions

# --- PowerDNS SQLite3 database – audit writes (zone/record changes) ---
-w /var/lib/powerdns/pdns.db -p wa -k pdns-db-change

# --- Kernel module loading (CIS 4.1.16) ---
-w /sbin/insmod  -p x -k modules
-w /sbin/rmmod   -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules

# Make rules immutable – requires reboot to change (CIS 4.1.17)
-e 2
AUDIT

# Configure auditd to halt on full log (CIS 4.1.1.2 / 4.1.1.3)
sed -i 's/^space_left_action.*/space_left_action = email/' /etc/audit/auditd.conf
sed -i 's/^action_mail_acct.*/action_mail_acct = root/' /etc/audit/auditd.conf
sed -i 's/^admin_space_left_action.*/admin_space_left_action = halt/' /etc/audit/auditd.conf

# Ensure auditd starts before other services (CIS 4.1.1.1)
sed -i 's/^max_log_file_action.*/max_log_file_action = keep_logs/' /etc/audit/auditd.conf

systemctl enable auditd
systemctl restart auditd

# =============================================================================
# 11. RSYSLOG
# =============================================================================

echo "==> [CIS 4.2] Configuring rsyslog..."
apt-get install -y rsyslog

cat >>/etc/rsyslog.conf <<'RSYS'
# CIS: Ensure file creation mode is correct
$FileCreateMode 0640
RSYS

# CIS 4.2.1.3 – Ensure rsyslog default file permissions
sed -i 's/^\$FileCreateMode.*/\$FileCreateMode 0640/' /etc/rsyslog.conf

systemctl enable rsyslog
systemctl restart rsyslog

# =============================================================================
# 12. SSH HARDENING
# =============================================================================

echo "==> [CIS 5.2] Hardening SSH server configuration..."
SSHD_CONF=/etc/ssh/sshd_config

# Back up original
cp -n "${SSHD_CONF}" "${SSHD_CONF}.orig"

# Helper to set or add an SSH config directive
ssh_set() {
  local key="$1" val="$2"
  if grep -qiE "^#?[[:space:]]*${key}[[:space:]]" "${SSHD_CONF}"; then
    sed -i -E "s|^#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "${SSHD_CONF}"
  else
    echo "${key} ${val}" >>"${SSHD_CONF}"
  fi
}

# CIS 5.2.4 – Permissions on SSH private host keys
find /etc/ssh -xdev -type f -name 'ssh_host_*_key' -exec chmod 600 {} \;
find /etc/ssh -xdev -type f -name 'ssh_host_*_key.pub' -exec chmod 644 {} \;

ssh_set "Protocol" "2"
ssh_set "LogLevel" "VERBOSE"
ssh_set "LoginGraceTime" "60"
ssh_set "PermitRootLogin" "no"
ssh_set "StrictModes" "yes"
ssh_set "MaxAuthTries" "4"
ssh_set "MaxSessions" "4"
ssh_set "PubkeyAuthentication" "yes"
ssh_set "IgnoreRhosts" "yes"
ssh_set "HostbasedAuthentication" "no"
ssh_set "PermitEmptyPasswords" "no"
ssh_set "PermitUserEnvironment" "no"
ssh_set "X11Forwarding" "no"
ssh_set "PrintLastLog" "yes"
ssh_set "TCPKeepAlive" "no"
ssh_set "AllowTcpForwarding" "no"
ssh_set "AllowAgentForwarding" "no"
ssh_set "GatewayPorts" "no"
ssh_set "ClientAliveInterval" "300"
ssh_set "ClientAliveCountMax" "3"
ssh_set "Banner" "/etc/issue.net"
ssh_set "AcceptEnv" "LANG LC_*"
ssh_set "UsePAM" "yes"
ssh_set "Compression" "no"

# CIS 5.2.13 – Strong ciphers only
ssh_set "Ciphers" \
  "aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"

# CIS 5.2.14 – Strong MACs only
ssh_set "MACs" \
  "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256"

# CIS 5.2.15 – Strong KexAlgorithms only
ssh_set "KexAlgorithms" \
  "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521"

sshd -t && systemctl restart ssh

# =============================================================================
# 13. PAM / PASSWORD POLICY
# =============================================================================

echo "==> [CIS 5.3] Configuring PAM and password policy..."
apt-get install -y libpam-pwquality

# -- CIS 5.3.1 – Password creation requirements --
cat >/etc/security/pwquality.conf <<'PWQ'
minlen  = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
maxrepeat = 3
reject_username
dictcheck = 1
enforcing = 1
PWQ

# -- CIS 5.3.2 / 5.3.3 – Lockout policy (pam_faillock) --
# Ubuntu 24.04 uses pam_faillock via common-auth/common-account
if [ -f /etc/pam.d/common-auth ] && ! grep -q "pam_faillock" /etc/pam.d/common-auth; then
  sed -i '/^auth.*pam_unix.so/i auth required pam_faillock.so preauth silent audit deny=5 unlock_time=900' /etc/pam.d/common-auth
  sed -i '/^auth.*pam_unix.so/a auth [default=die] pam_faillock.so authfail audit deny=5 unlock_time=900' /etc/pam.d/common-auth
fi
if [ -f /etc/pam.d/common-account ] && ! grep -q "pam_faillock" /etc/pam.d/common-account; then
  echo "account required pam_faillock.so" >>/etc/pam.d/common-account
fi

# -- CIS 5.3.4 – Password reuse (remember last 5) --
if [ -f /etc/pam.d/common-password ]; then
  if ! grep -q "remember=" /etc/pam.d/common-password; then
    sed -i '/pam_unix.so/s/$/ remember=5/' /etc/pam.d/common-password
  fi
fi

# =============================================================================
# 14. USER ACCOUNT & PASSWORD AGING
# =============================================================================

echo "==> [CIS 5.4-5.5] Configuring password aging and account defaults..."

# -- CIS 5.4.1.1-3 – Password expiry settings --
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   365/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   7/' /etc/login.defs

# -- CIS 5.4.1.4 – Lock inactive accounts after 30 days --
useradd -D -f 30

# -- CIS 5.4.4 – Default umask --
echo "umask 027" >/etc/profile.d/cis-umask.sh
chmod 644 /etc/profile.d/cis-umask.sh
sed -i 's/^UMASK.*/UMASK           027/' /etc/login.defs

# -- CIS 5.4.5 – Default shell timeout --
echo "readonly TMOUT=900 ; export TMOUT" >/etc/profile.d/cis-timeout.sh
chmod 644 /etc/profile.d/cis-timeout.sh

# -- CIS 5.5 – Restrict su to wheel/sudo group --
if [ -f /etc/pam.d/su ] && ! grep -q "pam_wheel" /etc/pam.d/su; then
  sed -i '/^#.*pam_wheel.so use_uid/s/^#//' /etc/pam.d/su
fi

# =============================================================================
# 15. SUDO CONFIGURATION
# =============================================================================

echo "==> [CIS 5.3.7] Hardening sudo..."
# Ensure sudo is installed
apt-get install -y sudo

# Log sudo activity
cat >/etc/sudoers.d/cis-logging <<'SUDO'
Defaults logfile="/var/log/sudo.log"
Defaults log_input, log_output
Defaults use_pty
Defaults !visiblepw
Defaults passwd_timeout=1
SUDO
chmod 440 /etc/sudoers.d/cis-logging

# =============================================================================
# 16. SYSTEM FILE PERMISSIONS
# =============================================================================

echo "==> [CIS 6.1] Verifying critical file permissions..."

chmod 644 /etc/passwd
chmod 640 /etc/shadow
chmod 644 /etc/group
chmod 640 /etc/gshadow
chmod 644 /etc/passwd-
chmod 640 /etc/shadow-
chmod 644 /etc/group-
chmod 640 /etc/gshadow-

chown root:root /etc/passwd /etc/group /etc/passwd- /etc/group-
chown root:shadow /etc/shadow /etc/gshadow /etc/shadow- /etc/gshadow-

# Ensure no world-writable files in /etc
find /etc -xdev -type f -perm -0002 -exec chmod o-w {} \; 2>/dev/null || true

# Ensure no unowned files
find / -xdev \( -nouser -o -nogroup \) -exec chown root:root {} \; 2>/dev/null || true

# =============================================================================
# 17. CRON PERMISSIONS
# =============================================================================

echo "==> [CIS 5.1] Securing cron..."
[ -f /etc/crontab ] && chmod og-rwx /etc/crontab
[ -d /etc/cron.hourly ] && chmod og-rwx /etc/cron.hourly
[ -d /etc/cron.daily ] && chmod og-rwx /etc/cron.daily
[ -d /etc/cron.weekly ] && chmod og-rwx /etc/cron.weekly
[ -d /etc/cron.monthly ] && chmod og-rwx /etc/cron.monthly
[ -d /etc/cron.d ] && chmod og-rwx /etc/cron.d

# Allow only root to use cron/at
echo "root" >/etc/cron.allow
[ -f /etc/cron.deny ] && rm -f /etc/cron.deny
echo "root" >/etc/at.allow
[ -f /etc/at.deny ] && rm -f /etc/at.deny

echo "==> [CIS] Level 1 hardening complete."
echo "==> NOTE: A reboot is recommended to apply bootloader/audit rule changes."
