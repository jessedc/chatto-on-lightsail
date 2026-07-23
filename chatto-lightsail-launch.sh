#!/bin/bash
# Covers the package, swap, service-account, and directory steps of runbook
# section 2. It does NOT reboot (do that manually once after first boot to
# apply the kernel upgrade) and does NOT install AWS CLI v2, whose
# signature verification stays a manual runbook step.
set -euo pipefail

exec > >(tee -a /var/log/chatto-launch.log |
  logger -t chatto-launch -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive

echo "Starting Chatto base-instance preparation"

# First boot races unattended-upgrades for the dpkg lock; wait instead of
# dying under set -e, because user data never re-runs.
APT_OPTS=(-o DPkg::Lock::Timeout=300)

apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" full-upgrade -y
apt-get "${APT_OPTS[@]}" install -y \
  ca-certificates \
  curl \
  jq \
  tar \
  age \
  unzip \
  gnupg

# Create a 1 GiB emergency swap file. Recreate it if a previous partial run
# left one with the wrong size.
if [ -f /swapfile ] &&
  [ "$(stat -c %s /swapfile)" -ne $((1024 * 1024 * 1024)) ]; then
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
fi

if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile
fi

chmod 600 /swapfile

if ! blkid -p -s TYPE -o value /swapfile 2>/dev/null |
  grep -qx swap; then
  mkswap /swapfile
fi

if ! swapon --show=NAME --noheadings |
  grep -qx '/swapfile'; then
  swapon /swapfile
fi

if ! grep -Fxq '/swapfile none swap sw 0 0' /etc/fstab; then
  printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab
fi

printf '%s\n' 'vm.swappiness=10' \
  > /etc/sysctl.d/90-chatto-memory.conf
sysctl --system

# Create the dedicated service account.
if ! getent passwd chatto >/dev/null; then
  useradd --system --create-home \
    --home-dir /var/lib/chatto \
    --shell /usr/sbin/nologin \
    chatto
fi

install -d -o chatto -g chatto -m 0750 \
  /etc/chatto \
  /var/lib/chatto/data \
  /var/lib/chatto/certs

touch /var/log/chatto-launch.complete
echo "Chatto base-instance preparation completed successfully"
echo "Still required manually: reboot for the kernel upgrade, then AWS CLI v2 install (runbook section 2)"
