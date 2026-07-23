#!/bin/bash
# Publish a systemd unit failure to the single configured operations topic.
set -euo pipefail

AWS_BIN=${AWS_BIN:-/usr/local/bin/aws}
failed_unit=${1:-}

[ -x "${AWS_BIN}" ] || {
  echo "alert: AWS CLI is unavailable: ${AWS_BIN}" >&2
  exit 1
}
[ -n "${failed_unit}" ] || {
  echo "alert: failed unit name is required" >&2
  exit 1
}
[ -n "${CHATTO_SNS_TOPIC_ARN:-}" ] || {
  echo "alert: CHATTO_SNS_TOPIC_ARN is required" >&2
  exit 1
}
[ -n "${CHATTO_AWS_REGION:-}" ] || {
  echo "alert: CHATTO_AWS_REGION is required" >&2
  exit 1
}

host_name=$(hostname --fqdn 2>/dev/null || hostname)
subject_host=${host_name:0:60}
message="Chatto operation failed: unit=${failed_unit} host=${host_name}"

"${AWS_BIN}" sns publish \
  --topic-arn "${CHATTO_SNS_TOPIC_ARN}" \
  --region "${CHATTO_AWS_REGION}" \
  --subject "Chatto operation failed on ${subject_host}" \
  --message "${message}" \
  --output json
