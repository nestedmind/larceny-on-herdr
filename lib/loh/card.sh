# shellcheck shell=bash
# loh card k=v...: set fields on this agent's own status card.
#
# A card is a set of labels on the agent's herdr terminal (`hc label`). Agents
# may set only step, pr, round, note, place, meeting and matt. An empty value
# (`note=`) removes the field. The hooks in hooks/status-card.sh write step and
# pr on their own, and clear place when the next turn starts.
# shellcheck source=lib/loh/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

card_usage() {
  cat >&2 <<'EOF'
Usage: loh card <key>=<value>...
Keys: step, pr, round, note, place, meeting, matt. An empty value removes the field.
  place=<room>  go to a room and stay until your next prompt starts a turn.
                Rooms: lounge, kitchen, ping pong, rest room, meeting room, desk
                (desk: back to your seat, kept until the idle time runs out).
  meeting=1     sit in the meeting room, with Matt, until you clear it
                (meeting=). A new prompt does not clear it.
  matt=out      the coordinator sets it when Matt is away (he writes on Discord,
                or says he is going out): in the office he walks out of the
                entrance. Clear it (matt=) when he is back; the office clears
                it too at its own sign of him.
EOF
}

# clean <text>: drop control characters (newlines included) and cut to 60
# characters. Keep in step with clean() in hooks/status-card.sh.
clean() {
  local v
  v="$(printf '%s' "$1" | tr -d '\000-\037\177')"
  printf '%s' "${v:0:60}"
}

# place_name <room>: the label value for a room as a person says it, or fail.
# An empty room stays empty (it removes the label).
place_name() {
  local v
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' _-' ' ' | sed -e 's/^ //' -e 's/ $//')"
  case "$v" in
    "") ;;
    lounge | kitchen | desk) printf '%s' "$v" ;;
    "ping pong" | pingpong | pong) printf 'pong' ;;
    "rest room" | restroom | rest) printf 'rest' ;;
    "meeting room" | meetingroom | meeting) printf 'meeting' ;;
    *)
      printf '%s' "$1"
      return 1
      ;;
  esac
}

[[ $# -gt 0 ]] || {
  card_usage
  exit 2
}

pairs=()
for arg in "$@"; do
  if [[ "$arg" != *=* || "$arg" == =* ]]; then
    echo "loh: card: expected <key>=<value>, got: $arg" >&2
    card_usage
    exit 2
  fi
  key="${arg%%=*}"
  value="${arg#*=}"
  case "$key" in
    step | pr | round | note) ;;
    place)
      value="$(place_name "$value")" || {
        echo "loh: card: unknown room: ${value:-?} (rooms: lounge, kitchen, ping pong, rest room, meeting room, desk)" >&2
        exit 2
      }
      ;;
    meeting)
      [[ -z "$value" || "$value" == 1 ]] || {
        echo "loh: card: meeting is 1 (in a meeting) or empty (meeting over), got: $value" >&2
        exit 2
      }
      ;;
    matt)
      [[ -z "$value" || "$value" == out ]] || {
        echo "loh: card: matt is out (Matt is away) or empty (Matt is back), got: $value" >&2
        exit 2
      }
      ;;
    with_matt | crew | role | task | ctx)
      echo "loh: card: $key is set by loh and cannot be changed here" >&2
      exit 2
      ;;
    *)
      echo "loh: card: unknown field: $key (allowed: step, pr, round, note, place, meeting, matt)" >&2
      exit 2
      ;;
  esac
  pairs+=("$key=$(clean "$value")")
done

[[ -n "${HC_TERMINAL_ID:-}" ]] || die "HC_TERMINAL_ID is not set; loh card works only inside a herdr terminal"
need hc
hc label "$HC_TERMINAL_ID" "${pairs[@]}"
