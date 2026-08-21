<#
.SYNOPSIS
  Bake the CI toolchain + GitHub Actions runner (unregistered) + boot waiter into the
  Windows golden template, for ephemeral JIT runners.

.NOTES
  Reads RUNNER_VERSION / DOTNET_CHANNEL / GIT_URL from the environment (Packer
  environment_vars). Expects windows-runner-once.ps1 + gha-runner-waiter.ps1 already
  uploaded to C:\Windows\Temp.
#>
$ErrorActionPreference = 'Stop'
$rv     = $env:RUNNER_VERSION
$ch     = $env:DOTNET_CHANNEL
$giturl = $env:GIT_URL

New-Item -Force -ItemType Directory 'C:\gha-runner', 'C:\actions-runner', 'C:\actions-work' | Out-Null
Copy-Item 'C:\Windows\Temp\windows-runner-once.ps1' 'C:\gha-runner\windows-runner-once.ps1' -Force
Copy-Item 'C:\Windows\Temp\gha-runner-waiter.ps1'   'C:\gha-runner\gha-runner-waiter.ps1'   -Force

Write-Host 'Installing Git for Windows...'
Invoke-WebRequest $giturl -OutFile 'C:\Windows\Temp\git.exe' -UseBasicParsing
Start-Process 'C:\Windows\Temp\git.exe' -ArgumentList '/VERYSILENT', '/NORESTART' -Wait

Write-Host "Installing .NET SDK $ch..."
Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile 'C:\Windows\Temp\dotnet-install.ps1' -UseBasicParsing
& 'C:\Windows\Temp\dotnet-install.ps1' -Channel $ch -InstallDir 'C:\Program Files\dotnet'

if ($env:PWSH_MSI_URL) {
    Write-Host 'Installing PowerShell 7 (pwsh)...'
    Invoke-WebRequest $env:PWSH_MSI_URL -OutFile 'C:\Windows\Temp\pwsh.msi' -UseBasicParsing
    Start-Process msiexec -ArgumentList '/i', 'C:\Windows\Temp\pwsh.msi', '/quiet', '/norestart', 'ADD_PATH=1' -Wait
}

if ($env:INSTALL_BUILDTOOLS -eq 'true') {
    Write-Host 'Installing Visual Studio Build Tools (MSBuild + MSVC C++ + Windows SDK)...'
    $bt = 'C:\Windows\Temp\vs_BuildTools.exe'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest $env:VS_BUILDTOOLS_URL -OutFile $bt -UseBasicParsing
    # The bootstrapper is a real PE ~1-4 MB; a truncated/redirect download shows up as
    # "corrupted and unreadable" at Start-Process, so sanity-check before running.
    $sz = (Get-Item $bt).Length
    if ($sz -lt 1MB) { throw "vs_BuildTools.exe download looks bad ($sz bytes)" }
    Unblock-File $bt
    # VCTools + VC.Tools + Windows SDK are what .NET Native AOT and C++ builds need; the
    # MSBuild/ManagedDesktop workloads cover MSBuild + .NET Framework/desktop.
    $vsArgs = @(
        '--quiet', '--wait', '--norestart', '--nocache', '--installPath', 'C:\BuildTools',
        '--add', 'Microsoft.VisualStudio.Workload.MSBuildTools',
        '--add', 'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools',
        '--add', 'Microsoft.VisualStudio.Workload.VCTools',
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621',
        '--includeRecommended'
    )
    $p = Start-Process 'C:\Windows\Temp\vs_BuildTools.exe' -ArgumentList $vsArgs -Wait -PassThru
    # 0 = ok, 3010 = ok-but-reboot-required; anything else is a real failure.
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "VS Build Tools install failed: exit $($p.ExitCode)" }
    Write-Host "VS Build Tools installed (exit $($p.ExitCode))."
}

# Standalone CMake + Ninja on PATH (VS Build Tools bundles CMake but not on PATH; mirrors
# the Linux image so cmake/ninja "just work").
if ($env:CMAKE_VERSION) {
    Write-Host "Installing CMake $env:CMAKE_VERSION..."
    Invoke-WebRequest "https://github.com/Kitware/CMake/releases/download/v$($env:CMAKE_VERSION)/cmake-$($env:CMAKE_VERSION)-windows-x86_64.zip" -OutFile 'C:\Windows\Temp\cmake.zip' -UseBasicParsing
    Expand-Archive 'C:\Windows\Temp\cmake.zip' -DestinationPath 'C:\Windows\Temp\cmakex' -Force
    if (Test-Path 'C:\Program Files\CMake') { Remove-Item 'C:\Program Files\CMake' -Recurse -Force }
    Move-Item (Get-ChildItem 'C:\Windows\Temp\cmakex' -Directory | Select-Object -First 1).FullName 'C:\Program Files\CMake'
}
if ($env:NINJA_VERSION) {
    Write-Host "Installing Ninja $env:NINJA_VERSION..."
    New-Item -ItemType Directory -Force 'C:\Program Files\Ninja' | Out-Null
    Invoke-WebRequest "https://github.com/ninja-build/ninja/releases/download/v$($env:NINJA_VERSION)/ninja-win.zip" -OutFile 'C:\Windows\Temp\ninja.zip' -UseBasicParsing
    Expand-Archive 'C:\Windows\Temp\ninja.zip' -DestinationPath 'C:\Program Files\Ninja' -Force
}

