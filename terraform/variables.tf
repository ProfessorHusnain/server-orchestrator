# Inputs to the reusable module. Most configuration is read from config/*.yaml
# (see locals.tf); these variables carry the per-run selection and the secrets
# that must NOT live in config (injected via TF_VAR_* env vars).

variable "server_name" {
  description = "Name of the server to act on. Must match a file config/servers/<server_name>.yaml. Also the unit of state isolation and snapshot labeling."
  type        = string
}

variable "hcloud_token" {
  description = "Hetzner Cloud API token. Provide via TF_VAR_hcloud_token (never commit)."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key contents injected into the server for Ansible access. Provide via TF_VAR_ssh_public_key."
  type        = string
}

variable "rdp_password" {
  description = "Password for the RDP/desktop login. Injected via TF_VAR_rdp_password (sourced from a GitHub variable at runtime). Used by cloud-init to set the user's password so RDP works on first boot; Ansible reconciles it too."
  type        = string
  sensitive   = true
}

variable "config_dir" {
  description = "Path to the config/ directory, relative to the Terraform working dir."
  type        = string
  default     = "../config"
}

variable "profile_override" {
  description = "Optional profile name (light/medium/fast/heavy/monster) that wins over the server's committed config for THIS run only. Empty = use the config. Set ephemerally by CI from the dispatch input; never committed."
  type        = string
  default     = ""
}
