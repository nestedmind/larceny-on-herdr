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

# office_open <workspace root>: succeed while an office tab is open. The office
# pings `loh office-ping` every 5 s; the file it writes holds the time in
# seconds, and counts for LOH_OFFICE_FRESH seconds (default 15). A missing
# file, one with anything but digits in it, and a time in the future are all
# "closed", so a notification is never lost to a bad file.
office_open() {
  local f="$1/.loh/office-open" t now fresh="${LOH_OFFICE_FRESH:-15}"
  [[ "$fresh" =~ ^[0-9]+$ ]] || fresh=15
  [[ -f "$f" ]] || return 1
  t="$(head -n 1 "$f" 2>/dev/null)" || return 1
  [[ "$t" =~ ^[0-9]{1,12}$ ]] || return 1
  now="$(date +%s)"
  ((t <= now + 5 && now - t <= fresh))
}

# office_props <crew> <workspace root>: print the props the office mod opens
# with, as one line of JSON: the crew name, the workspace folder and this loh.
# `loh init` and `loh office` both open the tab with them.
office_props() {
  need jq
  jq -cn --arg crew "$1" --arg dir "$2" --arg loh "$LOH_ROOT/bin/loh" \
    '{crew: $crew, dir: $dir, loh: $loh}'
}

# office_open_cmd <workspace root> <props>: print the herdr-app command that
# opens the office tab, quoted so it pastes whole.
office_open_cmd() {
  printf 'herdr-app do tab.new --name office --mod crew-office --folder %q --props %q\n' "$1" "$2"
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
#   scofield_args: --flag v    extra arguments for scofield's claude command
#   amy_args: --flag v         extra arguments for amy's claude command
#                              (split on whitespace, never evaluated; optional)
#   idle_minutes: 3            minutes a person sits at their desk after a turn
#                              ends before the office sends them to the kitchen
#                              or lounge (a whole number above zero; default 3)
#   repos:
#     - name: api              repo name (required)
#       path: ./api            relative to the workspace root (required)
#       branch: main           default branch (required)
#       github: owner/api      owner/repo for gh -R (required)
#
# pane_mode is one of default, acceptEdits, auto, plan, dontAsk. bypassPermissions
# is refused on purpose: crew panes must never skip every permission check.
#
# Any top-level key other than name, pane_mode, scofield_args, amy_args, idle_minutes, repos and
# board is an
# error, so a typo such as `pane_mod:` cannot silently fall back to the default.
# scofield_args and amy_args may not hold --dangerously-skip-permissions,
# --allow-dangerously-skip-permissions, --permission-mode, --agent, --settings,
# --allowedTools, --allowed-tools, --permission-prompt-tool, --mcp-config or --add-dir
# (any of them, with a space or =): they would undo pane_mode, the agent's role or what it may do.
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
# malformed manifest. manifest_load_file <file> parses that file instead of the
# workspace's own (loh init checks a new manifest this way before it moves it
# into place).
#   WS_ROOT WS_NAME WS_PANE_MODE WS_IDLE_MINUTES WS_SCOFIELD_ARGS WS_AMY_ARGS
#   (the two args values are raw strings; empty when the key is absent)
#   REPO_NAMES[] REPO_PATHS[] REPO_BRANCHES[] REPO_GITHUBS[]
# shellcheck disable=SC2034 # WS_*_ARGS are read by up.sh, which sources this file
manifest_load() {
  local file
  file="$(manifest_path)" || exit 1
  manifest_load_file "$file"
}

manifest_load_file() {
  WS_ROOT="$(workspace_root)" || exit 1
  local file="$1"
  [[ -f "$file" ]] || die "manifest not found: $file"
  WS_NAME=""
  WS_PANE_MODE="auto"
  WS_IDLE_MINUTES="3"
  WS_SCOFIELD_ARGS=""
  WS_AMY_ARGS=""
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
        idle_minutes) WS_IDLE_MINUTES="$val" ;;
        scofield_args) WS_SCOFIELD_ARGS="$val" ;;
        amy_args) WS_AMY_ARGS="$val" ;;
        board) ;;
        *) die "$file: line $n: unknown key '$key' (allowed: name, pane_mode, scofield_args, amy_args, idle_minutes, repos, board)" ;;
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
  local akey aval aword awords
  for akey in scofield_args amy_args; do
    aval="$([[ $akey == scofield_args ]] && printf '%s' "$WS_SCOFIELD_ARGS" || printf '%s' "$WS_AMY_ARGS")"
    read -r -a awords <<<"$aval" # split as up.sh does: whitespace only, no globbing
    for aword in ${awords[@]+"${awords[@]}"}; do
      case "$aword" in
        --dangerously-skip-permissions | --allow-dangerously-skip-permissions | --permission-mode | --permission-mode=* | --agent | --agent=* | --settings | --settings=* | --allowedTools | --allowedTools=* | --allowed-tools | --allowed-tools=* | --permission-prompt-tool | --permission-prompt-tool=* | --mcp-config | --mcp-config=* | --add-dir | --add-dir=*)
          die "$file: $akey may not contain '$aword': permissions, the agent and settings come from loh, not from the manifest" ;;
      esac
    done
  done
  [[ "$LOH_PANE_MODES" == *" $WS_PANE_MODE "* ]] || die "$file: pane_mode '$WS_PANE_MODE' is not one of:${LOH_PANE_MODES}"
  [[ "$WS_IDLE_MINUTES" =~ ^[1-9][0-9]*$ ]] || die "$file: idle_minutes '$WS_IDLE_MINUTES' must be a whole number of minutes above zero"
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

