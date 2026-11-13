# shellcheck shell=bash
# loh card k=v...: set fields on this agent's own status card.
#
# A card is a set of labels on the agent's herdr terminal (`hc label`). Agents
# may set only step, pr, round and note. An empty value (`note=`) removes the
# field. The hooks in hooks/status-card.sh write step and pr on their own.
# shellcheck source=lib/loh/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

card_usage() {
  cat >&2 <<'EOF'
Usage: loh card <key>=<value>...
Keys: step, pr, round, note. An empty value removes the field.
EOF
}

# clean <text>: drop control characters (newlines included) and cut to 60
# characters. Keep in step with clean() in hooks/status-card.sh.
clean() {
  local v
  v="$(printf '%s' "$1" | tr -d '\000-\037\177')"
  printf '%s' "${v:0:60}"
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
    with_matt | crew | role | task | ctx)
      echo "loh: card: $key is set by loh and cannot be changed here" >&2
      exit 2
      ;;
    *)
      echo "loh: card: unknown field: $key (allowed: step, pr, round, note)" >&2
      exit 2
      ;;
  esac
  pairs+=("$key=$(clean "$value")")
done

[[ -n "${HC_TERMINAL_ID:-}" ]] || die "HC_TERMINAL_ID is not set; loh card works only inside a herdr terminal"
need hc
hc label "$HC_TERMINAL_ID" "${pairs[@]}"
