# shellcheck shell=bash
# Shared helpers for loh commands. Source this file; do not run it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# The sourcing script sets its own `set -euo pipefail` (bin/loh does this for
# every command it dispatches).

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
