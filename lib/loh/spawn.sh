# shellcheck shell=bash
# loh spawn: make a worktree for a ticket and start a coder in it.
# Usage: loh spawn <coder> <repo> <ticket> [--model M]
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  echo "Usage: loh spawn <coder> <repo> <ticket> [--model M]" >&2
  exit 2
}

pos=()
model=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || usage
      model="$2"
      shift 2
      ;;
    -*) usage ;;
    *)
      pos+=("$1")
      shift
      ;;
  esac
done
[[ ${#pos[@]} -eq 3 ]] || usage
coder="${pos[0]}"
repo="${pos[1]}"
ticket="${pos[2]}"

[[ "$coder" =~ ^[a-z][a-z0-9-]*$ ]] || die "coder '$coder' must be a plain lowercase name"
[[ "$ticket" =~ ^[0-9]+$ ]] || die "ticket '$ticket' must be an issue number"

need hc
need jq
need git
need gh
manifest_load
repo_lookup "$repo"
i="$REPO_I"
github="${REPO_GITHUBS[i]}"
base="${REPO_BRANCHES[i]}"
repo_path="$(repo_dir "$i")"
[[ -d "$repo_path" ]] || die "repo '$repo' not found at $repo_path"
config="$repo_path/.larceny/config.md"
[[ -f "$config" ]] || die "no .larceny/config.md in $repo_path (run /larceny:onboard there first)"

# The name must be free: refuse a live terminal, clear a finished one.
case "$(agent_state "$coder")" in
  live) die "$coder is already live; end it first (hc kill $coder) or pick another coder" ;;
  finished) hc rm "$coder" >/dev/null ;;
esac

title="$(gh issue view "$ticket" -R "$github" --json title --jq .title)" ||
  die "could not read $github#$ticket with gh"
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40)"
slug="${slug%-}"
[[ -n "$slug" ]] || slug="work"
branch="$coder/$ticket-$slug"
worktree="$WS_ROOT/.worktrees/$coder-$repo-$ticket"
[[ ! -e "$worktree" ]] || die "worktree already exists: $worktree"

# Two fetches into one repo at once can fail on the ref update, so serialise
# them on a lock file in the repo's git dir (flock), and retry once either way.
fetch_origin() {
  local lock
  lock="$(git -C "$repo_path" rev-parse --path-format=absolute --git-common-dir)/loh-fetch.lock"
  if command -v flock >/dev/null 2>&1; then
    flock "$lock" git -C "$repo_path" fetch -q origin
  else
    git -C "$repo_path" fetch -q origin
  fi
}
fetch_origin || fetch_origin || die "git fetch failed in $repo_path"
mkdir -p "$WS_ROOT/.worktrees"
git -C "$repo_path" worktree add --no-track -b "$branch" "$worktree" "origin/$base" ||
  die "could not create worktree $worktree on $branch"

# From here on a failure leaves a worktree, a branch and maybe a terminal.
# Say exactly how to clear them so the spawn can be retried.
cleanup_hint() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    {
      echo "loh: spawn did not finish. To clean up and retry:"
      echo "  hc kill $coder"
      echo "  hc rm $coder"
      echo "  git -C $repo_path worktree remove --force $worktree"
      echo "  git -C $repo_path branch -D $branch"
    } >&2
  fi
}
trap cleanup_hint EXIT
mkdir -p "$worktree/.larceny"
cp "$config" "$worktree/.larceny/config.md"

# Build the dispatch prompt from the template. Values may hold "&" or "\".
shopt -u patsub_replacement 2>/dev/null || true
value_or() { local v; v="$(config_values "$config" "$1" | head -n 1)"; printf '%s' "${v:-$2}"; }
rules=""
while IFS= read -r r; do
  [[ -n "$r" ]] && rules+="- $r"$'\n'
done < <(config_values "$config" rules)
[[ -n "$rules" ]] || rules="- (none listed)"$'\n'
rules="${rules%$'\n'}"

prompt="$(<"$LOH_ROOT/lib/loh/prompts/coder.md")"
prompt="${prompt//'{{coder}}'/$coder}"
prompt="${prompt//'{{workspace}}'/$WS_NAME}"
prompt="${prompt//'{{github}}'/$github}"
prompt="${prompt//'{{ticket}}'/$ticket}"
prompt="${prompt//'{{worktree}}'/$worktree}"
prompt="${prompt//'{{branch}}'/$branch}"
prompt="${prompt//'{{base}}'/$base}"
prompt="${prompt//'{{test}}'/$(value_or test "(not set)")}"
prompt="${prompt//'{{lint}}'/$(value_or lint "(not set)")}"
prompt="${prompt//'{{build}}'/$(value_or build "(not set)")}"
prompt="${prompt//'{{rules}}'/$rules}"

claude_args=(--agent "larceny:$coder" --permission-mode "$WS_PANE_MODE")
[[ -z "$model" ]] || claude_args+=(--model "$model")

start_and_prompt "$coder" "$prompt" \
  --bg --outlive-parent --name "$coder" --cwd "$worktree" \
  --label "crew=$WS_NAME" --label "role=coder" --label "task=$repo#$ticket" \
  -- claude "${claude_args[@]}"
trap - EXIT
echo "spawned $coder on $branch in $worktree"
