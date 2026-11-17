# shellcheck shell=bash
# loh release <coder> [--force]: archive a coder's transcript into the crew
# folder, then end the coder. The coordinator runs it instead of `hc kill` and
# `hc rm` once a coder's merge is checked.
#   - only a coder of this crew (role=coder, crew=<workspace>) is accepted
#   - a coder that is working or blocked is refused unless --force is given;
#     a forced coder is ended first, so its session file is complete when it
#     is copied
#   - the session folder is copied whole to
#     <workspace>/.loh/transcripts/<coder>-<repo>-<ticket>/, checked, and only
#     then removed (see archive_transcript in common.sh). If the copy fails,
#     the source is left alone and the coder is not ended (unless it already was).
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  echo "Usage: loh release <coder> [--force]" >&2
  exit 2
}

force=""
name=""
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    -*) usage ;;
    *)
      [[ -z "$name" ]] || usage
      name="$a"
      ;;
  esac
done
[[ -n "$name" ]] || usage
[[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || {
  echo "loh: invalid coder name: $name" >&2
  exit 2
}

need hc
need jq
manifest_load

info="$(hc_json get "$name" 2>/dev/null)" || die "cannot look up $name"
# labels may be an object or a list of "key=value" strings
fields="$(jq -r '(.labels // {})
  | if type == "array"
    then (map(select(type == "string" and test("="))
              | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}) | add // {})
    else . end as $l
  | [($l.crew // ""), ($l.role // ""), ($l.task // "")] | join("\u001f")' <<<"$info")"
IFS=$'\037' read -r crew role task <<<"$fields"
if [[ "$crew" != "$WS_NAME" || "$role" != "coder" ]]; then
  die "$name is not a coder of crew $WS_NAME"
fi
cwd="$(jq -r '.cwd // ""' <<<"$info")"
life="$(jq -r '.state // ""' <<<"$info")"
state="$(jq -r '.status.state // ""' <<<"$info")"

busy=""
if [[ "$life" == "live" && ( "$state" == "working" || "$state" == "blocked" ) ]]; then
  [[ -n "$force" ]] || die "$name is still $state; wait for its turn to end or pass --force"
  busy=1
fi

# A coder that is still writing is ended first, so the copy is complete.
if [[ -n "$busy" ]]; then
  hc kill "$name" >/dev/null
fi
rc=0
archive_transcript "$name" "$cwd" "$task" || rc=$?
if [[ $rc -ne 0 && -z "$busy" ]]; then
  exit "$rc"
fi
[[ -n "$busy" ]] || hc kill "$name" >/dev/null
hc rm "$name" >/dev/null
echo "released $name"
exit "$rc"
