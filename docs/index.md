# gha-runner-images

Packer + Ansible automation for building Proxmox-hosted GitHub Actions self-hosted runner images

Repository: `https://github.com/der-pepe/gha-runner-images`

## Main goals

- Build reproducible Proxmox-hosted GitHub Actions self-hosted runner images
  (Windows + Linux) via Packer + Ansible.
- Keep runner registration out of golden images; register cloned VMs only.
- Never commit secrets, tokens, passwords, or real inventory.
- Provide the self-hosted CI runners that the C# projects build on.

## How agents should use this memory

- Start with this file, [[current-status]], [[instructions/agent-rules]], and [[tasks/lessons]].
- Use [[context-map]] to pick only the relevant docs for the task.
- Check [[environment]] before suggesting shell commands (local-only, gitignored — generate with `scripts/snapshot-environment.sh`).
- Create one file per active task under `tasks/` (parallel tasks supported).
- Use [[tasks/todo]] as the durable backlog only.

## Instructions

- [[instructions/agent-rules]]
- [[instructions/cli-tooling]]
- [[required-tools]] — tools a management host must install to build/validate
- [[context-map]]

## Decisions

- [[decisions/0001-self-sustaining-fleet]] — target fleet architecture

## Task tracking

- [[tasks/todo]] — durable backlog by priority
- `tasks/<task-name>.md` — one file per active task
- `tasks/done/` — completed task files
- [[tasks/lessons]] — correction patterns and recurring mistakes
- [[tasks/task-template]] — reusable task note template

## Main documents

- [[current-status]]
- [[environment]] — per-machine tool snapshot; local-only, gitignored (not on GitHub). Generate with `scripts/snapshot-environment.sh`
- [[sketchpad]] — scratch capture for raw ideas (NOT durable; do not act on without promotion)

- [[runner-architecture]] — two-stage Packer/Ansible model + fleet/orchestrator model
- [[deploy]] — building templates from this host onto a Ceph-backed Proxmox cluster
- [[consumers]] — projects using these runners + their tool requirements (hub)
- [[linux-runner]] — Linux runner build/registration
- [[windows-runner]] — Windows runner build/registration
- [[runner-fleet]] — fleet layout, local-orchestrator model, label strategy, sizing
- [[nas-runner-group]] — optional high-capacity NAS runner pool
- [[proxmox]] — Proxmox templating and cloning

## Structure lineage

This repo's agent-config structure is derived from the **agent-config-template** repo;
structural changes originate there. This repo is also the **infrastructure hub** —
[[consumers]] is the fleet-wide list of which projects use these runners and what tools
they need. Consuming projects record their needs in their own `docs/ci-requirements.md`
and request changes here; this repo owns the runner images and the consumers list.
