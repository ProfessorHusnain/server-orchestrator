# ServerOrchestrator — On-Demand Hetzner Cloud Desktop

## Context

The goal is a **cost-saving, on-demand cloud desktop platform** on Hetzner Cloud. You spin
up an Ubuntu server, RDP into it as a full desktop to work, and when done, tear it down to
stop paying for it. Critically, **before destroying** a server the system takes a **snapshot**
of its disk so all your state (installed apps, files, settings) persists. The next time you
bring that server up, it boots **from the latest snapshot** instead of a blank image — so it
feels like the same machine you left.

The system must manage **multiple independent servers**, each controlled individually (create/
destroy/snapshot one without affecting others). All declarative configuration lives under
`config/` as YAML; **Terraform** owns infrastructure and **Ansible** configures the inside of
each server (GNOME desktop + xrdp). Execution is designed to run from **GitHub Actions**
(profiles, RDP password, tokens injected as env vars / GitHub variables) but is fully runnable
locally now via exported env vars. **The GitHub Actions workflow is a later phase** — this plan
builds the Terraform + Ansible + scripts core.

## Key Decisions (from brainstorming)

- **Purpose:** ephemeral cloud desktop — spin up, RDP in, snapshot, destroy, restore later.
- **Snapshot retention:** keep exactly **2 per server** — `latest` + `previous` (rollback safety
  net). On destroy: snapshot → verify → prune to newest 2 (within that server's lineage) → delete server.
- **Cold start:** if no snapshot exists for a server, provision from **base Ubuntu 24.04 LTS** and
  let Ansible fully configure it; first destroy creates the first snapshot. Snapshot-exists →
  boot from snapshot + idempotent Ansible reconcile.
- **Desktop:** **GNOME by default**, switchable to XFCE via a `desktop_env` variable in config.
  Switching is a config change + playbook re-run (then snapshot to persist).
- **Region:** Hetzner **Singapore (`sin`)** — closest to Pakistan (Hetzner's only Asia region).
- **Server profiles** (selectable per server, also from GitHub later):
  - `light` → cx22 (2 vCPU, 4 GB)
  - `medium` → cx42 (8 vCPU, 16 GB)  ← default
  - `fast` → cpx42 (8 vCPU, 16 GB AMD)
  - `heavy` → ccx33 (8 vCPU, 32 GB dedicated)
  - `monster` → ccx43 (16 vCPU, 64 GB dedicated)
- **Multi-server model:** **one YAML file per server** under `config/servers/`; the reusable
  Terraform module is invoked per server with **per-server isolated state** (workspace/state path)
  and **per-server-labeled snapshots**. Acting on one server can never affect another.
- **Secrets:** all secrets (Hetzner API token, SSH private key, Slack webhook) via **env vars**;
  **RDP password via a GitHub variable** (user's explicit choice — note: GitHub *variables* are
  plaintext/visible, unlike secrets; accepted). `config/` holds only **non-secret** declarations.
- **Authentication:** SSH **key-based** for Ansible; RDP via username + password (from GitHub var).
- **Floating IP — fully dynamic & config-driven:**
  - `config/floating_ip.yaml` defines **named entries**; each entry either **adopts an existing**
    Hetzner floating IP (by name/ID) or **creates its own** lazily if missing.
  - A server references a named entry (e.g. `floating_ip: main`). Same entry referenced by
    multiple servers → that one IP is **reassigned** between them (shared case, fits "one desktop
    up at a time"). Distinct entries → each server gets its own. No reference → ephemeral IP.
  - Floating IPs have **independent lifecycle**: never auto-deleted on server destroy (just
    detached) — the IP survives teardowns. (Hetzner constraint: a floating IP attaches to only
    one server at a time.)
- **Security:** firewall restricted to **SSH (22) + RDP (3389)**; **fail2ban** on the box guarding
  RDP/SSH against brute-force.
- **Safe destroy:** always **snapshot → verify success → prune → delete server** (never reverse).
- **Slack notifications:**
  - **Provisioning lifecycle** posted from the **Terraform/CI layer** (create-started, create-done
    with IP, snapshot-created, destroy-done, failures) via `scripts/notify-slack.sh`.
  - **fail2ban brute-force** ban events post from a fail2ban action script on the server to the
    **same Slack webhook/channel**.

## Architecture

**State machine (per server):**

```
CREATE <server>:
  read config/servers/<server>.yaml (+ config/defaults.yaml, profiles.yaml, floating_ip.yaml)
  select/init per-server Terraform state (workspace)
  latest snapshot for <server> exists?
    YES → provision server FROM latest snapshot   → Ansible (idempotent reconcile)
    NO  → provision server FROM base Ubuntu 24.04  → Ansible (full configure)
  resolve floating IP entry (adopt/create) → detach-from-old + attach-to-<server> (if referenced)
  Slack: create-started → create-done (with RDP IP)

DESTROY <server>:
  create snapshot from running <server> (labeled server=<server>)
  VERIFY snapshot status == available   (abort destroy on failure, Slack alert)
  prune snapshots WHERE label server=<server>, keep newest 2 ([latest, previous])
  detach floating IP (do NOT delete it)
  destroy server (state preserved per-server)
  Slack: snapshot-created → destroy-done
```

**Tool boundaries:**
- **Terraform** (reusable module in `terraform/`): provider, server, firewall, snapshot data
  lookup + conditional base-vs-snapshot boot, conditional/dynamic floating IP, labels,
  cloud-init bootstrap, outputs. Pure logic — reads declarations from `config/` via `yamldecode`.
- **Ansible** (shared roles in `ansible/`): common base + updates, GNOME/XFCE desktop, xrdp +
  session wiring + RDP user/password, security (firewall reconcile, fail2ban + Slack ban action).
  Per-server differences come from vars only.
- **Scripts** (`scripts/`): thin local-run wrappers orchestrating the above + Slack helper.

## Folder Structure

```
ServerOrchestrator/
├── config/                          # ALL declarative, non-secret config (YAML)
│   ├── profiles.yaml                # light/medium/fast/heavy/monster → Hetzner types
│   ├── defaults.yaml                # region(sin), desktop_env(gnome), retention(2),
│   │                                #   ubuntu_image(ubuntu-24.04), default_profile(medium)
│   ├── floating_ip.yaml             # named FIP entries: adopt-existing | create; assignment
│   ├── servers/                     # ONE FILE PER SERVER = the unit of control
│   │   ├── alice.yaml               #   profile, desktop_env override?, floating_ip ref?,
│   │   └── bob.yaml                 #   region override?, ansible var overrides?
│   └── README.md
│
├── terraform/                       # REUSABLE module (invoked per server)
│   ├── main.tf                      # provider, server resource, cloud-init wiring
│   ├── variables.tf                 # server_name, profile, rdp_password, flags, paths…
│   ├── snapshots.tf                 # data lookup of latest snapshot for server; boot source
│   ├── floating_ip.tf               # dynamic: adopt-or-create + attach (per config entry)
│   ├── firewall.tf                  # SSH(22) + RDP(3389) rules
│   ├── outputs.tf                   # active IP (floating or ephemeral) for RDP, server id
│   └── cloud-init.yaml              # minimal bootstrap: user, ssh key, python3 (Ansible foothold)
│
├── ansible/                         # SHARED playbook + roles (vars differ per server)
│   ├── playbook.yml
│   ├── inventory/                   # built from active server's TF output (IP/user)
│   └── roles/
│       ├── common/                  # base packages, updates, timezone
│       ├── desktop/                 # GNOME (or XFCE via desktop_env var)
│       ├── xrdp/                    # xrdp install, session startup wiring, RDP user+password
│       └── security/                # firewall reconcile, fail2ban + Slack ban-action script
│
├── scripts/
│   ├── create.sh <server>           # init per-server state → terraform apply → ansible
│   ├── destroy.sh <server>          # snapshot → verify → prune(server) → detach FIP → destroy
│   ├── lib-config.sh                # read/parse config YAML (shared helper)
│   └── notify-slack.sh              # shared Slack post helper (lifecycle events)
│
└── docs/superpowers/specs/
    └── 2026-06-08-server-orchestrator-design.md   # this spec (copied here on exit)
```

## Implementation Outline (build order)

1. **`config/` schema + samples** — `profiles.yaml`, `defaults.yaml`, `floating_ip.yaml`, one
   sample `config/servers/alice.yaml`, and `config/README.md` documenting every field.
2. **Terraform module** — variables, provider, server resource reading profile/region from config;
   `cloud-init.yaml` minimal bootstrap; firewall (22+3389); outputs.
3. **Snapshot logic** (`snapshots.tf`) — data source finds newest snapshot labeled `server=<name>`;
   `boot_source = snapshot ?? base ubuntu-24.04`; snapshot creation + keep-2 prune handled in
   `destroy.sh` (Terraform/CLI) with verify-before-delete.
4. **Dynamic floating IP** (`floating_ip.tf`) — per config entry: data-lookup existing by name →
   adopt, else create; attach to server; detach (never delete) on destroy.
5. **Ansible roles** — `common`, then `desktop` (GNOME default / XFCE switch), `xrdp` (session +
   RDP user/password from env var), `security` (firewall reconcile + fail2ban + Slack ban action).
6. **Scripts** — `lib-config.sh` (YAML read), `create.sh`, `destroy.sh` (safe-destroy flow),
   `notify-slack.sh`; wire Slack lifecycle events into create/destroy.
7. **Per-server state isolation** — Terraform workspace (or per-server state path) keyed by server
   name, selected/created by `create.sh`/`destroy.sh`.
8. **Docs** — top-level `README.md` with local-run instructions (env vars to export) and the
   create/destroy workflow. (GitHub Actions workflow deferred to a later phase — structure is
   already CI-friendly: server name + profile + secrets all parameterized.)

## Reuse / Patterns

- Greenfield workspace (empty) — no existing code to reuse; all new.
- Terraform: use the official **`hetznercloud/hcloud`** provider; `yamldecode(file(...))` to read
  `config/` so `.tf` stays pure logic and config stays declarative.
- Ansible: standard role layout; `desktop_env` chooses the desktop role's package set + xrdp
  session; idempotent so it runs cleanly on both base-image and snapshot boots.
- Snapshot/IP labeling: Hetzner **labels** (`server=<name>`, `role=desktop-state`) so prune logic
  and FIP adoption reliably target the right resources and never touch unrelated images/IPs.

## Review fixes folded in

- **Floating IP protection:** `lifecycle { prevent_destroy = true }` on the
  `hcloud_floating_ip.created` resource so an accidental `terraform destroy` can't delete the
  stable IP (belt-and-suspenders alongside the script's detach-don't-delete convention).
- **Architecture compatibility guard:** a Terraform precondition asserting the **base image
  architecture matches the profile's architecture** (x86 today). Prevents booting an unbootable
  server if an ARM (`cax*`) profile is ever added.
- **RDP password rotation:** **already handled** — the xrdp role force-syncs the password on
  **every create** via `user: password: {{ rdp_password | password_hash('sha512') }}`, so rotating
  the GitHub variable propagates on the next create. (Note: it syncs on create, not retroactively
  to an already-running idle box — consistent with the ephemeral model.)

> **Deferred (not in scope):** idle/lifetime auto-destroy ("forgotten running server" cost
> guardrail) — to be designed and implemented separately later.

## Verification

End-to-end (requires a real Hetzner account + API token; costs apply while a server runs):

1. **Cold start:** `./scripts/create.sh alice` with no prior snapshot → confirm Terraform
   provisions from base Ubuntu 24.04, Ansible completes, output shows an RDP-reachable IP.
2. **RDP in:** connect with a standard RDP client (mstsc/Remmina) to the IP:3389 using the RDP
   username + the password from the GitHub variable → GNOME desktop loads.
3. **Snapshot + destroy:** `./scripts/destroy.sh alice` → confirm a snapshot labeled `server=alice`
   is created and verified *before* the server is deleted; Slack posts lifecycle messages.
4. **Warm restore:** `./scripts/create.sh alice` again → confirm it boots **from the snapshot**
   (state from step 2 present), not a blank image.
5. **Retention:** run create/destroy a third time → confirm exactly **2** snapshots remain for
   `alice` (newest two), older pruned.
6. **Isolation:** create `bob`, destroy `alice` → confirm `bob` is untouched (separate state +
   separate snapshot lineage).
7. **Floating IP dynamic:** with `alice` and `bob` both referencing FIP entry `main` → confirm the
   IP reassigns to whichever was last created; with distinct entries → each gets its own; entry set
   to adopt an existing IP → confirm it's adopted, not recreated; FIP survives a destroy (not deleted).
8. **Desktop switch:** set `desktop_env: xfce` in `config/servers/alice.yaml`, re-run Ansible →
   confirm XFCE session over xrdp.
9. **Security:** confirm only 22 + 3389 reachable; trigger repeated failed RDP/SSP logins →
   fail2ban bans the source and posts a Slack alert to the shared channel.
```
