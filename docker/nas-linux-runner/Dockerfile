# Beefy Linux GitHub Actions runner for the TrueNAS NAS group (Docker app, shares the GPU).
# CUDA devel base gives nvcc + CUDA libs so GPU jobs can build AND run; the TrueNAS nvidia
# runtime injects the host driver. Set CUDA_BASE to a -runtime image (or a plain ubuntu) if
# you don't need nvcc / GPU.
ARG CUDA_BASE=nvidia/cuda:12.6.2-devel-ubuntu24.04
FROM ${CUDA_BASE}

ARG RUNNER_VERSION=2.336.0
ARG DOTNET_CHANNEL=10.0
# Android (for .NET MAUI/Android + Gradle builds). Set INSTALL_ANDROID=0 to skip.
ARG INSTALL_ANDROID=1
ARG JDK_PACKAGE=openjdk-17-jdk
ARG ANDROID_API=35
ARG ANDROID_BUILD_TOOLS=35.0.0
ARG ANDROID_CMDLINE_TOOLS=11076708
ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk
ENV PATH="/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:${PATH}"

# CI toolchain (mirrors the Proxmox linux image): build tooling + Native AOT prereqs +
# language toolchains (golang-go, ruby-full; JDK comes with the Android block below).
# GL/EGL runtime libs (libglvnd dispatch + Mesa software fallback): .NET graphics stacks
# (SkiaSharp GPU, OpenGL/EGL offscreen render) dlopen libEGL.so.1 / libGL.so.1 at runtime —
# absent on the CUDA base. The nvidia runtime injects the GPU driver; libglvnd routes to it,
# Mesa (libgl1-mesa-dri / libegl-mesa0) is the CPU fallback when no GPU is attached.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang zlib1g-dev cmake ninja-build mingw-w64 binutils gdb \
      git curl wget unzip zip jq ca-certificates pkg-config sqlite3 ffmpeg \
      python3 python3-pip python3-venv sudo gnupg apt-transport-https \
      golang-go ruby-full openjdk-17-jdk \
      libglvnd0 libgl1 libglx0 libegl1 libgles2 libgl1-mesa-dri libegl-mesa0 \
      libasound2-dev libpulse-dev libudev-dev \
 && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# .NET 10 SDK + PowerShell 7 (Microsoft feed) + Node.js LTS (NodeSource).
RUN curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o /tmp/ms.deb \
 && dpkg -i /tmp/ms.deb && rm -f /tmp/ms.deb && apt-get update \
 && apt-get install -y "dotnet-sdk-${DOTNET_CHANNEL}" powershell \
 && curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

# Rust (rustup) for CodeQL Rust — system install under /opt/rust, on PATH for all users.
ENV RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust PATH="/opt/rust/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable \
 && chmod -R a+rX /opt/rust

# Code-quality scanners: Trivy + SonarScanner (dotnet tool + generic CLI), on PATH.
# All pinned. Trivy is checksum-verified; no vuln DB is baked (the workflow fetches it).
ARG TRIVY_VERSION=0.74.0
ARG SONAR_SCANNER_VERSION=8.1.0.6389
ARG DOTNET_SONARSCANNER_VERSION=11.2.1
ENV PATH="/opt/dotnet-tools:/opt/sonar-scanner/bin:${PATH}"
RUN curl -fsSLO "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
 && curl -fsSLO "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt" \
 && grep "trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" "trivy_${TRIVY_VERSION}_checksums.txt" | sha256sum -c - \
 && tar -xzf "trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" -C /usr/local/bin trivy && rm -f trivy_${TRIVY_VERSION}_* \
 && dotnet tool install --tool-path /opt/dotnet-tools --version "${DOTNET_SONARSCANNER_VERSION}" dotnet-sonarscanner \
 && curl -fsSL -o /tmp/sonar.zip "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}.zip" \
 && unzip -q /tmp/sonar.zip -d /opt && mv "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}" /opt/sonar-scanner && rm -f /tmp/sonar.zip \
 && chmod -R a+rX /opt/dotnet-tools /opt/sonar-scanner

