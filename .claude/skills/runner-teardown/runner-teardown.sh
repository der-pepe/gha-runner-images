#!/usr/bin/env bash
# Tear down a runner: deregister it from the GitHub org, then stop + purge its VM.
#
# Creds from the shared gitignored env (../pve-status/pve.local.env):
#   PROXMOX_URL / PROXMOX_TOKEN_ID / PROXMOX_TOKEN   (+ optional PROXMOX_NODE)
#   GITHUB_TOKEN  (org PAT with runner admin)   GITHUB_OWNER (e.g. der-pepe)
# If the GitHub creds are absent, only the VM is destroyed (GitHub entry left to
# go offline).
#
# Usage:
#   runner-teardown.sh <slot_vmid> [runner_name]   # name defaults to the VM name
set -euo pipefail

_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_SD/../pve-status/pve.local.env" ] && source "$_SD/../pve-status/pve.local.env"
: "${PROXMOX_URL:?}"; : "${PROXMOX_TOKEN_ID:?}"; : "${PROXMOX_TOKEN:?}"
NODE="${PROXMOX_NODE:-pve1}"
AUTH="Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN}"
api() { curl -fsS -k -H "$AUTH" "$@"; }

slot="${1:?vmid required}"
rname="${2:-}"
[ -n "$rname" ] || rname="$(api "${PROXMOX_URL}/nodes/${NODE}/qemu/${slot}/config" | jq -r '.data.name // empty')"

# 1. Deregister from GitHub (best effort).
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_OWNER:-}" ] && [ -n "$rname" ]; then
  rid="$(curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners?per_page=100" \
    | jq -r --arg n "$rname" '.runners[] | select(.name==$n) | .id' | head -1)"
  if [ -n "$rid" ]; then
    curl -fsS -X DELETE -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/${rid}" >/dev/null \
      && echo "deregistered GitHub runner ${rname} (id ${rid})"
  else
    echo "no GitHub runner named '${rname}' (already gone?)"
  fi
else
  echo "GITHUB_TOKEN/GITHUB_OWNER not set — skipping GitHub deregister"
fi

# 2. Stop + destroy the VM.
api -X POST "${PROXMOX_URL}/nodes/${NODE}/qemu/${slot}/status/stop" >/dev/null 2>&1 || true
until [ "$(api "${PROXMOX_URL}/nodes/${NODE}/qemu/${slot}/status/current" | jq -r '.data.status')" = "stopped" ]; do
  sleep 2
done
api -X DELETE "${PROXMOX_URL}/nodes/${NODE}/qemu/${slot}?purge=1&destroy-unreferenced-disks=1" >/dev/null
echo "VM ${slot} (${rname}) destroyed."
