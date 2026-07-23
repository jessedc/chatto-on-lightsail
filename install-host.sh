#!/bin/bash
# Prepare or install Chatto on an existing Debian 13 Lightsail instance.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=chatto-operator-lib.sh
source "${SCRIPT_DIR}/chatto-operator-lib.sh"

ACTION=
ENV_FILE=
CREDENTIALS_FILE=
SKIP_OWNER=false
INSTALL_TEMP_DIR=
AWS_CONFIG_TEMP=
AWS_CREDENTIALS_TEMP=
AWS_CLI_FINGERPRINT=FB5DB77FD5C118B80511ADA8A6310ACC4672475C

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-host.sh prepare
  sudo ./install-host.sh install --env FILE [--credentials FILE] [--skip-owner]

prepare
  Idempotently installs base packages, swap, the chatto service account, and
  private directories. Reboot the instance after this phase.

install
  Requires the completed prepare phase and reboot. It installs signature-
  verified AWS CLI v2, checksum-verified Chatto v0.4.14, configuration,
  systemd units, backup automation, and security-update policy.

--credentials FILE
  Read AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from a mode-0600 literal
  KEY=VALUE file produced by provision-aws.sh. If omitted and credentials are
  not already installed, the script prompts without echoing the secret.

--skip-owner
  Do not create the first owner account. The command prints the exact follow-up
  action and verification will remain incomplete until an owner exists.
EOF
}

cleanup() {
  if [[ "${AWS_CONFIG_TEMP}" == /etc/chatto/aws/.config.* ]]; then
    rm -f -- "${AWS_CONFIG_TEMP}"
  fi
  if [[ "${AWS_CREDENTIALS_TEMP}" == /etc/chatto/aws/.credentials.* ]]; then
    rm -f -- "${AWS_CREDENTIALS_TEMP}"
  fi
  if [ -n "${INSTALL_TEMP_DIR}" ] &&
    [[ "${INSTALL_TEMP_DIR}" == /tmp/chatto-host-install.* ]]; then
    rm -rf -- "${INSTALL_TEMP_DIR}"
  fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    prepare | install)
      [ -z "${ACTION}" ] || operator_die "choose only one action"
      ACTION=$1
      shift
      ;;
    --env)
      [ "$#" -ge 2 ] || operator_die "--env requires a file"
      ENV_FILE=$2
      shift 2
      ;;
    --credentials)
      [ "$#" -ge 2 ] || operator_die "--credentials requires a file"
      CREDENTIALS_FILE=$2
      shift 2
      ;;
    --skip-owner)
      SKIP_OWNER=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      operator_die "unknown argument: $1"
      ;;
  esac
done

[ -n "${ACTION}" ] || {
  usage >&2
  operator_die "prepare or install is required"
}
require_root

require_debian_13() {
  [ -r /etc/os-release ] ||
    operator_die "/etc/os-release is unavailable"
  # shellcheck disable=SC1091
  source /etc/os-release
  [ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ] ||
    operator_die "this installer is qualified only for Debian 13"
}

require_artifact() {
  [ -f "${SCRIPT_DIR}/$1" ] ||
    operator_die "repository artifact is missing: $1"
}

run_as_chatto() {
  (
    cd /var/lib/chatto
    runuser -u chatto -- "$@"
  )
}

