# ServerOrchestrator — Architecture

On-demand **Hetzner Cloud desktop** platform. Spin up an Ubuntu server, RDP in to
work, then destroy it to stop paying — **without losing state**. Before every
destroy a **snapshot** is taken; the next create boots from that snapshot, so it
feels like the same machine. Manages **multiple independent servers**, each
controlled individually. Designed to run from **GitHub Actions** (later phase);
fully runnable locally now via env vars.

## Core principles

- **Config is the source of truth.** All declarative, non-secret settings live in
  `config/*.yaml`. Terraform reads them via `yamldecode`; Ansible via vars. `.tf`
  files stay pure logic.
- **Secrets only via environment variables.** Hetzner token, SSH key, Slack
  webhook, and RDP password are never committed. (RDP password comes from a
  GitHub *variable* by user choice — plaintext, not a secret.)
- **One server = one YAML file = one unit of control.** `config/servers/<name>.yaml`.
  Each server gets its **own Terraform workspace** (isolated state) and **own
  snapshot lineage** (labeled `server=<name>`). Acting on one never affects another.
- **Tool boundaries:** Terraform owns infrastructure; Ansible owns the inside of
  the box; thin bash scripts orchestrate.

## Component layers

```
config/        Declarative YAML (profiles, defaults, floating IPs, per-server files)
   │  read by
   ▼
terraform/     Reusable module: server, firewall, snapshot boot-source, dynamic FIP
   │  outputs IP/user → consumed by
   ▼
scripts/       create.sh / destroy.sh orchestrate: resolve → apply → ansible → slack
   │  runs
   ▼
ansible/       Roles: common · desktop (gnome/xfce) · xrdp · security (ufw+fail2ban+slack)
```

## State machine

```
CREATE <server>                         DESTROY <server>  (order is safety-critical)
  resolve latest snapshot                 1. snapshot the running server
    exists → warm boot from snapshot      2. VERIFY snapshot = "available"  (abort if not)
    none   → cold boot Ubuntu 24.04 LTS   3. prune snapshots → keep newest 2 (latest+prev)
  resolve floating IP (adopt/create)      4. detach floating IP  (kept, NOT deleted)
  terraform apply (per-server workspace)  5. terraform destroy the server
  ansible configures desktop+rdp+security
  Slack: started → ready (with RDP IP)    Slack: snapshotting → verified → destroyed
```

**Why scripts resolve snapshot/FIP up front:** Terraform `data` sources error when
no match exists (the cold-start / first-IP case). The script looks them up via the
Hetzner API and passes IDs in as `TF_VAR_*` (empty = create/cold path). Keeps the
plan deterministic and avoids data-source-on-empty failures.

## Key design decisions

| Area | Decision |
|------|----------|
| **Purpose** | Ephemeral cost-saving cloud desktop (one up at a time, typically). |
| **Region** | Hetzner Singapore (`sin`) — closest to Pakistan. |
| **Snapshots** | Keep exactly **2 per server** (latest + previous rollback). Pruned on destroy. |
| **Cold start** | No snapshot → base Ubuntu 24.04 LTS + full Ansible. First destroy seeds the snapshot. |
| **Desktop** | **GNOME default**, switchable to XFCE via `desktop_env` (config change + re-run). |
| **Profiles** | Named map `light/medium/fast/heavy/monster` → Hetzner types (medium/cx42 default). |
| **Floating IP** | Fully dynamic & config-driven. Named entries: adopt-existing or create. Shared by reference, dedicated by distinct entry. Never auto-deleted (survives teardown). |
| **Auth** | SSH key-based (Ansible). RDP = username + password (from GitHub variable). |
| **Secrets** | All via env vars; `config/` holds only non-secret declarations. |
| **State isolation** | Per-server Terraform workspace + per-server-labeled snapshots. |
| **Server name** | Filename is authoritative; optional `name:` field is validated to match (catches copy-paste slips). |

## Security model (defense-in-depth)

