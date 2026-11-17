# shellcheck shell=bash
# loh office [--close]: open the crew's office tab, or reload it.
#
# herdr-app does not reload a mod's code while its tab is open, so a reload is
# a new tab and then closing the old one. The new tab opens first: closing the
# only tab closes the whole space. The id of the tab it opened is kept in
# <workspace>/.loh/office-tab, because herdr-app has no command that lists
# tabs. A saved id is closed whatever the heartbeat says, because a hidden
# office tab sends none; if that close fails the tab is already gone, which is
# only a note. The heartbeat (.loh/office-open, see `loh office-ping`) matters
# for one case: it is fresh and no id is saved, an office opened by hand, so
# the old tab has to be closed by hand. `loh office --close` closes the saved tab.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  echo "Usage: loh office [--close]" >&2
  exit 2
}

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

if ! out="$(herdr-app "do" tab.new --name office --mod crew-office --folder "$ws" --props "$props")"; then
  die "could not open the office tab; open it with: $(office_open_cmd "$ws" "$props")"
fi
new="$(jq -r '.tab // empty' <<<"$out" 2>/dev/null || true)"

if [[ -n "$new" ]]; then
  printf '%s\n' "$new" >"$tab_file"
  echo "opened the office tab for $WS_NAME"
else
  rm -f "$tab_file"
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
