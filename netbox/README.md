# NetBox – Morpheus Blueprint

## Architecture

A single-node NetBox deployment on Ubuntu 24.04 LTS. All components run on the same VM.

| Component | Role |
|-----------|------|
| PostgreSQL | Primary relational database |
| Redis | Caching and background task queue |
| NetBox (Gunicorn) | WSGI application server |
| nginx | Reverse proxy / HTTPS termination |

```
          ┌──────────────────────────────────────┐
          │           netbox VM                  │
          │                                      │
          │  nginx (443/80)                      │
          │     └─► Gunicorn (127.0.0.1:8001)    │
          │            └─► NetBox (Django)        │
          │                  ├─► PostgreSQL       │
          │                  └─► Redis            │
          └──────────────────────────────────────┘
```

## Files

```
netbox/
├── blueprint.json              # Morpheus App Blueprint definition
├── playbooks/
│   └── netbox-install.yml      # Ansible playbook – full installation
└── README.md
```

## Playbook Overview

`playbooks/netbox-install.yml` performs the following in order:

1. **PostgreSQL** – installs, starts, creates the `netbox` database and user
2. **Redis** – installs and starts `redis-server`
3. **System packages** – all build and Python dependencies required by NetBox
4. **Clone NetBox** – checks out the requested release tag from GitHub to `/opt/netbox`
5. **System user** – creates the `netbox` system user/group; sets ownership on `media/`, `reports/`, `scripts/`
6. **Secrets** – generates `SECRET_KEY` and `API_TOKEN_PEPPER` via Python's `secrets` module
7. **configuration.py** – writes the complete NetBox config with DB, Redis, and generated secrets
8. **upgrade.sh** – runs the bundled upgrade script (creates venv, installs Python packages, runs migrations)
9. **Superuser** – creates the initial Django superuser
10. **Gunicorn / systemd** – copies `contrib/gunicorn.py` and enables `netbox` + `netbox-rq` systemd services
11. **nginx + SSL** – installs nginx, generates a self-signed certificate, and enables the bundled nginx site

## Importing into Morpheus

### 1. Create the Ansible Task

In **Provisioning → Automation → Tasks**, create a new task:

| Field | Value |
|-------|-------|
| **Name** | `netbox-install` |
| **Type** | `Ansible Playbook` |
| **Playbook** | `netbox-install.yml` (or the full path if using a git repository) |
| **Execute Target** | `Local` (the provisioned VM) |

Upload or reference `playbooks/netbox-install.yml`. Blueprint options are automatically passed to Ansible as extra vars.

### 2. Create the Workflow

In **Provisioning → Automation → Workflows**, create a workflow:

| Field | Value |
|-------|-------|
| **Name** | `netbox-install` |
| **Phase** | Post-Provision |
| **Tasks** | `netbox-install` |

### 3. Import the Blueprint

In **Provisioning → Blueprints**:
1. Click **+ Add Blueprint** → **Morpheus**
2. Paste / import `blueprint.json`
3. Adjust `layout.code` and `plan.code` to match your environment

### 4. Deploy the App

In **Provisioning → Apps → + Add App**:
1. Select the **NetBox** blueprint
2. Fill in the prompted options:

| Option | Required | Description |
|--------|----------|-------------|
| **NetBox Version** | No | Git release tag (default: `v4.3.4`) |
| **Database Password** | Yes | PostgreSQL password for the `netbox` user |
| **Allowed Hosts** | No | `ALLOWED_HOSTS` value (default: `*`) |
| **Admin Username** | No | Initial superuser username (default: `admin`) |
| **Admin Password** | Yes | Initial superuser password |
| **Admin Email** | No | Initial superuser email |

3. Deploy. After provisioning completes, NetBox is available at `https://<vm-hostname>/`.

## Post-Deploy Notes

- **SSL certificate** – a self-signed certificate is generated during provisioning. Replace `/etc/ssl/certs/netbox.crt` and `/etc/ssl/private/netbox.key` with a CA-signed certificate for production.
- **Allowed Hosts** – if you set `ALLOWED_HOSTS = ['*']` initially, update `/opt/netbox/netbox/netbox/configuration.py` with the actual hostname or IP once known, then restart the service: `systemctl restart netbox`.
- **NetBox version** – to upgrade, update the `netbox_version` option and re-run the workflow, or manually `git checkout <new-tag>` on the server and run `/opt/netbox/upgrade.sh`.
- **Secrets** – `SECRET_KEY` and `API_TOKEN_PEPPER` are generated at provisioning time and written to `configuration.py`. Back up this file or record these values; they are not stored elsewhere.

## Customisation

| Parameter | Location | Description |
|-----------|----------|-------------|
| `layout.code` | `blueprint.json` | Morpheus instance layout (must match your catalog) |
| `plan.code` | `blueprint.json` | VM sizing plan (default: 4 GB RAM) |
| `network.idName` | `blueprint.json` | Target network name |
| `netbox_path` | playbook `vars` | Installation directory (default: `/opt/netbox`) |
| `CONN_MAX_AGE` | `configuration.py` | Database connection pool age in seconds |

## Prerequisites

- Ubuntu 24.04 image registered in Morpheus
- Internet access from the provisioned VM (to reach GitHub and Ubuntu apt mirrors)
- Ansible execution environment in Morpheus with `ansible.builtin` collection (standard Ansible)
- VM reachable on port 443 (HTTPS) from client workstations