```
Internet
   ▼  Hetzner Cloud Firewall   (network edge, terraform/firewall.tf) — allow 22, 3389, icmp
   ▼  UFW                      (in-host, ansible security role)      — default-deny, allow 22/3389
   ▼  fail2ban                 (in-host)                             — bans brute-force IPs on 22/3389
   ▼  xrdp / sshd
```

- **Two firewalls on purpose:** the Hetzner firewall blocks junk at the edge; UFW
  is baked into the server/snapshot so it stays protected even if the cloud
  firewall is misconfigured or detached.
- **fail2ban** sits on top — dynamically bans brute-force sources on the open
  RDP/SSH ports (jails for both `sshd` and `xrdp`).

## Slack notifications

- **Provisioning lifecycle** (create-started, ready+IP, snapshot verified,
  destroyed, failures) posted from the **Terraform/CI layer** via `notify-slack.sh`.
- **fail2ban brute-force bans** posted from an on-server action script (installed by
  Ansible) to the **same webhook/channel**.
- Webhook is optional — absent = no Slack, never fails the run.

## Folder structure

```
config/
  profiles.yaml          # named profiles → Hetzner server types
  defaults.yaml          # region, desktop_env, retention, ubuntu image, username, firewall CIDRs
  floating_ip.yaml       # named FIP entries (adopt | create), dynamic & shareable
  servers/<name>.yaml    # ONE FILE PER SERVER — the unit of control (overrides defaults)
terraform/               # reusable module (per-server isolated state)
  main · variables · locals · firewall · snapshots · floating_ip · outputs · cloud-init.yaml
ansible/                 # shared playbook + roles (per-server differences via vars)
  roles/{common,desktop,xrdp,security}/   # desktop = DE (gnome/xfce) + VS Code (MS apt repo)
scripts/
  create.sh · destroy.sh (safe-destroy) · lib-config.sh (incl. tf_init) · notify-slack.sh
.github/workflows/
  orchestrate.yml        # manual create/destroy (workflow_dispatch)
```

## Execution flow

**Both local and CI run the same scripts.** They differ only in where inputs and
Terraform state come from.

```
local:  export env vars → ./scripts/create.sh <server> → RDP → ./scripts/destroy.sh <server>
CI:     Actions → Orchestrate Desktop → {server, action, profile?}
        → same scripts, secrets/vars from GitHub, state in S3 bucket
```

1. Inputs: `HCLOUD_TOKEN`, SSH key, `TF_VAR_rdp_password` (GitHub *variable*),
   optional `SLACK_WEBHOOK_URL`; CI also supplies S3 state bucket config.
2. `create.sh <server>` → resolve snapshot/FIP → `tf_init` (S3 key or local
   workspace) → apply → Ansible → prints RDP target.
3. RDP to `<ip>:3389`; work.
4. `destroy.sh <server>` → snapshot → verify → prune → detach IP → destroy.
5. `create.sh <server>` again → restores from the snapshot.

**Per-run profile override** (CI input or `TF_VAR_profile_override` locally) wins
over the committed `profile` for that run only — nothing is committed.

### State backend (`tf_init` picks one)

GitHub runners are ephemeral, so state must be remote in CI:
- **`TF_STATE_BUCKET` set** → S3-compatible backend, isolated by per-server state
  **key** (`servers/<name>.tfstate`). Used in CI; works locally too if pointed at a bucket.
- **`TF_STATE_BUCKET` unset** → local backend + per-server **workspace**. Laptop default.

A generated `terraform/backend_override.tf` carries the choice (gitignored).

## Known caveats (flagged for the first real run)

- **xrdp fail2ban filter regex** is best-effort; xrdp's journal format varies by
  version and may need a one-line tweak after seeing real logs.
- **GNOME-over-xrdp** is the historically finicky path (polkit/colord fix included).
- **RDP open to `0.0.0.0/0`** by default — restricting `allowed_rdp_cidrs` to your
  IP in `defaults.yaml` is the single biggest hardening win.
- **No idle auto-destroy** — a forgotten running server has no automatic backstop
  yet (deferred; to be tackled separately later).
- Terraform/Ansible aren't installed on this dev machine, so `terraform validate`
  and a real end-to-end run haven't executed; YAML and bash syntax are verified.
```
