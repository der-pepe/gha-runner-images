#!/usr/bin/env bash
# Create or destroy an ephemeral runner slot VM for the orchestrator.
#
# create: full-clone a golden template to the slot VMID, then take a "clean"
#         (unregistered) snapshot the orchestrator rolls back to each cycle.
# destroy: stop + purge the slot VM.
#
# Proxmox creds come from the shared gitignored env (../pve-status/pve.local.env):
#   PROXMOX_URL / PROXMOX_TOKEN_ID / PROXMOX_TOKEN   (+ optional PROXMOX_NODE, PROXMOX_STORAGE)
#
# Usage:
#   runner-slot.sh create <template_vmid> <slot_vmid> <name> [snapshot=clean]
#   runner-slot.sh destroy <slot_vmid>
#
# PROXMOX_NODE is where the template lives (the clone is issued there); set
# PROXMOX_TARGET_NODE to place the slot on a DIFFERENT node (Ceph makes the template
# cluster-wide, so a cross-node full clone is fine). Defaults to PROXMOX_NODE.
set -euo pipefail

_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_SD/../pve-status/pve.local.env" ] && source "$_SD/../pve-status/pve.local.env"
: "${PROXMOX_URL:?}"; : "${PROXMOX_TOKEN_ID:?}"; : "${PROXMOX_TOKEN:?}"
NODE="${PROXMOX_NODE:-pve1}"
TARGET="${PROXMOX_TARGET_NODE:-$NODE}"
STORAGE="${PROXMOX_STORAGE:-OsdPool}"
AUTH="Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN}"

api() { curl -fsS -k -H "$AUTH" "$@"; }

wait_task() {
  local upid="$1" tnode="${2:-$NODE}" body status
  [ -n "$upid" ] && [ "$upid" != "null" ] || return 0
  while true; do
    body="$(api "${PROXMOX_URL}/nodes/${tnode}/tasks/${upid}/status")" || return 1
    status="$(printf '%s' "$body" | jq -r '.data.status // empty')"
    if [ "$status" = "stopped" ]; then
      [ "$(printf '%s' "$body" | jq -r '.data.exitstatus // empty')" = "OK" ] && return 0
      return 1
    fi
    sleep 2
  done
}

wait_stopped() {
  local slot="$1"
  until [ "$(api "${PROXMOX_URL}/nodes/${NODE}/qemu/${slot}/status/current" | jq -r '.data.status')" = "stopped" ]; do
    sleep 2
  done
}

create() {
  local tmpl="$1" slot="$2" name="$3" snap="${4:-clean}" upid
  echo "Cloning template ${tmpl} (${NODE}) -> slot ${slot} (${name}) on ${TARGET}, full clone on ${STORAGE}"
  upid="$(api -X POST "${PROXMOX_URL}/nodes/${NODE}/qemu/${tmpl}/clone" \
    --data-urlencode "newid=${slot}" --data-urlencode "name=${name}" \
    --data-urlencode "full=1" --data-urlencode "storage=${STORAGE}" \
    --data-urlencode "target=${TARGET}" | jq -r '.data // empty')"
  wait_task "$upid" || { echo "clone failed" >&2; exit 1; }

  echo "Taking '${snap}' snapshot of ${slot} (clean, unregistered)"
  upid="$(api -X POST "${PROXMOX_URL}/nodes/${TARGET}/qemu/${slot}/snapshot" \
    --data-urlencode "snapname=${snap}" | jq -r '.data // empty')"
  wait_task "$upid" "$TARGET" || { echo "snapshot failed" >&2; exit 1; }
  echo "slot ${slot} ready (snapshot '${snap}') — orchestrator can cycle it."
}

destroy() {
  local slot="$1" upid
  api -X POST "${PROXMOX_URL}/nodes/${TARGET}/qemu/${slot}/status/stop" >/dev/null 2>&1 || true
  wait_stopped "$slot"
  upid="$(api -X DELETE "${PROXMOX_URL}/nodes/${TARGET}/qemu/${slot}?purge=1&destroy-unreferenced-disks=1" | jq -r '.data // empty')"
  wait_task "$upid" || true
  echo "slot ${slot} destroyed."
}

case "${1:-}" in
  create)  shift; create "$@" ;;
  destroy) shift; destroy "$@" ;;
  *) echo "usage: runner-slot.sh create <template_vmid> <slot_vmid> <name> [snapshot] | destroy <slot_vmid>" >&2; exit 2 ;;
esac
