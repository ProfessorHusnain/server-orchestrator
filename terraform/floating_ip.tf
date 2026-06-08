# Dynamic floating IP.
#
# A server may reference a named entry in config/floating_ip.yaml (local.fip_ref).
# The entry's mode decides behavior:
#   adopt  -> use a pre-existing Hetzner floating IP (looked up by name).
#   create -> create-if-missing: reuse the IP if it already exists (looked up by
#             its fip-name label), otherwise create it.
#
# As with snapshots, "create-if-missing" can't be expressed with a bare data
# source (it errors when absent), so scripts/create.sh resolves the existing
# floating IP id up front and passes it in via TF_VAR_existing_fip_id:
#   - non-empty -> adopt that IP (assignment only; we don't manage its lifecycle)
#   - empty + mode=create -> create a new managed floating IP
#   - empty + mode=adopt  -> error (the IP the user asked to adopt is missing)
#
# Lifecycle: the IP is NEVER deleted on destroy. Created IPs carry a label and
# survive teardown; detach happens in scripts/destroy.sh before the server is
# removed, so the stable RDP target persists across cycles.

variable "existing_fip_id" {
  description = "Numeric ID of an already-existing floating IP for this server's referenced entry, or empty string. Set by scripts/create.sh."
  type        = string
  default     = ""
}

# Adopt path: an existing floating IP (by id, resolved by the wrapper).
data "hcloud_floating_ip" "adopted" {
  count = local.fip_enabled && var.existing_fip_id != "" ? 1 : 0
  id    = var.existing_fip_id
}

# Create path: a new managed floating IP, only when one doesn't already exist
# and the entry's mode is create.
resource "hcloud_floating_ip" "created" {
  count         = local.fip_enabled && var.existing_fip_id == "" && local.fip_mode == "create" ? 1 : 0
  type          = try(local.fip_cfg.type, "ipv4")
  name          = local.fip_cfg.name
  home_location = try(local.fip_cfg.home_location, local.region)
  description   = "Orchestrator floating IP (entry ${local.fip_ref})"
  labels = merge(local.common_labels, {
    "fip-name" = local.fip_cfg.name
    "role"     = "floating-ip"
  })

  # Belt-and-suspenders: the floating IP must survive teardowns. destroy.sh
  # already removes it from state before `terraform destroy`, but this blocks an
  # accidental destroy of the stable IP (and anything pointed at it) outright.
  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # Resolve the active floating IP ONCE (adopted IP, freshly created IP, or none),
  # then project id/address from it so the selection logic isn't duplicated.
  fip_source = !local.fip_enabled ? null : (
    var.existing_fip_id != "" ? data.hcloud_floating_ip.adopted[0] : (
      length(hcloud_floating_ip.created) > 0 ? hcloud_floating_ip.created[0] : null
    )
  )

  fip_id      = local.fip_source != null ? local.fip_source.id : null
  fip_address = local.fip_source != null ? local.fip_source.ip_address : null
}

# Attach the resolved floating IP to this server. Using a separate assignment
# resource (rather than server_id on the IP) so adopting a shared IP cleanly
# reassigns it from whatever server held it last.
resource "hcloud_floating_ip_assignment" "this" {
  count          = local.fip_id != null ? 1 : 0
  floating_ip_id = local.fip_id
  server_id      = hcloud_server.this.id
}
