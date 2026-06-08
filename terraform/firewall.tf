# Firewall: allow only SSH (22, for Ansible) and RDP (3389, for the desktop).
# Everything else inbound is dropped by default. Source CIDRs come from config
# so RDP can be restricted to known IPs (defaults to anywhere).
resource "hcloud_firewall" "this" {
  name   = "orchestrator-${var.server_name}"
  labels = local.common_labels

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = local.allowed_ssh_cidrs
    description = "SSH (Ansible)"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "3389"
    source_ips  = local.allowed_rdp_cidrs
    description = "RDP (desktop)"
  }

  # Allow ICMP (ping) for basic reachability checks.
  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP (ping)"
  }

  apply_to {
    server = hcloud_server.this.id
  }
}
