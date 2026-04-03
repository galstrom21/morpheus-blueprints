# PowerDNS 3-Node Cluster – Morpheus Blueprint

## Architecture

| Node | Role | Backend | Services |
|------|------|---------|----------|
| `pdns-01` | Primary | SQLite3 (local) | PowerDNS Authoritative – zone authority |
| `pdns-02` | Secondary | SQLite3 (local) | PowerDNS Authoritative – AXFR replica |
| `pdns-03` | Secondary | SQLite3 (local) | PowerDNS Authoritative – AXFR replica |

Each node has its own local SQLite3 database. Zone data is created on `pdns-01` and automatically replicated to `pdns-02` and `pdns-03` using PowerDNS native AXFR/NOTIFY and the **autosecondary** mechanism — no shared database or network DB port required.

```
          ┌─────────────────────┐
          │      Clients        │
          └──────┬──────┬───────┘
                 │      │
        ┌────────▼─┐  ┌─▼────────┐
        │ pdns-02  │  │ pdns-03  │  (Secondary – AXFR replica)
        │ pdns:53  │  │ pdns:53  │
        │ sqlite3  │  │ sqlite3  │
        └────────┬─┘  └─┬────────┘
           NOTIFY/AXFR   NOTIFY/AXFR
        ┌────────▼───────▼────────┐
        │         pdns-01          │
        │  pdns:53  pdns-api:8081  │  (Primary – zone authority)
        │  sqlite3 (local)         │
        └──────────────────────────┘
```

**Replication flow:**
1. Zones are created/edited on `pdns-01` via the API or `pdnsutil`.
2. `pdns-01` sends NOTIFY to secondaries (configure `also-notify` post-deploy with secondary IPs, or rely on NS-record-based NOTIFY).
3. Each secondary's `supermasters` table contains the primary IP — on receiving a NOTIFY from it, the secondary auto-creates the zone and performs an AXFR to pull the data.

## Files

```
pdns/
├── blueprint.json              # Morpheus App Blueprint definition
├── scripts/
│   ├── cis-hardening.sh        # CIS Ubuntu 24.04 Level 1 hardening (all nodes)
│   ├── primary-setup.sh        # Provision script for pdns-01
│   └── secondary-setup.sh      # Provision script for pdns-02 / pdns-03
└── README.md
```

## Importing into Morpheus

### 1. Upload Scripts as Tasks

In **Provisioning → Automation → Tasks**, create three **Shell Script** tasks:

| Task Name | Script |
|-----------|--------|
| `pdns-primary-setup` | `scripts/primary-setup.sh` |
| `pdns-secondary-setup` | `scripts/secondary-setup.sh` |
| `pdns-cis-hardening` | `scripts/cis-hardening.sh` |

Set **Execute Target** to `Local` (runs on the provisioned VM).

### 2. Create Task Sets (Workflows)

In **Provisioning → Automation → Workflows**, create two workflows. The CIS hardening task runs last so all application services exist before being hardened:

| Workflow Name | Phase | Tasks (in order) |
|---------------|-------|-----------------|
| `pdns-primary-setup` | Post-Provision | `pdns-primary-setup` → `pdns-cis-hardening` |
| `pdns-secondary-setup` | Post-Provision | `pdns-secondary-setup` → `pdns-cis-hardening` |

### 3. Import the Blueprint

In **Provisioning → Blueprints**:
1. Click **+ Add Blueprint** → **Morpheus**
2. Paste / import `blueprint.json`
3. Adjust the `layout.code` and `plan.code` values to match your environment's instance types and service plans.

### 4. Deploy the App

In **Provisioning → Apps → + Add App**:
1. Select the **PowerDNS 3-Node Cluster** blueprint.
2. Fill in the prompted options:
   - **PowerDNS API Key** – shared API key for all nodes
   - **Enable PowerDNS Recursor** – optional, installs `pdns-recursor`
   - **GRUB Password Hash** – optional; output of `grub-mkpasswd-pbkdf2` for CIS 1.4.1
