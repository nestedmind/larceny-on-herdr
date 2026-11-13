# shellcheck shell=bash
# loh open <name>: lock a crew agent and show it in herdr-app.
#
# herdr-app resolves terminal addresses (t9), not names, so the address comes
# from `hc get`. A terminal that already has a pane in the app carries a
# herdr.tab label and is focused; any other is kept into a new tab first. When
# herdr-app is not running, or its command fails, the agent stays locked and
# the output says how to attach from a terminal instead.
set -euo pipefail
# shellcheck source=lib/loh/lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/lock.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: loh open <name>" >&2
  exit 2
fi
who="$1"

info="$(crew_terminal "$who")"
set_lock "$who" on

addr="$(jq -r '.address // ""' <<<"$info")"
shown="$(jq -r '.labels["herdr.tab"] // ""' <<<"$info")"

attach_hint() {
  echo "herdr-app is not available; attach from a terminal with: hc attach $who"
}

if [[ -z "$addr" ]] || ! command -v herdr-app >/dev/null 2>&1 || ! herdr-app status >/dev/null 2>&1; then
  attach_hint
  exit 0
fi

if [[ -n "$shown" ]]; then
  herdr-app "do" agent.focus --terminal "$addr" >/dev/null || attach_hint
else
  herdr-app "do" terminal.keep --terminal "$addr" --place tab >/dev/null || attach_hint
fi
