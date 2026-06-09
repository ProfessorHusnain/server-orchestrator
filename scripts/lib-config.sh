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
    # Guard: bucket, endpoint, region, and server name are interpolated directly
    # into an HCL string literal. A '"' or '\' in any value would break the
    # generated .tf file. Restrict to a safe charset before writing.
    local _safe='^[a-zA-Z0-9_./:@-]+$'
    [[ "${TF_STATE_BUCKET}"           =~ $_safe ]] || { echo "error: TF_STATE_BUCKET contains characters unsafe for HCL ('\"', '\\', spaces etc.)" >&2; exit 1; }
    [[ "${TF_STATE_ENDPOINT}"         =~ $_safe ]] || { echo "error: TF_STATE_ENDPOINT contains characters unsafe for HCL" >&2; exit 1; }
    [[ "${TF_STATE_REGION:-auto}"     =~ $_safe ]] || { echo "error: TF_STATE_REGION contains characters unsafe for HCL" >&2; exit 1; }
    [[ "$server"                      =~ $_safe ]] || { echo "error: server name '$server' contains characters unsafe for HCL" >&2; exit 1; }
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
# yaml_get <file> <key> [<key> ...]
#   Traverses the nested mapping by the given keys and prints the value.
#   Keys are passed as data (argv), never eval'd, so arbitrary config values
#   (including ones with quotes) can't inject code or break parsing.
#   e.g. yaml_get defaults.yaml defaults region
#        yaml_get floating_ip.yaml floating_ips "$FIP_REF" name
yaml_get() {
  local file="$1"; shift
  python3 - "$CONFIG_DIR/$file" "$@" <<'PY'
import yaml, sys
path = sys.argv[1]
keys = sys.argv[2:]
d = yaml.safe_load(open(path))
cur = d
for k in keys:
    try:
        cur = cur[k]
    except (KeyError, TypeError, IndexError):
        sys.stderr.write(
            f"error: {path}: no value at key path {' -> '.join(keys)} "
            f"(missing '{k}')\n")
        sys.exit(1)
print("" if cur is None else cur)
PY
}

# Assert the server file's `name:` field matches the filename (filename is
# authoritative). Missing `name:` is allowed (back-compat); a mismatch is fatal.
# A missing or empty `server:` block is also tolerated here (treated as no
# declared name); other consumers that genuinely need the block error on their own.
validate_server_name() {
  local server="$1"
  local declared
  declared="$(python3 - "$CONFIG_DIR/servers/$server.yaml" <<'PY'
import yaml, sys
doc = yaml.safe_load(open(sys.argv[1])) or {}
srv = doc.get("server") or {}
print(srv.get("name", "") if isinstance(srv, dict) else "")
PY
)"
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
s = (yaml.safe_load(open(f"{cfgdir}/servers/{server}.yaml")) or {}).get("server") or {}
d = (yaml.safe_load(open(f"{cfgdir}/defaults.yaml")) or {}).get("defaults") or {}
val = s.get(key, d.get(dkey)) if isinstance(s, dict) else d.get(dkey)
print("" if val is None else val)
PY
}

# True if the argument is a truthy flag value. server_value renders a YAML
# boolean via Python's str() (True/False), so accept those alongside the usual
# yes/on/1 spellings. Anything else (incl. empty / False) is false.
truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|on|1) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- Hetzner API ------------------------------------------------------------
# URL-encode a string for safe use in a query value (e.g. a label value that
# may contain spaces or selector metacharacters like , = & ).
urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

hapi() { # hapi <method> <path> [data]
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sf -X "$method" -H "Authorization: Bearer $HCLOUD_TOKEN" \
      -H "Content-Type: application/json" --data "$data" "$HCLOUD_API$path"
  else
    curl -sf -X "$method" -H "Authorization: Bearer $HCLOUD_TOKEN" "$HCLOUD_API$path"
  fi
}

# Snapshot label selector (single source of truth for create/list/prune).
# server=<name>,role=desktop-state — ties snapshots to one server.
snapshot_label_selector() {
  local server="$1"
  printf 'server=%s,role=desktop-state' "$server"
}

# Newest available snapshot ID for a server, or empty.
latest_snapshot_id() {
  local server="$1"
  local sel; sel="$(urlencode "$(snapshot_label_selector "$server")")"
  hapi GET "/images?type=snapshot&label_selector=${sel}&sort=created:desc" \
    | jq -r '.images | map(select(.status=="available")) | .[0].id // empty'
}

# Existing floating IP ID for a named entry (looked up by its fip-name label), or empty.
existing_fip_id() {
  local fip_name="$1"
  local sel; sel="$(urlencode "fip-name=${fip_name}")"
  hapi GET "/floating_ips?label_selector=${sel}" \
    | jq -r '.floating_ips[0].id // empty'
}
