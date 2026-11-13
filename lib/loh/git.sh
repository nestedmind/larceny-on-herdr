# shellcheck shell=bash
# loh git <persona> <args...>: run git as a persona.
#
# Sets GIT_AUTHOR_* and GIT_COMMITTER_* to the persona's GitHub login and
# noreply email, and GH_TOKEN so pushes work through gh's credential helper.
# Login and id come from `gh api user` with the persona's token and are cached
# in ${XDG_CACHE_HOME:-~/.cache}/larceny-on-herdr/identity-<persona> (line 1:
# login, line 2: email). It never runs `git config`. With no token file, git
# runs on the ambient identity.
#
# Prerequisite: pushes only use GH_TOKEN if gh is git's credential helper. Run
# `gh auth setup-git` once per machine (it edits the user's git config, so
# loh does not do it).
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=gh.sh
source "$(dirname "${BASH_SOURCE[0]}")/gh.sh"

# fetch_identity <persona> <token>: print "<login>\t<email>" from `gh api user`.
fetch_identity() {
  local persona="$1" token="$2" json login id
  json="$(GH_TOKEN="$token" gh api user 2>/dev/null)" ||
    die "could not read the GitHub identity for $persona (gh api user failed)"
  login="$(jq -r '.login // ""' <<<"$json" 2>/dev/null)" || login=""
  id="$(jq -r '.id // "" | tostring' <<<"$json" 2>/dev/null)" || id=""
  if [[ ! "$login" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ || ! "$id" =~ ^[0-9]+$ ]]; then
    die "could not read the GitHub identity for $persona (no login or id in the reply)"
  fi
  printf '%s\t%s+%s@users.noreply.github.com\n' "$login" "$id" "$login"
}

# load_identity <persona> <token>: set IDENT_LOGIN and IDENT_EMAIL, from the
# cache when it holds a valid entry, else from GitHub (then cached).
load_identity() {
  local persona="$1" token="$2" dir file pair tmp
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/larceny-on-herdr"
  file="$dir/identity-$persona"
  if [[ ! -f "$file" ]]; then
    pair="$(fetch_identity "$persona" "$token")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.identity-$persona.XXXXXX")"
    printf '%s\n' "${pair%%$'\t'*}" "${pair#*$'\t'}" >"$tmp"
    mv "$tmp" "$file"
  fi
  {
    IFS= read -r IDENT_LOGIN
    IFS= read -r IDENT_EMAIL
  } <"$file" || true
  if [[ ! "$IDENT_LOGIN" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ||
    ! "$IDENT_EMAIL" =~ ^[0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com$ ]]; then
    die "cached identity for $persona is malformed: $file (delete it to refresh)"
  fi
}

loh_git_main() {
  if [[ $# -lt 2 ]]; then
    echo "Usage: loh git <persona> <args...>" >&2
    exit 2
  fi
  local persona="$1" token IDENT_LOGIN="" IDENT_EMAIL=""
  shift
  persona_check "$persona"
  need git
  token="$(persona_token "$persona")"
  if [[ -n "$token" ]]; then
    need gh
    need jq
    load_identity "$persona" "$token"
    export GIT_AUTHOR_NAME="$IDENT_LOGIN" GIT_AUTHOR_EMAIL="$IDENT_EMAIL"
    export GIT_COMMITTER_NAME="$IDENT_LOGIN" GIT_COMMITTER_EMAIL="$IDENT_EMAIL"
    export GH_TOKEN="$token"
  fi
  exec git "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  loh_git_main "$@"
fi
