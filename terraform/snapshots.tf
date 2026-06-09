# Boot-source selection: latest snapshot for this server, else base Ubuntu.
#
# WHY a variable instead of a data source: the hcloud_image data source errors
# when no image matches, which is exactly the cold-start case (no snapshot yet).
# So the wrapper script (scripts/create.sh) queries the newest snapshot ID for
# this server up front and passes it in via TF_VAR_snapshot_image_id:
#   - non-empty -> warm boot from that snapshot
#   - empty     -> cold start; look up the pinned base Ubuntu image
# This keeps the plan deterministic and avoids data-source-on-empty failures.

variable "snapshot_image_id" {
  description = "Numeric ID of the latest snapshot for this server, or empty string for cold start. Set by scripts/create.sh via TF_VAR_snapshot_image_id."
  type        = string
  default     = ""
}

# Base Ubuntu image, looked up only on cold start (no snapshot id provided).
data "hcloud_image" "base" {
  count             = var.snapshot_image_id == "" ? 1 : 0
  name              = local.ubuntu_image
  with_architecture = local.architecture
}

# Warm-boot snapshot, looked up by id only when one is provided. Used solely to
# read its architecture for the guard below; the actual boot uses the id directly.
data "hcloud_image" "snapshot" {
  count = var.snapshot_image_id != "" ? 1 : 0
  id    = var.snapshot_image_id
}

locals {
  boot_image_id = var.snapshot_image_id != "" ? var.snapshot_image_id : data.hcloud_image.base[0].id

  # Architecture of whichever image we are about to boot from — base on cold
  # start, snapshot on warm boot. Single value the guard (server precondition in
  # main.tf) checks on BOTH paths so a mismatch trips before provisioning.
  boot_image_arch = var.snapshot_image_id != "" ? data.hcloud_image.snapshot[0].architecture : data.hcloud_image.base[0].architecture

  boot_image_desc = var.snapshot_image_id != "" ? "snapshot id ${var.snapshot_image_id}" : "base image '${local.ubuntu_image}'"
}
