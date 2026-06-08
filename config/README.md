# `config/` — declarative, non-secret configuration

Everything in this folder is **declarative** and **non-secret**. Terraform reads
it with `yamldecode(file(...))` and Ansible reads it via `vars_files`, so the
`.tf` files stay pure logic and all the knobs live here as YAML.

**Secrets never live here.** The Hetzner API token, SSH private key, Slack
webhook URL, and the RDP password are injected at runtime as environment
variables (and, later, as GitHub variables/secrets). See the top-level
`README.md` for the env-var list.

## Files

| File | Purpose |
|------|---------|
| `profiles.yaml` | Named server profiles → Hetzner server types (`light`…`monster`). |
| `defaults.yaml` | Global defaults inherited by every server (region, desktop, retention, etc.). |
| `floating_ip.yaml` | Named floating-IP entries (adopt-existing or create), dynamic & shareable. |
| `servers/<name>.yaml` | One file per server — the unit of control. Overrides defaults. |

## How values resolve

For a given server, a value is taken from `servers/<name>.yaml` if present,
otherwise from `defaults.yaml`. Profiles are looked up by name in
`profiles.yaml`; floating-IP references are looked up by name in
`floating_ip.yaml`.

## Adding a server

1. Copy `servers/alice.yaml` to `servers/<new-name>.yaml`.
2. Set `name: <new-name>` to match the filename, and adjust `profile`,
   `desktop_env`, `floating_ip`, etc. (or leave them to default).
3. Run `./scripts/create.sh <new-name>`.

> The filename is authoritative for identity, state isolation, and snapshot
> labeling. The `name:` field is self-documenting and the scripts **assert it
> matches the filename** — a mismatch aborts the run (catches copy-paste slips).

Each server gets its own Terraform workspace (isolated state) and its own
snapshot lineage labeled `server=<new-name>`, so it is fully independent.
