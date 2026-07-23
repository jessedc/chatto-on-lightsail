#!/bin/bash
# Send one notification while Debian reports that a reboot is pending.
set -euo pipefail
umask 077

AWS_BIN=${AWS_BIN:-/usr/local/bin/aws}
REBOOT_REQUIRED_FILE=${REBOOT_REQUIRED_FILE:-/var/run/reboot-required}
CHATTO_REBOOT_STATE_FILE=${CHATTO_REBOOT_STATE_FILE:-/var/lib/chatto/operations/reboot-required.notified}
state_dir=${CHATTO_REBOOT_STATE_FILE%/*}

[ -x "${AWS_BIN}" ] || {
  echo "reboot check: AWS CLI is unavailable: ${AWS_BIN}" >&2
  exit 1
}
[ -n "${CHATTO_SNS_TOPIC_ARN:-}" ] || {
  echo "reboot check: CHATTO_SNS_TOPIC_ARN is required" >&2
  exit 1
}
[ -n "${CHATTO_AWS_REGION:-}" ] || {
  echo "reboot check: CHATTO_AWS_REGION is required" >&2
  exit 1
}
[ -d "${state_dir}" ] && [ -w "${state_dir}" ] || {
  echo "reboot check: state directory is missing or not writable: ${state_dir}" >&2
  exit 1
}

if [ ! -e "${REBOOT_REQUIRED_FILE}" ]; then
  rm -f -- "${CHATTO_REBOOT_STATE_FILE}"
  echo "No reboot is pending"
  exit 0
fi

if [ -e "${CHATTO_REBOOT_STATE_FILE}" ]; then
  echo "A reboot is still pending; notification was already sent"
  exit 0
fi

host_name=$(hostname --fqdn 2>/dev/null || hostname)
subject_host=${host_name:0:60}
message="Debian reports that ${host_name} requires a reboot. Complete the verified-backup and manual-reboot procedure."

"${AWS_BIN}" sns publish \
  --topic-arn "${CHATTO_SNS_TOPIC_ARN}" \
  --region "${CHATTO_AWS_REGION}" \
  --subject "Chatto host reboot required: ${subject_host}" \
  --message "${message}" \
  --output json

touch "${CHATTO_REBOOT_STATE_FILE}"
echo "Published reboot-required notification for ${host_name}"
