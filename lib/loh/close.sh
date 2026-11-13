# shellcheck shell=bash
# loh close <name>: end a sidebar chat with a crew agent by unlocking it.
set -euo pipefail
# shellcheck source=lib/loh/lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/lock.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: loh close <name>" >&2
  exit 2
fi
set_lock "$1" off