3. Deploy. A reboot per node after provisioning is recommended to activate bootloader and audit rule changes.
4. **Post-deploy:** SSH to `pdns-01` and add `also-notify = <pdns-02-ip>,<pdns-03-ip>` to `/etc/powerdns/pdns.conf`, then `systemctl reload pdns`. This ensures explicit NOTIFY is sent whenever zones change.

## CIS Level 1 Controls Applied

| CIS Section | Control | Script Section |
|-------------|---------|---------------|
| 1.1.1 | Disable unused filesystems (cramfs, squashfs, udf, dccp, sctp, etc.) | § 1 |
| 1.1.2–3 | `/tmp` and `/dev/shm` nodev/nosuid/noexec | § 1 |
| 1.1.4 | Sticky bit on world-writable directories | § 1 |
| 1.3.1–2 | AIDE integrity checking with daily cron job | § 3 |
| 1.4.1 | GRUB bootloader password (optional, via Morpheus option) | § 4 |
| 1.4.2 | Bootloader config file permissions (og-rwx) | § 4 |
| 1.5.1 | Core dump restrictions (`fs.suid_dumpable=0`) | § 5 / § 9 |
| 1.5.3 | ASLR enabled (`randomize_va_space=2`) | § 9 |
| 1.5.4 | Prelink disabled/removed | § 5 |
| 1.6 | AppArmor installed, enabled, and profiles set to enforce | § 6 |
| 1.7 | Login warning banners (/etc/motd, /etc/issue, /etc/issue.net) | § 7 |
| 1.9 | Automatic unattended security upgrades | § 2 |
| 2.1–2.3 | Unnecessary services disabled, legacy clients removed | § 8 |
| 2.2.1 | chrony time synchronisation | § 8 |
| 3.1–3.4 | Uncommon network protocols disabled (dccp, sctp, rds, tipc) | § 1 |
| 3.2–3.3 | Network sysctl hardening (redirects, martians, SYN cookies, RP filter, IPv6 RA) | § 9 |
| 4.1 | auditd with full CIS audit rule set (time, identity, network, MAC, logins, permissions, mounts, modules) | § 10 |
| 4.2 | rsyslog with restrictive file creation mode | § 11 |
| 5.1 | cron/at restricted to root only | § 17 |
| 5.2 | SSH hardened: no root login, strong ciphers/MACs/KEX, no forwarding, banner, ClientAlive | § 12 |
| 5.3 | PAM: pwquality complexity (14 chars, mixed) + pam_faillock 5-attempt lockout | § 13 |
| 5.4.1 | Password aging (max 365d / min 1d / warn 7d) | § 14 |
| 5.4.4 | Default umask 027 | § 14 |
| 5.4.5 | Shell inactivity timeout TMOUT=900 | § 14 |
| 5.5 | sudo restricted to group; pty enforcement + full command logging | § 15 |
| 6.1 | Critical file permissions (/etc/passwd, shadow, group, gshadow) | § 16 |

## Customisation

| Parameter | Location | Description |
|-----------|----------|-------------|
| `layout.code` | `blueprint.json` | Morpheus instance layout (must match your catalog) |
| `plan.code` | `blueprint.json` | VM sizing plan code |
| `network.idName` | `blueprint.json` | Target network name |
| `PDNS_DB` | `primary-setup.sh` / `secondary-setup.sh` | Path to the SQLite3 database file |
| `webserver-allow-from` | `primary-setup.sh` | Subnets allowed to reach the API |
| `allow-axfr-ips` | `primary-setup.sh` | Subnets allowed to perform AXFR zone transfers |
| `also-notify` | `/etc/powerdns/pdns.conf` on pdns-01 | Explicit secondary IPs to send NOTIFY to (set post-deploy) |
| `pwquality.conf` | `cis-hardening.sh` | Password complexity rules |
| `pam_faillock deny=` | `cis-hardening.sh` | Account lockout threshold (default: 5) |
| `PASS_MAX_DAYS` | `cis-hardening.sh` | Maximum password age in days (default: 365) |

## Prerequisites

- Ubuntu 24.04 image registered in Morpheus
- Network connectivity between all three VMs on ports 22, 53, and 8081
- Morpheus linked-tier variable resolution enabled (used by `secondary-setup.sh` to discover the primary IP)
