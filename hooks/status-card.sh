#!/usr/bin/env bash
# Claude Code hook: publish this agent's status card as herdr labels.
#
# Wired in hooks/hooks.json to UserPromptSubmit, PreToolUse, PostToolUse and
# Stop. Claude Code passes the event as JSON on stdin. The script writes
# `step=` (and `pr=` after `gh pr create`) with `hc label` on the terminal
# named in HC_TERMINAL_ID.
#
# It never fails and never blocks: outside herdr, on bad input, or when hc
# fails, it exits 0 and writes nothing.
set +e +u +o pipefail

[[ -n "${HC_TERMINAL_ID:-}" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v hc >/dev/null 2>&1 || exit 0

input="$(cat)"
[[ -n "$input" ]] || exit 0

# field <jq filter>: print one field of the hook input, or nothing.
field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

# clean <text>: drop control characters (newlines included) and cut to 60
# characters. Keep in step with clean() in lib/loh/card.sh.
clean() {
  local v
  v="$(printf '%s' "$1" | tr -d '\000-\037\177')"
  printf '%s' "${v:0:60}"
}

# label <k=v>...: set labels (values cleaned), swallowing every failure.
label() {
  local args=() kv
  for kv in "$@"; do args+=("${kv%%=*}=$(clean "${kv#*=}")"); done
  # hooks.json already bounds the hook at 5 s. Use timeout (GNU) or gtimeout
  # (Homebrew coreutils) when present; stock macOS has neither, so call hc
  # directly there.
  local t=""
  if command -v timeout >/dev/null 2>&1; then
    t=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    t=gtimeout
  fi
  if [[ -n "$t" ]]; then
    "$t" 3 hc label "$HC_TERMINAL_ID" "${args[@]}" >/dev/null 2>&1
  else
    hc label "$HC_TERMINAL_ID" "${args[@]}" >/dev/null 2>&1
  fi
}

# rel_path <abs path> <cwd>: the path relative to the repo that holds the file
# (found from the file's own folder, or the nearest one that exists), else
# relative to the repo of cwd, else unchanged.
rel_path() {
  local p="$1" cwd="$2" root d
  d="$(dirname "$p")"
  while [[ "$d" == /* && ! -d "$d" && "$d" != / ]]; do d="$(dirname "$d")"; done
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" ||
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || root="$cwd"
  root="${root%/}"
  if [[ -n "$root" && "$p" == "$root/"* ]]; then
    printf '%s' "${p#"$root"/}"
  else
    printf '%s' "$p"
  fi
}

# project_test_cmd <cwd>: the `test:` line of the nearest .larceny/config.md.
project_test_cmd() {
  local dir="$1" line
  [[ "$dir" == /* ]] || return 0 # a relative cwd is bad input; do not walk it
  while [[ -n "$dir" ]]; do
    if [[ -f "$dir/.larceny/config.md" ]]; then
      line="$(grep -m1 -E '^[[:space:]]*test:' "$dir/.larceny/config.md")"
      line="${line#*:}"
      printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^`//' -e 's/`$//'
      return 0
    fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
}

# is_test_cmd <command words...> <cwd via TEST_CWD>: true when the command runs
# the project's tests. Each word of the configured test command must be a
# prefix of the matching word of the command, so `bats test/` matches
# `bats test/loh.bats`. Without a config, common test runners match.
is_test_cmd() {
  local -a words=("$@") want
  local cfg i ok
  cfg="$(project_test_cmd "$TEST_CWD")"
  for t in "$cfg" "npm test" "npm run test" "pnpm test" "yarn test" "pytest" "cargo test" "go test" "make test"; do
    [[ -n "$t" ]] || continue
    read -r -a want <<<"$t"
    ok=1
    for i in "${!want[@]}"; do
      [[ "${words[$i]:-}" == "${want[$i]}"* ]] || {
        ok=""
        break
      }
    done
    [[ -n "$ok" ]] && return 0
  done
  return 1
}

# bash_step <command>: step text for a Bash tool call.
bash_step() {
  local -a w
  local first="${1%%$'\n'*}" i sub=""
  read -r -a w <<<"$first"
  while [[ ${#w[@]} -gt 0 && "${w[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    w=("${w[@]:1}")
  done
  [[ ${#w[@]} -gt 0 ]] || {
    printf 'running a command'
    return
  }
  if is_test_cmd "${w[@]}"; then
    printf 'running tests'
    return
  fi
  local tool="${w[0]}" start=1
  if [[ "$tool" == loh && ( "${w[1]:-}" == git || "${w[1]:-}" == gh ) ]]; then
    tool="${w[1]}"
    start=3 # loh git <persona> <subcommand>
  fi
  if [[ "$tool" == git || "$tool" == gh ]]; then
    for ((i = start; i < ${#w[@]}; i++)); do
      case "$tool:${w[$i]}" in
        git:-C | git:-c | git:--git-dir | git:--work-tree | git:--namespace | git:--config-env | gh:-R | gh:--repo)
          i=$((i + 1)) # skip the option's value
          continue
          ;;
      esac
      [[ "${w[$i]}" == -* ]] && continue
      sub="${w[$i]}"
      break
    done
    if [[ -n "$sub" ]]; then
      printf '%s %s' "$tool" "$sub"
      return
    fi
  fi
  printf 'running a command'
}

# Subagents share the session's hooks; the card belongs to the main agent.
[[ -z "$(field '.agent_id')" ]] || exit 0

event="$(field '.hook_event_name')"
cwd="$(field '.cwd')"
[[ -n "$cwd" ]] || cwd="$PWD"
TEST_CWD="$cwd"

case "$event" in
  UserPromptSubmit)
    label "step=reading the prompt"
    ;;
  PreToolUse)
    tool="$(field '.tool_name')"
    case "$tool" in
      Edit | Write | MultiEdit | NotebookEdit)
        file="$(field '.tool_input.file_path // .tool_input.notebook_path')"
        if [[ -n "$file" ]]; then
          rel="$(rel_path "$file" "$cwd")"
          # The label value holds 60 characters: "editing " plus the path. Keep
          # the end of a long path, where the file name is.
          if ((${#rel} > 52)); then rel="...${rel: -49}"; fi
          label "step=editing $rel"
        else
          label "step=running a command"
        fi
        ;;
      Bash)
        label "step=$(bash_step "$(field '.tool_input.command')")"
        ;;
      *)
        label "step=running a command"
        ;;
    esac
    ;;
  PostToolUse)
    [[ "$(field '.tool_name')" == Bash ]] || exit 0
    command="$(field '.tool_input.command')"
    if [[ "$command" =~ (^|[[:space:]])gh[[:space:]]+([^[:space:]]+[[:space:]]+)*pr[[:space:]]+create ]]; then
      stdout="$(field '.tool_response.stdout')"
      if [[ "$stdout" =~ /pull/([0-9]+) ]]; then
        label "pr=${BASH_REMATCH[1]}"
      fi
    fi
    ;;
  Stop | StopFailure)
    label "step=idle"
    ;;
esac
exit 0
