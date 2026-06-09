terraform {
  required_version = ">= 1.5.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }

  # NOTE: the backend is intentionally NOT declared here. scripts/lib-config.sh
  # (tf_init) generates terraform/backend_override.tf at init time, choosing:
  #   - an S3-compatible backend (CI / shared) when TF_STATE_BUCKET is set, with
  #     a per-server state key for isolation, or
  #   - the local backend + per-server workspaces (laptop, no bucket).
  # This keeps the same code working in both environments without committing any
  # backend credentials. backend_override.tf is gitignored.
}

provider "hcloud" {
  token = var.hcloud_token
}

# SSH key registered with Hetzner so cloud-init can authorize Ansible access.
# Named per-server to avoid collisions across servers sharing one project.
resource "hcloud_ssh_key" "this" {
  name       = "orchestrator-${var.server_name}"
  public_key = var.ssh_public_key
  labels     = local.common_labels
}

# Minimal cloud-init: ensure the login user exists with the SSH key and the
# RDP password, and that python3 is present so Ansible always has a foothold.
# Runs on BOTH cold-start (base Ubuntu) and warm boots (from snapshot); it is
# idempotent, so re-applying the user/password on a snapshot boot is harmless.
locals {
  cloud_init = templatefile("${path.module}/cloud-init.yaml", {
    username     = local.username
    rdp_password = var.rdp_password
    ssh_key      = var.ssh_public_key
  })
}

resource "hcloud_server" "this" {
  name        = var.server_name
  server_type = local.server_type
  location    = local.region

  # Boot source is decided in snapshots.tf: the latest snapshot for this server
  # if one exists, otherwise the pinned base Ubuntu image (cold start).
  image = local.boot_image_id

  ssh_keys  = [hcloud_ssh_key.this.id]
  user_data = local.cloud_init
  labels    = local.common_labels

  # ssh_keys cannot change after creation without a rebuild; that's fine here
  # because state lives in snapshots, not on the live disk identity.
  lifecycle {
    ignore_changes = [ssh_keys, image]

    # Architecture guard, evaluated on BOTH cold start and warm (snapshot) boot:
    # the profile's required arch must match the arch of the image we boot from.
    # Trips before provisioning if e.g. an ARM (cax*) profile is paired with an
    # x86 image/snapshot, instead of booting an unbootable server. (A data-source
    # postcondition would only cover the cold-start path; this covers both because
    # the server resource exists in every plan.)
    precondition {
      condition     = local.boot_image_arch == local.profile_arch
      error_message = "Architecture mismatch: profile '${local.profile_name}' requires '${local.profile_arch}' but ${local.boot_image_desc} is '${local.boot_image_arch}'. Set the profile's arch or the image/snapshot to match."
    }
  }
}
