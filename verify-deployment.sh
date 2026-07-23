#!/bin/bash
# Verify an installed Chatto Lightsail host and optionally exercise live paths.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=chatto-operator-lib.sh
source "${SCRIPT_DIR}/chatto-operator-lib.sh"

ENV_FILE=/etc/chatto/deployment.env
RUN_BACKUP=false
SEND_ALERT=false
RUN_CAPACITY=false

usage() {
  cat <<'EOF'
Usage:
  sudo ./verify-deployment.sh [--env FILE] [--run-backup] [--send-alert]
      [--capacity]

The default verification is read-only. It checks the installed files,
systemd services and timers, HTTPS health, listening sockets, the restricted
AWS identity, and the newest S3 backup.

--run-backup
  Run a real encrypted backup and verify its remote object.

--send-alert
  Publish a test message to the configured SNS operations topic.

--capacity
  Run the 15-minute $5-instance capacity gate. Begin the documented two-browser
  messaging and 10 MB transfer workload before invoking this option.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)
      [ "$#" -ge 2 ] || operator_die "--env requires a file"
      ENV_FILE=$2
      shift 2
      ;;
    --run-backup)
      RUN_BACKUP=true
      shift
      ;;
    --send-alert)
      SEND_ALERT=true
      shift
      ;;
    --capacity)
      RUN_CAPACITY=true
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

require_root
load_deployment_env "${ENV_FILE}"
validate_provisioned_deployment_env

for command_name in \
  apt-config awk basename curl df grep journalctl jq ps runuser sha256sum \
  ss stat systemctl systemd-analyze tailscale; do
  require_command "${command_name}"
done

runtime_aws() {
  runuser -u chatto -- env \
    AWS_CONFIG_FILE=/etc/chatto/aws/config \
    AWS_SHARED_CREDENTIALS_FILE=/etc/chatto/aws/credentials \
    AWS_PROFILE=chatto-backup \
    AWS_PAGER= \
    /usr/local/bin/aws "$@"
}

require_file_state() {
  local path=$1
  local expected=$2
  local actual

  [ -e "${path}" ] || operator_die "required path is absent: ${path}"
  actual=$(stat -c '%U:%G %a' "${path}")
  [ "${actual}" = "${expected}" ] ||
    operator_die "${path} has ${actual}; expected ${expected}"
}

operator_log "Checking installed files and versions"
[ -f /var/log/chatto-launch.complete ] ||
  operator_die "base-instance completion marker is absent"
if [ -s /var/log/chatto-launch.boot-id ] &&
  [ "$(< /var/log/chatto-launch.boot-id)" = \
    "$(< /proc/sys/kernel/random/boot_id)" ]; then
  operator_die "the instance has not rebooted since the prepare phase"
fi
[ "$(/usr/local/bin/chatto version)" = \
  "chatto version ${CHATTO_VERSION#v}" ] ||
  operator_die "installed Chatto version does not match ${CHATTO_VERSION}"
/usr/local/bin/aws --version 2>&1 | grep -q '^aws-cli/2\.' ||
  operator_die "AWS CLI v2 is not installed"

require_file_state /etc/chatto/chatto.toml 'chatto:chatto 600'
require_file_state /etc/chatto/chatto.env 'root:root 644'
require_file_state /etc/chatto/deployment.env 'root:root 600'
require_file_state /etc/chatto/backup.env 'root:root 644'
require_file_state /etc/chatto/backup-passphrase 'chatto:chatto 600'
require_file_state /etc/chatto/aws/config 'chatto:chatto 600'
require_file_state /etc/chatto/aws/credentials 'chatto:chatto 600'
require_file_state /etc/chatto/owner-created 'root:root 600'

operator_log "Checking systemd units and timers"
systemd-analyze verify \
  /etc/systemd/system/chatto.service \
  /etc/systemd/system/chatto-backup.service \
  /etc/systemd/system/chatto-backup.timer \
  /etc/systemd/system/chatto-backup-alert@.service \
  /etc/systemd/system/chatto-reboot-required.service \
  /etc/systemd/system/chatto-reboot-required.timer
systemctl is-active --quiet chatto.service ||
  operator_die "chatto.service is not active"
systemctl is-enabled --quiet chatto.service ||
  operator_die "chatto.service is not enabled"
systemctl is-enabled --quiet chatto-backup.timer ||
  operator_die "chatto-backup.timer is not enabled"
systemctl is-active --quiet chatto-backup.timer ||
  operator_die "chatto-backup.timer is not active"
systemctl is-enabled --quiet chatto-reboot-required.timer ||
  operator_die "chatto-reboot-required.timer is not enabled"
