#!/bin/bash
# Provision and verify the AWS resources used by a Chatto Lightsail host.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=chatto-operator-lib.sh
source "${SCRIPT_DIR}/chatto-operator-lib.sh"

ENV_FILE=
OUTPUT_FILE=./chatto-provisioned.env
ACCESS_KEY_OUTPUT=
ACCESS_KEY_TEMP=
SMTP_CREDENTIALS_OUTPUT=
SMTP_CREDENTIALS_TEMP=
SMTP_ACCESS_KEY_ID_TEMP=
AWS_BIN=${AWS_BIN:-aws}
TEMP_DIR=
SES_IDENTITY_READY=false
SES_PRODUCTION_READY=false

usage() {
  cat <<'EOF'
Usage:
  ./provision-aws.sh --env FILE [--output FILE]
      [--access-key-output FILE] [--smtp-credentials-output FILE]

Run this command on an operator workstation or in AWS CloudShell with an
administrative AWS identity. It idempotently provisions and verifies:

  - the private, encrypted, versioned S3 backup bucket;
  - the chatto-operations SNS topic and email subscription;
  - the Amazon SES sending-domain identity;
  - restricted chatto-backup and chatto-smtp IAM users.

--access-key-output creates the runtime user's first access key and writes it
to a new mode-0600 file. The file is never printed and is never overwritten.
Store the secret in a password manager and remove the temporary file after the
host installation succeeds.

--smtp-credentials-output creates the regional SES SMTP user's first access
key, derives its SMTP password, and writes both to a new mode-0600 file. The
AWS secret access key is not retained. Publish the reported DKIM records and
obtain SES production access before this credential can be created.
EOF
}

cleanup() {
  if [ -n "${SMTP_ACCESS_KEY_ID_TEMP}" ]; then
    "${AWS_BIN}" iam delete-access-key \
      --user-name chatto-smtp \
      --access-key-id "${SMTP_ACCESS_KEY_ID_TEMP}" \
      --output json >/dev/null 2>&1 || true
  fi
  if [ -n "${ACCESS_KEY_TEMP}" ] &&
    [[ "${ACCESS_KEY_TEMP}" == */.chatto-access-key.* ]]; then
    rm -f -- "${ACCESS_KEY_TEMP}"
  fi
  if [ -n "${SMTP_CREDENTIALS_TEMP}" ] &&
    [[ "${SMTP_CREDENTIALS_TEMP}" == */.chatto-smtp-credentials.* ]]; then
    rm -f -- "${SMTP_CREDENTIALS_TEMP}"
  fi
  if [ -n "${TEMP_DIR}" ] && [[ "${TEMP_DIR}" == */chatto-provision.* ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)
      [ "$#" -ge 2 ] || operator_die "--env requires a file"
      ENV_FILE=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || operator_die "--output requires a file"
      OUTPUT_FILE=$2
      shift 2
      ;;
    --access-key-output)
      [ "$#" -ge 2 ] || operator_die "--access-key-output requires a file"
      ACCESS_KEY_OUTPUT=$2
      shift 2
      ;;
    --smtp-credentials-output)
      [ "$#" -ge 2 ] ||
        operator_die "--smtp-credentials-output requires a file"
      SMTP_CREDENTIALS_OUTPUT=$2
      shift 2
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

[ -n "${ENV_FILE}" ] || {
  usage >&2
  operator_die "--env is required"
}

require_command "${AWS_BIN}"
require_command jq
require_command mktemp
require_command python3
load_deployment_env "${ENV_FILE}"
validate_base_deployment_env

export AWS_PAGER=
export AWS_REGION=${CHATTO_AWS_REGION}
export AWS_DEFAULT_REGION=${CHATTO_AWS_REGION}

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chatto-provision.XXXXXX")
LIFECYCLE_FILE="${TEMP_DIR}/lifecycle.json"
BUCKET_POLICY_FILE="${TEMP_DIR}/bucket-policy.json"
RUNTIME_POLICY_FILE="${TEMP_DIR}/runtime-policy.json"
SMTP_POLICY_FILE="${TEMP_DIR}/smtp-policy.json"

