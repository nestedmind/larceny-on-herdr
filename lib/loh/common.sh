# shellcheck shell=bash
# Shared helpers for loh commands. Source this file; do not run it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# bin/loh runs each command as a separate `bash lib/loh/<cmd>.sh`, so shell
# options do not carry over: every command script sets its own
# `set -euo pipefail` before sourcing this file.

# die <message...>: print "loh: <message>" on stderr and exit 1.
die() {
  printf 'loh: %s\n' "$*" >&2
  exit 1
}

# need <cmd>: die unless <cmd> is on PATH.
need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# hc_json <args...>: run `hc <args...> --json` and print its output.
# Dies if hc is missing; otherwise returns hc's own exit status.
hc_json() {
  need hc
  hc "$@" --json
}

# workspace_root: print the workspace root, the folder that holds
# .loh/workspace.md. Walks up from $PWD. LOH_WORKSPACE, when set, overrides
# the walk and must name an existing directory.
workspace_root() {
  if [[ -n "${LOH_WORKSPACE:-}" ]]; then
    [[ -d "$LOH_WORKSPACE" ]] || die "LOH_WORKSPACE is not a directory: $LOH_WORKSPACE"
    printf '%s\n' "$LOH_WORKSPACE"
    return 0
  fi
  local dir="$PWD"
  while :; do
    if [[ -f "$dir/.loh/workspace.md" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
  die "no .loh/workspace.md found in $PWD or any parent (set LOH_WORKSPACE to override)"
}

# manifest_path: print the path of the workspace manifest,
# <root>/.loh/workspace.md. Every reader of the manifest goes through here.
# When the file is missing it still prints that path, so callers report it.
manifest_path() {
  local root
  root="$(workspace_root)" || exit 1
  printf '%s\n' "$root/.loh/workspace.md"
}

# ---------------------------------------------------------------------------
# Workspace manifest: .loh/workspace.md
#
#   name: demo                 workspace name (required); the crew= label
#   pane_mode: auto            Claude permission mode for crew panes
#   repos:
#     - name: api              repo name (required)
#       path: ./api            relative to the workspace root (required)
#       branch: main           default branch (required)
#       github: owner/api      owner/repo for gh -R (required)
#
# pane_mode is one of default, acceptEdits, auto, plan, dontAsk. bypassPermissions
# is refused on purpose: crew panes must never skip every permission check.
#
# Any top-level key other than name, pane_mode, repos and board is an
# error, so a typo such as `pane_mod:` cannot silently fall back to the default.
# board is accepted and ignored. `#` comment lines are ignored.
# ---------------------------------------------------------------------------

LOH_PANE_MODES=" default acceptEdits auto plan dontAsk "

# _manifest_value <raw>: trim and strip one pair of surrounding quotes.
_manifest_value() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'(.*)\'$ ]]; then
    v="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$v"
}

# manifest_load: parse the manifest into globals. Dies on a missing or
# malformed manifest.
#   WS_ROOT WS_NAME WS_PANE_MODE
#   REPO_NAMES[] REPO_PATHS[] REPO_BRANCHES[] REPO_GITHUBS[]
manifest_load() {
  WS_ROOT="$(workspace_root)" || exit 1
  local file
  file="$(manifest_path)" || exit 1
  [[ -f "$file" ]] || die "manifest not found: $file"
  WS_NAME=""
  WS_PANE_MODE="auto"
  REPO_NAMES=()
  REPO_PATHS=()
  REPO_BRANCHES=()
  REPO_GITHUBS=()

  local line key val n=0 in_repos="" cur=-1
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ "$line" =~ ^repos:[[:space:]]*$ ]]; then
      in_repos=1
    elif [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
      in_repos=""
      key="${BASH_REMATCH[1]}"
      val="$(_manifest_value "${BASH_REMATCH[2]}")"
      case "$key" in
        name) WS_NAME="$val" ;;
        pane_mode) WS_PANE_MODE="$val" ;;
        board) ;;
        *) die "$file: line $n: unknown key '$key' (allowed: name, pane_mode, repos, board)" ;;
      esac
    elif [[ -n "$in_repos" && "$line" =~ ^[[:space:]]+-[[:space:]]+([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
      cur=$((cur + 1))
      REPO_NAMES[cur]="" REPO_PATHS[cur]="" REPO_BRANCHES[cur]="" REPO_GITHUBS[cur]=""
      key="${BASH_REMATCH[1]}"
      val="$(_manifest_value "${BASH_REMATCH[2]}")"
      _manifest_repo_field "$cur" "$key" "$val"
    elif [[ -n "$in_repos" && $cur -ge 0 && "$line" =~ ^[[:space:]]+([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="$(_manifest_value "${BASH_REMATCH[2]}")"
      _manifest_repo_field "$cur" "$key" "$val"
    else
      die "$file: line $n: cannot parse: $line"
    fi
  done <"$file"

  [[ -n "$WS_NAME" ]] || die "$file: missing required key 'name:'"
  [[ "$WS_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "$file: name '$WS_NAME' may only hold letters, digits, '.', '_' and '-'"
  [[ "$LOH_PANE_MODES" == *" $WS_PANE_MODE "* ]] || die "$file: pane_mode '$WS_PANE_MODE' is not one of:${LOH_PANE_MODES}"
  [[ ${#REPO_NAMES[@]} -gt 0 ]] || die "$file: no repos listed under 'repos:'"
  local i j
  for i in "${!REPO_NAMES[@]}"; do
    [[ -n "${REPO_NAMES[i]}" ]] || die "$file: repo entry $((i + 1)) has no name"
    [[ -n "${REPO_PATHS[i]}" ]] || die "$file: repo '${REPO_NAMES[i]}' is missing 'path'"
    [[ -n "${REPO_BRANCHES[i]}" ]] || die "$file: repo '${REPO_NAMES[i]}' is missing 'branch'"
    [[ -n "${REPO_GITHUBS[i]}" ]] || die "$file: repo '${REPO_NAMES[i]}' is missing 'github'"
    for ((j = 0; j < i; j++)); do
      [[ "${REPO_NAMES[j]}" != "${REPO_NAMES[i]}" ]] || die "$file: duplicate repo name '${REPO_NAMES[i]}'"
    done
  done
}

# _manifest_repo_field <index> <key> <value>
_manifest_repo_field() {
  case "$2" in
    name) REPO_NAMES[$1]="$3" ;;
    path) REPO_PATHS[$1]="$3" ;;
    branch) REPO_BRANCHES[$1]="$3" ;;
    github) REPO_GITHUBS[$1]="$3" ;;
  esac
}

# repo_lookup <name>: set REPO_I to the repo's index; die if it is unknown.
repo_lookup() {
  local i
  for i in "${!REPO_NAMES[@]}"; do
    if [[ "${REPO_NAMES[i]}" == "$1" ]]; then
      # shellcheck disable=SC2034 # read by the commands that source this file
      REPO_I="$i"
      return 0
    fi
  done
  die "unknown repo '$1' (manifest lists: ${REPO_NAMES[*]})"
}

# repo_dir <index>: print the repo's absolute path.
repo_dir() {
  local p="${REPO_PATHS[$1]}"
  if [[ "$p" == /* ]]; then
    printf '%s\n' "$p"
  else
    printf '%s\n' "$WS_ROOT/${p#./}"
  fi
}

# config_values <file> <key>: print the value of each `key: value` line of a
# larceny config, one per line.
config_values() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^$2:[[:space:]]*(.*)$ ]]; then
      _manifest_value "${BASH_REMATCH[1]}"
      printf '\n'
    fi
  done <"$1"
}

# ---------------------------------------------------------------------------
# Agent helpers (hc terminals addressed by name)
# ---------------------------------------------------------------------------

# agent_state <name>: print live, finished or none.
agent_state() {
  local out st
  out="$(hc_json get "$1" 2>/dev/null)" || {
    echo none
    return 0
  }
  st="$(jq -r '.state // "none"' <<<"$out" 2>/dev/null)" || st=none
  case "$st" in
    live | finished) echo "$st" ;;
    *) echo none ;;
  esac
}

# wait_idle <name> <timeout-seconds>: poll `hc get` until status.state is
# "idle". Returns 0 once idle, 1 on timeout, 2 if the terminal finished first.
# LOH_POLL (default 1) is the pause between polls in seconds.
wait_idle() {
  local name="$1" timeout="$2" deadline out st fin
  deadline=$((SECONDS + timeout))
  while :; do
    out="$(hc_json get "$name" 2>/dev/null)" || out=""
    st="$(jq -r '.status.state // ""' <<<"$out" 2>/dev/null)" || st=""
    [[ "$st" == "idle" ]] && return 0
    fin="$(jq -r '.state // ""' <<<"$out" 2>/dev/null)" || fin=""
    [[ "$fin" == "finished" ]] && return 2
    ((SECONDS >= deadline)) && return 1
    sleep "${LOH_POLL:-1}"
  done
}

# agent_crew <name>: print the terminal's crew label ("" if none).
agent_crew() {
  hc_json get "$1" 2>/dev/null | jq -r '(.labels // {})
    | if type == "array"
      then (map(select(type == "string" and test("="))
                | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}) | add // {})
      else . end
    | .crew // ""' 2>/dev/null || true
}

# start_and_prompt <name> <prompt> <hc run args...>: run the terminal, wait
# for idle, then send the prompt. If the agent never reaches idle, the prompt
# is not sent (a startup dialog would eat it) and this dies with guidance.
start_and_prompt() {
  local name="$1" prompt="$2" timeout="${LOH_START_TIMEOUT:-60}" rc=0
  shift 2
  need hc
  hc run "$@" >/dev/null
  wait_idle "$name" "$timeout" || rc=$?
  case "$rc" in
    0) ;;
    2) die "$name exited before it was ready (check the agent name and flags), so no prompt was sent. Inspect it with: hc read $name" ;;
    *) die "$name did not reach idle within ${timeout}s, so no prompt was sent. Inspect it with: hc read $name" ;;
  esac
  hc send "$name" "$prompt"
}
