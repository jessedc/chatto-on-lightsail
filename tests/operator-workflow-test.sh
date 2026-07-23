#!/bin/bash
set -euo pipefail

REPOSITORY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chatto-operator-test.XXXXXX")

cleanup() {
  if [[ "${TEST_TEMP_DIR}" == */chatto-operator-test.* ]]; then
    rm -rf -- "${TEST_TEMP_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

INPUT_ENV="${TEST_TEMP_DIR}/deployment.env"
OUTPUT_ENV="${TEST_TEMP_DIR}/provisioned.env"
ACCESS_ENV="${TEST_TEMP_DIR}/access-key.env"

cat > "${INPUT_ENV}" <<'EOF'
CHAT_HOST=chat.example.com
ACME_CONTACT_EMAIL=operator@example.com
OWNER_LOGIN=chatadmin
OWNER_DISPLAY_NAME=Chatto Owner
CHATTO_VERSION=v0.4.14
CHATTO_AWS_ACCOUNT_ID=
CHATTO_AWS_REGION=us-west-2
CHATTO_S3_BUCKET=chatto-test-example-bucket
CHATTO_BACKUP_PREFIX=chatto/backups
CHATTO_SNS_TOPIC_ARN=
CHATTO_ALERT_EMAIL=operator@example.com
EOF

AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${INPUT_ENV}" \
  --output "${OUTPUT_ENV}" \
  --access-key-output "${ACCESS_ENV}" >/dev/null

grep -Fqx 'CHATTO_AWS_ACCOUNT_ID=123456789012' "${OUTPUT_ENV}" ||
  fail "provisioned account ID was not recorded"
grep -Fqx \
  'CHATTO_SNS_TOPIC_ARN=arn:aws:sns:us-west-2:123456789012:chatto-operations' \
  "${OUTPUT_ENV}" ||
  fail "provisioned topic ARN was not recorded"
grep -Fqx 'AWS_ACCESS_KEY_ID=AKIA1234567890ABCDEF' "${ACCESS_ENV}" ||
  fail "access key output is missing"

if stat -f %Lp "${ACCESS_ENV}" >/dev/null 2>&1; then
  access_mode=$(stat -f %Lp "${ACCESS_ENV}")
else
  access_mode=$(stat -c %a "${ACCESS_ENV}")
fi
[ "${access_mode}" = 600 ] ||
  fail "access key output mode is ${access_mode}, expected 600"

MOCK_ACCESS_KEY_EXISTS=1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${OUTPUT_ENV}" \
  --output "${OUTPUT_ENV}" >/dev/null

wrong_region_output="${TEST_TEMP_DIR}/wrong-region.env"
if MOCK_BUCKET_REGION=us-east-1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${INPUT_ENV}" \
  --output "${wrong_region_output}" >/dev/null 2>&1; then
  fail "an existing bucket in the wrong region was accepted"
fi

pending_output="${TEST_TEMP_DIR}/pending-provisioned.env"
if MOCK_ACCESS_KEY_EXISTS=1 \
  MOCK_SUBSCRIPTION_PENDING=1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${INPUT_ENV}" \
  --output "${pending_output}" >/dev/null 2>&1; then
  fail "pending SNS subscription was accepted"
fi
[ -s "${pending_output}" ] ||
  fail "pending SNS run did not preserve the provisioned deployment record"

malicious_marker="${TEST_TEMP_DIR}/must-not-exist"
malicious_env="${TEST_TEMP_DIR}/literal.env"
# shellcheck disable=SC2016
literal_value='$(touch must-not-exist)'
sed \
  "s|OWNER_DISPLAY_NAME=Chatto Owner|OWNER_DISPLAY_NAME=${literal_value}|" \
  "${INPUT_ENV}" > "${malicious_env}"
(
  cd "${TEST_TEMP_DIR}"
  # shellcheck disable=SC1091
  source "${REPOSITORY_DIR}/chatto-operator-lib.sh"
  load_deployment_env "${malicious_env}"
  [ "${OWNER_DISPLAY_NAME}" = "${literal_value}" ]
) || fail "literal environment value was not preserved"
[ ! -e "${malicious_marker}" ] ||
  fail "deployment environment was evaluated as shell code"

duplicate_env="${TEST_TEMP_DIR}/duplicate.env"
cp "${INPUT_ENV}" "${duplicate_env}"
printf '%s\n' 'CHAT_HOST=second.example.com' >> "${duplicate_env}"
if (
  # shellcheck disable=SC1091
  source "${REPOSITORY_DIR}/chatto-operator-lib.sh"
  load_deployment_env "${duplicate_env}"
) >/dev/null 2>&1; then
  fail "duplicate deployment variable was accepted"
fi

reserved_env="${TEST_TEMP_DIR}/reserved.env"
sed 's/OWNER_LOGIN=chatadmin/OWNER_LOGIN=owner/' \
  "${INPUT_ENV}" > "${reserved_env}"
if (
  # shellcheck disable=SC1091
  source "${REPOSITORY_DIR}/chatto-operator-lib.sh"
  load_deployment_env "${reserved_env}"
  validate_base_deployment_env
) >/dev/null 2>&1; then
  fail "reserved Chatto owner login was accepted"
fi

invalid_login_env="${TEST_TEMP_DIR}/invalid-login.env"
sed 's/OWNER_LOGIN=chatadmin/OWNER_LOGIN=bad+login/' \
  "${INPUT_ENV}" > "${invalid_login_env}"
if (
  # shellcheck disable=SC1091
  source "${REPOSITORY_DIR}/chatto-operator-lib.sh"
  load_deployment_env "${invalid_login_env}"
  validate_base_deployment_env
) >/dev/null 2>&1; then
  fail "owner login rejected by Chatto was accepted by preflight"
fi

printf '%s\n' 'operator workflow tests passed'
