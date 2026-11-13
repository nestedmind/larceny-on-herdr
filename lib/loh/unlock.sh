# shellcheck shell=bash
# loh unlock <name>: remove the with_matt label from a crew agent.
set -euo pipefail
# shellcheck source=lib/loh/lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/lock.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: loh unlock <name>" >&2
  exit 2
fi
set_lock "$1" off
