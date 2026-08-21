# Runner consumers

The projects whose CI runs on the self-hosted runners built by this repo, and what
each needs installed. This is the **hub** for fleet CI requirements: when a project
needs a tool on a runner, it records that need in its own `docs/ci-requirements.md`
and the corresponding row here is added/updated in the same change.

Keep this informational. Agents working in a consumer project do not edit other
projects; they record their own need locally and a maintainer reflects it here.

## How a project requests a runner change

1. The project records the dependency in its own `docs/ci-requirements.md`.
2. A change to this repo adds/updates the project's row below and installs the tool
   in the relevant Ansible role/playbook (Linux and/or Windows).
3. Re-provision the affected runners (registration playbooks run on clones only).

## Consumers

> **Label model:** runners use generic labels (`[self-hosted, linux, x64, dotnet10]`)
> plus a node label, and are **ephemeral** (one job per boot). Project-specific labels
> are not baked into runners by default — projects select runners by capability
> (os/arch/dotnet/`vs-buildtools`/`nas`), not by project name. The "Runner labels"
> column below is what each project's jobs target, not a dedicated runner.


| Project | Runner labels | Tools needed beyond base image |
|---|---|---|
| DePam | `[self-hosted, linux, x64, dotnet10]`, `[self-hosted, windows, x64, dotnet10, vs-buildtools]` | mingw-w64 cross-compile toolchain, CMake, Ninja (native cores); binutils for binary inspection. Security-analysis stack (already in the Linux base image): Roslyn analyzers via the .NET 10 SDK (no extra package), SonarScanner for .NET (`dotnet-sonarscanner`, pushes to an external SonarQube server) + Trivy CLI |
| ArtifactView | `[self-hosted, windows, x64, dotnet10]` | net10.0-windows build; GDI+ / Windows desktop libs |
| DedupSharp | `[self-hosted, linux, x64, dotnet10]` | base .NET only |
| ReMedia | `[self-hosted, windows, x64, dotnet10]` | ffmpeg, ffprobe (WPF desktop build) |
| FileAudit | `[self-hosted, linux, x64, dotnet10]` | ffmpeg/ffprobe (optional), sqlite3, zip tools |

## Base image contents (for reference)

Defined by the Packer + Ansible automation in this repo:
- Git, PowerShell 7, .NET 10 SDK (all runners)
- **Linux runner** also bakes (packer/linux, `runner_apt_packages` + vars): build-essential,
  clang + zlib1g-dev (Native AOT), cmake, ninja, mingw-w64, binutils, gdb, sqlite3, ffmpeg,
  zip/unzip, python3, Node.js LTS, and the `android` .NET workload. Android SDK/JDK are NOT
  baked — Android jobs provide those (setup-java / android-actions).
  Also `libasound2-dev`, `libpulse-dev`, `libudev-dev` — the headers native audio
  (ALSA/PulseAudio) and device-enumeration (udev/hidraw) bindings compile against.
- **NAS GPU runner** (`docker/nas-linux-runner`, labels `nas,gpu,android`) mirrors the Linux
  toolchain and adds the **GL/EGL runtime** (`libglvnd0`, `libgl1`, `libglx0`, `libegl1`,
  `libgles2`, plus Mesa `libgl1-mesa-dri`/`libegl-mesa0` as the no-GPU fallback) — .NET
  graphics stacks `dlopen` `libEGL.so.1`/`libGL.so.1`, which the CUDA base image lacks.
- **Code-quality / security scanners** (Linux base image; also present on Windows + NAS):
  **Trivy** at `/usr/local/bin/trivy` (release artifact, SHA-256 verified), **SonarScanner
  for .NET** (`dotnet-sonarscanner`) under `/opt/dotnet-tools`, and the generic
  `sonar-scanner` CLI. All symlinked onto `/usr/local/bin` so they work for the runner
  service account. Versions are pinned via Packer vars (`trivy_version`,
  `dotnet_sonarscanner_version`, `sonar_scanner_version`) — no unbounded "latest".
  **Not baked**: the SonarQube server, `SONAR_TOKEN`/host URL/project key, and the Trivy
  vulnerability DB/caches — the consuming workflow supplies those. Roslyn analyzers need no
  package — they ship with the .NET 10 SDK.
- **Cloud / IaC CLIs** (all three images): **OpenTofu** (`tofu`), **TFLint**, **AWS CLI v2**,
  **Azure CLI** (`az`) and **Cloudflare Wrangler**. Versions are pinned via Packer vars /
  Docker ARGs (`opentofu_version`, `tflint_version`, `awscli_version`, `azure_cli_version`,
  `wrangler_version`). Verification differs by vendor, deliberately: OpenTofu and TFLint are
  SHA-256 checked against their published checksum files; Azure CLI on Linux comes from the
  Microsoft apt repo so apt's GPG chain covers it; **AWS CLI v2 is pinned but not
  checksum-verified** — AWS publishes a GPG signature instead of a checksum file. **No cloud
  credentials, profiles, or subscriptions are baked** — the consuming workflow supplies them.
- **Packaging tools** (all three images): **UPX** (executable packer) and **NSIS** (Windows
  installer builder). On Linux/NAS both come from Ubuntu's repos (`upx-ucl`, `nsis`) so apt's
  GPG chain covers them and they track the distro; NSIS on Linux pairs with the mingw-w64
  cross-compile toolchain to build Windows installers without a Windows runner. On Windows,
  UPX is a SHA-256-verified release zip under `C:\Tools\upx`, and NSIS installs silently to
  `C:\Program Files (x86)\NSIS` — pinned only, as no checksum is published for its setup.exe.
- **Windows runner** also bakes (packer/windows): Git, .NET 10 SDK, PowerShell 7 (pwsh),
  the runner + boot-waiter, and **Visual Studio Build Tools** (`install_buildtools`:
  MSBuild + ManagedDesktop + VCTools + VC.Tools.x86.x64 + Windows 11 SDK) — so MSBuild,
  .NET Framework/desktop, native C++, and **Windows Native AOT** work on the core runner.
  The Windows runner advertises the `vs-buildtools` label. (The separate
  `windows-gha-buildtools` image is now redundant for most needs — buildtools are in core.)

Anything a project lists above that is **not** in the base image needs a role/playbook
change here.

## Notes

- Tool lists reflect what each project's docs declare; verify against the project's
  `docs/ci-requirements.md` before changing a role.
- Runner labels are the contract — changing them affects the consuming projects'
  `runs-on:` lines.
