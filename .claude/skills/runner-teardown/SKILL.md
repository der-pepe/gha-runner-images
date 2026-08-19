---
name: runner-teardown
description: Tear down a runner — deregister it from the GitHub org, then stop and purge its Proxmox VM. Use when removing a runner slot/VM cleanly so it doesn't linger as an offline GitHub runner.
---

# runner-teardown

Creds from the shared gitignored `.claude/skills/pve-status/pve.local.env`:
PROXMOX_URL/TOKEN_ID/TOKEN (+ optional PROXMOX_NODE), and — for the GitHub step —
`GITHUB_TOKEN` (org PAT with runner admin) + `GITHUB_OWNER` (e.g. der-pepe). Without
the GitHub creds it only destroys the VM.

```bash
bash .claude/skills/runner-teardown/runner-teardown.sh <slot_vmid> [runner_name]
```

Finds the org runner by name (defaults to the VM name), deletes it from GitHub, then
stops + purges the VM. This is the scripted version of the manual 301 teardown.
Destructive — confirm the VMID first (`/pve-status vm <id>`).