install_aws_cli() {
  local aws_arch
  local archive_url
  local fingerprint
  local gpg_dir="${INSTALL_TEMP_DIR}/gnupg"
  local install_args=()

  if [ -x /usr/local/bin/aws ] &&
    /usr/local/bin/aws --version 2>&1 | grep -q '^aws-cli/2\.'; then
    operator_log "AWS CLI v2 is already installed"
    return
  fi

  case "$(uname -m)" in
    x86_64)
      aws_arch=x86_64
      ;;
    aarch64 | arm64)
      aws_arch=aarch64
      ;;
    *)
      operator_die "AWS CLI v2 does not support host architecture $(uname -m)"
      ;;
  esac

  archive_url="https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip"
  mkdir -m 0700 "${gpg_dir}"
  GNUPGHOME=${gpg_dir} gpg --batch \
    --import "${SCRIPT_DIR}/aws-cli-public-key.asc" >/dev/null 2>&1
  fingerprint=$(GNUPGHOME=${gpg_dir} gpg --batch --with-colons \
    --fingerprint A6310ACC4672475C |
    awk -F: '$1 == "fpr" { print $10; exit }')
  [ "${fingerprint}" = "${AWS_CLI_FINGERPRINT}" ] ||
    operator_die "the bundled AWS CLI signing key has an unexpected fingerprint"

  operator_log "Downloading and signature-verifying AWS CLI v2"
  curl -fsSLo "${INSTALL_TEMP_DIR}/awscliv2.zip" "${archive_url}"
  curl -fsSLo "${INSTALL_TEMP_DIR}/awscliv2.sig" "${archive_url}.sig"
  GNUPGHOME=${gpg_dir} gpg --batch --verify \
    "${INSTALL_TEMP_DIR}/awscliv2.sig" \
    "${INSTALL_TEMP_DIR}/awscliv2.zip"
  unzip -q "${INSTALL_TEMP_DIR}/awscliv2.zip" -d "${INSTALL_TEMP_DIR}"

  if [ -d /usr/local/aws-cli ]; then
    install_args+=(--update)
  fi
  "${INSTALL_TEMP_DIR}/aws/install" \
    --bin-dir /usr/local/bin \
    --install-dir /usr/local/aws-cli \
    "${install_args[@]}"
  /usr/local/bin/aws --version 2>&1 | grep -q '^aws-cli/2\.' ||
    operator_die "AWS CLI v2 installation did not validate"
}

install_chatto_binary() {
  local chatto_arch
  local asset
  local checksums
  local release_url
  local current_version=

  case "$(uname -m)" in
    x86_64)
      chatto_arch=x86_64
      ;;
    aarch64 | arm64)
      chatto_arch=arm64
      ;;
    *)
      operator_die "Chatto does not publish a binary for $(uname -m)"
      ;;
  esac

  if [ -x /usr/local/bin/chatto ]; then
    current_version=$(/usr/local/bin/chatto version 2>/dev/null || true)
    if [ "${current_version}" = \
      "chatto version ${CHATTO_VERSION#v}" ]; then
      operator_log "Chatto ${CHATTO_VERSION} is already installed"
      return
    fi
    operator_die \
      "a different Chatto binary is installed; use the manual upgrade/rollback procedure"
  fi

  asset="chatto_Linux_${chatto_arch}.tar.gz"
  checksums="chatto_${CHATTO_VERSION#v}_checksums.txt"
  release_url="https://github.com/chattocorp/chatto/releases/download/${CHATTO_VERSION}"

  operator_log "Downloading and checksum-verifying Chatto ${CHATTO_VERSION}"
  curl -fsSLo "${INSTALL_TEMP_DIR}/${asset}" "${release_url}/${asset}"
  curl -fsSLo "${INSTALL_TEMP_DIR}/${checksums}" \
    "${release_url}/${checksums}"
  (
    cd "${INSTALL_TEMP_DIR}"
    grep "  ${asset}\$" "${checksums}" | sha256sum --check -
    tar -xzf "${asset}"
  )
  install -o root -g root -m 0755 \
    "${INSTALL_TEMP_DIR}/chatto" /usr/local/bin/chatto
  [ "$(/usr/local/bin/chatto version)" = \
    "chatto version ${CHATTO_VERSION#v}" ] ||
    operator_die "installed Chatto version does not match ${CHATTO_VERSION}"
}

