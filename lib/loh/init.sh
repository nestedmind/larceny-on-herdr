# shellcheck shell=bash
# loh init [<repo-path>...] [--workspace <dir>]: set up or extend a workspace.
#
# Makes a workspace (a sibling folder <repo>-crew next to the first repo, or
# the one --workspace names) or adds repos to an existing one, then runs
# `loh up` and opens the office. Safe to run again: a repo already listed (same
# path or same GitHub repo) is left alone, and a run with nothing new changes
# nothing. With no repo path the repo is the git top level of the current
# folder.
#
# Each repo's entry comes from git and gh: name is the folder name, path is
# absolute, github is owner/repo from the origin remote (a repo with no GitHub
# origin is refused), branch is the remote's default branch.
#
# The manifest is written to a temporary file next to it, parsed with the same
# parser every other command uses (manifest_load), and only then moved into
# place, so a failed check never leaves a half-written or changed manifest.
# It never runs /larceny:onboard, changes git config or ~/.claude, or installs
# anything.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { echo "Usage: loh init [<repo-path>...] [--workspace <dir>]" >&2; }

repo_args=()
ws_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      [[ $# -ge 2 && -n "$2" ]] || {
        usage
        exit 2
      }
      ws_arg="$2"
      shift 2
      ;;
    --workspace=*)
      ws_arg="${1#--workspace=}"
      [[ -n "$ws_arg" ]] || {
        usage
        exit 2
      }
      shift
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      repo_args+=("$1")
      shift
      ;;
  esac
