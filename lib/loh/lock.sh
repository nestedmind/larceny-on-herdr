# shellcheck shell=bash
# loh lock <name>: set the with_matt=1 label on a crew agent.
#
# The label tells `loh say` to leave the agent alone while Matt talks to it.
# Locking is idempotent and works only on terminals labelled with this
# workspace's crew. open.sh, unlock.sh, close.sh and status.sh source this
# file for crew_name, crew_terminal and set_lock; sourced, it runs nothing.
set -euo pipefail
# shellcheck source=lib/loh/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# crew_name: the workspace name from .loh/workspace.md, which is the value of
# the crew label on every terminal of this workspace. Trimmed, with one pair of
# surrounding quotes removed, the same rule as _manifest_value.
crew_name() {
  local root name
  root="$(workspace_root)" || exit 1
  name="$(sed -n 's/^name:[[:space:]]*//p' "$root/.loh/workspace.md" | head -n 1)"
  name="${name%"${name##*[![:space:]]}"}"
  if [[ "$name" =~ ^\"(.*)\"$ || "$name" =~ ^\'(.*)\'$ ]]; then
    name="${BASH_REMATCH[1]}"
  fi
  [[ -n "$name" ]] || die "no name: in $root/.loh/workspace.md"
  printf '%s\n' "$name"
}

# crew_terminal <name>: print `hc get <name> --json`, but die unless the
# terminal exists and carries this workspace's crew label.
crew_terminal() {
  local who="$1" crew info have
  need jq
  crew="$(crew_name)"
  info="$(hc_json get "$who" 2>/dev/null)" || die "cannot find a terminal named $who"
  have="$(jq -r '.labels.crew // ""' <<<"$info")"
  [[ "$have" == "$crew" ]] || die "$who is not in crew $crew; refusing to touch it"
  printf '%s\n' "$info"
}

# set_lock <name> on|off: set or remove with_matt on a crew terminal. Does
# nothing when the label is already as wanted.
set_lock() {
  local who="$1" mode="$2" info now
  info="$(crew_terminal "$who")"
  now="$(jq -r '.labels.with_matt // ""' <<<"$info")"
  if [[ "$mode" == on ]]; then
    if [[ "$now" == 1 ]]; then
      echo "$who is already locked"
    else
      hc label "$who" with_matt=1 >/dev/null
      echo "$who is locked: with Matt"
    fi
  else
    if [[ -z "$now" ]]; then
      echo "$who is not locked"
    else
      hc label "$who" with_matt= >/dev/null
      echo "$who is unlocked"
    fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: loh lock <name>" >&2
    exit 2
  fi
  set_lock "$1" on
fi
