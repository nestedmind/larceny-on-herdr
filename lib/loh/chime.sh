# shellcheck shell=bash
# loh chime [on|off|play]: switch the sound of `loh watch` notifications, or print it;
# `play` makes the sound once, whatever the setting (the office runs it with its toasts).
#
# The choice goes to <workspace>/.loh/chime ("on" or "off"). `loh watch` reads it
# at every notification, so a change takes effect at once, and the office's Chime
# button runs this command. With no argument it prints the saved setting: the file,
# else `chime:` in .loh/workspace.md, else on. LOH_CHIME=0|1 overrides it for one
# `loh watch` run only and is not part of what is printed here.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  echo "Usage: loh chime [on|off|play]" >&2
  exit 2
}

[[ $# -le 1 ]] || usage
case "${1-}" in
  "")
    if [[ $# -eq 1 ]]; then usage; fi
    root="$(workspace_root)" || exit 1
    chime_setting "$root"
    ;;
  on | off)
    root="$(workspace_root)" || exit 1
    [[ -d "$root/.loh" ]] || die "no .loh folder in $root"
    tmp="$root/.loh/chime.tmp.$$"
    printf '%s\n' "$1" >"$tmp"
    mv -f "$tmp" "$root/.loh/chime"
    ;;
  play) chime_alone ;;
  *) usage ;;
esac