if ($env:INSTALL_CODEQL_LANGS -eq 'true') {
    $ProgressPreference = 'SilentlyContinue'
    Write-Host 'Installing Node.js...'
    Invoke-WebRequest 'https://nodejs.org/dist/v20.17.0/node-v20.17.0-x64.msi' -OutFile 'C:\Windows\Temp\node.msi' -UseBasicParsing
    Start-Process msiexec -ArgumentList '/i', 'C:\Windows\Temp\node.msi', '/quiet', '/norestart' -Wait

    Write-Host 'Installing Python 3...'
    Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe' -OutFile 'C:\Windows\Temp\python.exe' -UseBasicParsing
    Start-Process 'C:\Windows\Temp\python.exe' -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_launcher=1' -Wait

    Write-Host 'Installing JDK 17 (Temurin)...'
    Invoke-WebRequest 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12%2B7/OpenJDK17U-jdk_x64_windows_hotspot_17.0.12_7.zip' -OutFile 'C:\Windows\Temp\jdk.zip' -UseBasicParsing
    Expand-Archive 'C:\Windows\Temp\jdk.zip' -DestinationPath 'C:\Windows\Temp\jdkx' -Force
    if (Test-Path 'C:\Java\jdk17') { Remove-Item 'C:\Java\jdk17' -Recurse -Force }
    New-Item -ItemType Directory -Force 'C:\Java' | Out-Null
    Move-Item (Get-ChildItem 'C:\Windows\Temp\jdkx' -Directory | Select-Object -First 1).FullName 'C:\Java\jdk17'
    [Environment]::SetEnvironmentVariable('JAVA_HOME', 'C:\Java\jdk17', 'Machine')

    Write-Host 'Installing Go...'
    Invoke-WebRequest 'https://go.dev/dl/go1.23.2.windows-amd64.zip' -OutFile 'C:\Windows\Temp\go.zip' -UseBasicParsing
    if (Test-Path 'C:\go') { Remove-Item 'C:\go' -Recurse -Force }
    Expand-Archive 'C:\Windows\Temp\go.zip' -DestinationPath 'C:\' -Force   # extracts to C:\go

    Write-Host 'Installing Ruby...'
    Invoke-WebRequest 'https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-3.3.5-1/rubyinstaller-3.3.5-1-x64.exe' -OutFile 'C:\Windows\Temp\ruby.exe' -UseBasicParsing
    # /suppressmsgboxes + /tasks="" so the Inno installer never waits on a dialog or runs the
    # ridk/MSYS2 devkit step (CodeQL only needs the interpreter); it hung without these.
    Start-Process 'C:\Windows\Temp\ruby.exe' -ArgumentList '/verysilent', '/suppressmsgboxes', '/norestart', '/tasks=', '/dir=C:\Ruby33' -Wait

    Write-Host 'Installing Rust (rustup)...'
    Invoke-WebRequest 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile 'C:\Windows\Temp\rustup-init.exe' -UseBasicParsing
    $env:RUSTUP_HOME = 'C:\Rust'; $env:CARGO_HOME = 'C:\Rust'
    Start-Process 'C:\Windows\Temp\rustup-init.exe' -ArgumentList '-y', '--default-toolchain', 'stable', '--profile', 'minimal', '--no-modify-path' -Wait
    [Environment]::SetEnvironmentVariable('RUSTUP_HOME', 'C:\Rust', 'Machine')
    [Environment]::SetEnvironmentVariable('CARGO_HOME', 'C:\Rust', 'Machine')
}

# Code-quality scanners: Trivy + SonarScanner (dotnet tool + generic CLI).
$ProgressPreference = 'SilentlyContinue'
Write-Host 'Installing Trivy...'
New-Item -ItemType Directory -Force 'C:\Tools\trivy' | Out-Null
Invoke-WebRequest "https://github.com/aquasecurity/trivy/releases/download/v$($env:TRIVY_VERSION)/trivy_$($env:TRIVY_VERSION)_windows-64bit.zip" -OutFile 'C:\Windows\Temp\trivy.zip' -UseBasicParsing
Expand-Archive 'C:\Windows\Temp\trivy.zip' -DestinationPath 'C:\Tools\trivy' -Force

