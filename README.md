# GitHub Actions Self-Hosted Runner Images

Infrastructure-as-Code (Packer + Ansible + PowerShell + a bash orchestrator) for a
**self-sustaining, ephemeral GitHub Actions runner fleet on Proxmox VE + Ceph**.

Golden VM templates are built once with Packer; a tiny per-node orchestrator LXC then
cycles clean **JIT (just-in-time) ephemeral** runners on a timer — clean VM per job, no
management host in the runtime path.

## Status

**Live: a 3-node self-sustaining Linux JIT fleet.** Windows + Linux golden templates
build reproducibly. `gha-orch01/02/03` (one LXC per node) each cycle a Linux JIT runner
(`gha-linux-eph01/02/03`) on a ~2-min systemd timer. See
[`docs/current-status.md`](docs/current-status.md) for the running state and
[`docs/decisions/0001-self-sustaining-fleet.md`](docs/decisions/0001-self-sustaining-fleet.md)
for the target architecture. Remaining: Windows ephemeral bake, the HA builder (Phase 4).

## Architecture

**Two stages, plus autonomous orchestration:**

1. **Packer builds golden templates** (from ISO) — base OS, guest agent, the GitHub
   runner package + a boot **waiter** baked in (unregistered), and the CI toolchain. On
   Ceph a template is cluster-wide (build once, clone anywhere).
2. **Per-node orchestrator LXC** (bash + curl + jq, systemd timer) reconciles that node's
   runner slots via **snapshot-rollback**: roll the slot VM back to its `clean` snapshot →
   generate a **JIT config** (holding the PAT locally) → inject it via the guest agent →
   the waiter runs `run.sh --jitconfig` → one job → shutdown → repeat.

Why JIT: no registration token or credentials land on the runner (only a one-shot encoded
config, deleted after read), it's inherently single-use, and it avoids the `config.sh`
update/deprecation issues. The PAT never leaves the orchestrator.

Ansible (`ansible/`) provides an alternative **persistent** service-runner path
(`*-register-runner.yml`) and the `dotnet_sdk` / `github_runner` roles; the ephemeral
fleet above is the primary model.

## Images

| Image | Purpose |
|---|---|
| `ubuntu-gha-core` | Linux runner: .NET 10 SDK (incl. Roslyn analyzers), PowerShell 7, Node.js LTS, build-essential + clang/zlib (Native AOT), cmake, ninja, mingw-w64, binutils, sqlite3, ffmpeg, python3, git; **code-quality scanners** — Trivy + SonarScanner for .NET (`dotnet-sonarscanner`) + generic `sonar-scanner` CLI — plus the baked runner + waiter |
| `win-gha-core` | Windows Server Core runner: Git, PowerShell 7, .NET 10 SDK, VS Build Tools; also carries Trivy + SonarScanner |
| `win-gha-buildtools` | Optional heavier Windows runner with Visual Studio Build Tools/MSBuild |

The Linux toolchain is an extensible `runner_apt_packages` var + `dotnet_channel` /
`install_nodejs` / `dotnet_workloads` toggles; heavy add-ons (e.g. the Android SDK) belong
in a future beefier image, not the lean core. Requirements per consuming project are
tracked in [`docs/consumers.md`](docs/consumers.md).

**Code-quality scanners** (Linux; also Windows + NAS): **Trivy** (`/usr/local/bin/trivy`,
release artifact SHA-256-verified), **SonarScanner for .NET** (`dotnet-sonarscanner` under
`/opt/dotnet-tools`), and the generic `sonar-scanner` CLI — all on `/usr/local/bin` for the
runner service account. Versions are **pinned** via one Packer variable per tool
(`trivy_version`, `dotnet_sonarscanner_version`, `sonar_scanner_version`); no unbounded
"latest". The **SonarQube server, its `SONAR_TOKEN`/URL, and the Trivy vulnerability DB are
NOT baked** — the consuming workflow supplies them. Roslyn analyzers ship with the .NET SDK
(no package). Each Linux build runs `scripts/smoke-test-linux.sh` **as the runner account**,
failing the bake if `dotnet --info`, `dotnet sonarscanner --version`, or `trivy --version` is
missing, off-PATH, or the wrong pinned version.

## Fleet

One orchestrator LXC + a Linux and a Windows runner slot per node, **non-HA and
node-pinned** (a down node's runner is just down). Each orchestrator points at its own
node's API — no cross-node dependency.

| Node | Orchestrator LXC | Linux runner | Windows runner |
|---|---|---|---|
| pve1 | gha-orch01 | gha-linux-eph01 | gha-win-eph01 |
| pve2 | gha-orch02 | gha-linux-eph02 | gha-win-eph02 |
| pve3 | gha-orch03 | gha-linux-eph03 | gha-win-eph03 |

Linux runners use vmstate (RAM) snapshots for ~15s recovery; Windows use off-state
snapshots (~1 min cold). Each node's orchestrator manages its own slots.

## Deploy (from a management host)

Proxmox creds via env (see the `pve-status` skill's local env). Then:

```bash
# 1. discover cluster storage/bridge/ISOs -> fills packer/*/local.pkrvars.hcl
scripts/discover-proxmox.sh

# 2. build a golden template (background; needs xorriso + a build-privileged token)
bash .claude/skills/template-build/template-build.sh linux

# 3. create a runner slot from the template (clone + 'clean' snapshot)
bash .claude/skills/runner-slot/runner-slot.sh create <template_vmid> <slot_vmid> <name>

# 4. provision an orchestrator LXC, then on it:
sudo orchestrator/install-orchestrator.sh
#    fill /etc/gha-local-orchestrator/{env, node.local.env} -> the timer self-cycles the slot
```

Prereqs and the full Ceph/token/build runbook are in
[`docs/deploy.md`](docs/deploy.md) and [`docs/required-tools.md`](docs/required-tools.md).

## Control-plane skills

Drive the fleet from Claude Code: `/pve-status` (read cluster/VM/snapshot/agent),
`/runner-slot` (create/destroy slots), `/runner-teardown` (deregister + purge),
`/template-build` (Packer build), `/orchestrate-once` (one reconcile pass).

## Runner labels

Use explicit self-hosted labels (project-neutral, so runners are reusable):

```yaml
runs-on: [self-hosted, linux, x64, dotnet10]        # Linux
runs-on: [self-hosted, windows, x64, dotnet10]      # Windows
runs-on: [self-hosted, linux, x64, dotnet10, pve1]  # pin to a node
```

## Safety

Never commit: GitHub PATs, runner registration tokens, Proxmox API tokens, Windows
Administrator passwords, vault password files, or real inventory. Committed config is
`.example.*` only; real values are gitignored and/or ansible-vault encrypted. Runner
registration/JIT tokens are short-lived — never baked into images.
