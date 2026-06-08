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

  # Architecture guard: the profile's required arch must match the image arch we
  # boot from. Trips before provisioning if e.g. an ARM (cax*) profile is paired
  # with an x86 image, instead of booting an unbootable server with a cryptic error.
  lifecycle {
    postcondition {
      condition     = self.architecture == local.profile_arch
      error_message = "Architecture mismatch: profile '${local.profile_name}' requires '${local.profile_arch}' but base image '${local.ubuntu_image}' is '${self.architecture}'. Set the profile's arch or the image to match."
    }
  }
}

locals {
  boot_image_id = var.snapshot_image_id != "" ? var.snapshot_image_id : data.hcloud_image.base[0].id
}