generate_ses_smtp_password() {
  local secret_access_key=$1
  local region=$2

  printf '%s' "${secret_access_key}" |
    python3 -c '
import base64
import hashlib
import hmac
import sys

region = sys.argv[1].encode()
secret = sys.stdin.buffer.read()

def sign(key, message):
    return hmac.new(key, message, hashlib.sha256).digest()

key = sign(b"AWS4" + secret, b"11111111")
key = sign(key, region)
key = sign(key, b"ses")
key = sign(key, b"aws4_request")
key = sign(key, b"SendRawEmail")
sys.stdout.write(base64.b64encode(bytes([4]) + key).decode())
' "${region}"
}

operator_log "Checking the operator AWS identity"
identity_json=$("${AWS_BIN}" sts get-caller-identity --output json)
actual_account=$(jq -er '.Account' <<<"${identity_json}")
[[ "${actual_account}" =~ ^[0-9]{12}$ ]] ||
  operator_die "STS returned an invalid AWS account ID"
if [ -n "${CHATTO_AWS_ACCOUNT_ID:-}" ] &&
  [ "${CHATTO_AWS_ACCOUNT_ID}" != "${actual_account}" ]; then
  operator_die \
    "configured account ${CHATTO_AWS_ACCOUNT_ID} does not match STS account ${actual_account}"
fi
CHATTO_AWS_ACCOUNT_ID=${actual_account}
CHATTO_SNS_TOPIC_ARN="arn:aws:sns:${CHATTO_AWS_REGION}:${CHATTO_AWS_ACCOUNT_ID}:chatto-operations"

operator_log "Provisioning S3 bucket ${CHATTO_S3_BUCKET}"
if ! bucket_location_json=$("${AWS_BIN}" s3api get-bucket-location \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --output json 2>/dev/null); then
  if [ "${CHATTO_AWS_REGION}" = us-east-1 ]; then
    "${AWS_BIN}" s3api create-bucket \
      --bucket "${CHATTO_S3_BUCKET}" \
      --object-ownership BucketOwnerEnforced \
      --output json >/dev/null
  else
    "${AWS_BIN}" s3api create-bucket \
      --bucket "${CHATTO_S3_BUCKET}" \
      --create-bucket-configuration \
        "LocationConstraint=${CHATTO_AWS_REGION}" \
      --object-ownership BucketOwnerEnforced \
      --output json >/dev/null
  fi
  bucket_location_json=$("${AWS_BIN}" s3api get-bucket-location \
    --bucket "${CHATTO_S3_BUCKET}" \
    --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
    --output json)
fi
bucket_region=$(jq -er '
  if (.LocationConstraint == null or .LocationConstraint == "") then
    "us-east-1"
  elif .LocationConstraint == "EU" then
    "eu-west-1"
  else
    .LocationConstraint
  end
' <<<"${bucket_location_json}")
[ "${bucket_region}" = "${CHATTO_AWS_REGION}" ] ||
  operator_die \
    "bucket ${CHATTO_S3_BUCKET} is in ${bucket_region}, not ${CHATTO_AWS_REGION}"

"${AWS_BIN}" s3api put-bucket-ownership-controls \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --ownership-controls \
    '{"Rules":[{"ObjectOwnership":"BucketOwnerEnforced"}]}'

"${AWS_BIN}" s3api put-public-access-block \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

"${AWS_BIN}" s3api put-bucket-encryption \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":false}]}'

"${AWS_BIN}" s3api put-bucket-versioning \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled

jq -n --arg prefix "${CHATTO_BACKUP_PREFIX}/" '{
  Rules: [{
    ID: "chatto-backup-retention",
    Status: "Enabled",
    Filter: {Prefix: $prefix},
    Expiration: {Days: 14},
    NoncurrentVersionExpiration: {NoncurrentDays: 14},
    AbortIncompleteMultipartUpload: {DaysAfterInitiation: 1}
  }]
}' > "${LIFECYCLE_FILE}"

"${AWS_BIN}" s3api put-bucket-lifecycle-configuration \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --lifecycle-configuration "file://${LIFECYCLE_FILE}"

jq -n --arg bucket "${CHATTO_S3_BUCKET}" '{
  Version: "2012-10-17",
  Statement: [{
    Sid: "DenyInsecureTransport",
    Effect: "Deny",
    Principal: "*",
    Action: "s3:*",
    Resource: [
      ("arn:aws:s3:::" + $bucket),
      ("arn:aws:s3:::" + $bucket + "/*")
    ],
    Condition: {Bool: {"aws:SecureTransport": "false"}}
  }]
}' > "${BUCKET_POLICY_FILE}"