done
[[ ${#repo_args[@]} -gt 0 ]] || repo_args=(.)

need git
need jq

# github_slug <url>: print owner/repo for a GitHub remote URL, else fail.
# Accepts https://github.com/o/r, ssh://git@github.com/o/r and git@github.com:o/r,
# each with or without a trailing .git or slash.
github_slug() {
  local rest="$1"
  case "$rest" in
    http://github.com/* | https://github.com/* | https://www.github.com/*)
      rest="${rest#*://}"
      rest="${rest#www.}"
      rest="${rest#github.com/}"
      ;;
    ssh://*@github.com/* | ssh://github.com/*)
      rest="${rest#ssh://}"
      rest="${rest#*@}"
      rest="${rest#github.com/}"
      ;;
    *@github.com:*) rest="${rest#*@github.com:}" ;;
    *) return 1 ;;
  esac
  rest="${rest%/}"
  rest="${rest%.git}"
  [[ "$rest" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s' "$rest"
}

# default_branch <repo dir> <slug>: gh's answer, else origin/HEAD, else fail.
default_branch() {
  local dir="$1" slug="$2" b=""
  if command -v gh >/dev/null 2>&1; then
    b="$(gh repo view "$slug" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)" || b=""
  fi
  if [[ -z "$b" ]]; then
    b="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || b=""
    b="${b#origin/}"
  fi
  [[ -n "$b" ]] || return 1
  printf '%s' "$b"
}

# canon <path>: absolute path with symlinks resolved, when the folder exists.
canon() {
  if [[ -d "$1" ]]; then (cd -P "$1" && pwd); else printf '%s' "$1"; fi
}

# --- the workspace ---------------------------------------------------------

# Resolve every repo first, so a bad one stops us before anything is written.
cand_names=() cand_paths=() cand_branches=() cand_githubs=()
for arg in "${repo_args[@]}"; do
  [[ -d "$arg" ]] || die "$arg is not a folder"
  top="$(git -C "$arg" rev-parse --show-toplevel 2>/dev/null)" || die "$arg is not a git repo"
  top="$(canon "$top")"
  name="$(basename "$top")"
  url="$(git -C "$top" remote get-url origin 2>/dev/null)" || url=""
  slug="$(github_slug "$url")" || die "$name ($top) has no GitHub origin remote${url:+ (origin is $url)}"
  branch="$(default_branch "$top" "$slug")" || die "cannot tell the default branch of $slug (gh did not answer and origin/HEAD is not set)"
  cand_names+=("$name")
  cand_paths+=("$top")
  cand_branches+=("$branch")
  cand_githubs+=("$slug")
done

if [[ -n "$ws_arg" ]]; then
  [[ "$ws_arg" == /* ]] || ws_arg="$PWD/$ws_arg"
  ws="$ws_arg"
else
  ws="$(dirname "${cand_paths[0]}")/${cand_names[0]}-crew"
fi
ws="$(canon "$ws")"
manifest="$ws/.loh/workspace.md"

cur_names=() cur_paths=() cur_githubs=()
is_new=""
if [[ -f "$manifest" ]]; then
  (LOH_WORKSPACE="$ws" manifest_load) || die "the manifest $manifest does not pass its check; fix it first"
  LOH_WORKSPACE="$ws"
  manifest_load
  for i in "${!REPO_NAMES[@]}"; do
    cur_names+=("${REPO_NAMES[i]}")
    cur_paths+=("$(canon "$(repo_dir "$i")")")
    cur_githubs+=("${REPO_GITHUBS[i]}")
  done
else
  is_new=1
fi

# Pick what is new: skip a listed repo, refuse a name clash.
add_i=()
for i in "${!cand_names[@]}"; do
  listed=""
  for j in "${!cur_names[@]}"; do
    if [[ "${cur_paths[j]}" == "${cand_paths[i]}" || "${cur_githubs[j],,}" == "${cand_githubs[i],,}" ]]; then
      listed=1
      break
    fi
  done
  [[ -z "$listed" ]] || continue
  for j in "${!cur_names[@]}"; do
    [[ "${cur_names[j]}" != "${cand_names[i]}" ]] ||
      die "name '${cand_names[i]}' is already listed in $manifest for ${cur_githubs[j]}; ${cand_paths[i]} was not added"
  done
  add_i+=("$i")
  cur_names+=("${cand_names[i]}")
  cur_paths+=("${cand_paths[i]}")
  cur_githubs+=("${cand_githubs[i]}")
done

# --- write the manifest ----------------------------------------------------

# new_entries: the manifest text for the repos being added.
new_entries() {
  local i
  for i in "${add_i[@]}"; do
    printf '  - name: %s\n    path: %s\n    branch: %s\n    github: %s\n' \
      "${cand_names[i]}" "${cand_paths[i]}" "${cand_branches[i]}" "${cand_githubs[i]}"
  done
}

# merged_manifest: the existing manifest with the new entries after its last
# repo entry, so a key that follows `repos:` (such as board:) stays after it.
merged_manifest() {
  local -a lines=()
  local line n=0 in_repos="" last=0 k
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    lines+=("$line")
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ "$line" =~ ^repos:[[:space:]]*$ ]]; then
      in_repos=1
    elif [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*: ]]; then
      in_repos=""
    elif [[ -n "$in_repos" ]]; then
      last=$n
    fi
  done <"$manifest"
  ((last > 0)) || last=$n
  for ((k = 0; k < ${#lines[@]}; k++)); do
    printf '%s\n' "${lines[k]}"
    if ((k + 1 == last)); then new_entries; fi
  done
}

added_names=()
tmp=""
made_dirs=()
cleanup() {
  [[ -z "$tmp" ]] || rm -f "$tmp"
}
trap cleanup EXIT

if [[ ${#add_i[@]} -gt 0 ]]; then
  if [[ -n "$is_new" ]]; then
    [[ -d "$ws" ]] || made_dirs+=("$ws")
    mkdir -p "$ws/.loh"
    made_dirs+=("$ws/.loh")
  fi
  tmp="$ws/.loh/workspace.md.tmp.$$"
  if [[ -n "$is_new" ]]; then
    {
      printf '# .loh/workspace.md\nname: %s\npane_mode: auto\nrepos:\n' "${cand_names[add_i[0]]}"
      new_entries
    } >"$tmp"
  else
    merged_manifest >"$tmp"
  fi
  if ! (LOH_WORKSPACE="$ws" manifest_load_file "$tmp"); then
    rm -f "$tmp"
    tmp=""
    # Take away only what this run made, and only if it is empty.
    for ((k = ${#made_dirs[@]} - 1; k >= 0; k--)); do rmdir "${made_dirs[k]}" 2>/dev/null || true; done
    die "the new manifest did not pass its check, so $manifest is ${is_new:+not made}${is_new:-left as it was}"
  fi
  mv -f "$tmp" "$manifest"
  tmp=""
  for i in "${add_i[@]}"; do added_names+=("${cand_names[i]}"); done
  echo "wrote $manifest: added ${added_names[*]}"
else
  echo "nothing new: $manifest already lists ${cand_names[*]}"
fi

# --- start the crew --------------------------------------------------------

export LOH_WORKSPACE="$ws"
manifest_load
crew_load
COORD="$(agent_name "$CREW_COORDINATOR")"
coord_was_live=""
if [[ -z "$is_new" && ${#add_i[@]} -gt 0 ]]; then
  [[ "$(agent_state "$COORD")" == live ]] && coord_was_live=1
fi

"$LOH_ROOT/bin/loh" up

# Tell a coordinator who was already running, so he onboards the new repos.
if [[ -n "$coord_was_live" ]]; then
  bare=()
  for i in "${add_i[@]}"; do
    [[ -f "${cand_paths[i]}/.larceny/config.md" ]] || bare+=("${cand_names[i]}")
  done
  msg="loh init added to the workspace: ${added_names[*]}. Read .loh/workspace.md for their paths."
  if [[ ${#bare[@]} -gt 0 ]]; then
    bare_list="${bare[*]}"
    msg+=" These have no .larceny/config.md yet, so onboard them: ${bare_list// /, }."
  else
    msg+=" Every one already has a .larceny/config.md."
  fi
  "$LOH_ROOT/bin/loh" say --queue "$COORD" "$msg"
fi

# --- the office ------------------------------------------------------------

props="$(jq -cn --arg crew "$WS_NAME" --arg dir "$ws" '{crew: $crew, dir: $dir}')"
open_cmd="herdr-app do tab.new --name office --mod crew-office --folder $ws --props '$props'"
if office_open "$ws"; then
  echo "the office is already open for $WS_NAME"
elif command -v herdr-app >/dev/null 2>&1 && herdr-app status >/dev/null 2>&1; then
  if herdr-app "do" tab.new --name office --mod crew-office --folder "$ws" --props "$props" >/dev/null; then
    echo "opened the office tab for $WS_NAME"
  else
    echo "could not open the office tab; open it with: $open_cmd"
  fi
else
  echo "herdr-app is not available; open the office later with: $open_cmd"
fi
