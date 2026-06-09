#!/usr/bin/env bash
# Create (or restore) a server: ./scripts/create.sh <server-name>
#
#   - selects a per-server Terraform workspace (isolated state)
#   - resolves the latest snapshot for the server -> warm boot, else cold start
#   - resolves the referenced floating IP (adopt existing / create new)
#   - terraform apply
#   - generates the Ansible inventory from outputs and runs the playbook
#   - posts Slack lifecycle messages
#
# Required env: HCLOUD_TOKEN, TF_VAR_ssh_public_key, TF_VAR_rdp_password,
#               SSH_PRIVATE_KEY_FILE (path to the matching private key)
# Optional env: SLACK_WEBHOOK_URL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-config.sh"

SERVER="${1:?usage: create.sh <server-name>}"
[[ -f "$CONFIG_DIR/servers/$SERVER.yaml" ]] || { echo "error: config/servers/$SERVER.yaml not found" >&2; exit 1; }
validate_server_name "$SERVER"

require_tools terraform ansible-playbook curl jq python3
require_env HCLOUD_TOKEN TF_VAR_ssh_public_key TF_VAR_rdp_password SSH_PRIVATE_KEY_FILE
# Terraform reads the token via TF_VAR_hcloud_token; mirror it from HCLOUD_TOKEN.
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"
export TF_VAR_server_name="$SERVER"

# ---- Git-over-SSH (per-server flag) -----------------------------------------
# If this server opts in (git_ssh: true), the git identity + SSH key must be
# present in the environment BEFORE we spend money on cloud resources, so fail
# fast here. The key is a GitHub secret; name/email are GitHub vars.
GIT_SSH="$(server_value "$SERVER" git_ssh git_ssh || true)"
if truthy "$GIT_SSH"; then
  echo ">> git over SSH is ENABLED for '$SERVER'"
  require_env GIT_USER_NAME GIT_USER_EMAIL GIT_SSH_PRIVATE_KEY
else
  echo ">> git over SSH is disabled for '$SERVER'"
fi

notify_slack ":hourglass_flowing_sand: *${SERVER}*: create started"

# ---- Resolve boot source (snapshot vs cold start) ---------------------------
echo ">> Looking up latest snapshot for '$SERVER'..."
# A transient API failure here must degrade to a cold start, not abort the run
# (pipefail would otherwise kill the script on a momentary 5xx). An empty result
# — whether "no snapshot" or "lookup failed" — means cold start.
SNAP_ID="$(latest_snapshot_id "$SERVER" || true)"
export TF_VAR_snapshot_image_id="${SNAP_ID:-}"
if [[ -n "$SNAP_ID" ]]; then
  echo ">> Warm boot from snapshot id=$SNAP_ID"
else
  echo ">> Cold start from base Ubuntu image"
fi

# ---- Resolve floating IP (adopt existing if present) ------------------------
FIP_REF="$(server_value "$SERVER" floating_ip floating_ip || true)"
export TF_VAR_existing_fip_id=""
if [[ -n "$FIP_REF" ]]; then
  FIP_NAME="$(yaml_get floating_ip.yaml floating_ips "$FIP_REF" name)"
  EXISTING_FIP="$(existing_fip_id "$FIP_NAME")"
  export TF_VAR_existing_fip_id="${EXISTING_FIP:-}"
  echo ">> Floating IP entry '$FIP_REF' (name=$FIP_NAME) existing_id='${EXISTING_FIP:-<none>}'"
fi

# ---- Terraform (per-server isolated state: S3 key or local workspace) -------
cd "$TF_DIR"
tf_init "$SERVER"
terraform apply -input=false -auto-approve

RDP_IP="$(terraform output -raw rdp_ip)"
USERNAME="$(terraform output -raw username)"
DESKTOP_ENV="$(terraform output -raw desktop_env)"
ARCHITECTURE="$(terraform output -raw architecture)"

# ---- Ansible inventory from outputs -----------------------------------------
mkdir -p "$ANSIBLE_DIR/inventory"
cat > "$ANSIBLE_DIR/inventory/hosts.ini" <<EOF
[desktop]
$RDP_IP ansible_user=$USERNAME ansible_ssh_private_key_file=$SSH_PRIVATE_KEY_FILE
EOF

echo ">> Waiting for SSH on $RDP_IP..."
SSH_READY=0
for i in $(seq 1 30); do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
       -i "$SSH_PRIVATE_KEY_FILE" "$USERNAME@$RDP_IP" true 2>/dev/null; then
    SSH_READY=1
    break
  fi
  sleep 10
done
if [[ "$SSH_READY" -ne 1 ]]; then
  echo "error: SSH on $RDP_IP never came up after 30 attempts (~5 min)" >&2
  notify_slack ":x: *${SERVER}*: SSH never reachable at \`${RDP_IP}\` — create aborted before Ansible"
  exit 1
fi

# ---- Configure with Ansible -------------------------------------------------
# The git SSH private key is passed via the ENVIRONMENT (read by the git role
# with lookup('env',...)), never on the command line, so it doesn't leak into
# the process list or `ps` output. Name/email/flag are non-secret -> -e is fine.
cd "$ANSIBLE_DIR"
GIT_SSH_PRIVATE_KEY="${GIT_SSH_PRIVATE_KEY:-}" \
ansible-playbook playbook.yml \
  -e "desktop_env=$DESKTOP_ENV" \
  -e "rdp_username=$USERNAME" \
  -e "rdp_password=$TF_VAR_rdp_password" \
  -e "server_name=$SERVER" \
  -e "architecture=$ARCHITECTURE" \
  -e "git_ssh=$GIT_SSH" \
  -e "git_user_name=${GIT_USER_NAME:-}" \
  -e "git_user_email=${GIT_USER_EMAIL:-}" \
  -e "slack_webhook_url=${SLACK_WEBHOOK_URL:-}"

echo ">> Done. RDP to $RDP_IP:3389 as '$USERNAME'."
notify_slack ":white_check_mark: *${SERVER}*: ready — RDP to \`${RDP_IP}:3389\` as \`${USERNAME}\` (${DESKTOP_ENV})"
