#!/bin/bash
# Covers the package, swap, service-account, and directory steps of runbook
# section 2. It does NOT reboot (do that manually once after first boot to
# apply the kernel upgrade) and does NOT install AWS CLI v2, whose
# signature verification stays a manual runbook step.
set -euo pipefail

COMPLETION_MARKER=/var/log/chatto-launch.complete
PREPARE_BOOT_ID=/var/log/chatto-launch.boot-id
rm -f "${COMPLETION_MARKER}"
rm -f "${PREPARE_BOOT_ID}"

exec > >(tee -a /var/log/chatto-launch.log |
  logger -t chatto-launch -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive

echo "Starting Chatto base-instance preparation"

# First boot races unattended-upgrades for the dpkg lock. Keep the lock timeout
# and retry transient APT failures because Lightsail launch scripts do not
# automatically rerun.
APT_OPTS=(-o DPkg::Lock::Timeout=300)

apt_retry() {
  local attempt
  local delay

  for attempt in 1 2 3 4 5; do
    if apt-get "${APT_OPTS[@]}" "$@"; then
      return 0
    fi

    if [ "${attempt}" -eq 5 ]; then
      echo "APT operation failed after ${attempt} attempts: apt-get $*" >&2
      return 1
    fi

    delay=$((attempt * 5))
    [ "${delay}" -le 20 ] || delay=20
    echo "APT operation failed (attempt ${attempt}/5); retrying in ${delay}s" >&2
    sleep "${delay}"
  done
}

create_swap() {
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
}

apt_retry update

# Activate swap before the upgrade and package installation can create their
# peak memory pressure.
create_swap

apt_retry full-upgrade -y
apt_retry install -y \
  ca-certificates \
  curl \
  jq \
  tar \
  age \
  unzip \
  gnupg \
  unattended-upgrades

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

cat /proc/sys/kernel/random/boot_id > "${PREPARE_BOOT_ID}"
touch "${COMPLETION_MARKER}"
echo "Chatto base-instance preparation completed successfully"
echo "Still required manually: reboot for the kernel upgrade, then AWS CLI v2 install (runbook section 2)"
