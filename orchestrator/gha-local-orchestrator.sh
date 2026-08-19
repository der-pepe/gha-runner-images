#!/usr/bin/env bash
# Skeleton local runner orchestrator for one Proxmox node (bash port).
#
# Intended to run from gha-orch01/02/03 as a systemd timer. Each instance manages
# only the runner VMs on its own Proxmox node.
#
# This is a SCAFFOLD, not production-ready code. Fill in the Proxmox status,
# rollback/reclone, and bootstrap-injection pieces to match your actual
# Proxmox/storage/networking workflow. The token-request and slot-iteration logic
# is real; the reset strategy is left as TODO on purpose.
#
# Dependencies (intentionally minimal — keep the orchestrator LXC lean):
#   bash, curl, jq        (no PowerShell, no YAML parser)
#
# Secrets come from the environment (systemd EnvironmentFile), never the config:
#   PROXMOX_TOKEN_ID, PROXMOX_TOKEN, GITHUB_TOKEN
#
# Usage:
#   gha-local-orchestrator.sh [config-file]
# Default config: ./node.local.env (next to this script).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/node.local.env}"

# --- Preconditions -----------------------------------------------------------
: "${PROXMOX_TOKEN_ID:?Set PROXMOX_TOKEN_ID}"
: "${PROXMOX_TOKEN:?Set PROXMOX_TOKEN}"
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN}"
command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq not found" >&2; exit 1; }
[ -f "$CONFIG_FILE" ] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }

# Flat, shell-sourceable config (SLOT_COUNT + indexed SLOT_<n>_* vars).
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${PROXMOX_URL:?Set PROXMOX_URL in config}"
: "${PROXMOX_NODE:?Set PROXMOX_NODE in config}"
: "${SLOT_COUNT:?Set SLOT_COUNT in config}"

PVE_AUTH="Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN}"

# This orchestrator LXC's LAN address, injected into the runner env so a finished runner
# can poke the trigger socket for an immediate reset (see gha-orch-trigger.socket). Falls
# back to empty -> the runner just shuts down and the 15s timer picks it up.
ORCH_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
ORCH_TRIGGER_URL="http://${ORCH_IP}:9099/"

# --- GitHub: generate a JIT (just-in-time) runner config ----------------------
# Returns the base64 encoded_jit_config. The runner runs `run.sh --jitconfig <blob>`
# directly — no config.sh, no registration token on disk, inherently single-use +
# ephemeral. The PAT (GITHUB_TOKEN) stays here; the runner only ever sees the one-shot
# encoded config.
generate_jitconfig() {
  local owner="$1" repo="$2" scope="$3" name="$4" labels_csv="$5" uri labels_json body
  if [ "$scope" = "org" ]; then
    uri="https://api.github.com/orgs/${owner}/actions/runners/generate-jitconfig"
  else
    uri="https://api.github.com/repos/${owner}/${repo}/actions/runners/generate-jitconfig"
  fi
  labels_json="$(printf '%s' "$labels_csv" | jq -R 'split(",")')"
  body="$(jq -n --arg name "$name" --argjson labels "$labels_json" \
    '{name:$name, runner_group_id:1, labels:$labels, work_folder:"_work"}')"
  curl -fsS -X POST "$uri" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$body" \
  | jq -r '.encoded_jit_config // empty'
}

# Remove any existing runner registration with this name. A prior JIT config that never
# connected (VM died mid-cycle) lingers as an offline runner and makes generate-jitconfig
# fail with 409 on the same name. Best-effort.
delete_runner_by_name() {
  local name="$1" base id
  if [ "$REGISTRATION_SCOPE" = "org" ]; then
    base="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners"
  else
    base="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners"
  fi
  id="$(curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "${base}?per_page=100" 2>/dev/null | jq -r --arg n "$name" 'first(.runners[]|select(.name==$n)|.id) // empty')"
  if [ -n "$id" ]; then
    curl -fsS -X DELETE -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
      "${base}/${id}" >/dev/null 2>&1 || true
  fi
}

# --- Proxmox: current status of a VM -----------------------------------------
get_proxmox_vm_state() {
  local vmid="$1"
  curl -fsS -k \
    -H "$PVE_AUTH" \
    "${PROXMOX_URL}/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/current" \
  | jq -r '.data.status'
}

