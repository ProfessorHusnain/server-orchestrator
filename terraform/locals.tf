# Read config/*.yaml and compute this server's EFFECTIVE settings by layering
# config/servers/<name>.yaml over config/defaults.yaml. Keeping all of this in
# locals means the resource files (main/firewall/floating_ip/snapshots) stay
# pure logic and every tunable lives in declarative YAML.

locals {
  # ---- Raw config -----------------------------------------------------------
  defaults    = yamldecode(file("${var.config_dir}/defaults.yaml")).defaults
  profiles    = yamldecode(file("${var.config_dir}/profiles.yaml")).profiles
  fip_entries = yamldecode(file("${var.config_dir}/floating_ip.yaml")).floating_ips
  server_cfg  = yamldecode(file("${var.config_dir}/servers/${var.server_name}.yaml")).server

  # ---- Effective per-server settings (server file overrides defaults) -------
  # Precedence: ephemeral CI override (var.profile_override) > server file > defaults.
  profile_name = var.profile_override != "" ? var.profile_override : try(local.server_cfg.profile, local.defaults.profile)
  server_type  = local.profiles[local.profile_name].type

  region       = try(local.server_cfg.region, local.defaults.region)
  desktop_env  = try(local.server_cfg.desktop_env, local.defaults.desktop_env)
  ubuntu_image = local.defaults.ubuntu_image
  architecture = local.defaults.architecture
  username     = local.defaults.username

  # Architecture the selected profile requires. Optional per-profile `arch:`
  # (e.g. for a future ARM/cax* profile), defaulting to the global architecture.
  # Compared against the base image arch in snapshots.tf to catch a mismatch
  # before booting an unbootable server.
  profile_arch = try(local.profiles[local.profile_name].arch, local.architecture)

  allowed_ssh_cidrs = local.defaults.allowed_ssh_cidrs
  allowed_rdp_cidrs = local.defaults.allowed_rdp_cidrs

  # ---- Floating IP resolution ----------------------------------------------
  # A server may reference a named entry in floating_ip.yaml, or none.
  fip_ref     = try(local.server_cfg.floating_ip, null)
  fip_enabled = local.fip_ref != null
  fip_cfg     = local.fip_enabled ? local.fip_entries[local.fip_ref] : null
  # create = create-if-missing (managed by us); adopt = use a pre-existing IP.
  fip_mode = local.fip_enabled ? try(local.fip_cfg.mode, "create") : null

  # ---- Labels ---------------------------------------------------------------
  # `server=<name>` ties every resource (and snapshots) to this server so the
  # keep-2 prune and FIP lookups only ever touch this server's own resources.
  common_labels = {
    server  = var.server_name
    managed = "server-orchestrator"
  }

  # NOTE: the snapshot label selector (server=<name>,role=desktop-state) used by
  # listing/pruning lives in scripts/lib-config.sh (snapshot_label_selector), the
  # single source of truth for the scripts that actually query it. Terraform only
  # writes the labels (on the create_image call in destroy.sh), so no TF-side
  # selector local is kept here to avoid a third copy that can drift.
}