Write-Host "Installing dotnet-sonarscanner $env:DOTNET_SONARSCANNER_VERSION..."
# Pinned + idempotent (uninstall-then-install upgrades a prior pin cleanly).
# On a fresh image the tool is NOT installed, so `dotnet tool uninstall` writes to stderr
# and returns non-zero — the expected case here, not a failure. Under
# $ErrorActionPreference='Stop' PowerShell promotes native stderr to a TERMINATING error,
# so `2>$null` alone does not save us: the bake died after ~80 minutes on a clean build.
# Demote errors for this one call, swallow both streams, and clear the exit status; the
# install on the next line is the step that actually has to succeed.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& 'C:\Program Files\dotnet\dotnet.exe' tool uninstall --tool-path 'C:\Tools\dotnet-tools' dotnet-sonarscanner 2>&1 | Out-Null
$ErrorActionPreference = $prevEap
$global:LASTEXITCODE = 0
& 'C:\Program Files\dotnet\dotnet.exe' tool install --tool-path 'C:\Tools\dotnet-tools' --version $env:DOTNET_SONARSCANNER_VERSION dotnet-sonarscanner

Write-Host 'Installing SonarScanner CLI...'
Invoke-WebRequest "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-$($env:SONAR_SCANNER_VERSION)-windows-x64.zip" -OutFile 'C:\Windows\Temp\sonar.zip' -UseBasicParsing
Expand-Archive 'C:\Windows\Temp\sonar.zip' -DestinationPath 'C:\Windows\Temp\sonarx' -Force
if (Test-Path 'C:\Tools\sonar-scanner') { Remove-Item 'C:\Tools\sonar-scanner' -Recurse -Force }
Move-Item (Get-ChildItem 'C:\Windows\Temp\sonarx' -Directory | Select-Object -First 1).FullName 'C:\Tools\sonar-scanner'

# Cloud/IaC CLIs. OpenTofu and TFLint are SHA-256 verified against their published checksum
# files (same treatment as Trivy). AWS and Azure ship MSIs with no checksum file published
# alongside them, so those are version-pinned only — a deliberate, documented gap.
Write-Host "Installing OpenTofu $env:OPENTOFU_VERSION..."
New-Item -Force -ItemType Directory 'C:\Tools\opentofu' | Out-Null
Invoke-WebRequest "https://github.com/opentofu/opentofu/releases/download/v$($env:OPENTOFU_VERSION)/tofu_$($env:OPENTOFU_VERSION)_windows_amd64.zip" -OutFile 'C:\Windows\Temp\tofu.zip' -UseBasicParsing
Invoke-WebRequest "https://github.com/opentofu/opentofu/releases/download/v$($env:OPENTOFU_VERSION)/tofu_$($env:OPENTOFU_VERSION)_SHA256SUMS" -OutFile 'C:\Windows\Temp\tofu_sums.txt' -UseBasicParsing
$want = ((Get-Content 'C:\Windows\Temp\tofu_sums.txt' | Where-Object { $_ -match "tofu_$([regex]::Escape($env:OPENTOFU_VERSION))_windows_amd64\.zip$" }) -split '\s+')[0]
$got  = (Get-FileHash 'C:\Windows\Temp\tofu.zip' -Algorithm SHA256).Hash.ToLower()
if (-not $want -or $got -ne $want.ToLower()) { throw "OpenTofu checksum mismatch: got $got want $want" }
Expand-Archive 'C:\Windows\Temp\tofu.zip' -DestinationPath 'C:\Tools\opentofu' -Force

Write-Host "Installing TFLint $env:TFLINT_VERSION..."
New-Item -Force -ItemType Directory 'C:\Tools\tflint' | Out-Null
Invoke-WebRequest "https://github.com/terraform-linters/tflint/releases/download/v$($env:TFLINT_VERSION)/tflint_windows_amd64.zip" -OutFile 'C:\Windows\Temp\tflint.zip' -UseBasicParsing
Invoke-WebRequest "https://github.com/terraform-linters/tflint/releases/download/v$($env:TFLINT_VERSION)/checksums.txt" -OutFile 'C:\Windows\Temp\tflint_sums.txt' -UseBasicParsing
$want = ((Get-Content 'C:\Windows\Temp\tflint_sums.txt' | Where-Object { $_ -match 'tflint_windows_amd64\.zip$' }) -split '\s+')[0]
$got  = (Get-FileHash 'C:\Windows\Temp\tflint.zip' -Algorithm SHA256).Hash.ToLower()
if (-not $want -or $got -ne $want.ToLower()) { throw "TFLint checksum mismatch: got $got want $want" }
Expand-Archive 'C:\Windows\Temp\tflint.zip' -DestinationPath 'C:\Tools\tflint' -Force

