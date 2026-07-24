#!/bin/bash
# Report which deployment artifacts exist on this workstation and name the
# next README step. Read-only: it never changes local or AWS state, so it is
# safe to run at any point, especially when resuming a paused deployment.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=chatto-operator-lib.sh
source "${SCRIPT_DIR}/chatto-operator-lib.sh"

cd "${SCRIPT_DIR}"

NEXT=
suggest() {
  [ -n "${NEXT}" ] || NEXT=$1
}

report() {
  printf '[chatto] %-10s %s\n' "$1" "$2"
}

is_placeholder() {
  case "$1" in
    '' | *example.com* | replace-with*)
      return 0
      ;;
  esac
  return 1
}

if ./check-operator-tools.sh >/dev/null 2>&1; then
  report 'step A' 'operator tools verified'
else
  report 'step A' 'incomplete; run ./check-operator-tools.sh for details'
  suggest 'step A (install and verify the operator tools)'
fi

SESSION_ACTIVE=false
if aws configure list-profiles 2>/dev/null | grep -Fqx chatto-admin; then
  if operator_arn=$(aws sts get-caller-identity --profile chatto-admin \
    --query Arn --output text 2>/dev/null); then
    SESSION_ACTIVE=true
    report 'step B' "authenticated as ${operator_arn}"
  else
    report 'step B' \
      'chatto-admin profile exists but the session is inactive; rerun: aws login --profile chatto-admin'
    suggest 'step B (refresh the chatto-admin session)'
  fi
else
  report 'step B' 'no chatto-admin profile; run: aws login --profile chatto-admin'
  suggest 'step B (authenticate the personal-account operator)'
fi

DEPLOY_VALUES_READY=false
if [ ! -f chatto-deploy.env ]; then
  report 'step C' \
    'chatto-deploy.env does not exist; copy chatto-deploy.env.example and record the instance values'
  suggest 'step C (create the instance and record its values)'
elif ! (load_deployment_env chatto-deploy.env) >/dev/null 2>&1; then
  report 'step C' 'chatto-deploy.env exists but does not load; fix the reported line'
  suggest 'step C (repair chatto-deploy.env)'
else
  load_deployment_env chatto-deploy.env
  if is_placeholder "${CHAT_HOST:-}" ||
    is_placeholder "${LIGHTSAIL_INSTANCE_NAME:-}" ||
    is_placeholder "${LIGHTSAIL_STATIC_IP:-}" ||
    is_placeholder "${CHATTO_AWS_REGION:-}"; then
    report 'step C' \
      'chatto-deploy.env still holds example values for the host, instance, static IP, or region'
    suggest 'step C (record the instance values in chatto-deploy.env)'
  else
    DEPLOY_VALUES_READY=true
    if dig +short "${CHAT_HOST}" A 2>/dev/null |
      grep -Fqx "${LIGHTSAIL_STATIC_IP}"; then
      report 'step C' \
        "DNS: ${CHAT_HOST} resolves to the recorded static IP ${LIGHTSAIL_STATIC_IP}"
    else
      report 'step C' \
        "DNS: ${CHAT_HOST} does not resolve to ${LIGHTSAIL_STATIC_IP}; create or fix the A record"
      suggest 'step C (point the chat hostname at the static IP)'
    fi
  fi
fi

if [ "${SESSION_ACTIVE}" = true ] && [ "${DEPLOY_VALUES_READY}" = true ]; then
  if instance_state=$(aws lightsail get-instance \
    --profile chatto-admin \
    --region "${CHATTO_AWS_REGION}" \
    --instance-name "${LIGHTSAIL_INSTANCE_NAME}" \
    --query 'instance.state.name' --output text 2>/dev/null); then
    report 'step C' \
      "instance ${LIGHTSAIL_INSTANCE_NAME} is ${instance_state} in ${CHATTO_AWS_REGION}"
  else
    report 'step C' \
      "instance ${LIGHTSAIL_INSTANCE_NAME} was not found in ${CHATTO_AWS_REGION}"
    suggest 'step C (create the Lightsail instance)'
  fi
  if port_summary=$(aws lightsail get-instance-port-states \
    --profile chatto-admin \
    --region "${CHATTO_AWS_REGION}" \
    --instance-name "${LIGHTSAIL_INSTANCE_NAME}" \
    --output json 2>/dev/null |
    jq -c '[.portStates[] | {fromPort, cidrs, ipv6Cidrs}]'); then
    report 'step D' \
      "open ports (compare with the step D rules): ${port_summary}"
  fi
else
  report 'step D' \
    'firewall not checked; needs an active chatto-admin session and recorded instance values'
fi

if [ -s chatto-tailscale-authkey.env ]; then
  report 'step E' 'Tailscale auth key saved for the host installer'
else
  report 'step E' \
    'no saved Tailscale auth key; run ./save-tailscale-authkey.sh (absence is normal once the host install has consumed it)'
  suggest 'step E (prepare Tailscale and save an auth key)'
fi

if [ -f chatto-deploy.env ] &&
  ! grep -qE 'example\.com|replace-with' chatto-deploy.env; then
  report 'step F' 'chatto-deploy.env contains no example placeholders'
else
  report 'step F' 'chatto-deploy.env is missing or still holds example values'
  suggest 'step F (complete the deployment input)'
fi

report 'step G' \
  'backup passphrase and owner password live in the password manager; not checkable here'

if [ -f chatto-provisioned.env ] &&
  grep -q '^CHATTO_AWS_ACCOUNT_ID=[0-9]' chatto-provisioned.env; then
  report 'section 1' 'chatto-provisioned.env records completed AWS provisioning'
else
  report 'section 1' 'no completed provisioning record; run ./provision-aws.sh'
  suggest 'section 1 (provision AWS)'
fi

for credential_file in chatto-access-key.env chatto-smtp-credentials.env; do
  if [ -s "${credential_file}" ]; then
    report 'section 1' \
      "${credential_file} is present; transfer it, store it in the password manager, then remove it"
  else
    report 'section 1' \
      "${credential_file} is absent: not yet created, or already transferred and removed"
  fi
done

report 'sections 2+' \
  'host state is not inspectable from the workstation; run sudo ./verify-deployment.sh on the host'

if [ -n "${NEXT}" ]; then
  operator_log "next: ${NEXT}"
else
  operator_log \
    'all workstation artifacts are in place; continue with the host-side sections of the README'
fi
