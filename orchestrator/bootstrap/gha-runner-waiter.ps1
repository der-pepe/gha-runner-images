<#
.SYNOPSIS
  Boot waiter for the Windows ephemeral runner.

.DESCRIPTION
  Registered as a Scheduled Task (at startup, SYSTEM) in the golden template. On each
  boot it waits for the orchestrator to inject C:\gha-runner\runner.env.ps1 (via the
  guest agent), then runs the one-shot JIT bootstrap. Mirrors the Linux
  gha-runner-waiter.service.
#>

$ErrorActionPreference = 'Continue'
$envFile   = 'C:\gha-runner\runner.env.ps1'
$bootstrap = 'C:\gha-runner\windows-runner-once.ps1'

# Wait up to ~5 min for the orchestrator to write the env (rollback -> start -> agent up
# -> file-write).
#
# Require a COMPLETE file, not merely an existing one: the JIT blob is ~4 KB and the write
# is not atomic from a concurrent reader's point of view, so a waiter that wakes mid-write
# reads a truncated env and the runner dies on a syntax error. GHA_ENV_COMPLETE is the last
# line the orchestrator writes, so its presence means everything before it landed.
function Test-EnvComplete {
    param($Path)
    if (-not (Test-Path $Path)) { return $false }
    try { return ((Get-Content -Raw -ErrorAction Stop $Path) -match 'GHA_ENV_COMPLETE') }
    catch { return $false }
}

for ($i = 0; $i -lt 150; $i++) {
    if (Test-EnvComplete $envFile) { break }
    Start-Sleep -Seconds 2
}

if (Test-EnvComplete $envFile) {
    & powershell.exe -ExecutionPolicy Bypass -File $bootstrap
} else {
    Write-Warning 'no complete C:\gha-runner\runner.env.ps1 injected'
}
