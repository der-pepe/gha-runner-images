# Roadmap: self-sustaining fleet (tiny orchestrators + HA builder)

Target architecture: see [[decisions/0001-self-sustaining-fleet]].
Goal: after bootstrap, WSL is dev-only. 3 tiny per-node orchestrators own runner
lifecycle; 1 HA builder owns image regeneration (single cluster-wide template).

## Phase 0 — Foundations (DONE)

- [x] Windows golden template builds (virtio, updates, host CPU) — reproducible
- [x] Linux golden template builds (autoinstall) — reproducible
- [x] Registration logic (github_runner role) works, org-scope supported
- [x] discover-proxmox.sh fills pkrvars + fleet.local.yml

## Phase 1 — Prove one runner (DONE)

- [x] Clone one VM from a template, Ansible-register it (org-level), confirm it appears
      in the **der-pepe** GitHub org's runners and runs a job. This is the same
      registration the orchestrator will call — proving it de-risks the orchestrator.

## Phase 2 — Runner-lifecycle loop (DONE — proven end-to-end 2026-07-01)

- [x] Implement `reset_runner_slot` in `orchestrator/gha-local-orchestrator.sh`:
      pick reset strategy (snapshot-rollback vs destroy+reclone), inject fresh org
      registration token + runner name/labels/ephemeral via cloud-init/guest-agent,
      start the VM.
- [x] Proven: clean snapshot -> register --ephemeral -> job -> deregister -> shutdown -> ready to re-cycle (via orchestrate-once skill).

## Phase 3 — Tiny orchestrators (DONE — 3 nodes live 2026-07-02)

- [x] install-orchestrator.sh provisions the LXC (deps, scripts, config, secrets, units). gha-orch01 live on pve1, self-cycling slot 311 on the timer. Replicate to pve2/3.: config
      (`node.local.env`), secrets EnvironmentFile (Proxmox + GitHub tokens, least
      privilege), and the reconcile service+timer. Stays tiny (bash + curl + jq).

## Phase 4 — HA builder (DEPLOYED + verified 2026-07-03)

- [ ] Builder LXC (~1-2 GB): Packer + git checkout of this repo + build tokens (Proxmox
      build-priv token, build password) + CephFS ISO access. Rootfs on Ceph.
- [ ] Put the builder in a Proxmox **HA group** so a node failure relocates it.
- [ ] systemd timer on the builder: `git pull` + `packer build` of the single
      cluster-wide template per OS, on a fixed schedule (~60-90 days) — this is the
      **primary** regeneration trigger (ADR-0001). The existing eval-age checker
      (`WIN_TEMPLATE_EVAL_MAX_DAYS`, default 100, alert-only) stays as an independent
      **safety net** that catches a stalled schedule before the 180-day eval expires; the
      two are complementary, not the same mechanism.
- [ ] Template handover (see ADR): build to a versioned VMID, flip a `current-template`
      marker on success, orchestrators re-seed slots rolling/idle-only, retain N-1 then
      delete. Confirm `full_clone: true` everywhere so slots are template-independent.

## Phase 5 — Confirm self-sustaining

- [ ] Run the fleet for a full regen cycle with WSL powered off; verify runners keep
      cycling and templates regenerate with no laptop involvement.

## Notes

- Phase 1 + Phase 2 are the critical path to "ephemeral runners actually work". Phase 3-4
  remove WSL from regeneration. Do them in order.
- The orchestrator README still describes the older tiny-bash-only model; update it to the
  ADR's node-agent model when Phase 3 lands.