"${AWS_BIN}" s3api put-bucket-policy \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --policy "file://${BUCKET_POLICY_FILE}"

operator_log "Verifying S3 controls"
ownership_json=$("${AWS_BIN}" s3api get-bucket-ownership-controls \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --output json)
jq -e \
  '.OwnershipControls.Rules | any(.ObjectOwnership == "BucketOwnerEnforced")' \
  <<<"${ownership_json}" >/dev/null

public_access_json=$("${AWS_BIN}" s3api get-public-access-block \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --output json)
jq -e '.PublicAccessBlockConfiguration |
  .BlockPublicAcls and .IgnorePublicAcls and
  .BlockPublicPolicy and .RestrictPublicBuckets' \
  <<<"${public_access_json}" >/dev/null

encryption_json=$("${AWS_BIN}" s3api get-bucket-encryption \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --output json)
jq -e '.ServerSideEncryptionConfiguration.Rules |
  any(.ApplyServerSideEncryptionByDefault.SSEAlgorithm == "AES256")' \
  <<<"${encryption_json}" >/dev/null

versioning_json=$("${AWS_BIN}" s3api get-bucket-versioning \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --output json)
jq -e '.Status == "Enabled"' <<<"${versioning_json}" >/dev/null

lifecycle_json=$("${AWS_BIN}" s3api get-bucket-lifecycle-configuration \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --output json)
jq -e --arg prefix "${CHATTO_BACKUP_PREFIX}/" '
  .Rules | any(
    .ID == "chatto-backup-retention" and
    .Status == "Enabled" and
    .Filter.Prefix == $prefix and
    .Expiration.Days == 14 and
    .NoncurrentVersionExpiration.NoncurrentDays == 14 and
    .AbortIncompleteMultipartUpload.DaysAfterInitiation == 1
  )' <<<"${lifecycle_json}" >/dev/null

policy_text=$("${AWS_BIN}" s3api get-bucket-policy \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --query Policy --output text)
jq -e '.Statement | any(
  .Sid == "DenyInsecureTransport" and
  .Effect == "Deny" and
  .Condition.Bool."aws:SecureTransport" == "false"
)' <<<"${policy_text}" >/dev/null
policy_status_json=$("${AWS_BIN}" s3api get-bucket-policy-status \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --output json)
jq -e '.PolicyStatus.IsPublic == false' \
  <<<"${policy_status_json}" >/dev/null

operator_log "Provisioning SNS topic and email subscription"
actual_topic=$("${AWS_BIN}" sns create-topic \
  --name chatto-operations \
  --query TopicArn --output text)
[ "${actual_topic}" = "${CHATTO_SNS_TOPIC_ARN}" ] ||
  operator_die "SNS returned unexpected topic ARN: ${actual_topic}"

subscriptions_json=$("${AWS_BIN}" sns list-subscriptions-by-topic \
  --topic-arn "${CHATTO_SNS_TOPIC_ARN}" \
  --output json)
if ! jq -e --arg email "${CHATTO_ALERT_EMAIL}" '
  .Subscriptions | any(
    .Protocol == "email" and .Endpoint == $email
  )' <<<"${subscriptions_json}" >/dev/null; then
  "${AWS_BIN}" sns subscribe \
    --topic-arn "${CHATTO_SNS_TOPIC_ARN}" \
    --protocol email \
    --notification-endpoint "${CHATTO_ALERT_EMAIL}" \
    --return-subscription-arn \
    --output json >/dev/null
  subscriptions_json=$("${AWS_BIN}" sns list-subscriptions-by-topic \
    --topic-arn "${CHATTO_SNS_TOPIC_ARN}" \
    --output json)
fi

operator_log "Provisioning SES identity ${CHATTO_SES_DOMAIN}"
if ! ses_identity_json=$("${AWS_BIN}" sesv2 get-email-identity \
  --email-identity "${CHATTO_SES_DOMAIN}" \
  --output json 2>/dev/null); then
  ses_identity_json=$("${AWS_BIN}" sesv2 create-email-identity \
    --email-identity "${CHATTO_SES_DOMAIN}" \
    --output json)
