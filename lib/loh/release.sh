# shellcheck shell=bash
# loh release <coder> [--force]: archive a coder's transcript into the crew
# folder, then end the coder. The coordinator runs it instead of `hc kill` and
# `hc rm` once a coder's merge is checked.
#   - only a coder of this crew (role=coder, crew=<workspace>) is accepted
#   - a coder that is working or blocked is refused unless --force is given
#   - the coder is ended first (hc kill) and awaited until hc get shows it
#     finished, because Claude Code writes a last ~2 KB to the session file as
#     it shuts down; only then is the transcript archived, and hc rm follows
#   - the session folder is copied whole to
#     <workspace>/.loh/transcripts/<coder>-<repo>-<ticket>/, checked, and only
#     then removed (see archive_transcript in common.sh). If the copy fails,
#     the source is left alone, the terminal is still removed, and the exit
#     status is 1; the message says where the transcript is.
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

if [[ "$life" == "live" && ( "$state" == "working" || "$state" == "blocked" ) && -z "$force" ]]; then
  die "$name is still $state; wait for its turn to end or pass --force"
fi

# The coder is ended first and awaited, so the last write Claude Code makes at
# shutdown is in the session file before it is copied.
end_terminal "$name"
rc=0
archive_transcript "$name" "$cwd" "$task" || rc=$?
hc rm "$name" >/dev/null
echo "released $name"
exit "$rc"
