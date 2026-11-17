# shellcheck shell=bash
# loh office-ping: record that an office tab is open.
#
# The office runs this every 5 seconds while it is on screen. It writes the
# time, in seconds, to <workspace>/.loh/office-open. `loh watch` reads it
# (office_open in common.sh) and, while it is fresh, leaves the notice to the
# office's own toasts instead of sending a desktop notification. The folder it
# runs in only has to be inside the workspace.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [[ $# -ne 0 ]]; then
  echo "Usage: loh office-ping" >&2
  exit 2
fi
root="$(workspace_root)" || exit 1
[[ -d "$root/.loh" ]] || die "no .loh folder in $root"
tmp="$root/.loh/office-open.$$"
printf '%s\n' "$(date +%s)" >"$tmp"
mv -f "$tmp" "$root/.loh/office-open"
