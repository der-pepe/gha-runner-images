#!/usr/bin/env bash
set -euo pipefail

# One-shot JIT GitHub Actions runner bootstrap.
# Runs inside a disposable Linux runner VM after the orchestrator injects
# /etc/gha-runner/env with RUNNER_JITCONFIG (a base64 encoded JIT config).
#
# JIT: no config.sh, no registration token, no on-disk credentials. run.sh consumes
# the one-shot config, runs a single job, exits; GitHub auto-removes the runner. Then
# this shuts the VM down and the orchestrator rolls it back for the next job.

ENV_FILE="${GHA_RUNNER_ENV_FILE:-/etc/gha-runner/env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${RUNNER_JITCONFIG:?RUNNER_JITCONFIG is required}"

RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_USER="${RUNNER_USER:-gha-runner}"

# Set the machine hostname to the runner name (all clones share the template hostname
# otherwise). Immediate, no reboot. Best-effort.
if [[ -n "${RUNNER_NAME:-}" ]]; then
  hostnamectl set-hostname "$RUNNER_NAME" 2>/dev/null || true
fi

cd "$RUNNER_DIR"
if [[ ! -x ./run.sh ]]; then
  echo "run.sh not found in $RUNNER_DIR; bake the runner package before using this script." >&2
  exit 1
fi

# The injected config is single-use; remove the env file once we've read it so a
# leftover blob can't be read by the job.
rm -f "$ENV_FILE" 2>/dev/null || true

# A vmstate (RAM) snapshot restore leaves the guest clock frozen at snapshot time (can be
# far in the past). A stale clock breaks JIT/token auth — GitHub rejects the runner and it
# exits. Step the clock immediately from an HTTPS Date header (fast, no NTP roundtrip),
# then hand off to NTP for ongoing accuracy. Harmless on a cold boot (already correct).
#
# Two things this MUST NOT do, both learned the hard way:
#   1. Abort the bootstrap. Under `set -e` an unguarded assignment inherits curl's exit
#      status, so a slow or unreachable fetch killed the runner before it ever started
#      (the waiter died with status=28, curl's timeout code). Every step here is
#      best-effort: a missing date just leaves NTP to converge.
#   2. Verify TLS. The certificate validity window is checked against the very clock we
#      are here to correct, so a stale clock makes a *verified* fetch fail — the fetch
#      that would have fixed it. -k breaks that chicken-and-egg. The value only seeds the
#      clock; authenticated NTP below immediately takes over.
http_date=""
for _dh in https://github.com https://api.github.com; do
  http_date="$(curl -skI --max-time 5 "$_dh" 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r' | tail -1)" || http_date=""
  [ -n "$http_date" ] && break
done
if [ -n "$http_date" ]; then date -s "$http_date" >/dev/null 2>&1 || true; fi
timedatectl set-ntp true 2>/dev/null || true
systemctl restart systemd-timesyncd 2>/dev/null || true

sudo -u "$RUNNER_USER" ./run.sh --jitconfig "$RUNNER_JITCONFIG"

# Poke the orchestrator's LAN trigger so it resets this slot immediately instead of
# waiting for the poll timer. Best-effort; the timer is the fallback.
if [ -n "${ORCH_TRIGGER_URL:-}" ]; then
  curl -fsS --max-time 3 "$ORCH_TRIGGER_URL" >/dev/null 2>&1 || true
fi

shutdown -h now
