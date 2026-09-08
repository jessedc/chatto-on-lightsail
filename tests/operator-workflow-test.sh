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
SMTP_ENV="${TEST_TEMP_DIR}/smtp-credentials.env"

cat > "${INPUT_ENV}" <<'EOF'
CHAT_HOST=chat.example.com
LIGHTSAIL_INSTANCE_NAME=chatto-test-instance
LIGHTSAIL_STATIC_IP=203.0.113.10
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
CHATTO_SES_DOMAIN=jessedc.dev
CHATTO_SMTP_FROM=noreply@jessedc.dev
EOF

AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${INPUT_ENV}" \
  --output "${OUTPUT_ENV}" \
  --access-key-output "${ACCESS_ENV}" \
  --smtp-credentials-output "${SMTP_ENV}" >/dev/null

grep -Fqx 'CHATTO_AWS_ACCOUNT_ID=123456789012' "${OUTPUT_ENV}" ||
  fail "provisioned account ID was not recorded"
grep -Fqx \
  'CHATTO_SNS_TOPIC_ARN=arn:aws:sns:us-west-2:123456789012:chatto-operations' \
  "${OUTPUT_ENV}" ||
  fail "provisioned topic ARN was not recorded"
grep -Fqx 'AWS_ACCESS_KEY_ID=AKIA1234567890ABCDEF' "${ACCESS_ENV}" ||
  fail "access key output is missing"
grep -Fqx 'CHATTO_SMTP_USERNAME=AKIAFEDCBA0987654321' "${SMTP_ENV}" ||
  fail "SMTP username output is missing"
grep -Fqx \
  'CHATTO_SMTP_PASSWORD=BHspkruO2yV4iIRAHk8Y6jc73JKySU5ccV3pisPKzSOJ' \
  "${SMTP_ENV}" ||
  fail "derived SMTP password is incorrect"
if grep -Fq '0123456789012345678901234567890123456789' "${SMTP_ENV}"; then
  fail "raw AWS secret access key leaked into the SMTP credential output"
fi
grep -Fqx 'CHATTO_SES_DOMAIN=jessedc.dev' "${OUTPUT_ENV}" ||
  fail "SES domain was not recorded"
grep -Fqx 'CHATTO_SMTP_FROM=noreply@jessedc.dev' "${OUTPUT_ENV}" ||
  fail "SMTP sender was not recorded"

if stat -f %Lp "${ACCESS_ENV}" >/dev/null 2>&1; then
  access_mode=$(stat -f %Lp "${ACCESS_ENV}")
else
  access_mode=$(stat -c %a "${ACCESS_ENV}")
fi
[ "${access_mode}" = 600 ] ||
  fail "access key output mode is ${access_mode}, expected 600"
if stat -f %Lp "${SMTP_ENV}" >/dev/null 2>&1; then
  smtp_mode=$(stat -f %Lp "${SMTP_ENV}")
else
  smtp_mode=$(stat -c %a "${SMTP_ENV}")
fi
[ "${smtp_mode}" = 600 ] ||
  fail "SMTP credential output mode is ${smtp_mode}, expected 600"

smtp_snapshot="${TEST_TEMP_DIR}/smtp-credentials.snapshot"
access_snapshot="${TEST_TEMP_DIR}/access-key.snapshot"
cp "${SMTP_ENV}" "${smtp_snapshot}"
cp "${ACCESS_ENV}" "${access_snapshot}"
MOCK_ACCESS_KEY_EXISTS=1 \
  MOCK_SMTP_ACCESS_KEY_EXISTS=1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${OUTPUT_ENV}" \
  --output "${OUTPUT_ENV}" \
  --access-key-output "${ACCESS_ENV}" \
  --smtp-credentials-output "${SMTP_ENV}" >/dev/null ||
  fail "a rerun with already-captured credential outputs failed"
cmp -s "${SMTP_ENV}" "${smtp_snapshot}" ||
  fail "the rerun changed the existing SMTP credential output"
cmp -s "${ACCESS_ENV}" "${access_snapshot}" ||
  fail "the rerun changed the existing access-key output"

uncaptured_smtp="${TEST_TEMP_DIR}/uncaptured-smtp.env"
if MOCK_ACCESS_KEY_EXISTS=1 \
  MOCK_SMTP_ACCESS_KEY_EXISTS=1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${OUTPUT_ENV}" \
  --output "${OUTPUT_ENV}" \
  --smtp-credentials-output "${uncaptured_smtp}" >/dev/null 2>&1; then
  fail "an existing SMTP key without its captured file was accepted"