# --- Proxmox helpers ---------------------------------------------------------
# POST to a Proxmox API path; echo the raw JSON response.
pve_post() {
  local path="$1"; shift
  curl -fsS -k -H "$PVE_AUTH" -X POST "${PROXMOX_URL}${path}" "$@"
}

# Wait for a Proxmox task (UPID) to finish successfully.
# A task that only emitted warnings reports exitstatus "WARNINGS: <n>", not "OK" — that is
# still success. Windows vmstate rollbacks routinely warn (e.g. "netdev net0: using
# 'host_mtu=1500' for migration compat"), so treating warnings as failure would fail every
# reset on a healthy slot.
wait_for_task() {
  local upid="$1" tries=120 body status exitstatus
  [ -n "$upid" ] && [ "$upid" != "null" ] || return 0
  while [ "$tries" -gt 0 ]; do
    body="$(curl -fsS -k -H "$PVE_AUTH" "${PROXMOX_URL}/nodes/${PROXMOX_NODE}/tasks/${upid}/status" 2>/dev/null)" || true
    status="$(printf '%s' "$body" | jq -r '.data.status // empty')"
    if [ "$status" = "stopped" ]; then
      exitstatus="$(printf '%s' "$body" | jq -r '.data.exitstatus // empty')"
      case "$exitstatus" in
        OK|WARNINGS:*) return 0 ;;
      esac
      echo "task ${upid} did not exit OK (exitstatus: ${exitstatus:-unknown})" >&2; return 1
    fi
    sleep 2; tries=$((tries - 1))
  done
  echo "task ${upid} timed out" >&2; return 1
}

# Wait for the QEMU guest agent to respond.
wait_for_agent() {
  local vmid="$1" tries=120
  while [ "$tries" -gt 0 ]; do
    if curl -fsS -k -H "$PVE_AUTH" -X POST \
         "${PROXMOX_URL}/nodes/${PROXMOX_NODE}/qemu/${vmid}/agent/ping" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2; tries=$((tries - 1))
  done
  echo "guest agent on ${vmid} not responding" >&2; return 1
}

# Write a file into the guest via the agent (used to inject the runner env).
pve_agent_write_file() {
  local vmid="$1" path="$2" content="$3"
  curl -fsS -k -H "$PVE_AUTH" -X POST \
    --data-urlencode "file=${path}" \
    --data-urlencode "content=${content}" \
    "${PROXMOX_URL}/nodes/${PROXMOX_NODE}/qemu/${vmid}/agent/file-write" >/dev/null
}

