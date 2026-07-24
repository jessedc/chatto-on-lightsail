#!/bin/bash
# Save the single-use Tailscale auth key to chatto-tailscale-authkey.env
# without echoing it or placing it in shell history.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=chatto-operator-lib.sh
source "${SCRIPT_DIR}/chatto-operator-lib.sh"

OUTPUT_FILE="${SCRIPT_DIR}/chatto-tailscale-authkey.env"

[ ! -e "${OUTPUT_FILE}" ] ||
  operator_die \
    "refusing to overwrite ${OUTPUT_FILE}; remove it first to save a new key"

umask 077
read -r -s -p 'Tailscale auth key: ' TS_AUTHKEY
printf '\n'
[[ "${TS_AUTHKEY}" == tskey-auth-* ]] ||
  operator_die "the value does not look like a Tailscale auth key"
printf 'TS_AUTHKEY=%s\n' "${TS_AUTHKEY}" > "${OUTPUT_FILE}"
operator_log "saved ${OUTPUT_FILE} with mode 0600"