fi
[ ! -e "${uncaptured_smtp}" ] ||
  fail "the uncaptured-key failure still wrote an SMTP credential file"

MOCK_ACCESS_KEY_EXISTS=1 \
  MOCK_SMTP_ACCESS_KEY_EXISTS=1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${OUTPUT_ENV}" \
  --output "${OUTPUT_ENV}" >/dev/null

created_identity_state="${TEST_TEMP_DIR}/ses-identity-created"
created_identity_output="${TEST_TEMP_DIR}/created-identity.env"
if MOCK_ACCESS_KEY_EXISTS=1 \
  MOCK_SMTP_ACCESS_KEY_EXISTS=1 \
  MOCK_SES_STATE_FILE="${created_identity_state}" \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${INPUT_ENV}" \
  --output "${created_identity_output}" >/dev/null 2>&1; then
  fail "a newly created SES identity was accepted before DKIM verification"
fi
[ -f "${created_identity_state}" ] ||
  fail "a missing SES domain identity was not created"
[ -s "${created_identity_output}" ] ||
  fail "SES identity creation did not preserve the deployment record"

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
  MOCK_SMTP_ACCESS_KEY_EXISTS=1 \
  MOCK_SUBSCRIPTION_PENDING=1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${INPUT_ENV}" \
  --output "${pending_output}" >/dev/null 2>&1; then
  fail "pending SNS subscription was accepted"
fi
[ -s "${pending_output}" ] ||
  fail "pending SNS run did not preserve the provisioned deployment record"

pending_ses_output="${TEST_TEMP_DIR}/pending-ses-provisioned.env"
pending_ses_log="${TEST_TEMP_DIR}/pending-ses.log"
if MOCK_ACCESS_KEY_EXISTS=1 \
  MOCK_SMTP_ACCESS_KEY_EXISTS=1 \
  MOCK_SES_PENDING=1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${INPUT_ENV}" \
  --output "${pending_ses_output}" \
  >"${pending_ses_log}" 2>&1; then
  fail "pending SES domain verification was accepted"
fi
grep -Fq \
  'dkimtoken1._domainkey.jessedc.dev CNAME dkimtoken1.dkim.amazonses.com' \
  "${pending_ses_log}" ||
  fail "pending SES run did not report its Easy DKIM records"
[ -s "${pending_ses_output}" ] ||
  fail "pending SES run did not preserve the provisioned deployment record"

sandbox_output="${TEST_TEMP_DIR}/sandbox-provisioned.env"
sandbox_log="${TEST_TEMP_DIR}/sandbox.log"
MOCK_ACCESS_KEY_EXISTS=1 \
  MOCK_SMTP_ACCESS_KEY_EXISTS=1 \
  MOCK_SES_SANDBOX=1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${INPUT_ENV}" \
  --output "${sandbox_output}" \
  >"${sandbox_log}" 2>&1 ||
  fail "SES sandbox account was rejected instead of being accepted with a warning"
grep -Fq \
  'SES production sending is not enabled in us-west-2' \
  "${sandbox_log}" ||
  fail "SES sandbox run did not warn about sandbox delivery limits"
[ -s "${sandbox_output}" ] ||
  fail "SES sandbox run did not preserve the provisioned deployment record"

unexpected_smtp_group_output="${TEST_TEMP_DIR}/unexpected-smtp-group.env"
if MOCK_ACCESS_KEY_EXISTS=1 \
  MOCK_SMTP_ACCESS_KEY_EXISTS=1 \
  MOCK_SMTP_GROUP=1 \
  AWS_BIN="${REPOSITORY_DIR}/tests/mock-aws.sh" \
  "${REPOSITORY_DIR}/provision-aws.sh" \
  --env "${INPUT_ENV}" \
  --output "${unexpected_smtp_group_output}" >/dev/null 2>&1; then
  fail "unexpected chatto-smtp IAM group membership was accepted"
fi

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

invalid_sender_env="${TEST_TEMP_DIR}/invalid-sender.env"
sed 's/CHATTO_SMTP_FROM=noreply@jessedc.dev/CHATTO_SMTP_FROM=noreply@example.com/' \
  "${INPUT_ENV}" > "${invalid_sender_env}"
if (
  # shellcheck disable=SC1091
  source "${REPOSITORY_DIR}/chatto-operator-lib.sh"
  load_deployment_env "${invalid_sender_env}"
  validate_base_deployment_env
) >/dev/null 2>&1; then
  fail "SMTP sender outside the SES domain was accepted"
fi

printf '%s\n' 'operator workflow tests passed'