Write-Host "Installing AWS CLI v2 $env:AWSCLI_VERSION..."
Invoke-WebRequest "https://awscli.amazonaws.com/AWSCLIV2-$($env:AWSCLI_VERSION).msi" -OutFile 'C:\Windows\Temp\awscli.msi' -UseBasicParsing
Start-Process msiexec.exe -ArgumentList '/i','C:\Windows\Temp\awscli.msi','/qn','/norestart' -Wait

Write-Host "Installing Azure CLI $env:AZURE_CLI_VERSION..."
Invoke-WebRequest "https://azcliprod.blob.core.windows.net/msi/azure-cli-$($env:AZURE_CLI_VERSION)-x64.msi" -OutFile 'C:\Windows\Temp\azurecli.msi' -UseBasicParsing
Start-Process msiexec.exe -ArgumentList '/i','C:\Windows\Temp\azurecli.msi','/qn','/norestart' -Wait

Write-Host "Installing Wrangler $env:WRANGLER_VERSION..."
& npm install -g "wrangler@$($env:WRANGLER_VERSION)" 2>&1 | Out-Null
$global:LASTEXITCODE = 0

Write-Host 'Updating machine PATH + DOTNET_ROOT...'
$p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$p = ($p.TrimEnd(';') + ';C:\Tools\opentofu;C:\Tools\tflint')
$p = ($p.TrimEnd(';') + ';C:\Program Files\dotnet;C:\Program Files\Git\cmd;C:\Program Files\CMake\bin;C:\Program Files\Ninja;C:\Java\jdk17\bin;C:\go\bin;C:\Ruby33\bin;C:\Rust\bin;C:\Tools\trivy;C:\Tools\dotnet-tools;C:\Tools\sonar-scanner\bin')
[Environment]::SetEnvironmentVariable('Path', $p, 'Machine')
[Environment]::SetEnvironmentVariable('DOTNET_ROOT', 'C:\Program Files\dotnet', 'Machine')

# AGENT_TOOLSDIRECTORY moves the toolcache OUT of _work. The runner's default cache
# (C:\actions-runner\_work\_tool) sits inside the workspace, so on these ephemeral slots every
# job starts from a vmstate rollback with an empty cache and re-downloads its toolchain — the
# CodeQL bundle alone costs ~40s of download plus extraction, every run. A path outside _work is
# part of the image, so anything seeded at build time survives the rollback.
[Environment]::SetEnvironmentVariable('AGENT_TOOLSDIRECTORY', 'C:\hostedtoolcache', 'Machine')
New-Item -Force -ItemType Directory 'C:\hostedtoolcache' | Out-Null

# Seed the CodeQL bundle into that toolcache, in the layout actions/tool-cache expects:
# <tools>\CodeQL\<version>\x64 plus a sibling <version>\x64.complete marker — without the
# marker the entry is ignored and the action downloads anyway. codeql-action requests a specific
# bundle version, so a mismatch simply falls back to downloading (slow, not broken).
if ($env:CODEQL_BUNDLE_VERSION) {
    Write-Host "Seeding CodeQL bundle $env:CODEQL_BUNDLE_VERSION into the toolcache..."
    $cqRoot = "C:\hostedtoolcache\CodeQL\$($env:CODEQL_BUNDLE_VERSION)\x64"
    New-Item -Force -ItemType Directory $cqRoot | Out-Null
    Invoke-WebRequest "https://github.com/github/codeql-action/releases/download/codeql-bundle-v$($env:CODEQL_BUNDLE_VERSION)/codeql-bundle-win64.tar.gz" -OutFile 'C:\Windows\Temp\codeql.tar.gz' -UseBasicParsing
    & tar.exe xz -C $cqRoot -f 'C:\Windows\Temp\codeql.tar.gz'
    Remove-Item 'C:\Windows\Temp\codeql.tar.gz' -Force -ErrorAction SilentlyContinue
    New-Item -Force -ItemType File "C:\hostedtoolcache\CodeQL\$($env:CODEQL_BUNDLE_VERSION)\x64.complete" | Out-Null
}

Write-Host "Extracting GitHub Actions runner $rv (unregistered)..."
$zip = 'C:\actions-runner\runner.zip'
Invoke-WebRequest "https://github.com/actions/runner/releases/download/v$rv/actions-runner-win-x64-$rv.zip" -OutFile $zip -UseBasicParsing
Expand-Archive $zip -DestinationPath 'C:\actions-runner' -Force
Remove-Item $zip -Force

Write-Host 'Registering the boot waiter scheduled task (SYSTEM, at startup)...'
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -NonInteractive -File C:\gha-runner\gha-runner-waiter.ps1'
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'gha-runner-waiter' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host 'Windows runner bake complete.'
