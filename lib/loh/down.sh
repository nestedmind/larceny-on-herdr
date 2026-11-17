# shellcheck shell=bash
# loh down: end this workspace's crew terminals.
# Usage: loh down [--all]
#   (default)  coders labelled crew=<this workspace>
#   --all      every terminal with this crew label: also scofield, amy and
#              loh-watch
# Each coder's transcript is archived into <workspace>/.loh/transcripts/ as
# `loh release` does, after the coder ends; if that fails, the coder is still
# ended, the source is left, and loh down exits 1.
# Terminals without the label are never touched. If loh runs inside one of the
# terminals it would end (hc sets HC_TERMINAL_ID there), that terminal is
# ended last, after the summary, because killing it ends loh too.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

all=""
case "${1:-}" in
  "") ;;
  --all) all=1 ;;
  *)
    echo "Usage: loh down [--all]" >&2
    exit 2
    ;;
esac
[[ $# -le 1 ]] || {
  echo "Usage: loh down [--all]" >&2
  exit 2
}

need hc
need jq
manifest_load

# label_filter extracts "crew|role" from a terminal's labels, which may be an
# object or a list of "key=value" strings.
label_filter='(.labels // {})
  | if type == "array"
    then (map(select(type == "string" and test("="))
              | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}) | add // {})
    else . end
  | "\(.crew // "")|\(.role // "")"'

# archive_coder <name> <info json>: archive that coder's transcript. A failure
# is reported (archive_transcript says why) and remembered in $failed.
failed=0
archive_coder() {
  local cwd task
  cwd="$(jq -r '.cwd // ""' <<<"$2")"
  task="$(jq -r '(.labels // {}) | if type == "array" then (map(select(type == "string" and startswith("task=")) | sub("^task="; "")) | first // "") else (.task // "") end' <<<"$2")"
  archive_transcript "$1" "$cwd" "$task" || failed=1
}

self="${HC_TERMINAL_ID:-}"
self_name=""
self_role=""
self_info=""
ended=0
rows="$(hc_json ls | jq -r '.terminals[]? | select(.name != null) | "\(.address // "")\t\(.name)"')"
while IFS=$'\t' read -r addr name; do
  [[ -n "$name" ]] || continue
  json="$(hc_json get "$name" 2>/dev/null)" || continue
  info="$(jq -r "$label_filter" <<<"$json" 2>/dev/null)" || continue
  crew="${info%%|*}"
  role="${info#*|}"
  [[ "$crew" == "$WS_NAME" ]] || continue
  if [[ -z "$all" && "$role" != "coder" ]]; then
    continue
  fi
  if [[ -n "$self" && "$addr" == "$self" ]]; then
    self_name="$name"
    self_role="$role"
    self_info="$json"
    continue
  fi
  end_terminal "$name"
  [[ "$role" != "coder" ]] || archive_coder "$name" "$json"
  echo "ended $name"
  ended=$((ended + 1))
done <<<"$rows"

if [[ -n "$self_name" ]]; then
  # Killing this terminal ends loh too, so a coder running loh down archives
  # its own transcript first (its session file is still being written, so the
  # last lines of this turn may be missing from the copy).
  [[ "$self_role" != "coder" ]] || archive_coder "$self_name" "$self_info"
  echo "ended $self_name (this terminal, last)"
  hc kill "$self_name" >/dev/null
  exit "$failed"
fi
[[ $ended -gt 0 ]] || echo "nothing to end for crew $WS_NAME"
exit "$failed"
