#!/usr/bin/env bash
# Safely tear down a server: ./scripts/destroy.sh <server-name>
#
# Order is critical (never destroy before the snapshot is confirmed):
#   1. create a snapshot of the running server (labeled server=<name>)
#   2. VERIFY the snapshot reached status=available  (abort + alert on failure)
#   3. prune this server's snapshots, keeping the newest N (config: snapshot_retention)
#   4. detach the floating IP (NEVER delete it — it must survive teardown)
#   5. terraform destroy the server
#
# Required env: HCLOUD_TOKEN, TF_VAR_ssh_public_key, TF_VAR_rdp_password
# Optional env: SLACK_WEBHOOK_URL
#               FLOATING_IP_MODE  ephemeral (default) | from-config
#                 Must match the value used in the corresponding create run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-config.sh"

SERVER="${1:?usage: destroy.sh <server-name>}"
[[ -f "$CONFIG_DIR/servers/$SERVER.yaml" ]] || { echo "error: config/servers/$SERVER.yaml not found" >&2; exit 1; }
validate_server_name "$SERVER"

require_tools terraform curl jq python3
require_env HCLOUD_TOKEN TF_VAR_ssh_public_key TF_VAR_rdp_password
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"
export TF_VAR_server_name="$SERVER"
export TF_VAR_rdp_username="${RDP_USERNAME:-orchestrator}"
export TF_VAR_floating_ip_mode="${FLOATING_IP_MODE:-ephemeral}"
export TF_VAR_region_override="${TF_VAR_region_override:-}"

RETENTION="$(yaml_get defaults.yaml defaults snapshot_retention)"
# Guard the prune slice: retention MUST be an integer >= 1. A 0/empty/non-numeric
# value would make `.[$keep:]` select every available snapshot (including the one
# we are about to create) and delete the very backup this flow exists to protect.
if ! [[ "$RETENTION" =~ ^[0-9]+$ ]] || [[ "$RETENTION" -lt 1 ]]; then
  echo "error: snapshot_retention must be an integer >= 1 (got '$RETENTION')" >&2
  exit 1
fi

cd "$TF_DIR"
tf_init "$SERVER"
# server_id is absent if state is empty (e.g. a re-run after a completed destroy).
# `terraform output -raw` errors on a missing output; treat that as "nothing to
# tear down" and exit cleanly rather than aborting with a raw terraform error.
SERVER_ID="$(terraform output -raw server_id 2>/dev/null || true)"
if [[ -z "$SERVER_ID" || "$SERVER_ID" == "null" ]]; then
  echo ">> No server in state for '$SERVER' (already destroyed?). Nothing to do."
  notify_slack ":information_source: *${SERVER}*: no server in state — already destroyed, nothing to do"
  exit 0
fi

notify_slack ":camera_with_flash: *${SERVER}*: snapshotting before destroy"

# ---- 1. Create snapshot -----------------------------------------------------
echo ">> Creating snapshot of server id=$SERVER_ID..."
TS="$(date -u +%Y%m%d-%H%M%S)"
CREATE_RESP="$(hapi POST "/servers/$SERVER_ID/actions/create_image" \
  "$(jq -cn --arg server "$SERVER" --arg ts "$TS" \
    '{type:"snapshot",description:($server+"-"+$ts),labels:{server:$server,"role":"desktop-state"}}')")"
SNAP_ID="$(echo "$CREATE_RESP" | jq -r '.image.id')"
ACTION_ID="$(echo "$CREATE_RESP" | jq -r '.action.id')"
[[ "$SNAP_ID" != "null" && -n "$SNAP_ID" ]] || { echo "error: snapshot create failed"; notify_slack ":x: *${SERVER}*: snapshot creation FAILED — destroy aborted"; exit 1; }

# ---- 2. Verify snapshot became available ------------------------------------
# The create_image action is the authoritative completion signal (poll it, not
# the image row, which can flip to "available" before the action finishes).
# Require the action to reach success AND the image to read available before we
# ever destroy the server. Anything else — error, or timeout — aborts.
echo ">> Waiting for snapshot id=$SNAP_ID to become available..."
VERIFIED=0
for i in $(seq 1 120); do
  # A transient API blip during polling must not abort the whole destroy; an
  # empty read just means "not ready yet" and we keep waiting.
  ACT_STATUS="$(hapi GET "/actions/$ACTION_ID" 2>/dev/null | jq -r '.action.status' 2>/dev/null || true)"
  if [[ "$ACT_STATUS" == "success" ]]; then
    STATUS="$(hapi GET "/images/$SNAP_ID" 2>/dev/null | jq -r '.image.status' 2>/dev/null || true)"
    if [[ "$STATUS" == "available" ]]; then
      echo ">> Snapshot available."
      VERIFIED=1
      break
    fi
  fi
  if [[ "$ACT_STATUS" == "error" ]]; then
    echo "error: snapshot action failed"; notify_slack ":x: *${SERVER}*: snapshot action errored — destroy aborted"; exit 1
  fi
  sleep 10