fi
[ "$(jq -er '.IdentityType' <<<"${ses_identity_json}")" = DOMAIN ] ||
  operator_die "SES returned a non-domain identity for ${CHATTO_SES_DOMAIN}"
if ! jq -e '.DkimAttributes.SigningEnabled == true' \
  <<<"${ses_identity_json}" >/dev/null; then
  "${AWS_BIN}" sesv2 put-email-identity-dkim-attributes \
    --email-identity "${CHATTO_SES_DOMAIN}" \
    --signing-enabled \
    --output json >/dev/null
  ses_identity_json=$("${AWS_BIN}" sesv2 get-email-identity \
    --email-identity "${CHATTO_SES_DOMAIN}" \
    --output json)
fi
if jq -e '
  .VerifiedForSendingStatus == true and
  .DkimAttributes.SigningEnabled == true and
  .DkimAttributes.Status == "SUCCESS"
' <<<"${ses_identity_json}" >/dev/null; then
  SES_IDENTITY_READY=true
fi

ses_account_json=$("${AWS_BIN}" sesv2 get-account --output json)
if jq -e '
  .SendingEnabled == true and
  .ProductionAccessEnabled == true
' <<<"${ses_account_json}" >/dev/null; then
  SES_PRODUCTION_READY=true
fi

operator_log "Provisioning restricted IAM user chatto-backup"
if ! "${AWS_BIN}" iam get-user \
  --user-name chatto-backup --output json >/dev/null 2>&1; then
  "${AWS_BIN}" iam create-user \
    --user-name chatto-backup --output json >/dev/null
fi

runtime_user_json=$("${AWS_BIN}" iam get-user \
  --user-name chatto-backup --output json)
expected_user_arn="arn:aws:iam::${CHATTO_AWS_ACCOUNT_ID}:user/chatto-backup"
[ "$(jq -er '.User.Arn' <<<"${runtime_user_json}")" = "${expected_user_arn}" ] ||
  operator_die "chatto-backup exists at an unexpected IAM path or account"

if "${AWS_BIN}" iam get-login-profile \
  --user-name chatto-backup --output json >/dev/null 2>&1; then
  operator_die "chatto-backup has console access; remove its login profile first"
fi

attached_json=$("${AWS_BIN}" iam list-attached-user-policies \
  --user-name chatto-backup --output json)
[ "$(jq -r '.AttachedPolicies | length' <<<"${attached_json}")" -eq 0 ] ||
  operator_die "chatto-backup has managed policies attached; remove them first"

inline_json=$("${AWS_BIN}" iam list-user-policies \
  --user-name chatto-backup --output json)
if ! jq -e '.PolicyNames |
  all(. == "ChattoBackupAndAlerts")' <<<"${inline_json}" >/dev/null; then
  operator_die "chatto-backup has an unexpected inline policy"
fi

