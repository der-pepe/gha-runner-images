packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.3"
    }
  }
}

variable "proxmox_url" {}
variable "proxmox_username" {}
variable "proxmox_token" {
  type      = string
  sensitive = true
}
variable "proxmox_node" { default = "pve" }
variable "iso_file" { default = "local:iso/ubuntu-24.04-live-server-amd64.iso" }
variable "storage_pool" { default = "local-lvm" }
variable "iso_storage_pool" {
  default     = "local"
  description = "Storage for the generated cidata CD (autoinstall user-data/meta-data). Must allow ISO content; on Ceph use a CephFS storage."
}
variable "bridge" { default = "vmbr0" }
variable "vm_name" { default = "tmpl-ubuntu-gha-core" }
variable "cpu_type" {
  default     = "host"
  description = "Proxmox CPU type. 'host' exposes the full physical CPU for best CI performance; safe for the pinned non-HA fleet."
}

variable "ssh_username" {
  default     = "ansible"
  description = "Build/provisioning user created by autoinstall (must match user-data identity.username)."
}
variable "ssh_password" {
  type        = string
  sensitive   = true
  default     = "ChangeMe_GHA_2026"
  description = "Build user password. MUST match the hashed password in cloud-init/user-data. Replace both for production."
}
variable "install_updates" {
  type        = bool
  default     = true
  description = "Run apt dist-upgrade during the build. Set false for fast test builds."
}
variable "runner_version" {
  default     = "2.336.0"
  description = "Pinned GitHub Actions runner version to bake into the image (unregistered)."
}
variable "runner_cores" {
  default     = 4
  description = "vCPU cores for the runner VM/slots. Also the template's clone default."
}
variable "runner_memory" {
  default     = 8192
  description = "RAM (MB) for the runner VM/slots. 8 GB fits the smallest node (pve2, 15.5 GB) and handles SonarScanner + a .NET build; route heavier scans to the NAS runner."
}

# CI toolchain baked into the image (ephemeral runners can't install per-job). Derived
# from docs/consumers.md; extend here + record the consumer row in the same change.
variable "runner_apt_packages" {
  # clang + zlib1g-dev are the Native AOT Linux prereqs. openjdk/golang/ruby are for CodeQL
  # (Java/Kotlin, Go, Ruby); C#/C++/JS/Python toolchains are covered by dotnet/build-essential/node/python3.
  # libasound2-dev/libpulse-dev/libudev-dev are the -dev headers native audio + device-enumeration
  # bindings (ALSA/PulseAudio, udev/hidraw) compile against; the runtime libs come in as their deps.
  # upx-ucl packs release binaries; nsis builds Windows installers FROM Linux, which pairs with the
  # mingw-w64 cross-compile toolchain already here. Both come from Ubuntu's repos, so apt's GPG
  # chain covers them and they track the distro rather than carrying a pin of their own.
  default     = "build-essential clang zlib1g-dev cmake ninja-build mingw-w64 binutils gdb git curl wget unzip zip jq ca-certificates pkg-config sqlite3 ffmpeg python3 python3-pip python3-venv openjdk-17-jdk golang-go ruby-full libasound2-dev libpulse-dev libudev-dev upx-ucl nsis"
  description = "Space-separated apt packages installed into the runner image."
}
variable "dotnet_workloads" {
  default     = ""
  description = "Space-separated .NET workloads to install (e.g. 'android wasm-tools'). Empty = none."
}
variable "opentofu_version" {
  default     = "1.12.6"
  description = "OpenTofu (tofu) CLI version. Release zip, SHA-256 verified against the published SHA256SUMS."
}
variable "tflint_version" {
  default     = "0.64.0"
  description = "TFLint (Terraform/OpenTofu linter) version. Release zip, SHA-256 verified against the published checksums.txt."
}
variable "wrangler_version" {
  default     = ""
  description = "Wrangler version, or EMPTY to track latest (the default). Note the coupling: wrangler's engines field gates on Node, so a major bump can demand a newer Node than the image installs — exactly how a bake failed with EBADENGINE."
}
variable "awscli_version" {
  default     = ""
  description = "AWS CLI v2 version, or EMPTY to track latest (the default). Cloud CLIs gate on remote service APIs rather than on your code, so going stale is the bigger risk. NOTE: AWS publishes a GPG signature rather than a checksums file, so this is not checksum-verified either way."
}
variable "azure_cli_version" {
  default     = ""
  description = "Azure CLI apt version (e.g. 2.89.1-1~noble). Empty = whatever the Microsoft repo currently serves, which is GPG-verified by apt — same treatment as dotnet-sdk/powershell above."
}
variable "codeql_bundle_version" {
  default     = "2.26.3"
  description = "CodeQL bundle pre-seeded into the toolcache so ephemeral jobs don't re-download ~500 MB every run. Must match the version github/codeql-action requests: if the action wants a newer bundle it misses this cache and downloads anyway (harmless, just slow). Bump when the action does; empty string skips seeding."
}
variable "trivy_version" {
  default     = ""
  description = "Trivy version, or EMPTY to track the latest release (the default). Trivy is a vulnerability scanner: running behind means missing detections, so staleness is the bigger risk here than a surprise bump. The download is SHA-256 verified against whichever release is fetched either way. Set a version to pin if a release misbehaves."
}
variable "sonar_scanner_version" {
  default     = "8.1.0.6389"
  description = "Generic SonarScanner CLI version (for non-.NET analysis)."
}
variable "dotnet_sonarscanner_version" {
  default     = "11.2.1"
  description = "SonarScanner for .NET (dotnet-sonarscanner global tool) version. Pinned — never install unbounded latest."
}
variable "dotnet_channel" {
  default     = "10.0"
  description = ".NET SDK channel to install (matches the dotnet10 runner label)."
}
variable "install_powershell" {
  type        = bool
  default     = true
  description = "Install PowerShell 7 (consumers.md lists it for all runners)."
}
variable "install_nodejs" {
  type        = bool
  default     = true
  description = "Install Node.js current LTS from NodeSource."
}

