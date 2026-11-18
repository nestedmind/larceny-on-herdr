# shellcheck shell=bash
# loh office-ping [--lights on|off]: record that an office tab is open.
#
# The office runs this every 5 seconds while it is on screen. It writes the
# time, in seconds, to <workspace>/.loh/office-open. `loh watch` reads it
# (office_open in common.sh) and, while it is fresh, leaves the notice to the
# office's own toasts instead of sending a desktop notification. The folder it
# runs in only has to be inside the workspace. It also prints the lights choice
# of `loh office lights`, if one was made. --lights says what the office shows
# now (the button and L never reach loh otherwise): it is written, with the
# time, to <workspace>/.loh/office-lights-shown, which `loh office lights`
# prints while the office is open.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

shown=""
case $# in
  0) ;;
  2)
    [[ "$1" == "--lights" && "$2" =~ ^(on|off)$ ]] || {
      echo "Usage: loh office-ping [--lights on|off]" >&2
      exit 2
    }
    shown="$2"
    ;;
  *)
    echo "Usage: loh office-ping [--lights on|off]" >&2
    exit 2
    ;;
esac
root="$(workspace_root)" || exit 1
[[ -d "$root/.loh" ]] || die "no .loh folder in $root"
tmp="$root/.loh/office-open.$$"
printf '%s\n' "$(date +%s)" >"$tmp"
mv -f "$tmp" "$root/.loh/office-open"
if [[ -n "$shown" ]]; then
  printf '%s %s\n' "$shown" "$(date +%s)" >"$tmp"
  mv -f "$tmp" "$root/.loh/office-lights-shown"
fi
# The office reads the lights choice `loh office lights` saved from this line
# ("lights <on|off> <stamp>"), so it needs no command of its own.
if [[ -f "$root/.loh/office-lights" ]]; then
  read -r state stamp <"$root/.loh/office-lights" || true
  [[ "$state" =~ ^(on|off)$ && "$stamp" =~ ^[0-9]+$ ]] && printf 'lights %s %s\n' "$state" "$stamp"
fi
exit 0
