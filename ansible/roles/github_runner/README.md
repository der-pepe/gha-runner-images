# github_runner role

Registers a self-hosted GitHub Actions runner on a **cloned** VM (Linux via ssh or
Windows via winrm). Never run against the golden template — runner names must be unique
and registration tokens are short-lived.

Each run: creates the `runner_user` account + directories, requests a fresh
registration token from the GitHub API (`no_log`), downloads/extracts the pinned runner
package, and configures it. By default it installs a long-lived **service** runner;
set `runner_ephemeral: true` to register with `--ephemeral` and skip the service (the
orchestrator drives a single job).

Platform is selected from `ansible_connection` (`winrm` → Windows), so it works in plays
with `gather_facts: false`.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `actions_runner_version` | `2.335.1` | Pinned runner package version |
| `actions_runner_dir` | `/opt/actions-runner` | Install dir (group_vars set Windows path) |
| `actions_work_dir` | `/opt/actions-work` | Work dir |
| `runner_user` | `gha-runner` | Local service account |
| `registration_scope` | `org` | `org` (org-wide runner) or `repo` (single repo) |
| `github_owner` | `CHANGE_ME_OWNER` | Org name (org scope) or owner (repo scope) |
| `github_repo` | `CHANGE_ME_REPO` | Repo name — only used when scope is `repo` |
| `runner_name` | `inventory_hostname` | Runner name |
| `runner_labels` | `self-hosted,proxmox,dotnet10,ephemeral` | Labels |
| `runner_ephemeral` | `false` | `--ephemeral`, no persistent service |

### Required secrets (from ansible-vault, never defaulted)

- `github_pat` — PAT used to request the short-lived registration token.
- `gha_runner_password` — Windows service account password (Windows only).

## Usage

```yaml
- hosts: linux
  become: true
  vars:
    github_owner: my-org
    github_repo: my-repo
  roles:
    - github_runner
```
