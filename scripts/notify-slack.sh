#!/usr/bin/env bash
# Shared Slack helper for provisioning-lifecycle messages (posted from this
# CI/Terraform layer). fail2ban brute-force alerts are posted separately by the
# on-server action installed by Ansible — both go to the same webhook.
#
# Usage: notify_slack "<message>"
# No-op (and never fails the run) if SLACK_WEBHOOK_URL is unset/empty.
set -euo pipefail

notify_slack() {
  local message="$1"
  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    return 0
  fi
  curl -sf -X POST -H 'Content-type: application/json' \
    --data "$(printf '{"text":%s}' "$(json_escape "$message")")" \
    "$SLACK_WEBHOOK_URL" >/dev/null || echo "warn: Slack notify failed" >&2
}

# Minimal JSON string escaper (quotes the value, escapes \ and ").
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}
