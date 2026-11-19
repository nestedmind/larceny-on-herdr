# shellcheck shell=bash
# loh back <name>: remove the matt label (matt=out) from a crew agent. The office runs it
# when it sees a sign of Matt, so he walks back in.
set -euo pipefail
# shellcheck source=lib/loh/lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/lock.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: loh back <name>" >&2
  exit 2
fi
info="$(crew_terminal "$1")"
if [[ -z "$(jq -r '.labels.matt // ""' <<<"$info")" ]]; then
  echo "$1 does not say Matt is out"
else
  hc label "$1" matt= >/dev/null
  echo "Matt is back ($1)"
fi
