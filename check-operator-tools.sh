#!/bin/bash
# Verify the operator workstation tools before any deployment step.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=chatto-operator-lib.sh
source "${SCRIPT_DIR}/chatto-operator-lib.sh"

for tool in \
  bash aws python3 jq shellcheck curl tar ssh scp dig grep mktemp sed stat; do
  command -v "${tool}" >/dev/null 2>&1 ||
    operator_die "missing required operator tool: ${tool}"
done

aws_version=$(aws --version 2>&1)
if [[ ! "${aws_version}" =~ ^aws-cli/2\.([0-9]+)\. ]] ||
  ((BASH_REMATCH[1] < 32)); then
  operator_die "AWS CLI v2.32 or newer is required; found: ${aws_version}"
fi

printf '%s\n' "${aws_version}"
jq --version
shellcheck --version
operator_log "all operator workstation tools are present"
