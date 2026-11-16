# shellcheck shell=bash
# loh start: start one standing persona (Yoda, Sara, Maya or Opemipo) unless it
# is already live. Usage: loh start <yoda|sara|maya|opemipo>
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  echo "Usage: loh start <yoda|sara|maya|opemipo>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
name="$1"
case "$name" in
  yoda) role=advisor agent=larceny:yoda ;;
  sara) role=teacher agent=larceny:sara ;;
  maya) role=designer agent=maya ;;
  opemipo) role=researcher agent=opemipo ;;
  *) usage ;;
esac

need hc
need jq
manifest_load

# model_in <file> <persona>: print the persona's override from the file's
# `models:` block (indented `<persona>: <model>` lines), or nothing.
model_in() {
  local line in_block=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^models:[[:space:]]*(.*)$ ]]; then
      in_block=1
    elif [[ "$line" =~ ^[[:space:]]+$2:[[:space:]]*(.*)$ && -n "$in_block" ]]; then
      _manifest_value "${BASH_REMATCH[1]}"
      return 0
    elif [[ ! "$line" =~ ^[[:space:]] ]]; then
      in_block=""
    fi
  done <"$1"
}

# resolve_model <persona>: the first repo (manifest order) whose project config
# sets `models:` decides; a repo that says `crew: global` reads the global file.
# docs/crew-resolution.md in larceny describes the rule.
resolve_model() {
  local i cfg m global
  global="${LARCENY_CONFIG_DIR:-$HOME/.config/larceny}/global-config.md"
  for i in "${!REPO_NAMES[@]}"; do
    cfg="$(repo_dir "$i")/.larceny/config.md"
    [[ -f "$cfg" ]] || continue
    m="$(model_in "$cfg" "$1")"
    if [[ -n "$m" ]]; then
      printf '%s' "$m"
      return 0
    fi
    if [[ -f "$global" ]] && grep -qE '^crew:[[:space:]]*global[[:space:]]*$' "$cfg"; then
      m="$(model_in "$global" "$1")"
      if [[ -n "$m" ]]; then
        printf '%s' "$m"
        return 0
      fi
    fi
  done
}

case "$(agent_state "$name")" in
  live)
    crew="$(agent_crew "$name")"
    [[ "$crew" == "$WS_NAME" ]] ||
      die "$name is live for crew '${crew:-none}', not '$WS_NAME'; run loh down --all there first"
    echo "$name already live"
    exit 0
    ;;
  finished) hc rm "$name" >/dev/null ;;
esac

model="$(resolve_model "$name")"
claude_args=(--agent "$agent" --permission-mode "$WS_PANE_MODE")
[[ -z "$model" ]] || claude_args+=(--model "$model")

repos=""
for i in "${!REPO_NAMES[@]}"; do
  repos+="- ${REPO_NAMES[i]}: $(repo_dir "$i") (default branch ${REPO_BRANCHES[i]}, GitHub ${REPO_GITHUBS[i]})"$'\n'
done

prompt="You are running in a herdr terminal for the workspace \"$WS_NAME\" (root $WS_ROOT), started from the office. You work from the workspace folder and are not tied to one repo; when a task needs a project, the person or the coordinator names it in the conversation.

Before anything else, load larceny-on-herdr:herdr-runtime with the Skill tool. It overrides how you address and wait on other agents: follow it over larceny's subagent instructions.

The workspace's repos:
${repos}
Each repo keeps its own .larceny/config.md. Address other agents by name with \`loh say <name> \"<text>\"\`."

start_and_prompt "$name" "$prompt" \
  --bg --no-parent --name "$name" --cwd "$WS_ROOT" \
  --label "crew=$WS_NAME" --label "role=$role" \
  -- claude "${claude_args[@]}"
echo "started $name"