write_runtime_environment() {
  local environment_temp="${INSTALL_TEMP_DIR}/chatto.env"
  local deployment_temp="${INSTALL_TEMP_DIR}/deployment.env"
  local backup_temp="${INSTALL_TEMP_DIR}/backup.env"

  {
    printf 'CHATTO_WEBSERVER_URL=https://%s\n' "${CHAT_HOST}"
    printf 'CHATTO_WEBSERVER_PORT=443\n'
    printf 'CHATTO_WEBSERVER_ALLOWED_ORIGINS=https://%s\n' "${CHAT_HOST}"
    printf 'CHATTO_WEBSERVER_API_COMPRESSION=false\n'
    printf 'CHATTO_WEBSERVER_WEBSOCKET_COMPRESSION=false\n'
    printf 'CHATTO_WEBSERVER_TLS_ENABLED=true\n'
    printf 'CHATTO_WEBSERVER_TLS_DOMAIN=%s\n' "${CHAT_HOST}"
    printf 'CHATTO_WEBSERVER_TLS_EMAIL=%s\n' "${ACME_CONTACT_EMAIL}"
    printf 'CHATTO_WEBSERVER_TLS_CACHE_DIR=/var/lib/chatto/certs\n'
    printf 'CHATTO_WEBSERVER_TLS_HTTP_PORT=80\n'
    printf 'CHATTO_AUTH_DIRECT_REGISTRATION=false\n'
    printf 'CHATTO_SMTP_ENABLED=false\n'
    printf 'CHATTO_LIMITS_MAX_USERS=10\n'
    printf 'CHATTO_OPERATOR_API_ENABLED=true\n'
    printf 'CHATTO_OPERATOR_API_SOCKET_PATH=/run/chatto/operator.sock\n'
    printf 'CHATTO_VIDEO_ENABLED=false\n'
    printf 'CHATTO_LIVEKIT_ENABLED=false\n'
    printf 'CHATTO_NATS_REPLICAS=1\n'
    printf 'CHATTO_NATS_EMBEDDED_ENABLED=true\n'
    printf 'CHATTO_NATS_EMBEDDED_PORT=4222\n'
    printf 'CHATTO_NATS_EMBEDDED_BIND_ADDRESS=127.0.0.1\n'
    printf 'CHATTO_NATS_EMBEDDED_HTTP_PORT=0\n'
    printf 'CHATTO_NATS_EMBEDDED_DATA_DIR=/var/lib/chatto/data\n'
    printf 'CHATTO_CORE_ASSETS_STORAGE_BACKEND=nats\n'
    printf 'CHATTO_CORE_ASSETS_MAX_UPLOAD_SIZE=10MB\n'
    printf 'CHATTO_CORE_ASSETS_CACHE_ENABLED=false\n'
  } > "${environment_temp}"

  write_deployment_env "${deployment_temp}"
  {
    printf 'CHATTO_S3_BUCKET=%s\n' "${CHATTO_S3_BUCKET}"
    printf 'CHATTO_BACKUP_PREFIX=%s\n' "${CHATTO_BACKUP_PREFIX}"
    printf 'CHATTO_AWS_REGION=%s\n' "${CHATTO_AWS_REGION}"
    printf 'CHATTO_AWS_ACCOUNT_ID=%s\n' "${CHATTO_AWS_ACCOUNT_ID}"
    printf 'CHATTO_SNS_TOPIC_ARN=%s\n' "${CHATTO_SNS_TOPIC_ARN}"
  } > "${backup_temp}"

  install -o root -g root -m 0644 \
    "${environment_temp}" /etc/chatto/chatto.env
  install -o root -g root -m 0600 \
    "${deployment_temp}" /etc/chatto/deployment.env
  install -o root -g root -m 0644 \
    "${backup_temp}" /etc/chatto/backup.env
}