# ---------------------------------------------------------------------------
# Crew names: larceny's docs/crew-resolution.md
# ---------------------------------------------------------------------------

# _crew_key <key>: print the key's resolved value and return 0, or return 1
# when no repo sets it. Repos are tried in manifest order. A repo's own
# .larceny/config.md wins; else, when that file says `crew: global`, the
# global file (LARCENY_CONFIG_DIR or ~/.config/larceny/global-config.md).
# Both files are read on every call. Needs manifest_load first.
_crew_key() {
  local key="$1" i cfg v mode
  local global="${LARCENY_CONFIG_DIR:-$HOME/.config/larceny}/global-config.md"
  for i in "${!REPO_NAMES[@]}"; do
    cfg="$(repo_dir "$i")/.larceny/config.md"
    [[ -r "$cfg" ]] || continue
    v="$(config_values "$cfg" "$key" | head -n 1)"
    if [[ -n "$v" ]]; then
      printf '%s' "$v"
      return 0
    fi
    mode="$(config_values "$cfg" crew | head -n 1)"
    if [[ "$mode" == global* && -r "$global" ]]; then
      v="$(config_values "$global" "$key" | head -n 1)"
      if [[ -n "$v" ]]; then
        printf '%s' "$v"
        return 0
      fi
    fi
  done
  return 1
}

# crew_load: resolve the crew into globals. Needs manifest_load first.
#   CREW_COORDINATOR CREW_REVIEWER CREW_ADVISOR CREW_TEACHER CREW_PERSON
#   CREW_CODERS[] (the coders in roster order, without the coordinator)
# Shipped names when nothing sets a key; CREW_PERSON is empty then.
# shellcheck disable=SC2034 # read by the commands that source this file
crew_load() {
  local v roster name first=1
  CREW_COORDINATOR="Scofield"
  CREW_CODERS=(Sucre Mahone Sheba Whip)
  CREW_REVIEWER="Amy"
  CREW_ADVISOR="Yoda"
  CREW_TEACHER="Sara"
  CREW_PERSON=""
  if v="$(_crew_key coders)" && [[ "$v" != default ]]; then
    CREW_CODERS=()
    IFS=',' read -r -a roster <<<"$v"
    for name in "${roster[@]}"; do
      name="$(_manifest_value "$name")"
      [[ -n "$name" ]] || continue
      if [[ -n "$first" ]]; then
        CREW_COORDINATOR="$name"
        first=""
      else
        CREW_CODERS+=("$name")
      fi
    done
  fi
  if v="$(_crew_key reviewer)" && [[ "$v" != default ]]; then CREW_REVIEWER="$v"; fi
  if v="$(_crew_key advisor)" && [[ "$v" != default ]]; then CREW_ADVISOR="$v"; fi
  if v="$(_crew_key teacher)" && [[ "$v" != default ]]; then CREW_TEACHER="$v"; fi
  if v="$(_crew_key person)"; then CREW_PERSON="$v"; fi
  return 0
}

