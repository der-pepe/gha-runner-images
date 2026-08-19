#!/usr/bin/env bash
# Provision the HA template builder on THIS host (a Debian/Ubuntu LXC with ~2 GB RAM +
# a few GB disk). Installs Packer + Git + jq + xorriso, clones this repo, and installs
# the build timer. Run as root.
#
# After running, fill:
#   /etc/gha-builder/env         PROXMOX_TOKEN_ID / PROXMOX_TOKEN (build-privileged)
#   /etc/gha-builder/build.env   PROXMOX_URL / BUILD_KINDS / REPO_DIR (non-secret)
# then: systemctl start gha-template-builder.service   (or wait for the timer)
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/der-pepe/gha-runner-images.git}"
REPO_DIR="${REPO_DIR:-/opt/gha-runner-images}"
APP=/opt/gha-builder
CFG=/etc/gha-builder

echo "== dependencies (packer, git, jq, xorriso) =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends git jq curl xorriso ca-certificates gnupg
if ! command -v packer >/dev/null; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
  # shellcheck source=/dev/null
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${codename} main" \
    > /etc/apt/sources.list.d/hashicorp.list
  apt-get update -qq
  apt-get install -y packer
fi

echo "== repo checkout at ${REPO_DIR} =="
if [ -d "$REPO_DIR/.git" ]; then git -C "$REPO_DIR" pull --ff-only || true
else git clone "$REPO_URL" "$REPO_DIR"; fi

echo "== install builder script =="
install -d "$APP" "$CFG"
install -m 0755 "$SD/gha-template-builder.sh" "$APP/gha-template-builder.sh"

echo "== config =="
if [ ! -f "$CFG/build.env" ]; then
  cat > "$CFG/build.env" <<EOF
REPO_DIR=${REPO_DIR}
PROXMOX_URL=https://127.0.0.1:8006/api2/json
BUILD_KINDS=linux
EOF
  echo "  -> edit $CFG/build.env (PROXMOX_URL, BUILD_KINDS)"
fi
if [ ! -f "$CFG/env" ]; then
  printf '# builder secrets — chmod 600, never commit\nPROXMOX_TOKEN_ID=\nPROXMOX_TOKEN=\n' > "$CFG/env"
  chmod 600 "$CFG/env"
  echo "  -> FILL $CFG/env (PROXMOX_TOKEN_ID / PROXMOX_TOKEN, build-privileged)"
fi

echo "== systemd units =="
install -m 0644 "$SD/gha-template-builder.service" /etc/systemd/system/
install -m 0644 "$SD/gha-template-builder.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now gha-template-builder.timer

echo
echo "Installed. Fill $CFG/env, then:  systemctl start gha-template-builder.service"
echo "Timer: monthly (see gha-template-builder.timer). Logs: journalctl -u gha-template-builder -f"
echo "For HA: add this LXC to a Proxmox HA group (rootfs on Ceph)."
