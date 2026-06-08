# Outputs consumed by the wrapper scripts (Ansible inventory, Slack messages).

output "server_id" {
  description = "Numeric ID of the server (used by destroy.sh to create the snapshot)."
  value       = hcloud_server.this.id
}

output "server_name" {
  description = "Server name."
  value       = hcloud_server.this.name
}

output "ephemeral_ip" {
  description = "The server's own public IPv4 address."
  value       = hcloud_server.this.ipv4_address
}

output "floating_ip" {
  description = "The attached floating IP address, or null if none is used."
  value       = local.fip_address
}

# The address Ansible/RDP should target: floating IP when present, else the
# server's ephemeral public IP.
output "rdp_ip" {
  description = "Address to use for SSH (Ansible) and RDP."
  value       = local.fip_address != null ? local.fip_address : hcloud_server.this.ipv4_address
}

output "username" {
  description = "Login username for SSH and RDP."
  value       = local.username
}

output "desktop_env" {
  description = "Desktop environment Ansible should configure."
  value       = local.desktop_env
}