# agent_name <name>: the herdr terminal name for a crew name (lower case).
# Dies when the result is not a plain name hc can take.
agent_name() {
  local n="${1,,}"
  [[ "$n" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "crew name '$1' cannot be a terminal name (letters, digits, '.', '_' and '-' only)"
  printf '%s' "$n"
}

# claude_session_dir <cwd>: print the folder where Claude Code keeps the
# sessions of an agent that runs in <cwd>: every non-alphanumeric character of
# the cwd becomes "-", under ${LOH_CLAUDE_PROJECTS:-~/.claude/projects}.
claude_session_dir() {
  printf '%s/%s\n' "${LOH_CLAUDE_PROJECTS:-$HOME/.claude/projects}" \
    "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
}

# end_terminal <name>: `hc kill` the terminal, then wait until `hc get` shows
# it is no longer live, so Claude Code's last write to the session file has
# landed before anything copies it. Waits LOH_KILL_WAIT seconds (default 20),
# looking every LOH_KILL_POLL seconds (default 0.2). A terminal that cannot be
# looked up any more counts as finished. On a timeout it says so on stderr and
# returns 0: the caller archives what is there.
end_terminal() {
  local name="$1" wait="${LOH_KILL_WAIT:-20}" poll="${LOH_KILL_POLL:-0.2}"
  local deadline state
  hc kill "$name" >/dev/null
  deadline=$((SECONDS + wait))
  while :; do
    state="$(hc_json get "$name" 2>/dev/null | jq -r '.state // ""' 2>/dev/null)" || state=""
    [[ "$state" != "live" ]] && return 0
    if ((SECONDS >= deadline)); then
      echo "loh: $name did not finish within ${wait}s of the kill; archiving what is written so far" >&2
      return 0
    fi
    sleep "$poll"
  done
}

# _tree_listing <dir>: one "path size" line per file under <dir>, sorted.
_tree_listing() {
  (
    cd "$1" || exit 1
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$f" "$(wc -c <"$f" | tr -d ' ')"
    done
  )
}

# archive_transcript <name> <cwd> <task>: copy a coder's whole session folder
# to <workspace>/.loh/transcripts/<name>-<repo>-<ticket>/ (-2, -3 ... when the
# name is taken), check the copy has the same files and sizes, and only then
# remove the source. The source is removed only when the coder's cwd is inside
# <workspace>/.worktrees/ (no ".." in it), so the folders of the coordinator,
# the reviewer or the main repo are never touched. Needs manifest_load.
# Returns 0 when there was nothing to copy or the archive is made, 1 when the
# copy failed (the source is then left alone).
archive_transcript() {
  local name="$1" cwd="$2" task="$3"
  local wt="$WS_ROOT/.worktrees/" src label dest base n=2 safe=""
  if [[ -z "$cwd" ]]; then
    echo "no folder recorded for $name; no transcript to archive"
    return 0
  fi
  src="$(claude_session_dir "$cwd")"
  if [[ ! -d "$src" ]]; then
    echo "no transcript folder for $name; nothing to archive"
    return 0
  fi
  [[ "$cwd" == "$wt"?* && "$cwd" != *..* ]] && safe=1
  label="$name"
  if [[ "$task" == *"#"* ]]; then
    label="$name-${task%%#*}-${task#*#}"
  fi
  label="$(printf '%s' "$label" | sed 's/[^A-Za-z0-9._-]/-/g')"
  base="$WS_ROOT/.loh/transcripts/$label"
  dest="$base"
  if ! mkdir -p "$WS_ROOT/.loh/transcripts" 2>/dev/null; then
    echo "loh: cannot make $WS_ROOT/.loh/transcripts; the source is left at $src" >&2
    return 1
  fi
  until mkdir "$dest" 2>/dev/null; do
    dest="$base-$n"
    n=$((n + 1))
    if ((n > 1000)); then
      echo "loh: cannot find a free archive name under $base; the source is left at $src" >&2
      return 1
    fi
  done
  if ! cp -a "$src/." "$dest/" 2>/dev/null ||
    [[ "$(_tree_listing "$src")" != "$(_tree_listing "$dest")" ]]; then
    rm -rf "$dest"
    echo "loh: copying $src failed or did not verify; the source is left at $src" >&2
    return 1
  fi
  if [[ -n "$safe" ]]; then
    rm -rf "$src"
  else
    echo "loh: $name ran outside $wt; the source is left at $src"
  fi
  echo "archived $name's transcript to $dest"
}
