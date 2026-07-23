#!/bin/bash
set -euo pipefail

exec > >(tee -a /var/log/chatto-launch.log |
  logger -t chatto-launch -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive

echo "Starting Chatto base-instance preparation"

apt-get update
apt-get full-upgrade -y
apt-get install -y \
  ca-certificates \
  curl \
  jq \
  tar \
  age \
  unzip \
  gnupg

# Create a 1 GiB emergency swap file.
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