systemctl is-active --quiet chatto-reboot-required.timer ||
  operator_die "chatto-reboot-required.timer is not active"
systemctl is-active --quiet unattended-upgrades.service ||
  operator_die "unattended-upgrades.service is not active"

operator_log "Checking HTTPS health and readiness"
for _ in $(seq 1 12); do
  if curl --fail --silent --show-error --max-time 10 \
    --resolve "${CHAT_HOST}:443:127.0.0.1" \
    "https://${CHAT_HOST}/healthz" >/dev/null &&
    curl --fail --silent --show-error --max-time 10 \
      --resolve "${CHAT_HOST}:443:127.0.0.1" \
      "https://${CHAT_HOST}/readyz" >/dev/null; then
    health_ready=true
    break
  fi
  health_ready=false
  sleep 5
done
[ "${health_ready}" = true ] ||
  operator_die "HTTPS health or readiness did not succeed"

http_headers=$(curl --silent --show-error --max-time 10 \
  --resolve "${CHAT_HOST}:80:127.0.0.1" \
  --head "http://${CHAT_HOST}/")
grep -Eiq '^location: https://' <<<"${http_headers}" ||
  operator_die "HTTP does not redirect to HTTPS"

operator_log "Checking listening sockets"
[ -n "$(ss -H -ltn 'sport = :80')" ] ||
  operator_die "nothing is listening on TCP 80"
[ -n "$(ss -H -ltn 'sport = :443')" ] ||
  operator_die "nothing is listening on TCP 443"
nats_listeners=$(ss -H -ltn 'sport = :4222')
[ -n "${nats_listeners}" ] ||
  operator_die "embedded NATS is not listening on TCP 4222"
if awk '{print $4}' <<<"${nats_listeners}" |
  grep -Evq '^127\.0\.0\.1:4222$'; then
  operator_die "embedded NATS is listening on a non-loopback address"
fi
[ -z "$(ss -H -ltn 'sport = :8222')" ] ||
  operator_die "the NATS monitoring port 8222 must be disabled"

root_use=$(df -P / | awk 'NR == 2 {gsub("%", "", $5); print $5}')
[ "${root_use}" -lt 70 ] ||
  operator_die "root filesystem use is ${root_use}%, which exceeds the 70% gate"

operator_log "Checking the owner account through the local operator socket"
owner_json=$(runuser -u chatto -- /usr/local/bin/chatto operator \
  --config /etc/chatto/chatto.toml \
  --operator-socket /run/chatto/operator.sock \
  --json user list --search "${OWNER_LOGIN}" --limit 100)
jq -e --arg login "${OWNER_LOGIN}" '
  .users[]? |
  select(.user.login == $login) |
  .roles | index("owner") != null
' <<<"${owner_json}" >/dev/null ||
  operator_die "the configured owner account or owner role was not found"

operator_log "Checking restricted AWS runtime identity"
identity_json=$(runtime_aws sts get-caller-identity --output json)
[ "$(jq -er '.Account' <<<"${identity_json}")" = "${CHATTO_AWS_ACCOUNT_ID}" ] ||
  operator_die "runtime credentials use the wrong AWS account"
expected_runtime_arn="arn:aws:iam::${CHATTO_AWS_ACCOUNT_ID}:user/chatto-backup"
[ "$(jq -er '.Arn' <<<"${identity_json}")" = "${expected_runtime_arn}" ] ||
  operator_die "runtime credentials do not belong to chatto-backup"

if [ "${SEND_ALERT}" = true ]; then
  operator_log "Publishing an SNS delivery test"
  runtime_aws sns publish \
    --topic-arn "${CHATTO_SNS_TOPIC_ARN}" \
    --region "${CHATTO_AWS_REGION}" \
    --subject "Chatto operations verification" \
    --message "Successful verification message from $(hostname --fqdn 2>/dev/null || hostname)" \
    --output json >/dev/null
fi

if [ "${RUN_BACKUP}" = true ]; then
  operator_log "Running a real encrypted backup"
  systemctl start chatto-backup.service
  systemctl is-failed --quiet chatto-backup.service &&
    operator_die "chatto-backup.service failed"
fi