source "proxmox-iso" "ubuntu_gha_core" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  vm_name       = var.vm_name
  template_name = var.vm_name

  os       = "l26"
  machine  = "q35"
  cpu_type = var.cpu_type
  cores    = var.runner_cores
  sockets  = 1
  memory   = var.runner_memory

  # Ubuntu has inbox virtio drivers, so virtio-scsi disk + virtio NIC + guest agent all
  # work with no driver injection (unlike Windows).
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true

  disks {
    type         = "scsi"
    disk_size    = "40G"
    storage_pool = var.storage_pool
    format       = "raw"
  }

  network_adapters {
    model  = "virtio"
    bridge = var.bridge
  }

  iso_file    = var.iso_file
  unmount_iso = true

  # NoCloud datasource: autoinstall reads user-data/meta-data from a CD labeled "cidata".
  additional_iso_files {
    device           = "sata1"
    iso_storage_pool = var.iso_storage_pool
    cd_files = [
      "cloud-init/user-data",
      "cloud-init/meta-data",
    ]
    cd_label = "cidata"
    unmount  = true
  }

  communicator = "ssh"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "30m"

  boot_wait = "5s"

  # At the GRUB screen, drop to the command line and boot the casper kernel with
  # autoinstall + the NoCloud datasource (the cidata CD provides the data).
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz autoinstall ds=nocloud<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>",
  ]
}