load_credentials_file() {
  local credentials_file=$1
  local line
  local name
  local value
  local seen='|'
  local mode

  [ -f "${credentials_file}" ] && [ ! -L "${credentials_file}" ] ||
    operator_die "credential input must be a regular, non-symlink file"
  mode=$(stat -c %a "${credentials_file}")
  (( (8#${mode} & 8#077) == 0 )) ||
    operator_die "credential input must not be readable by group or other users"

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  while IFS= read -r line || [ -n "${line}" ]; do
    line=${line%$'\r'}
    case "${line}" in
      '' | \#*)
        continue
        ;;
    esac
    [[ "${line}" == *=* ]] ||
      operator_die "invalid credential input line"
    name=${line%%=*}
    value=${line#*=}
    case "${name}" in
      AWS_ACCESS_KEY_ID | AWS_SECRET_ACCESS_KEY)
        ;;
      *)
        operator_die "unsupported credential variable: ${name}"
        ;;
    esac
    case "${seen}" in
      *"|${name}|"*)
        operator_die "duplicate credential variable: ${name}"
        ;;
    esac
    printf -v "${name}" '%s' "${value}"
    seen="${seen}${name}|"
  done < "${credentials_file}"
}

verify_aws_profile() {
  local config_file=$1
  local credentials_file=$2
  local identity_json=
  local expected_arn

  for _ in $(seq 1 6); do
    if identity_json=$(runuser -u chatto -- env \
      AWS_CONFIG_FILE="${config_file}" \
      AWS_SHARED_CREDENTIALS_FILE="${credentials_file}" \
      AWS_PROFILE=chatto-backup \
      AWS_PAGER= \
      /usr/local/bin/aws sts get-caller-identity \
      --output json 2>/dev/null); then
      break
    fi
    sleep 5
  done
  [ -n "${identity_json}" ] ||
    operator_die "the chatto-backup AWS credentials did not authenticate"
  [ "$(jq -er '.Account' <<<"${identity_json}")" = \
    "${CHATTO_AWS_ACCOUNT_ID}" ] ||
    operator_die "the chatto-backup credentials use the wrong AWS account"
  expected_arn="arn:aws:iam::${CHATTO_AWS_ACCOUNT_ID}:user/chatto-backup"
  [ "$(jq -er '.Arn' <<<"${identity_json}")" = "${expected_arn}" ] ||
    operator_die "the runtime credentials do not belong to chatto-backup"
}

configure_runtime_credentials() {
  local config_temp
  local credentials_temp

  install -d -o chatto -g chatto -m 0700 /etc/chatto/aws
  if [ -s /etc/chatto/aws/credentials ] &&
    [ -s /etc/chatto/aws/config ] &&
    [ -z "${CREDENTIALS_FILE}" ]; then
    operator_log "Protected AWS runtime credentials are already installed"
    verify_aws_profile \
      /etc/chatto/aws/config /etc/chatto/aws/credentials
    return
  fi

  if [ -n "${CREDENTIALS_FILE}" ]; then
    load_credentials_file "${CREDENTIALS_FILE}"
  else
    [ -t 0 ] ||
      operator_die "use --credentials FILE when no interactive terminal is available"
    IFS= read -r -p 'chatto-backup AWS access key ID: ' \
      AWS_ACCESS_KEY_ID </dev/tty
    IFS= read -r -s -p 'chatto-backup AWS secret access key: ' \
      AWS_SECRET_ACCESS_KEY </dev/tty
    printf '\n' >/dev/tty
  fi

  [[ "${AWS_ACCESS_KEY_ID:-}" =~ ^A[A-Z0-9]{19}$ ]] ||
    operator_die "AWS access key ID has an unexpected format"
  [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] ||
    operator_die "AWS secret access key is empty"
  [ "${#AWS_SECRET_ACCESS_KEY}" -eq 40 ] &&
    [[ "${AWS_SECRET_ACCESS_KEY}" =~ ^[A-Za-z0-9/+=]+$ ]] ||
    operator_die "AWS secret access key has an unexpected format"

  config_temp=$(mktemp /etc/chatto/aws/.config.XXXXXX)
  credentials_temp=$(mktemp /etc/chatto/aws/.credentials.XXXXXX)
  AWS_CONFIG_TEMP=${config_temp}
  AWS_CREDENTIALS_TEMP=${credentials_temp}
  {
    printf '[profile chatto-backup]\n'
    printf 'region = %s\n' "${CHATTO_AWS_REGION}"
    printf 'output = json\n'
  } > "${config_temp}"
  {
    printf '[chatto-backup]\n'
    printf 'aws_access_key_id = %s\n' "${AWS_ACCESS_KEY_ID}"
    printf 'aws_secret_access_key = %s\n' "${AWS_SECRET_ACCESS_KEY}"
  } > "${credentials_temp}"
  chown chatto:chatto "${config_temp}" "${credentials_temp}"
  chmod 0600 "${config_temp}" "${credentials_temp}"
  verify_aws_profile "${config_temp}" "${credentials_temp}"
  mv -f -- "${config_temp}" /etc/chatto/aws/config
  AWS_CONFIG_TEMP=
  mv -f -- "${credentials_temp}" /etc/chatto/aws/credentials
  AWS_CREDENTIALS_TEMP=
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

configure_backup_passphrase() {
  local passphrase
  local confirmation
  local passphrase_temp

  if [ -s /etc/chatto/backup-passphrase ]; then
    operator_log "Backup encryption passphrase is already installed"
    return
  fi
  [ -t 0 ] ||
    operator_die "an interactive terminal is required to set the backup passphrase"

  IFS= read -r -s -p \
    'Backup passphrase from the password manager (minimum 24 characters): ' \
    passphrase </dev/tty
  printf '\n' >/dev/tty
  IFS= read -r -s -p 'Confirm backup passphrase: ' confirmation </dev/tty
  printf '\n' >/dev/tty
  [ "${passphrase}" = "${confirmation}" ] ||
    operator_die "backup passphrases did not match"
  [ "${#passphrase}" -ge 24 ] ||
    operator_die "backup passphrase must contain at least 24 characters"
  [[ "${passphrase}" != *$'\n'* && "${passphrase}" != *$'\r'* ]] ||
    operator_die "backup passphrase must be one line"

  passphrase_temp=$(mktemp /etc/chatto/.backup-passphrase.XXXXXX)
  printf '%s\n' "${passphrase}" > "${passphrase_temp}"
  chown chatto:chatto "${passphrase_temp}"
  chmod 0600 "${passphrase_temp}"
  mv -f -- "${passphrase_temp}" /etc/chatto/backup-passphrase
  unset passphrase confirmation
}

install_repository_artifacts() {
  install -d -o chatto -g chatto -m 0700 \
    /var/lib/chatto/backups /var/lib/chatto/operations

  install -o root -g root -m 0755 \
    "${SCRIPT_DIR}/chatto-lightsail-backup.sh" \
    "${SCRIPT_DIR}/chatto-lightsail-alert.sh" \
    "${SCRIPT_DIR}/chatto-lightsail-reboot-required.sh" \
    /usr/local/sbin/

  install -o root -g root -m 0644 \
    "${SCRIPT_DIR}/chatto.service" \
    "${SCRIPT_DIR}/chatto-backup.service" \
    "${SCRIPT_DIR}/chatto-backup.timer" \
    "${SCRIPT_DIR}/chatto-backup-alert@.service" \
    "${SCRIPT_DIR}/chatto-reboot-required.service" \
    "${SCRIPT_DIR}/chatto-reboot-required.timer" \
    /etc/systemd/system/

  install -o root -g root -m 0644 \
    "${SCRIPT_DIR}/chatto-auto-upgrades.conf" \
    /etc/apt/apt.conf.d/20auto-upgrades
  install -o root -g root -m 0644 \
    "${SCRIPT_DIR}/chatto-unattended-upgrades.conf" \
    /etc/apt/apt.conf.d/52chatto-unattended-upgrades
}

configure_owner() {
  local owner_json
  local owner_exists=false
  local owner_has_role=false
  local owner_marker=/etc/chatto/owner-created

  if [ -s "${owner_marker}" ]; then
    operator_log "Owner creation was already recorded"
    return
  fi

  owner_json=$(run_as_chatto /usr/local/bin/chatto operator \
    --config /etc/chatto/chatto.toml \
    --operator-socket /run/chatto/operator.sock \
    --json user list --search "${OWNER_LOGIN}" --limit 100)
  if jq -e --arg login "${OWNER_LOGIN}" \
    '.users[]? | select(.user.login == $login)' \
    <<<"${owner_json}" >/dev/null; then
    owner_exists=true
    if jq -e --arg login "${OWNER_LOGIN}" \
      '.users[]? | select(.user.login == $login) |
        .roles | index("owner") != null' \
      <<<"${owner_json}" >/dev/null; then
      owner_has_role=true
    fi
  fi

  if [ "${owner_exists}" = true ]; then
    [ "${owner_has_role}" = true ] ||
      operator_die "OWNER_LOGIN already exists without the owner role"
  elif [ "${SKIP_OWNER}" = true ]; then
    operator_warn "owner creation skipped by request"
    return
  else
    [ -t 0 ] ||
      operator_die "an interactive terminal is required to create the owner"
    operator_log "Creating owner ${OWNER_LOGIN}; Chatto will prompt for its password"
    run_as_chatto /usr/local/bin/chatto operator \
      --config /etc/chatto/chatto.toml \
      --operator-socket /run/chatto/operator.sock \
      user create \
      --login "${OWNER_LOGIN}" \
      --display-name "${OWNER_DISPLAY_NAME}" \
      --role owner
  fi

  printf '%s\n' "${OWNER_LOGIN}" > "${owner_marker}"
  chown root:root "${owner_marker}"
  chmod 0600 "${owner_marker}"
}

if [ "${ACTION}" = prepare ]; then
  require_debian_13
  require_artifact chatto-lightsail-launch.sh
  operator_log "Running idempotent base-instance preparation"
  bash "${SCRIPT_DIR}/chatto-lightsail-launch.sh"
  operator_log "Prepare phase completed. Reboot now, reconnect, then run:"
  operator_log "  sudo ./install-host.sh install --env chatto-provisioned.env --credentials chatto-access-key.env"
  exit 0
fi

[ -n "${ENV_FILE}" ] || {
  usage >&2
  operator_die "--env is required for the install action"
}
require_debian_13
[ -f /var/log/chatto-launch.complete ] ||
  operator_die "prepare phase is incomplete: /var/log/chatto-launch.complete is absent"
if [ -s /var/log/chatto-launch.boot-id ] &&
  [ "$(< /var/log/chatto-launch.boot-id)" = \
    "$(< /proc/sys/kernel/random/boot_id)" ]; then
  operator_die "the instance has not rebooted since the prepare phase"
fi
[ ! -e /var/run/reboot-required ] ||
  operator_die "Debian still requires a reboot; reboot and rerun the install phase"

for artifact in \
  aws-cli-public-key.asc \
  chatto.service \
  chatto-backup.service \
  chatto-backup.timer \
  chatto-backup-alert@.service \
  chatto-reboot-required.service \
  chatto-reboot-required.timer \
  chatto-lightsail-backup.sh \
  chatto-lightsail-alert.sh \
  chatto-lightsail-reboot-required.sh \
  chatto-auto-upgrades.conf \
  chatto-unattended-upgrades.conf; do
  require_artifact "${artifact}"
done

load_deployment_env "${ENV_FILE}"
validate_provisioned_deployment_env
require_command curl
require_command gpg
require_command jq
require_command mktemp
require_command runuser
require_command sha256sum
require_command systemctl
require_command systemd-analyze
require_command unzip

INSTALL_TEMP_DIR=$(mktemp -d /tmp/chatto-host-install.XXXXXX)
install_aws_cli
install_chatto_binary

if [ ! -s /etc/chatto/chatto.toml ]; then
  operator_log "Generating Chatto secret configuration"
  run_as_chatto /usr/local/bin/chatto init \
    --config /etc/chatto/chatto.toml
fi
chown chatto:chatto /etc/chatto/chatto.toml
chmod 0600 /etc/chatto/chatto.toml

write_runtime_environment
install_repository_artifacts
configure_runtime_credentials
configure_backup_passphrase

operator_log "Validating installed systemd units"
systemd-analyze verify \
  /etc/systemd/system/chatto.service \
  /etc/systemd/system/chatto-backup.service \
  /etc/systemd/system/chatto-backup.timer \
  /etc/systemd/system/chatto-backup-alert@.service \
  /etc/systemd/system/chatto-reboot-required.service \
  /etc/systemd/system/chatto-reboot-required.timer
systemctl daemon-reload
systemctl enable unattended-upgrades.service
systemctl start unattended-upgrades.service
systemctl enable --now chatto.service

for _ in $(seq 1 30); do
  if systemctl is-active --quiet chatto.service &&
    [ -S /run/chatto/operator.sock ]; then
    break
  fi
  sleep 2
done
systemctl is-active --quiet chatto.service ||
  operator_die "Chatto did not become active; inspect journalctl -u chatto"
[ -S /run/chatto/operator.sock ] ||
  operator_die "Chatto operator socket did not become ready"

configure_owner
systemctl enable --now \
  chatto-backup.timer chatto-reboot-required.timer

operator_log "Host installation completed successfully"
operator_log "Remove any transferred credential file after storing its secret safely."
operator_log "Next, run: sudo ./verify-deployment.sh --run-backup --send-alert"