operator_log "Checking the newest remote backup"
objects_json=$(runtime_aws s3api list-objects-v2 \
  --bucket "${CHATTO_S3_BUCKET}" \
  --prefix "${CHATTO_BACKUP_PREFIX}/" \
  --region "${CHATTO_AWS_REGION}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --output json)
latest_key=$(jq -er \
  '.Contents // [] | sort_by(.LastModified) | last | .Key // empty' \
  <<<"${objects_json}") ||
  operator_die "no remote backup exists below ${CHATTO_BACKUP_PREFIX}/"
[[ "${latest_key}" == "${CHATTO_BACKUP_PREFIX}/"* ]] ||
  operator_die "S3 returned an object outside the backup prefix"

head_json=$(runtime_aws s3api head-object \
  --bucket "${CHATTO_S3_BUCKET}" \
  --key "${latest_key}" \
  --region "${CHATTO_AWS_REGION}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --checksum-mode ENABLED \
  --output json)
remote_size=$(jq -er '.ContentLength' <<<"${head_json}")
remote_sha256=$(jq -er '.Metadata.sha256' <<<"${head_json}")
remote_checksum=$(jq -er '.ChecksumSHA256' <<<"${head_json}")
remote_encryption=$(jq -er '.ServerSideEncryption' <<<"${head_json}")
[[ "${remote_size}" =~ ^[1-9][0-9]*$ ]] ||
  operator_die "newest remote backup has an invalid size"
[[ "${remote_sha256}" =~ ^[0-9a-f]{64}$ ]] ||
  operator_die "newest remote backup lacks full-file SHA-256 metadata"
[ -n "${remote_checksum}" ] ||
  operator_die "newest remote backup lacks the S3 SHA-256 checksum"
[ "${remote_encryption}" = AES256 ] ||
  operator_die "newest remote backup is not encrypted with AES256"

archive_name=$(basename "${latest_key}")
local_archive="/var/lib/chatto/backups/${archive_name}"
if [ -f "${local_archive}" ]; then
  local_size=$(stat -c %s "${local_archive}")
  local_sha256=$(sha256sum "${local_archive}" | awk '{print $1}')
  [ "${local_size}" = "${remote_size}" ] ||
    operator_die "newest local and remote backup sizes differ"
  [ "${local_sha256}" = "${remote_sha256}" ] ||
    operator_die "newest local and remote backup SHA-256 values differ"
else
  operator_warn \
    "newest remote archive is not one of the two locally retained archives"
fi

operator_log "Checking unattended-upgrade policy"
apt_config=$(apt-config dump)
grep -Fq 'Unattended-Upgrade::Automatic-Reboot "false";' \
  <<<"${apt_config}" ||
  operator_die "automatic reboot is not explicitly disabled"
grep -Fq 'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";' \
  <<<"${apt_config}" ||
  operator_die "automatic reboot with users is not explicitly disabled"
grep -Fq "\${distro_id}:\${distro_codename}-security" \
  /etc/apt/apt.conf.d/52chatto-unattended-upgrades ||
  operator_die "the Debian security-only origin is not configured"

operator_log "Checking Tailscale administrative access"
systemctl is-active --quiet tailscaled ||
  operator_die "tailscaled is not active"
systemctl is-enabled --quiet tailscaled ||
  operator_die "tailscaled is not enabled"
tailscale_status=$(tailscale status --json)
[ "$(jq -er '.BackendState' <<<"${tailscale_status}")" = Running ] ||
  operator_die "Tailscale is not in the Running state"
tailnet_ip=$(jq -er '.Self.TailscaleIPs[0]' <<<"${tailscale_status}") ||
  operator_die "the host has no tailnet address"
tailnet_name=$(jq -er '.Self.DNSName' <<<"${tailscale_status}")
operator_log "Tailnet address ${tailnet_ip} (${tailnet_name%.})"

tailscale_prefs=$(tailscale debug prefs)
jq -e '.RunSSH != true' <<<"${tailscale_prefs}" >/dev/null ||
  operator_die "Tailscale SSH must remain disabled; host sshd is the only SSH server"
# An advertised exit node appears as 0.0.0.0/0 and ::/0 routes, so an empty
# route list also proves the host is not an exit node.
jq -e '(.AdvertiseRoutes // []) | length == 0' \
  <<<"${tailscale_prefs}" >/dev/null ||
  operator_die "the host must not advertise tailnet routes or an exit node"

if compgen -G '/etc/chatto/.tailscale-authkey.*' >/dev/null; then
  operator_die "leftover Tailscale auth-key material exists under /etc/chatto"
fi

# tailscaled's peer API legitimately listens on the host's own tailnet
# addresses; anything else would expose it beyond the tailnet.
tailscale_listeners=$(ss -H -ltnp | awk '/"tailscaled"/ {print $4}')
while IFS= read -r tailscale_listener; do
  [ -n "${tailscale_listener}" ] || continue
  listener_address=${tailscale_listener%:*}
  listener_address=${listener_address#[}
  listener_address=${listener_address%]}
  jq -e --arg address "${listener_address}" \
    '.Self.TailscaleIPs | index($address) != null' \
    <<<"${tailscale_status}" >/dev/null ||
    operator_die \
      "tailscaled is listening on a non-tailnet address: ${tailscale_listener}"
done <<<"${tailscale_listeners}"

# Tagged nodes have no node-key expiry. An untagged node with a pending
# expiry will silently lose tailnet SSH when the key lapses.
node_key_expiry=$(jq -r '.Self.KeyExpiry // empty' <<<"${tailscale_status}")
if jq -e '(.Self.Tags // []) | length == 0' \
  <<<"${tailscale_status}" >/dev/null &&
  [ -n "${node_key_expiry}" ] && [[ "${node_key_expiry}" != 0001-* ]]; then
  operator_warn \
    "the node key expires ${node_key_expiry}; use a tagged node or disable key expiry in the Tailscale admin console"
fi

capacity_previous_swap=-1
capacity_swap_growth=0

capacity_sample() {
  local capacity_start=$1
  local chatto_pid
  local rss_kib
  local mem_available_kib
  local swap_total_kib
  local swap_free_kib
  local swap_used_kib
  local filesystem_use

  chatto_pid=$(systemctl show chatto.service \
    --property=MainPID --value)
  [[ "${chatto_pid}" =~ ^[1-9][0-9]*$ ]] ||
    operator_die "Chatto has no running process during the capacity gate"
  rss_kib=$(ps -o rss= -p "${chatto_pid}" | awk '{print $1}')
  mem_available_kib=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  swap_total_kib=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
  swap_free_kib=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
  swap_used_kib=$((swap_total_kib - swap_free_kib))

  [ "${rss_kib}" -lt 358400 ] ||
    operator_die "Chatto RSS reached ${rss_kib} KiB during the capacity gate"
  [ "${mem_available_kib}" -ge 65536 ] ||
    operator_die "MemAvailable fell below 64 MiB during the capacity gate"

  if [ "${capacity_previous_swap}" -ge 0 ] &&
    [ "${swap_used_kib}" -gt "${capacity_previous_swap}" ]; then
    capacity_swap_growth=$((capacity_swap_growth + 1))
  else
    capacity_swap_growth=0
  fi
  capacity_previous_swap=${swap_used_kib}
  [ "${capacity_swap_growth}" -lt 6 ] ||
    operator_die "swap use grew for six consecutive capacity samples"

  while IFS= read -r filesystem_use; do
    [ "${filesystem_use}" -lt 70 ] ||
      operator_die "filesystem use reached ${filesystem_use}% during the capacity gate"
  done < <(df -P / /var/lib/chatto/backups |
    awk 'NR > 1 {gsub("%", "", $5); print $5}')

  curl --fail --silent --show-error --max-time 10 \
    --resolve "${CHAT_HOST}:443:127.0.0.1" \
    "https://${CHAT_HOST}/readyz" >/dev/null ||
    operator_die "readiness failed during the capacity gate"
  if journalctl -k --since "${capacity_start}" --no-pager |
    grep -Eiq 'out of memory|oom-kill|killed process'; then
    operator_die "the kernel reported an OOM event during the capacity gate"
  fi

  operator_log \
    "capacity: rss=${rss_kib}KiB mem_available=${mem_available_kib}KiB swap_used=${swap_used_kib}KiB"
}

if [ "${RUN_CAPACITY}" = true ]; then
  operator_log "Starting the foreground-activity/backup capacity gate"
  capacity_start=$(date --iso-8601=seconds)
  systemctl start --no-block chatto-backup.service
  while systemctl show chatto-backup.service \
    --property=ActiveState --value |
    grep -Exq 'activating|active'; do
    capacity_sample "${capacity_start}"
    sleep 5
  done
  systemctl is-failed --quiet chatto-backup.service &&
    operator_die "backup failed during the capacity gate"

  operator_log "Backup completed; continuing capacity samples for 15 minutes"
  for _ in $(seq 1 180); do
    capacity_sample "${capacity_start}"
    sleep 5
  done
fi

operator_log "Deployment verification completed successfully"
operator_log "Close public TCP 22 on both the IPv4 and IPv6 Lightsail firewalls only after a tailnet SSH session succeeds; follow runbook section 7."
if [ "${SEND_ALERT}" = true ]; then
  operator_log "Confirm that ${CHATTO_ALERT_EMAIL} received the SNS test message."
fi
if [ "${RUN_CAPACITY}" = false ]; then
  operator_log "Production acceptance still requires: sudo ./verify-deployment.sh --capacity"
fi
