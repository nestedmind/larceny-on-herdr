# shellcheck shell=bash
# loh gh <persona> <args...>: run gh as a persona.
#
# Reads the token from ${LARCENY_CONFIG_DIR:-~/.config/larceny}/gh-<persona>-token
# and passes it to gh in GH_TOKEN. The token goes through the environment only:
# never argv, output or logs. With no token file, gh runs on the ambient login.
#
# git.sh sources this file for the helpers below; the guard at the end keeps
# them from running gh in that case.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# persona_check <persona>: exit 2 unless it is a plain lowercase name.
persona_check() {
  if [[ ! "$1" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "loh: invalid persona name: $1" >&2
    exit 2
  fi
}

# persona_token_file <persona>: print the token file path.
persona_token_file() {
  printf '%s/gh-%s-token\n' "${LARCENY_CONFIG_DIR:-$HOME/.config/larceny}" "$1"
}

# persona_token <persona>: print the token, or nothing when there is no token
# file. Dies, without printing any contents, when the file exists but cannot be
# read or is empty.
persona_token() {
  local file token=""
  file="$(persona_token_file "$1")"
  [[ -e "$file" ]] || return 0
  [[ -r "$file" ]] || die "token file for $1 exists but is not readable: $file"
  IFS= read -r token <"$file" || [[ -n "$token" ]] || true
  [[ -n "$token" ]] || die "token file for $1 is empty: $file"
  printf '%s\n' "$token"
}

loh_gh_main() {
  if [[ $# -lt 2 ]]; then
    echo "Usage: loh gh <persona> <args...>" >&2
    exit 2
  fi
  local persona="$1" token
  shift
  persona_check "$persona"
  need gh
  token="$(persona_token "$persona")"
  if [[ -n "$token" ]]; then
    export GH_TOKEN="$token"
  fi
  if [[ "${1:-}" != pr || "${2:-}" != merge ]]; then
    exec gh "$@"
  fi
  local rc=0
  gh "$@" || rc=$?
  ((rc == 0)) && merged_flip "$@"
  exit "$rc"
}

# merged_flip <gh args>: after a successful `pr merge <n> -R <repo>` that GitHub reports MERGED, have loh
# status flip the labels of the crew coder whose pr it was. Only a numeric pr and
# an explicit repo are understood; anything else is left to the coder's own hook
# and to `loh status --prs`. Never fails the merge: its output is discarded.
merged_flip() {
  local n="${3:-}" repo="" a
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  shift 3
  while (($#)); do
    a="$1"
    shift
    case "$a" in
      -R | --repo)
        repo="${1:-}"
        shift || true
        ;;
      -R=* | --repo=*) repo="${a#*=}" ;;
    esac
  done
  [[ -n "$repo" && -n "${LOH_ROOT:-}" && -x "$LOH_ROOT/bin/loh" ]] || return 0
  # A zero exit is not a merge: --auto, --disable-auto and a merge queue exit 0 with the PR still open.
  [[ "$(gh pr view "$n" -R "$repo" --json state --jq .state 2>/dev/null)" == MERGED ]] || return 0
  "$LOH_ROOT/bin/loh" status --merged "$n" "$repo" >/dev/null 2>&1 || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  loh_gh_main "$@"
fi