jq -n \
  --arg bucket "${CHATTO_S3_BUCKET}" \
  --arg prefix "${CHATTO_BACKUP_PREFIX}" \
  --arg topic "${CHATTO_SNS_TOPIC_ARN}" '{
  Version: "2012-10-17",
  Statement: [
    {
      Sid: "InspectBucket",
      Effect: "Allow",
      Action: "s3:GetBucketLocation",
      Resource: ("arn:aws:s3:::" + $bucket)
    },
    {
      Sid: "ListBackupPrefix",
      Effect: "Allow",
      Action: "s3:ListBucket",
      Resource: ("arn:aws:s3:::" + $bucket),
      Condition: {
        StringLike: {
          "s3:prefix": [$prefix, ($prefix + "/*")]
        }
      }
    },
    {
      Sid: "UseBackupObjects",
      Effect: "Allow",
      Action: [
        "s3:PutObject",
        "s3:GetObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      Resource: ("arn:aws:s3:::" + $bucket + "/" + $prefix + "/*")
    },
    {
      Sid: "PublishOperationsAlerts",
      Effect: "Allow",
      Action: "sns:Publish",
      Resource: $topic
    }
  ]
}' > "${RUNTIME_POLICY_FILE}"

"${AWS_BIN}" iam put-user-policy \
  --user-name chatto-backup \
  --policy-name ChattoBackupAndAlerts \
  --policy-document "file://${RUNTIME_POLICY_FILE}"
installed_runtime_policy=$("${AWS_BIN}" iam get-user-policy \
  --user-name chatto-backup \
  --policy-name ChattoBackupAndAlerts \
  --output json)
policy_normalizer='
  def normalize:
    if type == "object" then with_entries(.value |= normalize)
    elif type == "array" then map(normalize) | sort_by(tostring)
    else . end;
  normalize
'
expected_runtime_policy=$(jq -Sc "${policy_normalizer}" \
  "${RUNTIME_POLICY_FILE}")
actual_runtime_policy=$(jq -Sc \
  ".PolicyDocument | ${policy_normalizer}" \
  <<<"${installed_runtime_policy}")
[ "${actual_runtime_policy}" = "${expected_runtime_policy}" ] ||
  operator_die "installed runtime IAM policy differs from the requested policy"

access_keys_json=$("${AWS_BIN}" iam list-access-keys \
  --user-name chatto-backup --output json)
access_key_count=$(jq -r '.AccessKeyMetadata | length' <<<"${access_keys_json}")
active_key_count=$(jq -r \
  '[.AccessKeyMetadata[] | select(.Status == "Active")] | length' \
  <<<"${access_keys_json}")

[ "${access_key_count}" -le 1 ] ||
  operator_die "chatto-backup has more than one access key"
[ "${access_key_count}" -eq "${active_key_count}" ] ||
  operator_die "chatto-backup has an inactive access key; delete it before continuing"

if [ -n "${ACCESS_KEY_OUTPUT}" ]; then
  access_key_output_dir=$(dirname "${ACCESS_KEY_OUTPUT}")
  if [ "${access_key_count}" -ne 0 ]; then
    operator_die \
      "an access key already exists; AWS cannot recover its secret, so omit --access-key-output"
  fi
  [ ! -e "${ACCESS_KEY_OUTPUT}" ] && [ ! -L "${ACCESS_KEY_OUTPUT}" ] ||
    operator_die "refusing to overwrite credential file: ${ACCESS_KEY_OUTPUT}"
  [ -d "${access_key_output_dir}" ] &&
    [ -w "${access_key_output_dir}" ] ||
    operator_die \
      "access-key output directory is not writable: ${access_key_output_dir}"
  ACCESS_KEY_TEMP=$(mktemp \
    "${access_key_output_dir}/.chatto-access-key.XXXXXX")
  chmod 0600 "${ACCESS_KEY_TEMP}"

  operator_log "Creating the runtime access key in ${ACCESS_KEY_OUTPUT}"
  access_key_json=$("${AWS_BIN}" iam create-access-key \
    --user-name chatto-backup --output json)
  access_key_id=$(jq -er '.AccessKey.AccessKeyId' <<<"${access_key_json}")
  secret_access_key=$(jq -er '.AccessKey.SecretAccessKey' <<<"${access_key_json}")
  umask 077
  {
    printf 'AWS_ACCESS_KEY_ID=%s\n' "${access_key_id}"
    printf 'AWS_SECRET_ACCESS_KEY=%s\n' "${secret_access_key}"
  } > "${ACCESS_KEY_TEMP}"
  mv -- "${ACCESS_KEY_TEMP}" "${ACCESS_KEY_OUTPUT}"
  ACCESS_KEY_TEMP=
  unset secret_access_key access_key_json
  access_key_count=1
fi

operator_log "Provisioning restricted IAM user chatto-smtp"
if ! "${AWS_BIN}" iam get-user \
  --user-name chatto-smtp --output json >/dev/null 2>&1; then
  "${AWS_BIN}" iam create-user \
    --user-name chatto-smtp --output json >/dev/null
fi

smtp_user_json=$("${AWS_BIN}" iam get-user \
  --user-name chatto-smtp --output json)
expected_smtp_user_arn="arn:aws:iam::${CHATTO_AWS_ACCOUNT_ID}:user/chatto-smtp"
[ "$(jq -er '.User.Arn' <<<"${smtp_user_json}")" = \
  "${expected_smtp_user_arn}" ] ||
  operator_die "chatto-smtp exists at an unexpected IAM path or account"

if "${AWS_BIN}" iam get-login-profile \
  --user-name chatto-smtp --output json >/dev/null 2>&1; then
  operator_die "chatto-smtp has console access; remove its login profile first"
fi

smtp_attached_json=$("${AWS_BIN}" iam list-attached-user-policies \
  --user-name chatto-smtp --output json)
[ "$(jq -r '.AttachedPolicies | length' \
  <<<"${smtp_attached_json}")" -eq 0 ] ||
  operator_die "chatto-smtp has managed policies attached; remove them first"

smtp_groups_json=$("${AWS_BIN}" iam list-groups-for-user \
  --user-name chatto-smtp --output json)
[ "$(jq -r '.Groups | length' <<<"${smtp_groups_json}")" -eq 0 ] ||
  operator_die "chatto-smtp belongs to an IAM group; remove it first"

smtp_inline_json=$("${AWS_BIN}" iam list-user-policies \
  --user-name chatto-smtp --output json)
if ! jq -e '.PolicyNames | all(. == "ChattoSESSend")' \
  <<<"${smtp_inline_json}" >/dev/null; then
  operator_die "chatto-smtp has an unexpected inline policy"
fi

ses_identity_arn="arn:aws:ses:${CHATTO_AWS_REGION}:${CHATTO_AWS_ACCOUNT_ID}:identity/${CHATTO_SES_DOMAIN}"
jq -n \
  --arg identity "${ses_identity_arn}" \
  --arg from "${CHATTO_SMTP_FROM}" '{
  Version: "2012-10-17",
  Statement: [{
    Sid: "SendChattoTransactionalEmail",
    Effect: "Allow",
    Action: "ses:SendRawEmail",
    Resource: $identity,
    Condition: {
      StringEquals: {
        "ses:FromAddress": $from
      }
    }
  }]
}' > "${SMTP_POLICY_FILE}"

"${AWS_BIN}" iam put-user-policy \
  --user-name chatto-smtp \
  --policy-name ChattoSESSend \
  --policy-document "file://${SMTP_POLICY_FILE}"
installed_smtp_policy=$("${AWS_BIN}" iam get-user-policy \
  --user-name chatto-smtp \
  --policy-name ChattoSESSend \
  --output json)
expected_smtp_policy=$(jq -Sc "${policy_normalizer}" \
  "${SMTP_POLICY_FILE}")
actual_smtp_policy=$(jq -Sc \
  ".PolicyDocument | ${policy_normalizer}" \
  <<<"${installed_smtp_policy}")
[ "${actual_smtp_policy}" = "${expected_smtp_policy}" ] ||
  operator_die "installed SMTP IAM policy differs from the requested policy"

smtp_access_keys_json=$("${AWS_BIN}" iam list-access-keys \
  --user-name chatto-smtp --output json)
smtp_access_key_count=$(jq -r \
  '.AccessKeyMetadata | length' <<<"${smtp_access_keys_json}")
smtp_active_key_count=$(jq -r \
  '[.AccessKeyMetadata[] | select(.Status == "Active")] | length' \
  <<<"${smtp_access_keys_json}")
[ "${smtp_access_key_count}" -le 1 ] ||
  operator_die "chatto-smtp has more than one access key"
[ "${smtp_access_key_count}" -eq "${smtp_active_key_count}" ] ||
  operator_die "chatto-smtp has an inactive access key; delete it first"

if [ -n "${SMTP_CREDENTIALS_OUTPUT}" ] &&
  [ "${SES_IDENTITY_READY}" = true ] &&
  [ "${SES_PRODUCTION_READY}" = true ]; then
  smtp_credentials_output_dir=$(dirname "${SMTP_CREDENTIALS_OUTPUT}")
  if [ "${smtp_access_key_count}" -ne 0 ]; then
    operator_die \
      "an SMTP access key already exists; AWS cannot recover its secret, so omit --smtp-credentials-output"
  fi
  [ ! -e "${SMTP_CREDENTIALS_OUTPUT}" ] &&
    [ ! -L "${SMTP_CREDENTIALS_OUTPUT}" ] ||
    operator_die \
      "refusing to overwrite SMTP credential file: ${SMTP_CREDENTIALS_OUTPUT}"
  [ -d "${smtp_credentials_output_dir}" ] &&
    [ -w "${smtp_credentials_output_dir}" ] ||
    operator_die \
      "SMTP credential output directory is not writable: ${smtp_credentials_output_dir}"
  SMTP_CREDENTIALS_TEMP=$(mktemp \
    "${smtp_credentials_output_dir}/.chatto-smtp-credentials.XXXXXX")
  chmod 0600 "${SMTP_CREDENTIALS_TEMP}"

  operator_log \
    "Creating the regional SMTP credential in ${SMTP_CREDENTIALS_OUTPUT}"
  smtp_access_key_json=$("${AWS_BIN}" iam create-access-key \
    --user-name chatto-smtp --output json)
  smtp_username=$(jq -er \
    '.AccessKey.AccessKeyId' <<<"${smtp_access_key_json}")
  SMTP_ACCESS_KEY_ID_TEMP=${smtp_username}
  smtp_secret_access_key=$(jq -er \
    '.AccessKey.SecretAccessKey' <<<"${smtp_access_key_json}")
  smtp_password=$(generate_ses_smtp_password \
    "${smtp_secret_access_key}" "${CHATTO_AWS_REGION}")
  [[ "${smtp_username}" =~ ^A[A-Z0-9]{19}$ ]] ||
    operator_die "created SMTP access key ID has an unexpected format"
  [ "${#smtp_password}" -eq 44 ] &&
    [[ "${smtp_password}" =~ ^[A-Za-z0-9+/]+$ ]] ||
    operator_die "derived SES SMTP password has an unexpected format"
  umask 077
  {
    printf 'CHATTO_SMTP_USERNAME=%s\n' "${smtp_username}"
    printf 'CHATTO_SMTP_PASSWORD=%s\n' "${smtp_password}"
  } > "${SMTP_CREDENTIALS_TEMP}"
  mv -- "${SMTP_CREDENTIALS_TEMP}" "${SMTP_CREDENTIALS_OUTPUT}"
  SMTP_CREDENTIALS_TEMP=
  SMTP_ACCESS_KEY_ID_TEMP=
  unset smtp_secret_access_key smtp_password smtp_access_key_json
  smtp_access_key_count=1
fi

output_dir=$(dirname "${OUTPUT_FILE}")
[ -d "${output_dir}" ] ||
  operator_die "output directory does not exist: ${output_dir}"
output_temp=$(mktemp "${output_dir}/.chatto-provisioned.XXXXXX")
write_deployment_env "${output_temp}"
chmod 0600 "${output_temp}"
mv -f -- "${output_temp}" "${OUTPUT_FILE}"
operator_log "Wrote the verified deployment record to ${OUTPUT_FILE}"

if [ "${SES_IDENTITY_READY}" != true ]; then
  [ "$(jq -r '.DkimAttributes.Tokens | length' \
    <<<"${ses_identity_json}")" -eq 3 ] ||
    operator_die "SES did not return exactly three Easy DKIM tokens"
  signing_hosted_zone=$(jq -er \
    '.DkimAttributes.SigningHostedZone // empty' \
    <<<"${ses_identity_json}") ||
    operator_die "SES did not return an Easy DKIM signing hosted zone"
  operator_log \
    "Publish these CNAME records in DNS for ${CHATTO_SES_DOMAIN}:"
  while IFS= read -r dkim_token; do
    [ -n "${dkim_token}" ] || continue
    operator_log \
      "  ${dkim_token}._domainkey.${CHATTO_SES_DOMAIN} CNAME ${dkim_token}.${signing_hosted_zone}"
  done < <(jq -r '.DkimAttributes.Tokens[]?' <<<"${ses_identity_json}")
  operator_die \
    "publish the SES Easy DKIM records, wait for verification, then rerun this command"
fi

if [ "${SES_PRODUCTION_READY}" != true ]; then
  operator_die \
    "SES production sending is not enabled in ${CHATTO_AWS_REGION}; request production access in SES and rerun this command"
fi

if [ "${smtp_access_key_count}" -eq 0 ]; then
  operator_die \
    "no SMTP access key exists; rerun with --smtp-credentials-output FILE"
fi

if [ "${access_key_count}" -eq 0 ]; then
  operator_die \
    "no runtime access key exists; rerun with --access-key-output FILE"
fi

if ! jq -e --arg email "${CHATTO_ALERT_EMAIL}" '
  .Subscriptions | any(
    .Protocol == "email" and
    .Endpoint == $email and
    .SubscriptionArn != "PendingConfirmation"
  )' <<<"${subscriptions_json}" >/dev/null; then
  operator_die \
    "confirm the SNS subscription sent to ${CHATTO_ALERT_EMAIL}, then rerun this command without --access-key-output"
fi

operator_log "AWS provisioning and verification completed successfully"
