# ServerOrchestrator — On-Demand Hetzner Cloud Desktop

Spin up an Ubuntu desktop on Hetzner Cloud, **RDP into it** to work, then tear it
down to stop paying — **without losing your state**. Before every destroy the
system takes a **snapshot**; the next create boots from that snapshot, so it
feels like the same machine you left.

- **Terraform** owns the infrastructure (server, firewall, snapshot boot, floating IP).
- **Ansible** configures the inside (GNOME/XFCE desktop + xrdp + fail2ban).
- **All declarative config** lives in [`config/`](config/) as YAML; **secrets** are
  injected at runtime as environment variables.
- Designed to run from **GitHub Actions** (a later phase); fully runnable locally now.

## How it works

```
CREATE <server>           DESTROY <server>
  snapshot exists?          snapshot the running server
   yes -> boot snapshot     verify it is "available"   (abort if not)
   no  -> boot Ubuntu 24.04 prune snapshots -> keep newest 2
  attach floating IP        detach floating IP (kept, not deleted)
  Ansible configures        destroy the server
```

Each server is defined by one file under [`config/servers/`](config/servers/) and
gets its **own Terraform workspace** (isolated state) and **own snapshot lineage**
(labeled `server=<name>`), so acting on one server never affects another.

## Layout

| Path | What it is |
|------|------------|
| [`config/`](config/) | Declarative, non-secret config (profiles, defaults, floating IPs, per-server files). |
| [`terraform/`](terraform/) | Reusable module: server, firewall, snapshot boot-source, dynamic floating IP. |
| [`ansible/`](ansible/) | Playbook + roles: `common`, `desktop`, `xrdp`, `security` (fail2ban + Slack). |
| [`scripts/`](scripts/) | `create.sh`, `destroy.sh` (safe-destroy), `notify-slack.sh`, `lib-config.sh`. |

## Prerequisites

On the runner (local Linux/WSL or the GitHub Actions Ubuntu runner):
`terraform`, `ansible`, `curl`, `jq`, `python3` (with `pyyaml`), `ssh`.

## Configuration

See [`config/README.md`](config/README.md). In short: pick a `profile`, optional
`desktop_env` (gnome/xfce), and optional `floating_ip` reference per server.

## Secrets — environment variables

These are **never** committed. Provide them in your shell (local) or as GitHub
secrets/variables (CI):

| Variable | Purpose |
|----------|---------|
| `HCLOUD_TOKEN` | Hetzner Cloud API token. |
| `TF_VAR_ssh_public_key` | SSH **public** key contents (for Ansible access). |
| `SSH_PRIVATE_KEY_FILE` | Path to the matching SSH **private** key file. |
| `TF_VAR_rdp_password` | Desktop/RDP login password. |
| `SLACK_WEBHOOK_URL` | *(optional)* Slack incoming webhook for lifecycle + fail2ban alerts. |

## Usage (local)

```bash
export HCLOUD_TOKEN=...                       # Hetzner API token
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
export SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519
export TF_VAR_rdp_password='choose-a-password'
export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...   # optional

./scripts/create.sh alice     # provision + configure -> prints RDP target
# ... RDP to <ip>:3389 as 'orchestrator', work ...
./scripts/destroy.sh alice    # snapshot -> verify -> prune -> detach IP -> destroy
./scripts/create.sh alice     # restores from the snapshot
```

## Switching desktop environment

Set `desktop_env: xfce` (or `gnome`) in `config/servers/<name>.yaml`, then re-run
`./scripts/create.sh <name>` to reconfigure. Destroy afterwards to bake the change
into the snapshot.

## Region

Servers run in Hetzner **Singapore (`sin`)** — the closest region to Pakistan.

## GitHub Actions

A manual workflow drives create/destroy: [.github/workflows/orchestrate.yml](.github/workflows/orchestrate.yml).

**Trigger:** `workflow_dispatch` (Actions tab → *Orchestrate Desktop* → *Run workflow*),
with inputs:

