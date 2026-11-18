# shellcheck shell=bash
# loh office [--close]: open the crew's office tab, with its props filled in, and
# close the one it opened before.
#
# You do not need it to pick up office code: herdr-app 0.1.16 reloads an open mod
# tab in place when a file in the mod's folder is saved, and the tab id stays the
# same. It is still how you open the office the first time, how you give it new
# props (a reload keeps the props the tab was opened with), and how you recover
# when no tab is open or the saved id is stale. Each run is a new tab and then
# closing the old one. The new tab opens first: closing the only tab closes the whole space. The id of the tab it opened is kept in
# <workspace>/.loh/office-tab, because herdr-app has no command that lists
# tabs. A saved id is closed whatever the heartbeat says, because a hidden
# office tab sends none; if that close fails the tab is already gone, which is
# only a note. The heartbeat (.loh/office-open, see `loh office-ping`) matters
# for one case: it is fresh and no id is saved, an office opened by hand, so
# the old tab has to be closed by hand. `loh office --close` closes the saved tab.
#
# loh office lights [on|off]: switch the office lights from a terminal, or print
# the current state: what the open office last reported through its ping (so the
# button and L count), else the last choice made here, else on. The choice goes to
# <workspace>/.loh/office-lights as "<on|off> <stamp>", the stamp being the time
# in nanoseconds (seconds where date has no nanoseconds) and always larger than the last, so a repeated choice is still a new one. `loh office-ping`
# prints that line and the open office, which runs it every 5 seconds, applies a
# stamp it has not seen yet, as if the button were pressed: whichever choice
# came last, from here or from the button, wins. It needs neither herdr-app nor
# a manifest.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  echo "Usage: loh office [--close]" >&2
  echo "       loh office lights [on|off]" >&2
  echo "  Opens the office tab with its props, to open it, to change props, or when no tab is open or its saved id is stale. Office code reloads by itself." >&2
  exit 2
}

if [[ "${1:-}" == "lights" ]]; then
  lights_usage() {
    echo "Usage: loh office lights [on|off]" >&2
    exit 2
  }
  [[ $# -le 2 ]] || lights_usage
  root="$(workspace_root)" || exit 1
  file="$root/.loh/office-lights"
  case "${2-}" in
    "")
      if [[ $# -eq 2 ]]; then lights_usage; fi
      state=on
      shown="$root/.loh/office-lights-shown"
      if office_open "$root" && [[ -f "$shown" ]]; then
        # An open office reports what it shows with each ping, so the button and L count.
        read -r state _ <"$shown" || true
      elif [[ -f "$file" ]]; then read -r state _ <"$file" || true; fi
      [[ "$state" == off ]] || state=on
      printf '%s\n' "$state"
      ;;
    on | off)
      [[ -d "$root/.loh" ]] || die "no .loh folder in $root"
      tmp="$file.tmp.$$"
      # The stamp only has to be new, and a later one larger: nanoseconds where date has them (macOS's does not), else
      # seconds, and never at or below the last stamp.
      stamp="$(date +%s%N)"
      [[ "$stamp" =~ ^[0-9]+$ ]] || stamp="$(date +%s)000000000"
      prev=""
      if [[ -f "$file" ]]; then read -r _ prev <"$file" || true; fi
      if [[ "$prev" =~ ^[0-9]+$ ]] && ((prev >= stamp)); then stamp=$((prev + 1)); fi
      printf '%s %s\n' "$2" "$stamp" >"$tmp"
      mv -f "$tmp" "$file"
      ;;
    *) lights_usage ;;
  esac
  exit 0
fi

close=""
case $# in
  0) ;;
  1)
    [[ "$1" == "--close" ]] || usage
    close=1
    ;;
  *) usage ;;
esac

manifest_load
ws="$WS_ROOT"
tab_file="$ws/.loh/office-tab"

# saved_tab: print the saved tab id, nothing when there is none or the file
# holds something that is not an id.
saved_tab() {
  local id=""
  [[ -f "$tab_file" ]] && id="$(head -n 1 "$tab_file" 2>/dev/null || true)"
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] && printf '%s\n' "$id"
  return 0
}

app_up() {
  command -v herdr-app >/dev/null 2>&1 && herdr-app status >/dev/null 2>&1
}

if [[ -n "$close" ]]; then
  old="$(saved_tab)"
  if [[ -z "$old" ]]; then
    echo "no office tab is saved for $WS_NAME; close it in herdr-app by hand"
    exit 0
  fi
  app_up || die "herdr-app is not available; close tab $old in herdr-app by hand"
  herdr-app "do" tab.close --id "$old" >/dev/null || die "could not close the office tab $old; close it in herdr-app by hand"
  rm -f "$tab_file"
  echo "closed the office tab for $WS_NAME"
  exit 0
fi

props="$(office_props "$WS_NAME" "$ws")"
if ! app_up; then
  echo "herdr-app is not available; open the office with: $(office_open_cmd "$ws" "$props")"
  exit 0
fi

# Read the old tab before opening, which overwrites the file.
old="$(saved_tab)" by_hand=""
if [[ -z "$old" ]] && office_open "$ws"; then
  by_hand=1
fi

if ! office_new_tab "$ws" "$props"; then
  die "could not open the office tab${OFFICE_ERR:+ ($OFFICE_ERR)}; open it with: $(office_open_cmd "$ws" "$props")"
fi
new="$OFFICE_NEW_TAB"

if [[ -n "$new" ]]; then
  echo "opened the office tab for $WS_NAME"
else
  echo "opened the office tab for $WS_NAME, but herdr-app gave no tab id, so loh office cannot close it later"
fi

if [[ -n "$old" ]]; then
  if herdr-app "do" tab.close --id "$old" >/dev/null; then
    echo "closed the old office tab"
  else
    echo "note: could not close the old office tab $old; it is probably gone already"
  fi
elif [[ -n "$by_hand" ]]; then
  echo "an office was already open that loh did not open: close the old one by hand"
fi
