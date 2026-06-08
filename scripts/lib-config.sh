#!/usr/bin/env bash
# Shared helpers: config reading, Hetzner API calls, and common setup.
# Sourced by create.sh and destroy.sh.
set -euo pipefail

# ---- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
TF_DIR="$ROOT_DIR/terraform"
ANSIBLE_DIR="$ROOT_DIR/ansible"

# shellcheck source=./notify-slack.sh
source "$SCRIPT_DIR/notify-slack.sh"

HCLOUD_API="https://api.hetzner.cloud/v1"

# ---- Preconditions ----------------------------------------------------------
require_env() {
  local missing=0
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      echo "error: required environment variable '$v' is not set" >&2
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

require_tools() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || { echo "error: '$t' not found on PATH" >&2; exit 1; }
  done
}

# ---- Terraform init + per-server state isolation ----------------------------
# Two modes, chosen by whether TF_STATE_BUCKET is set:
#
#   S3 backend (CI / shared): isolation via a distinct state KEY per server,
#     so each server has its own state object. Requires:
#       TF_STATE_BUCKET   bucket name
#       TF_STATE_ENDPOINT S3-compatible endpoint (e.g. https://<region>.your-objectstorage.com)
#       TF_STATE_REGION   region (default: auto)
#       AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   bucket credentials
#
#   Local backend (your laptop, no bucket): isolation via terraform workspaces
#     under terraform.tfstate.d/<server>/ — the original behavior.
#
# Call: tf_init <server>   (must be run from $TF_DIR)
tf_init() {
  local server="$1"
  local override="$TF_DIR/backend_override.tf"
  if [[ -n "${TF_STATE_BUCKET:-}" ]]; then
    require_env TF_STATE_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    # Generate an S3 backend keyed per-server (isolation via distinct key).
    cat > "$override" <<EOF
terraform {
  backend "s3" {
    bucket                      = "${TF_STATE_BUCKET}"
    key                         = "servers/${server}.tfstate"
    region                      = "${TF_STATE_REGION:-auto}"
    endpoints                   = { s3 = "${TF_STATE_ENDPOINT}" }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}
EOF
    terraform init -input=false -reconfigure >/dev/null
  else
    # No bucket: local backend + per-server workspace for isolation.
    rm -f "$override"
    terraform init -input=false -reconfigure >/dev/null
    terraform workspace select "$server" 2>/dev/null || terraform workspace new "$server"
  fi
}

# ---- Config reading (via python yaml; falls back to error if absent) --------
# yaml_get <file> <python-expr-on-`d`>   e.g. yaml_get defaults.yaml "d['defaults']['region']"
yaml_get() {
  local file="$1" expr="$2"
  python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))" \
    "$CONFIG_DIR/$file" "$expr"
}

# Assert the server file's `name:` field matches the filename (filename is
# authoritative). Missing `name:` is allowed (back-compat); a mismatch is fatal.
validate_server_name() {
  local server="$1"
  local declared
  declared="$(python3 -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))['server'].get('name',''))" \
    "$CONFIG_DIR/servers/$server.yaml")"
  if [[ -n "$declared" && "$declared" != "$server" ]]; then
    echo "error: config/servers/$server.yaml declares name: '$declared' but the filename is '$server'." >&2
    echo "       The filename is authoritative — fix the 'name:' field to '$server'." >&2
    exit 1
  fi
}

# Resolve a value from the server file, falling back to defaults.
# server_value <server> <key> <default-key-in-defaults>
server_value() {
  local server="$1" key="$2" default_key="$3"
  python3 - "$CONFIG_DIR" "$server" "$key" "$default_key" <<'PY'
import yaml, sys
cfgdir, server, key, dkey = sys.argv[1:5]
s = yaml.safe_load(open(f"{cfgdir}/servers/{server}.yaml"))["server"]
d = yaml.safe_load(open(f"{cfgdir}/defaults.yaml"))["defaults"]
val = s.get(key, d.get(dkey))
print("" if val is None else val)
PY
}

# ---- Hetzner API ------------------------------------------------------------
hapi() { # hapi <method> <path> [data]
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sf -X "$method" -H "Authorization: Bearer $HCLOUD_TOKEN" \
      -H "Content-Type: application/json" --data "$data" "$HCLOUD_API$path"
  else
    curl -sf -X "$method" -H "Authorization: Bearer $HCLOUD_TOKEN" "$HCLOUD_API$path"
  fi
}

# Newest available snapshot ID for a server, or empty.
latest_snapshot_id() {
  local server="$1"
  hapi GET "/images?type=snapshot&label_selector=server%3D${server}%2Crole%3Ddesktop-state&sort=created:desc" \
    | jq -r '.images | map(select(.status=="available")) | .[0].id // empty'
}

# Existing floating IP ID for a named entry (looked up by its fip-name label), or empty.
existing_fip_id() {
  local fip_name="$1"
  hapi GET "/floating_ips?label_selector=fip-name%3D${fip_name}" \
    | jq -r '.floating_ips[0].id // empty'
}