# Cloud/IaC CLIs, mirroring the Proxmox images. OpenTofu and TFLint are SHA-256 verified
# against their published checksum files; Azure CLI comes from the Microsoft apt repo added
# above (apt verifies its GPG chain). AWS CLI v2 ships a GPG signature rather than a checksum
# file, so it is version-pinned but not verified here.
ARG OPENTOFU_VERSION=1.12.6
ARG TFLINT_VERSION=0.64.0
ARG AWSCLI_VERSION=2.36.28
ARG WRANGLER_VERSION=4.125.0
RUN curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_amd64.zip" \
 && curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_SHA256SUMS" \
 && grep " tofu_${OPENTOFU_VERSION}_linux_amd64.zip$" "tofu_${OPENTOFU_VERSION}_SHA256SUMS" | sha256sum -c - \
 && unzip -o -q "tofu_${OPENTOFU_VERSION}_linux_amd64.zip" tofu -d /usr/local/bin && chmod 0755 /usr/local/bin/tofu \
 && rm -f tofu_${OPENTOFU_VERSION}_* \
 && curl -fsSL -o tflint_linux_amd64.zip "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip" \
 && curl -fsSL -o tflint_checksums.txt "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/checksums.txt" \
 && grep " tflint_linux_amd64.zip$" tflint_checksums.txt | sha256sum -c - \
 && unzip -o -q tflint_linux_amd64.zip tflint -d /usr/local/bin && chmod 0755 /usr/local/bin/tflint \
 && rm -f tflint_linux_amd64.zip tflint_checksums.txt \
 && curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
 && unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2 && /tmp/awscliv2/aws/install --update \
 && rm -rf /tmp/awscliv2 /tmp/awscliv2.zip \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg \
 && chmod 0644 /etc/apt/keyrings/microsoft.gpg \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/azure-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends azure-cli && rm -rf /var/lib/apt/lists/* \
 && npm install -g "wrangler@${WRANGLER_VERSION}"

# Android: JDK 17 + Android SDK (cmdline-tools, platform, build-tools) + the .NET android
# workload (for MAUI/Android + Gradle). ~2-3 GB; set INSTALL_ANDROID=0 to skip.
RUN if [ "$INSTALL_ANDROID" = "1" ]; then set -eux; \
      apt-get update && apt-get install -y --no-install-recommends "$JDK_PACKAGE" && rm -rf /var/lib/apt/lists/*; \
      mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"; \
      curl -fsSL -o /tmp/cmt.zip "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip"; \
      unzip -q /tmp/cmt.zip -d "$ANDROID_SDK_ROOT/cmdline-tools"; \
      mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"; \
      rm -f /tmp/cmt.zip; \
      yes | sdkmanager --licenses >/dev/null; \
      sdkmanager "platform-tools" "platforms;android-${ANDROID_API}" "build-tools;${ANDROID_BUILD_TOOLS}"; \
      dotnet workload install android --skip-manifest-update; \
    fi

# Non-root runner user; video/render groups for /dev/dri access (nvidia /dev/nvidia* is
# handled by the runtime). Create the groups first — the base image may lack 'render'.
RUN useradd -m -s /bin/bash runner \
 && groupadd -f video && groupadd -f render \
 && usermod -aG video,render runner

# Actions runner package (unregistered).
RUN mkdir -p /opt/actions-runner && cd /opt/actions-runner \
 && curl -fsSL -o runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && tar xzf runner.tar.gz && rm -f runner.tar.gz \
 && ./bin/installdependencies.sh \
 && mkdir -p /opt/actions-runner/_work \
 && chown -R runner:runner /opt/actions-runner && { chown -R runner:runner /opt/android-sdk 2>/dev/null || true; }

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER runner
WORKDIR /opt/actions-runner
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