| Input | Options | Default | What it controls |
|-------|---------|---------|-----------------|
| `server` | free text | `alice` | Which server config to act on |
| `action` | `create` / `destroy` | — | What to do |
| `profile` | `light` / `medium` / `fast` / `heavy` / `monster` / blank | blank | Override server size for this run only; blank = use the YAML config |
| `floating_ip` | `ephemeral` / `from-config` | `ephemeral` | `ephemeral` = server uses its own public IP only; `from-config` = attach the floating IP declared in the server's YAML |

Runs are serialized per server (`concurrency`) so create/destroy can't race.
After each run a **job summary** is written to the Actions UI showing the RDP
address, username, and desktop environment (create runs only).

### GitHub Secrets

Go to **Settings → Secrets and variables → Actions → Secrets**.

| Secret name | What it is | Required? |
|-------------|------------|-----------|
| `HCLOUD_TOKEN` | Hetzner Cloud API token (read/write) | **Always** |
| `SSH_PRIVATE_KEY` | SSH private key the runner uses to reach the server (Ansible + SSH wait). The matching public key is derived from it automatically. | **Always** |
| `TF_STATE_ACCESS_KEY` | S3-compatible object storage access key (for remote Terraform state) | **Always** |
| `TF_STATE_SECRET_KEY` | S3-compatible object storage secret key | **Always** |
| `SLACK_WEBHOOK_URL` | Incoming webhook URL for lifecycle notifications | Optional — omit to disable Slack |
| `GIT_SSH_PRIVATE_KEY` | Git deploy key (GitHub SSH private key for the desktop user) | Only when a server has `git_ssh: true` |

### GitHub Variables

Go to **Settings → Secrets and variables → Actions → Variables**.
These are non-secret and visible in logs — GitHub variables by design.

| Variable name | What it is | Required? |
|---------------|------------|-----------|
| `RDP_USERNAME` | Linux username for SSH and RDP login. Defaults to `orchestrator` if not set. | Optional |
| `RDP_PASSWORD` | Password for the desktop RDP login. Stored as a variable (not a secret) by design — it's a login password, not a key/token. | **Always** |
| `TF_STATE_BUCKET` | S3-compatible bucket name holding Terraform state files | **Always** |
| `TF_STATE_ENDPOINT` | S3 endpoint URL, e.g. `https://sin1.your-objectstorage.com` | **Always** |
| `TF_STATE_REGION` | S3 region string, e.g. `sin` (defaults to `auto` if blank) | Optional |
| `GIT_USER_NAME` | Full name set as `git config user.name` on the desktop | Only when a server has `git_ssh: true` |
| `GIT_USER_EMAIL` | Email set as `git config user.email` on the desktop | Only when a server has `git_ssh: true` |

#### Minimum setup (no Slack, no git-SSH)

1. Secrets: `HCLOUD_TOKEN`, `SSH_PRIVATE_KEY`, `TF_STATE_ACCESS_KEY`, `TF_STATE_SECRET_KEY`
2. Variables: `RDP_PASSWORD`, `TF_STATE_BUCKET`, `TF_STATE_ENDPOINT` — optionally `RDP_USERNAME` (defaults to `orchestrator`)
3. Dispatch with `action=create`, `server=alice`, `floating_ip=ephemeral`

### Remote Terraform state (required for CI)

GitHub runners are ephemeral, so Terraform state **must** be remote or a later
`destroy` can't find the server. State is stored in an **S3-compatible bucket**
(Hetzner Object Storage, AWS S3, Cloudflare R2, …), keyed **per server**
(`servers/<name>.tfstate`) — that key is what isolates each server's state.

The backend is selected at init time by `scripts/lib-config.sh` (`tf_init`):
- **`TF_STATE_BUCKET` set** → S3 backend (CI, or locally if you point at a bucket).
- **`TF_STATE_BUCKET` unset** → local backend + per-server workspaces (your laptop).

So the same scripts work both in CI and locally; only locally without a bucket do
you fall back to local state. (A generated `terraform/backend_override.tf` carries
the choice and is gitignored.)
