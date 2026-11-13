# shellcheck shell=bash
# loh down: end this workspace's crew terminals.
# Usage: loh down [--all]
#   (default)  coders labelled crew=<this workspace>
#   --all      every terminal with this crew label: also scofield, amy and
#              loh-watch
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

self="${HC_TERMINAL_ID:-}"
self_name=""
ended=0
rows="$(hc_json ls | jq -r '.terminals[]? | select(.name != null) | "\(.address // "")\t\(.name)"')"
while IFS=$'\t' read -r addr name; do
  [[ -n "$name" ]] || continue
  info="$(hc_json get "$name" 2>/dev/null | jq -r "$label_filter" 2>/dev/null)" || continue
  crew="${info%%|*}"
  role="${info#*|}"
  [[ "$crew" == "$WS_NAME" ]] || continue
  if [[ -z "$all" && "$role" != "coder" ]]; then
    continue
  fi
  if [[ -n "$self" && "$addr" == "$self" ]]; then
    self_name="$name"
    continue
  fi
  hc kill "$name" >/dev/null
  echo "ended $name"
  ended=$((ended + 1))
done <<<"$rows"

if [[ -n "$self_name" ]]; then
  echo "ended $self_name (this terminal, last)"
  hc kill "$self_name" >/dev/null
  exit 0
fi
[[ $ended -gt 0 ]] || echo "nothing to end for crew $WS_NAME"
