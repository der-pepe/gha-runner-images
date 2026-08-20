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
  default     = "build-essential clang zlib1g-dev cmake ninja-build mingw-w64 binutils gdb git curl wget unzip zip jq ca-certificates pkg-config sqlite3 ffmpeg python3 python3-pip python3-venv openjdk-17-jdk golang-go ruby-full libasound2-dev libpulse-dev libudev-dev"
  description = "Space-separated apt packages installed into the runner image."
}
variable "dotnet_workloads" {
  default     = ""
  description = "Space-separated .NET workloads to install (e.g. 'android wasm-tools'). Empty = none."
}
variable "codeql_bundle_version" {
  default     = "2.26.3"
  description = "CodeQL bundle pre-seeded into the toolcache so ephemeral jobs don't re-download ~500 MB every run. Must match the version github/codeql-action requests: if the action wants a newer bundle it misses this cache and downloads anyway (harmless, just slow). Bump when the action does; empty string skips seeding."
}
variable "trivy_version" {
  default     = "0.74.0"
  description = "Trivy (vuln/IaC/secret scanner) version to bake on PATH. Pinned; verified by checksum."
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
      # Rust (rustup) for CodeQL Rust — system install under /opt/rust, symlinked onto PATH.
      # The proxies need RUSTUP_HOME to find the toolchain, so it's exported for jobs via .env.
      "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sudo RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable",
      "sudo ln -sf /opt/rust/bin/cargo /opt/rust/bin/rustc /opt/rust/bin/rustup /usr/local/bin/",
      "sudo chmod -R a+rX /opt/rust",
      # Code-quality scanners: Trivy + SonarScanner (SonarScanner for .NET + generic CLI).
      # Trivy: download the pinned release artifact + its checksums file and verify the
      # SHA-256 before extracting (no unverified pipe-to-shell). NOTE: no vuln DB is baked —
      # the consuming workflow downloads/caches it (it would go stale in a golden image).
      "cd /tmp && curl -fsSLO https://github.com/aquasecurity/trivy/releases/download/v${var.trivy_version}/trivy_${var.trivy_version}_Linux-64bit.tar.gz && curl -fsSLO https://github.com/aquasecurity/trivy/releases/download/v${var.trivy_version}/trivy_${var.trivy_version}_checksums.txt",
      "cd /tmp && grep 'trivy_${var.trivy_version}_Linux-64bit.tar.gz' trivy_${var.trivy_version}_checksums.txt | sha256sum -c -",
      "sudo tar -xzf /tmp/trivy_${var.trivy_version}_Linux-64bit.tar.gz -C /usr/local/bin trivy && rm -f /tmp/trivy_${var.trivy_version}_*",
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
      "printf 'JAVA_HOME=%s\\nRUSTUP_HOME=/opt/rust\\nCARGO_HOME=/opt/rust\\nAGENT_TOOLSDIRECTORY=/opt/hostedtoolcache\\n' \"$(dirname $(dirname $(readlink -f $(command -v javac))))\" | sudo tee /opt/actions-runner/.env >/dev/null",
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
      "sudo -u gha-runner env EXPECTED_TRIVY='${var.trivy_version}' EXPECTED_SONARSCANNER='${var.dotnet_sonarscanner_version}' bash /tmp/smoke-test-linux.sh",
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
