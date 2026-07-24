#!/bin/bash
# Shared, side-effect-free helpers for the operator entry points.

operator_log() {
  printf '[chatto] %s\n' "$*"
}

operator_warn() {
  printf '[chatto] WARNING: %s\n' "$*" >&2
}

operator_die() {
  printf '[chatto] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    operator_die "required command is unavailable: $1"
}

require_root() {
  [ "$(id -u)" -eq 0 ] ||
    operator_die "run this command as root (for example, with sudo)"
}

require_value() {
  local name=$1
  [ -n "${!name:-}" ] || operator_die "${name} is required"
}

deployment_variable_names() {
  printf '%s\n' \
    CHAT_HOST \
    ACME_CONTACT_EMAIL \
    OWNER_LOGIN \
    OWNER_DISPLAY_NAME \
    CHATTO_VERSION \
    CHATTO_AWS_ACCOUNT_ID \
    CHATTO_AWS_REGION \
    CHATTO_S3_BUCKET \
    CHATTO_BACKUP_PREFIX \
    CHATTO_SNS_TOPIC_ARN \
    CHATTO_ALERT_EMAIL \
    CHATTO_SES_DOMAIN \
    CHATTO_SMTP_FROM \
    TAILSCALE_HOSTNAME
}

is_deployment_variable() {
  case "$1" in
    CHAT_HOST | ACME_CONTACT_EMAIL | OWNER_LOGIN | OWNER_DISPLAY_NAME | \
      CHATTO_VERSION | CHATTO_AWS_ACCOUNT_ID | CHATTO_AWS_REGION | \
      CHATTO_S3_BUCKET | CHATTO_BACKUP_PREFIX | CHATTO_SNS_TOPIC_ARN | \
      CHATTO_ALERT_EMAIL | CHATTO_SES_DOMAIN | CHATTO_SMTP_FROM | \
      TAILSCALE_HOSTNAME)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Read a deliberately simple KEY=VALUE file without sourcing or evaluating it.
# Values are literal text: quotes and shell substitutions have no special meaning.
load_deployment_env() {
  local env_file=$1
  local line
  local line_number=0
  local name
  local value
  local seen='|'

  [ -r "${env_file}" ] ||
    operator_die "deployment environment is not readable: ${env_file}"

  while IFS= read -r name; do
    unset "${name}"
  done < <(deployment_variable_names)

  while IFS= read -r line || [ -n "${line}" ]; do
    line_number=$((line_number + 1))
    line=${line%$'\r'}
    case "${line}" in
      '' | \#*)
        continue
        ;;
    esac

    [[ "${line}" == *=* ]] ||
      operator_die "${env_file}:${line_number}: expected KEY=VALUE"
    name=${line%%=*}
    value=${line#*=}

    is_deployment_variable "${name}" ||
      operator_die "${env_file}:${line_number}: unsupported variable ${name}"
    case "${seen}" in
      *"|${name}|"*)
        operator_die "${env_file}:${line_number}: duplicate variable ${name}"
        ;;
    esac
    [[ ! "${value}" =~ [[:cntrl:]] ]] ||
      operator_die "${env_file}:${line_number}: control characters are not allowed"

    printf -v "${name}" '%s' "${value}"
    seen="${seen}${name}|"
  done < "${env_file}"
}

