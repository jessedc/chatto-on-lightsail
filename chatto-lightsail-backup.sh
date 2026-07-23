#!/bin/bash
# Create an encrypted Chatto backup, upload it to S3, verify the remote object,
# and retain the two newest successfully created local archives.
set -euo pipefail
umask 077

CHATTO_BIN=${CHATTO_BIN:-/usr/local/bin/chatto}
AWS_BIN=${AWS_BIN:-/usr/local/bin/aws}
JQ_BIN=${JQ_BIN:-/usr/bin/jq}
SHA256SUM_BIN=${SHA256SUM_BIN:-/usr/bin/sha256sum}
STAT_BIN=${STAT_BIN:-/usr/bin/stat}
CHATTO_CONFIG=${CHATTO_CONFIG:-/etc/chatto/chatto.toml}
CHATTO_BACKUP_PASSPHRASE_FILE=${CHATTO_BACKUP_PASSPHRASE_FILE:-/etc/chatto/backup-passphrase}
CHATTO_BACKUP_DIR=${CHATTO_BACKUP_DIR:-/var/lib/chatto/backups}

fail() {
  echo "chatto backup: $*" >&2
  exit 1
}

require_env() {
  local name=$1
  [ -n "${!name:-}" ] || fail "required environment variable ${name} is empty"
}

require_executable() {
  local path=$1
  [ -x "${path}" ] || fail "required executable is unavailable: ${path}"
}

require_env CHATTO_S3_BUCKET
require_env CHATTO_BACKUP_PREFIX
require_env CHATTO_AWS_REGION
require_env CHATTO_AWS_ACCOUNT_ID

[[ "${CHATTO_S3_BUCKET}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
  fail "CHATTO_S3_BUCKET is not a valid S3 bucket name"
[[ "${CHATTO_BACKUP_PREFIX}" != /* ]] ||
  fail "CHATTO_BACKUP_PREFIX must not begin with a slash"
[[ "${CHATTO_BACKUP_PREFIX}" != */ ]] ||
  fail "CHATTO_BACKUP_PREFIX must not end with a slash"
[[ "${CHATTO_BACKUP_PREFIX}" != *"//"* ]] ||
  fail "CHATTO_BACKUP_PREFIX must not contain an empty path component"
[[ "${CHATTO_AWS_REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]] ||
  fail "CHATTO_AWS_REGION is not a valid AWS region name"
[[ "${CHATTO_AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] ||
  fail "CHATTO_AWS_ACCOUNT_ID must contain exactly 12 digits"

require_executable "${CHATTO_BIN}"
require_executable "${AWS_BIN}"
require_executable "${JQ_BIN}"
require_executable "${SHA256SUM_BIN}"
require_executable "${STAT_BIN}"

{ [ -r "${CHATTO_CONFIG}" ] && [ -s "${CHATTO_CONFIG}" ]; } ||
  fail "Chatto configuration is missing, empty, or unreadable: ${CHATTO_CONFIG}"
{ [ -r "${CHATTO_BACKUP_PASSPHRASE_FILE}" ] &&
  [ -s "${CHATTO_BACKUP_PASSPHRASE_FILE}" ]; } ||
  fail "backup passphrase is missing, empty, or unreadable: ${CHATTO_BACKUP_PASSPHRASE_FILE}"
{ [ -d "${CHATTO_BACKUP_DIR}" ] && [ -w "${CHATTO_BACKUP_DIR}" ]; } ||
  fail "backup staging directory is missing or not writable: ${CHATTO_BACKUP_DIR}"

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
archive_name="chatto-backup-${timestamp}.tar.gz.age"
archive_path="${CHATTO_BACKUP_DIR}/${archive_name}"
partial_path="${archive_path}.partial"
object_key="${CHATTO_BACKUP_PREFIX}/${archive_name}"

{ [ ! -e "${archive_path}" ] && [ ! -e "${partial_path}" ]; } ||
  fail "refusing to overwrite an archive created in the same UTC second"

cleanup_partial() {
  rm -f -- "${partial_path}"
}
trap cleanup_partial EXIT

"${CHATTO_BIN}" backup \
  --config "${CHATTO_CONFIG}" \
  --encrypt \
  --include-keys \
  --passphrase-file "${CHATTO_BACKUP_PASSPHRASE_FILE}" \
  -o "${partial_path}"

[ -s "${partial_path}" ] || fail "Chatto produced an empty backup archive"
mv -- "${partial_path}" "${archive_path}"
trap - EXIT

backup_size=$("${STAT_BIN}" -c %s "${archive_path}")
backup_sha256=$("${SHA256SUM_BIN}" "${archive_path}" | awk '{print $1}')
[[ "${backup_size}" =~ ^[1-9][0-9]*$ ]] ||
  fail "could not determine a nonzero archive size"
[[ "${backup_sha256}" =~ ^[0-9a-f]{64}$ ]] ||
  fail "could not determine the archive SHA-256 digest"

echo "Uploading ${archive_name} (${backup_size} bytes, sha256=${backup_sha256})"
"${AWS_BIN}" s3 cp "${archive_path}" \
  "s3://${CHATTO_S3_BUCKET}/${object_key}" \
  --region "${CHATTO_AWS_REGION}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --sse AES256 \
  --checksum-algorithm SHA256 \
  --metadata "sha256=${backup_sha256}" \
  --only-show-errors

head_json=$("${AWS_BIN}" s3api head-object \
  --bucket "${CHATTO_S3_BUCKET}" \
  --key "${object_key}" \
  --region "${CHATTO_AWS_REGION}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --checksum-mode ENABLED \
  --output json)

remote_size=$("${JQ_BIN}" -er '.ContentLength' <<<"${head_json}") ||
  fail "S3 did not return ContentLength"
remote_sha256=$("${JQ_BIN}" -er '.Metadata.sha256' <<<"${head_json}") ||
  fail "S3 did not return the full-file SHA-256 metadata"
s3_checksum=$("${JQ_BIN}" -er '.ChecksumSHA256' <<<"${head_json}") ||
  fail "S3 did not return its SHA-256 checksum"
remote_encryption=$("${JQ_BIN}" -er '.ServerSideEncryption' <<<"${head_json}") ||
  fail "S3 did not return the server-side encryption mode"

[ "${remote_size}" = "${backup_size}" ] ||
  fail "remote ContentLength ${remote_size} does not match ${backup_size}"
[ "${remote_sha256}" = "${backup_sha256}" ] ||
  fail "remote SHA-256 metadata does not match the local archive"
[ -n "${s3_checksum}" ] ||
  fail "S3 returned an empty SHA-256 checksum"
[ "${remote_encryption}" = AES256 ] ||
  fail "remote object encryption is ${remote_encryption}, not AES256"

# Lexicographic order is chronological because all names use the same UTC
# timestamp format. Cleanup happens only after the new remote object verifies.
shopt -s nullglob
archives=("${CHATTO_BACKUP_DIR}"/chatto-backup-*.tar.gz.age)
if [ "${#archives[@]}" -gt 2 ]; then
  mapfile -t archives < <(printf '%s\n' "${archives[@]}" | LC_ALL=C sort)
  remove_count=$(("${#archives[@]}" - 2))
  for ((index = 0; index < remove_count; index++)); do
    rm -f -- "${archives[index]}"
  done
fi

echo "Verified s3://${CHATTO_S3_BUCKET}/${object_key}"