build {
  sources = ["source.proxmox-iso.ubuntu_gha_core"]

  # Patch the image (toggle with install_updates).
  dynamic "provisioner" {
    for_each = var.install_updates ? [1] : []
    labels   = ["shell"]
    content {
      inline = [
        "sudo apt-get update",
        "sudo DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade",
      ]
    }
  }

  # Bake the CI toolchain (ephemeral runners can't install per-job): apt packages +
  # .NET SDK + PowerShell from the Microsoft feed.
  provisioner "shell" {
    inline = [
      "curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o /tmp/ms-prod.deb",
      "sudo dpkg -i /tmp/ms-prod.deb && rm -f /tmp/ms-prod.deb",
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ${var.runner_apt_packages} dotnet-sdk-${var.dotnet_channel}",
      "${var.install_powershell ? "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y powershell" : "true"}",
      # Node.js current LTS from NodeSource (Ubuntu's apt nodejs lags).
      "${var.install_nodejs ? "curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs" : "true"}",
      # .NET workloads (e.g. android, wasm-tools). Native AOT needs no workload (uses clang/zlib above).
      "${var.dotnet_workloads != "" ? "sudo dotnet workload install ${var.dotnet_workloads}" : "true"}",
      # Cloud/IaC CLIs. OpenTofu is checksum-verified from its published SHA256SUMS (same
      # treatment as Trivy). Azure CLI comes from the Microsoft apt repo configured above, so
      # apt's GPG chain verifies it. AWS CLI v2 ships a GPG signature instead of a checksum
      # file, so it is version-pinned but not verified here — a deliberate, documented gap.
      "curl -fsSLO https://github.com/opentofu/opentofu/releases/download/v${var.opentofu_version}/tofu_${var.opentofu_version}_linux_amd64.zip",
      "curl -fsSLO https://github.com/opentofu/opentofu/releases/download/v${var.opentofu_version}/tofu_${var.opentofu_version}_SHA256SUMS",
      "grep \" tofu_${var.opentofu_version}_linux_amd64.zip$\" tofu_${var.opentofu_version}_SHA256SUMS | sha256sum -c -",
      "sudo unzip -o -q tofu_${var.opentofu_version}_linux_amd64.zip tofu -d /usr/local/bin && sudo chmod 0755 /usr/local/bin/tofu && rm -f tofu_${var.opentofu_version}_*",
      "curl -fsSL -o /tmp/tflint.zip https://github.com/terraform-linters/tflint/releases/download/v${var.tflint_version}/tflint_linux_amd64.zip",
      "curl -fsSL -o /tmp/tflint_checksums.txt https://github.com/terraform-linters/tflint/releases/download/v${var.tflint_version}/checksums.txt",
      "(cd /tmp && cp tflint.zip tflint_linux_amd64.zip && grep ' tflint_linux_amd64.zip$' tflint_checksums.txt | sha256sum -c - && rm -f tflint_linux_amd64.zip)",
      "sudo unzip -o -q /tmp/tflint.zip tflint -d /usr/local/bin && sudo chmod 0755 /usr/local/bin/tflint && rm -f /tmp/tflint.zip /tmp/tflint_checksums.txt",
      "curl -fsSL -o /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64${var.awscli_version != "" ? "-${var.awscli_version}" : ""}.zip",
      "unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2 && sudo /tmp/awscliv2/aws/install --update && rm -rf /tmp/awscliv2 /tmp/awscliv2.zip",
      # Azure CLI lives in its OWN Microsoft repo — packages-microsoft-prod (installed above
      # for dotnet/powershell) does NOT carry it, so installing azure-cli without this fails
      # with "E: Unable to locate package azure-cli". Key goes in a keyring and the list entry
      # is signed-by it, so apt still verifies the GPG chain.
      "sudo install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg",
      "sudo chmod 0644 /etc/apt/keyrings/microsoft.gpg",
      "echo \"deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/azure-cli.list >/dev/null",
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y azure-cli${var.azure_cli_version != "" ? "=${var.azure_cli_version}" : ""}",
      "${var.install_nodejs ? "sudo npm install -g wrangler@${var.wrangler_version != "" ? var.wrangler_version : "latest"}" : "true"}",
      # Rust (rustup) for CodeQL Rust — system install under /opt/rust, symlinked onto PATH.
      # The proxies need RUSTUP_HOME to find the toolchain, so it's exported for jobs via .env.
      "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sudo RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable",
      "sudo ln -sf /opt/rust/bin/cargo /opt/rust/bin/rustc /opt/rust/bin/rustup /usr/local/bin/",
      "sudo chmod -R a+rX /opt/rust",
      # Code-quality scanners: Trivy + SonarScanner (SonarScanner for .NET + generic CLI).
      # Trivy: download the pinned release artifact + its checksums file and verify the
      # SHA-256 before extracting (no unverified pipe-to-shell). NOTE: no vuln DB is baked —
      # the consuming workflow downloads/caches it (it would go stale in a golden image).
      # Resolve the version first: an empty var means latest. Checksum verification is
      # unchanged either way — we verify against whichever release we actually fetched, so
      # tracking latest costs provenance-over-time, not integrity. One shell invocation so
      # the resolved version survives across the steps.
      "cd /tmp && TV='${var.trivy_version}'; [ -n \"$TV\" ] || TV=$(curl -fsSL https://api.github.com/repos/aquasecurity/trivy/releases/latest | jq -r .tag_name | sed 's/^v//'); echo \"trivy version: $TV\" && curl -fsSLO https://github.com/aquasecurity/trivy/releases/download/v$${TV}/trivy_$${TV}_Linux-64bit.tar.gz && curl -fsSLO https://github.com/aquasecurity/trivy/releases/download/v$${TV}/trivy_$${TV}_checksums.txt && grep \" trivy_$${TV}_Linux-64bit.tar.gz$\" trivy_$${TV}_checksums.txt | sha256sum -c - && sudo tar -xzf trivy_$${TV}_Linux-64bit.tar.gz -C /usr/local/bin trivy && rm -f trivy_$${TV}_*",
      # SonarScanner for .NET (pinned, machine-wide /opt/dotnet-tools). Uninstall-then-install
      # is idempotent + upgrades a prior pin cleanly.
      "sudo dotnet tool uninstall --tool-path /opt/dotnet-tools dotnet-sonarscanner 2>/dev/null || true",
      "sudo dotnet tool install --tool-path /opt/dotnet-tools --version ${var.dotnet_sonarscanner_version} dotnet-sonarscanner",
      # Generic SonarScanner CLI (non-.NET analysis; uses the baked JDK).
      "curl -fsSL -o /tmp/sonar.zip https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${var.sonar_scanner_version}.zip && sudo unzip -q /tmp/sonar.zip -d /opt && sudo mv /opt/sonar-scanner-${var.sonar_scanner_version} /opt/sonar-scanner && rm -f /tmp/sonar.zip",
      # Wrapper scripts on /usr/local/bin (NOT symlinks) so `dotnet sonarscanner` and
      # `sonar-scanner` exec from their REAL install dir — a symlinked .NET apphost / shell
      # launcher resolves its DLLs/dir relative to the link and fails. `trivy` is already a
      # real binary in /usr/local/bin. All resolve for the gha-runner account, no profile init.
      "sudo chmod -R a+rX /opt/dotnet-tools /opt/sonar-scanner",
      "printf '%s\\n' '#!/bin/sh' 'exec /opt/dotnet-tools/dotnet-sonarscanner \"$@\"' | sudo tee /usr/local/bin/dotnet-sonarscanner >/dev/null && sudo chmod 0755 /usr/local/bin/dotnet-sonarscanner",
      "printf '%s\\n' '#!/bin/sh' 'exec /opt/sonar-scanner/bin/sonar-scanner \"$@\"' | sudo tee /usr/local/bin/sonar-scanner >/dev/null && sudo chmod 0755 /usr/local/bin/sonar-scanner",
      "dotnet --version && cmake --version | head -1 && java -version && go version && ruby --version && RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust cargo --version && trivy --version | head -1 && sonar-scanner --version 2>&1 | grep -i version | head -1 && ${var.install_nodejs ? "node --version" : "true"}",
    ]
  }

  # Bake the GitHub Actions runner (UNREGISTERED) + the ephemeral waiter, so a cloned
  # slot only needs the orchestrator to inject /etc/gha-runner/env and boot.
  provisioner "file" {
    source      = "../../orchestrator/bootstrap/linux-runner-once.sh"
    destination = "/tmp/linux-runner-once.sh"
  }
  provisioner "file" {
    source      = "../../orchestrator/bootstrap/gha-runner-waiter.service"
    destination = "/tmp/gha-runner-waiter.service"
  }
  provisioner "shell" {
    inline = [
      "id gha-runner >/dev/null 2>&1 || sudo useradd -m -s /bin/bash gha-runner",
      "sudo mkdir -p /opt/actions-runner /opt/actions-work /opt/gha-runner /etc/gha-runner",
      "curl -fsSL -o /tmp/runner.tar.gz https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-x64-${var.runner_version}.tar.gz",
      "sudo tar -xzf /tmp/runner.tar.gz -C /opt/actions-runner",
      "sudo /opt/actions-runner/bin/installdependencies.sh",
      # Seed the CodeQL bundle into the toolcache. Layout is the one actions/tool-cache
      # expects: <tools>/CodeQL/<version>/x64 plus a sibling <version>/x64.complete marker —
      # without the marker the cache entry is ignored and the action downloads anyway.
      # codeql-action asks for the bundle by version, so this only hits when the pinned
      # version matches what the action wants; a mismatch just falls back to downloading.
      "${var.codeql_bundle_version != "" ? "sudo mkdir -p /opt/hostedtoolcache/CodeQL/${var.codeql_bundle_version}/x64 && curl -fsSL -o /tmp/codeql.tar.gz https://github.com/github/codeql-action/releases/download/codeql-bundle-v${var.codeql_bundle_version}/codeql-bundle-linux64.tar.gz && sudo tar -xzf /tmp/codeql.tar.gz -C /opt/hostedtoolcache/CodeQL/${var.codeql_bundle_version}/x64 && rm -f /tmp/codeql.tar.gz && sudo touch /opt/hostedtoolcache/CodeQL/${var.codeql_bundle_version}/x64.complete && sudo chmod -R a+rX /opt/hostedtoolcache" : "true"}",
      # JAVA_HOME (CodeQL Java) + RUSTUP/CARGO_HOME (CodeQL Rust) baked into the runner's .env,
      # which the runner loads for every job.
      # AGENT_TOOLSDIRECTORY moves the toolcache OUT of _work. The runner's default cache
      # ($RUNNER_WORKDIR/_tool) is inside the workspace, so on these ephemeral slots every
      # job starts from a rollback with an empty cache and re-downloads its toolchain
      # (CodeQL bundle, setup-node/python/java/dotnet). A path outside _work is part of the
      # image, so anything seeded at build time survives the rollback.
      # Telemetry opt-outs. These are build agents: nothing here benefits from usage
      # reporting, and every phone-home is latency plus an outbound connection from a
      # short-lived VM. All are the vendors' documented opt-out switches.
      "printf 'JAVA_HOME=%s\\nRUSTUP_HOME=/opt/rust\\nCARGO_HOME=/opt/rust\\nAGENT_TOOLSDIRECTORY=/opt/hostedtoolcache\\nDOTNET_CLI_TELEMETRY_OPTOUT=1\\nDOTNET_NOLOGO=1\\nPOWERSHELL_TELEMETRY_OPTOUT=1\\nWRANGLER_SEND_METRICS=false\\nAZURE_CORE_COLLECT_TELEMETRY=0\\nSAM_CLI_TELEMETRY=0\\n' \"$(dirname $(dirname $(readlink -f $(command -v javac))))\" | sudo tee /opt/actions-runner/.env >/dev/null",
      "sudo install -m 0755 /tmp/linux-runner-once.sh /opt/gha-runner/linux-runner-once.sh",
      "sudo chown -R gha-runner:gha-runner /opt/actions-runner /opt/actions-work",
      "sudo install -m 0644 /tmp/gha-runner-waiter.service /etc/systemd/system/gha-runner-waiter.service",
      "sudo systemctl enable gha-runner-waiter.service",
    ]
  }

  # Image smoke test, run AS THE RUNNER ACCOUNT (gha-runner): fail the build if dotnet,
  # dotnet-sonarscanner, or trivy is missing / off PATH / non-zero / not the pinned version.
  # Never contacts a SonarQube server or downloads the Trivy vuln DB.
  provisioner "file" {
    source      = "../../scripts/smoke-test-linux.sh"
    destination = "/tmp/smoke-test-linux.sh"
  }
  provisioner "shell" {
    inline = [
      "sudo -u gha-runner env EXPECTED_TRIVY='${var.trivy_version}' EXPECTED_SONARSCANNER='${var.dotnet_sonarscanner_version}' EXPECTED_OPENTOFU='${var.opentofu_version}' EXPECTED_TFLINT='${var.tflint_version}' EXPECTED_AWSCLI='${var.awscli_version}' EXPECTED_WRANGLER='${var.wrangler_version}' bash /tmp/smoke-test-linux.sh",
    ]
  }

  # Generalize the image so clones get unique identity (machine-id, ssh host keys).
  provisioner "shell" {
    inline = [
      # Install a first-boot oneshot that regenerates SSH host keys before sshd if they
      # are missing. We can't rely on cloud-init for this on a clone (it may have no
      # datasource), and without host keys sshd resets every connection.
      "printf '%s\\n' '[Unit]' 'Description=Regenerate SSH host keys if missing' 'Before=ssh.service' 'ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key' '[Service]' 'Type=oneshot' 'ExecStart=/usr/bin/ssh-keygen -A' '[Install]' 'WantedBy=multi-user.target' | sudo tee /etc/systemd/system/regen-ssh-host-keys.service >/dev/null",
      "sudo systemctl enable regen-ssh-host-keys.service",
      # Now generalize: clones regenerate keys (via the oneshot) and a fresh machine-id.
      "sudo cloud-init clean --logs",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo apt-get -y autoremove --purge",
      "sudo apt-get clean",
    ]
  }
}