validate_email() {
  local name=$1
  local value=${!name:-}
  [[ "${value}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] ||
    operator_die "${name} must be a simple email address"
}

validate_chat_host() {
  local label
  local old_ifs=${IFS}
  local labels=()

  require_value CHAT_HOST
  [ "${#CHAT_HOST}" -le 253 ] ||
    operator_die "CHAT_HOST is longer than 253 characters"
  [[ "${CHAT_HOST}" == *.* ]] ||
    operator_die "CHAT_HOST must be a fully qualified DNS name"
  [[ "${CHAT_HOST}" != .* && "${CHAT_HOST}" != *. &&
    "${CHAT_HOST}" != *..* &&
    "${CHAT_HOST}" != *[!A-Za-z0-9.-]* ]] ||
    operator_die "CHAT_HOST is not a valid DNS name"

  IFS=.
  read -r -a labels <<<"${CHAT_HOST}"
  IFS=${old_ifs}
  for label in "${labels[@]}"; do
    [ -n "${label}" ] && [ "${#label}" -le 63 ] &&
      [[ "${label}" != -* && "${label}" != *- ]] ||
      operator_die "CHAT_HOST contains an invalid DNS label"
  done
}

validate_aws_identifiers() {
  require_value CHATTO_AWS_REGION
  require_value CHATTO_S3_BUCKET
  require_value CHATTO_BACKUP_PREFIX

  [[ "${CHATTO_AWS_REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]] ||
    operator_die "CHATTO_AWS_REGION is not a valid AWS region"
  [[ "${CHATTO_S3_BUCKET}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
    operator_die "CHATTO_S3_BUCKET is not a valid S3 bucket name"
  [[ "${CHATTO_S3_BUCKET}" != *..* ]] ||
    operator_die "CHATTO_S3_BUCKET must not contain adjacent periods"
  [[ "${CHATTO_BACKUP_PREFIX}" != /* &&
    "${CHATTO_BACKUP_PREFIX}" != */ &&
    "${CHATTO_BACKUP_PREFIX}" != *'//'*
    ]] || operator_die \
    "CHATTO_BACKUP_PREFIX must not have leading, trailing, or adjacent slashes"
  [[ "${CHATTO_BACKUP_PREFIX}" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    operator_die \
      "CHATTO_BACKUP_PREFIX may contain only letters, digits, dot, underscore, hyphen, and slash"
}

validate_ses_configuration() {
  local from_domain
  local label
  local old_ifs=${IFS}
  local labels=()

  require_value CHATTO_SES_DOMAIN
  require_value CHATTO_SMTP_FROM
  validate_email CHATTO_SMTP_FROM
  [ "${#CHATTO_SES_DOMAIN}" -le 253 ] ||
    operator_die "CHATTO_SES_DOMAIN is longer than 253 characters"
  [[ "${CHATTO_SES_DOMAIN}" == *.* ]] &&
    [[ "${CHATTO_SES_DOMAIN}" != .* &&
      "${CHATTO_SES_DOMAIN}" != *. &&
      "${CHATTO_SES_DOMAIN}" != *..* &&
      "${CHATTO_SES_DOMAIN}" != *[!a-z0-9.-]* ]] ||
    operator_die "CHATTO_SES_DOMAIN must be a lowercase fully qualified DNS name"

  IFS=.
  read -r -a labels <<<"${CHATTO_SES_DOMAIN}"
  IFS=${old_ifs}
  for label in "${labels[@]}"; do
    [ -n "${label}" ] && [ "${#label}" -le 63 ] &&
      [[ "${label}" != -* && "${label}" != *- ]] ||
      operator_die "CHATTO_SES_DOMAIN contains an invalid DNS label"
  done

  from_domain=${CHATTO_SMTP_FROM##*@}
  [ "${from_domain}" = "${CHATTO_SES_DOMAIN}" ] ||
    operator_die \
      "CHATTO_SMTP_FROM must be an address directly below CHATTO_SES_DOMAIN"
}

# TAILSCALE_HOSTNAME is optional so pre-Tailscale deployment env files stay
# valid; an empty value normalizes to the default machine name.
validate_tailscale_hostname() {
  if [ -z "${TAILSCALE_HOSTNAME:-}" ]; then
    TAILSCALE_HOSTNAME=chatto
  fi
  [ "${#TAILSCALE_HOSTNAME}" -le 63 ] &&
    [[ "${TAILSCALE_HOSTNAME}" != *[!A-Za-z0-9-]* ]] &&
    [[ "${TAILSCALE_HOSTNAME}" != -* && "${TAILSCALE_HOSTNAME}" != *- ]] ||
    operator_die "TAILSCALE_HOSTNAME must be a single valid DNS label"
}

validate_base_deployment_env() {
  local normalized_owner_login

  validate_chat_host
  require_value ACME_CONTACT_EMAIL
  require_value OWNER_LOGIN
  require_value OWNER_DISPLAY_NAME
  require_value CHATTO_VERSION
  require_value CHATTO_ALERT_EMAIL
  validate_email ACME_CONTACT_EMAIL
  validate_email CHATTO_ALERT_EMAIL
  [[ "${OWNER_LOGIN}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$ ]] &&
    [[ "${OWNER_LOGIN}" != *. ]] ||
    operator_die \
      "OWNER_LOGIN must be 2-32 characters, start with a letter or digit, use only letters, digits, dot, underscore, or hyphen, and not end with a dot"
  [ "${#OWNER_DISPLAY_NAME}" -le 32 ] ||
    operator_die \
      "OWNER_DISPLAY_NAME is longer than Chatto's 32-character limit"
  [[ "${OWNER_DISPLAY_NAME}" =~ ^[[:alnum:]] ]] &&
    [[ "${OWNER_DISPLAY_NAME}" != *'  '* ]] ||
    operator_die \
      "OWNER_DISPLAY_NAME must start with a letter or digit and not contain consecutive spaces"
  normalized_owner_login=$(printf '%s' "${OWNER_LOGIN}" |
    LC_ALL=C tr '[:upper:]' '[:lower:]')
  case "${normalized_owner_login}" in
    root | admin | superuser | op | operator | support | \
      owner | moderator | everyone | all | here)
      operator_die \
        "OWNER_LOGIN is reserved by Chatto; choose a different login"
      ;;
  esac
  [ "${CHATTO_VERSION}" = v0.4.14 ] ||
    operator_die "CHATTO_VERSION must remain pinned to the qualified v0.4.14 release"
  validate_tailscale_hostname
  validate_aws_identifiers
  validate_ses_configuration
}

validate_provisioned_deployment_env() {
  local expected_topic

  validate_base_deployment_env
  require_value CHATTO_AWS_ACCOUNT_ID
  require_value CHATTO_SNS_TOPIC_ARN
  [[ "${CHATTO_AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] ||
    operator_die "CHATTO_AWS_ACCOUNT_ID must contain exactly 12 digits"
  expected_topic="arn:aws:sns:${CHATTO_AWS_REGION}:${CHATTO_AWS_ACCOUNT_ID}:chatto-operations"
  [ "${CHATTO_SNS_TOPIC_ARN}" = "${expected_topic}" ] ||
    operator_die "CHATTO_SNS_TOPIC_ARN must be ${expected_topic}"
}

write_deployment_env() {
  local output_file=$1
  local name

  umask 077
  : > "${output_file}"
  while IFS= read -r name; do
    printf '%s=%s\n' "${name}" "${!name:-}" >> "${output_file}"
  done < <(deployment_variable_names)
}
