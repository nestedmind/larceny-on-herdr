# shellcheck shell=bash
# loh up: start the workspace's standing agents, scofield and amy, unless they
# are already live. Usage: loh up
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [[ $# -gt 0 ]]; then
  echo "Usage: loh up" >&2
  exit 2
fi

need hc
need jq
manifest_load

# repo_summary: one line per repo for the founding prompts.
repo_summary() {
  local i
  for i in "${!REPO_NAMES[@]}"; do
    printf -- '- %s: %s (default branch %s, GitHub %s)\n' \
      "${REPO_NAMES[i]}" "$(repo_dir "$i")" "${REPO_BRANCHES[i]}" "${REPO_GITHUBS[i]}"
  done
}

# founding_prompt <role-skill> <role-line>
founding_prompt() {
  cat <<EOF
You are running in a herdr terminal for the workspace "$WS_NAME" (root $WS_ROOT). $2

Before anything else, load these with the Skill tool: $1 and larceny-on-herdr:herdr-runtime. The herdr-runtime skill overrides how you start, address and wait on other agents: follow it over larceny's subagent instructions.

The workspace's repos:
$(repo_summary)

Each repo keeps its own .larceny/config.md. Address other agents by name with \`loh say <name> "<text>"\`.
EOF
}

# standing_live <name>: return 0 (and say so) if <name> is live for this
# crew. Die if it is live for another crew: hc names are unique among live
# terminals, so a second one cannot be started. A finished terminal holding
# the name is removed; return 1 when the name is free to start.
standing_live() {
  local name="$1" crew
  case "$(agent_state "$name")" in
    live)
      crew="$(agent_crew "$name")"
      [[ "$crew" == "$WS_NAME" ]] ||
        die "$name is live for crew '${crew:-none}', not '$WS_NAME'; run loh down --all there first"
      echo "$name already live"
      return 0
      ;;
    finished) hc rm "$name" >/dev/null ;;
  esac
  return 1
}

# start_standing <name> <role> <agent> <skill> <role-line>
start_standing() {
  local name="$1" role="$2" agent="$3" skill="$4" line="$5"
  ! standing_live "$name" || return 0
  start_and_prompt "$name" "$(founding_prompt "$skill" "$line")" \
    --bg --no-parent --name "$name" --cwd "$WS_ROOT" \
    --label "crew=$WS_NAME" --label "role=$role" \
    -- claude --agent "$agent" --permission-mode "$WS_PANE_MODE"
  echo "started $name"
}

start_standing scofield coordinator larceny:coordinator larceny:coordinator \
  "You are the coordinator: you write and dispatch tickets with \`loh spawn <coder> <repo> <ticket>\` and track the crew."
start_standing amy reviewer larceny:reviewer larceny:adversarial-review \
  "You are the reviewer: coders message you by name when a PR is ready, and you review it against its ticket."

# loh watch (desktop notifications) runs as its own terminal. It is started
# only when this install has the command, and it is not a Claude session, so
# there is no idle wait and no prompt.
if [[ -f "$LOH_ROOT/lib/loh/watch.sh" ]]; then
  if ! standing_live loh-watch; then
    hc run --bg --no-parent --name loh-watch --cwd "$WS_ROOT" \
      --label "crew=$WS_NAME" --label "role=watch" \
      -- "$LOH_ROOT/bin/loh" watch "$WS_NAME" >/dev/null
    echo "started loh-watch"
  fi
fi