done
if [[ "$VERIFIED" -ne 1 ]]; then
  echo "error: snapshot never reached action=success + image=available (last action=$ACT_STATUS)" >&2
  notify_slack ":x: *${SERVER}*: snapshot never became available — destroy aborted"
  exit 1
fi
notify_slack ":floppy_disk: *${SERVER}*: snapshot \`${SNAP_ID}\` created & verified"

# ---- 2b. Tag new snapshot as latest, untag previous ------------------------
# Strip latest=true from any existing snapshot for this server first, then
# apply it to the new one. Analogous to Docker's :latest tag — always points
# to the most recent verified snapshot for this server.
PRUNE_SEL_TAG="$(urlencode "$(snapshot_label_selector "$SERVER")")"
PREV_LATEST_IDS="$(hapi GET "/images?type=snapshot&label_selector=${PRUNE_SEL_TAG}%2Clatest%3Dtrue" \
  | jq -r '.images[].id')"
for id in $PREV_LATEST_IDS; do
  hapi PUT "/images/$id" \
    "$(jq -cn --arg server "$SERVER" \
      '{"labels":{"server":$server,"role":"desktop-state","latest":"false"}}')" >/dev/null
done
hapi PUT "/images/$SNAP_ID" \
  "$(jq -cn --arg server "$SERVER" \
    '{"labels":{"server":$server,"role":"desktop-state","latest":"true"}}')" >/dev/null
echo ">> Tagged snapshot $SNAP_ID as latest."

# ---- 3. Prune snapshots, keep newest RETENTION -----------------------------
# The just-created snapshot ($SNAP_ID) is excluded by ID before the retention
# slice, so a sub-second API clock skew can never cause it to be deleted here.
echo ">> Pruning snapshots for '$SERVER', keeping newest $RETENTION..."
PRUNE_SEL="$(urlencode "$(snapshot_label_selector "$SERVER")")"
OLD_IDS="$(hapi GET "/images?type=snapshot&label_selector=${PRUNE_SEL}&sort=created:desc" \
  | jq -r --argjson keep "$RETENTION" --argjson new_id "$SNAP_ID" \
    '.images | map(select(.status=="available" and .id != $new_id)) | .[$keep:] | .[].id')"
for id in $OLD_IDS; do
  echo "   deleting old snapshot id=$id"
  hapi DELETE "/images/$id" >/dev/null
done

# ---- 4. Detach floating IP (do NOT delete) ----------------------------------
# Only attempt if this run used a floating IP (FLOATING_IP_MODE=from-config).
# If the server was created in ephemeral mode there is no FIP in state.
if [[ "${FLOATING_IP_MODE:-ephemeral}" == "from-config" ]]; then
  FIP_REF="$(server_value "$SERVER" floating_ip floating_ip || true)"
  if [[ -n "$FIP_REF" ]]; then
    FIP_NAME="$(yaml_get floating_ip.yaml floating_ips "$FIP_REF" name)"
    FIP_ID="$(existing_fip_id "$FIP_NAME")"
    if [[ -n "$FIP_ID" ]]; then
      echo ">> Detaching floating IP id=$FIP_ID (kept, not deleted)..."
      # Remove the assignment from Terraform state first so destroy won't try to
      # reconcile it, then unassign via API so the IP persists independently.
      terraform state rm 'hcloud_floating_ip_assignment.this[0]' 2>/dev/null || true
      hapi POST "/floating_ips/$FIP_ID/actions/unassign" >/dev/null || true
    fi
  fi
else
  echo ">> Floating IP mode=ephemeral — no FIP to detach"
fi

# ---- 5. Destroy the server ---------------------------------------------------
# Keep the floating IP resource out of destroy (it must survive). The assignment
# is already removed from state; the created FIP (if any) is removed from state
# too so terraform destroy only tears down the server, ssh key and firewall.
terraform state rm 'hcloud_floating_ip.created[0]' 2>/dev/null || true
terraform state rm 'data.hcloud_floating_ip.adopted[0]' 2>/dev/null || true

echo ">> Destroying server '$SERVER'..."
terraform destroy -input=false -auto-approve

notify_slack ":wastebasket: *${SERVER}*: destroyed (snapshot \`${SNAP_ID}\` retained; floating IP kept)"
echo ">> Done."
