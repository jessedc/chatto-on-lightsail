#!/bin/bash
# Print the literal value of one deployment variable, for use in command
# substitutions instead of hand-copied REPLACE_WITH placeholders.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=chatto-operator-lib.sh
source "${SCRIPT_DIR}/chatto-operator-lib.sh"

ENV_FILE="${SCRIPT_DIR}/chatto-deploy.env"

usage() {
  cat <<'EOF'
Usage:
  ./deployment-value.sh [--env FILE] NAME

Print the literal value of deployment variable NAME from chatto-deploy.env
(or FILE). Fails if the variable is unknown, empty, or still holds an
example placeholder.
EOF
}

NAME=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)
      [ "$#" -ge 2 ] || operator_die "--env requires a file"
      ENV_FILE=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      [ -z "${NAME}" ] || operator_die "exactly one variable name is expected"
      NAME=$1
      shift
      ;;
  esac
done

[ -n "${NAME}" ] || {
  usage >&2
  exit 1
}
is_deployment_variable "${NAME}" ||
  operator_die "unknown deployment variable: ${NAME}"

load_deployment_env "${ENV_FILE}"
value=${!NAME:-}
[ -n "${value}" ] || operator_die "${NAME} is empty in ${ENV_FILE}"
case "${value}" in
  *example.com* | replace-with*)
    operator_die "${NAME} still holds the example placeholder '${value}'"
    ;;
esac
printf '%s\n' "${value}"