# --- Reset one runner slot (snapshot-rollback + JIT config injection) ----------
# Rolls the slot VM back to its clean snapshot, starts it, generates a JIT runner
# config, and writes it into the guest via the agent. A waiter baked into the image
# runs `run.sh --jitconfig <blob>` — one job, then shuts down. The PAT stays here.
reset_runner_slot() {
  local idx="$1"
  local name vmid snapshot os labels upid jitconfig env_path env_content
  eval "name=\${SLOT_${idx}_NAME}"
  eval "vmid=\${SLOT_${idx}_VMID}"
  eval "snapshot=\${SLOT_${idx}_CLEAN_SNAPSHOT:-clean}"
  eval "os=\${SLOT_${idx}_OS}"
  eval "labels=\${SLOT_${idx}_LABELS}"

  echo "Resetting ${name} (vmid ${vmid}): rollback -> '${snapshot}'"

  # 1. Roll back to the clean snapshot.
  upid="$(pve_post "/nodes/${PROXMOX_NODE}/qemu/${vmid}/snapshot/${snapshot}/rollback" | jq -r '.data // empty')"
  wait_for_task "$upid" || { echo "ERR ${name}: rollback failed" >&2; return 1; }

  # 2. A vmstate (RAM) snapshot resumes the VM to 'running' ASYNCHRONOUSLY after the
  #    rollback task returns — restoring a live, agent-up, waiter-polling VM in seconds
  #    and skipping the ~60-90s cold boot. Wait briefly for that; if it stays stopped
  #    (off-state snapshot), start it explicitly. (Calling start on an already-running
  #    VM returns 409 and would abort the run.)
  running=""
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$(get_proxmox_vm_state "$vmid" 2>/dev/null)" = "running" ] && { running=1; break; }
    sleep 1
  done
  if [ -z "$running" ]; then
    upid="$(pve_post "/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/start" | jq -r '.data // empty')"
    wait_for_task "$upid" || { echo "ERR ${name}: start failed" >&2; return 1; }
  fi

  # 3. Wait for the guest agent (near-instant after a vmstate restore).
  wait_for_agent "$vmid" || { echo "ERR ${name}: agent not up" >&2; return 1; }

  # 4. Clear any stale same-name runner (else generate-jitconfig 409s), then generate a
  #    fresh JIT config (orchestrator holds the PAT; the runner never sees it).
  delete_runner_by_name "$name"
  jitconfig="$(generate_jitconfig "$GITHUB_OWNER" "$GITHUB_REPO" "$REGISTRATION_SCOPE" "$name" "$labels" || true)"
  if [ -z "$jitconfig" ] || [ "$jitconfig" = "null" ]; then
    echo "ERR ${name}: jitconfig generation failed" >&2; return 1
  fi

  # 5. Inject the JIT config via the guest agent (OS-specific path + format).
  if [ "$os" = "windows" ]; then
    env_path='C:\gha-runner\runner.env.ps1'
    env_content="\$env:RUNNER_JITCONFIG='${jitconfig}'
\$env:ORCH_TRIGGER_URL='${ORCH_TRIGGER_URL}'
\$env:RUNNER_NAME='${name}'"
  else
    env_path='/etc/gha-runner/env'
    # Single-quote values so `source /etc/gha-runner/env` can't word-split or run a stray
    # token if the JIT blob ever contains a shell-special char (base64 has no single quote).
    env_content="RUNNER_JITCONFIG='${jitconfig}'
ORCH_TRIGGER_URL='${ORCH_TRIGGER_URL}'
RUNNER_NAME='${name}'"
  fi
  pve_agent_write_file "$vmid" "$env_path" "$env_content" \
    || { echo "ERR ${name}: jitconfig injection failed" >&2; return 1; }

  echo "${name}: clean, started, JIT config injected — waiter will run one job."
  unset jitconfig env_content
}

# --- Is a runner with this name currently online in GitHub? -------------------
runner_is_online() {
  local name="$1" base
  if [ "$REGISTRATION_SCOPE" = "org" ]; then
    base="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners"
  else
    base="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners"
  fi
  curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "${base}?per_page=100" 2>/dev/null \
    | jq -e --arg n "$name" 'any(.runners[]; .name==$n and .status=="online")' >/dev/null 2>&1
}

# --- Proxmox: VM uptime in seconds (qemu runtime since last start/rollback) ----
get_vm_uptime() {
  curl -fsS -k -H "$PVE_AUTH" "${PROXMOX_URL}/nodes/${PROXMOX_NODE}/qemu/$1/status/current" 2>/dev/null \
    | jq -r '.data.uptime // 0'
}

# --- Reconcile loop over this node's slots ------------------------------------
for ((i = 1; i <= SLOT_COUNT; i++)); do
  eval "slot_name=\${SLOT_${i}_NAME:-}"
  eval "slot_vmid=\${SLOT_${i}_VMID:-}"
  if [ -z "$slot_name" ] || [ -z "$slot_vmid" ]; then
    echo "slot ${i}: incomplete config, skipping" >&2; continue
  fi

  if state="$(get_proxmox_vm_state "$slot_vmid" 2>/dev/null)"; then
    echo "${slot_name}: ${state}"
    if [ "$state" = "stopped" ]; then
      reset_runner_slot "$i"
    elif [ "$state" = "running" ]; then
      # Stuck detection: a runner connects within ~1-2 min of a reset, so a slot running
      # longer than the grace with NO online runner means the waiter/runner died without
      # shutting down (the orchestrator would otherwise skip a running VM forever). Reset it.
      up="$(get_vm_uptime "$slot_vmid")"
      if [ "${up:-0}" -gt "${STUCK_AFTER_SEC:-300}" ] && ! runner_is_online "$slot_name"; then
        echo "${slot_name}: running ${up}s with no online runner — resetting (stuck)"
        reset_runner_slot "$i"
      fi
    fi
  else
    echo "WARN ${slot_name}: status check failed (missing VM? clone from template here)" >&2
  fi
done
