#!/usr/bin/env bash
# Single-shot JIT runner for the NAS Linux GPU runner (TrueNAS Docker app).
# Mints a just-in-time runner config, runs ONE job, then exits. The container is set
# `restart: always`, so each job runs in a FRESH container — a pristine filesystem per job
# (cleaner than an in-container loop). The PAT stays in the container's secret env and never
# reaches a workflow (JIT config only). JIT runners auto-remove after their job, so there is
# only ever one registration — it does not accumulate.
#
# On a mint failure it sleeps before exiting so `restart: always` (plus Docker's restart
# backoff) doesn't hot-loop on a bad token / no network.
set -uo pipefail

: "${GITHUB_OWNER:?set GITHUB_OWNER}"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN (fine-grained org PAT: self-hosted-runners RW)}"
BASE="${RUNNER_NAME:-gha-nas-linux-$(hostname)}"
LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,dotnet10,nas,gpu,android}"
API="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners"
GH=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

fail_sleep() { echo "$1" >&2; sleep "${RETRY_DELAY:-10}"; exit 1; }

# Best-effort tidy: remove OFFLINE, non-busy leftovers sharing the base name (cleanly stopped
# containers) so the stable name is free to reuse.
cleanup_orphans() {
  curl -fsS "${GH[@]}" "${API}?per_page=100" 2>/dev/null \
    | jq -r --arg b "$BASE" '.runners[]|select((.name==$b or (.name|startswith($b+"-"))) and .status=="offline" and (.busy|not))|.id' \
    | while read -r id; do
        [ -n "$id" ] || continue
        curl -fsS -X DELETE "${GH[@]}" "${API}/${id}" >/dev/null 2>&1 || true
      done
}

# Mint a JIT config for a given name; empty on failure (e.g. 409 name-in-use).
mint() {
  local name="$1" lj body
  lj="$(printf '%s' "$LABELS" | jq -R 'split(",")')"
  body="$(jq -n --arg n "$name" --argjson l "$lj" '{name:$n, runner_group_id:1, labels:$l, work_folder:"_work"}')"
  curl -fsS -X POST "${API}/generate-jitconfig" "${GH[@]}" -d "$body" 2>/dev/null | jq -r '.encoded_jit_config // empty'
}

cleanup_orphans

# Prefer the stable name. On a redeploy the previous container's runner may still be ONLINE
# for a few seconds (name-in-use -> 409); retry the base a few times so it can auto-remove
# before we resort to a suffix. cleanup_orphans re-runs each try to reap it once it goes
# offline. Only if the base stays held (e.g. a stuck offline+busy runner) do we suffix.
NAME="$BASE"
jit=""
for _ in 1 2 3 4 5; do
  jit="$(mint "$NAME")"
  [ -n "$jit" ] && break
  sleep 3
  cleanup_orphans
done
if [ -z "$jit" ]; then
  NAME="${BASE}-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  echo "base name still unavailable after retries; using ${NAME}"
  jit="$(mint "$NAME")"
fi
[ -n "$jit" ] || fail_sleep "jitconfig generation failed (check the token scope / org)"

echo "NAS linux runner: name=${NAME} labels=${LABELS}"
nvidia-smi -L 2>/dev/null | head -1 || echo "(no GPU visible — check the app's GPU allocation)"

cd /opt/actions-runner || exit 1
# One job, then exit -> restart:always gives the next job a fresh container.
exec ./run.sh --jitconfig "$jit"
