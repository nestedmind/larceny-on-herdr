#!/usr/bin/env bash
# install.sh: set up loh on a new machine in one run. Safe to run again.
#
#   git clone https://github.com/nestedmind/larceny-on-herdr ~/llm-ws/larceny-on-herdr \
#     && ~/llm-ws/larceny-on-herdr/install.sh
#
# It asks before it installs anything. It never writes token files, never runs
# `gh auth setup-git`, and never edits ~/.claude itself (only `claude plugin`
# does, when it installs the plugin).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="larceny-on-herdr@larceny-on-herdr"
MARKET="larceny-on-herdr"
TESTED_HC="0.1.20"
TESTED_APP="0.1.15"
CORE_INSTALL="curl -fsSL https://releases.herdr.dev/core/install.sh | HC_VERSION=$TESTED_HC sh"
APP_INSTALL='curl -fsSL https://releases.herdr.dev/app/install.sh | sh'
CLAUDE_INSTALL='curl -fsSL https://claude.ai/install.sh | bash'

RELOAD_RC=""
DID=()
HAD=()
SKIPPED=()

say() { printf '%s\n' "$*"; }
did() { DID+=("$*"); say "  done: $*"; }
had() { HAD+=("$*"); say "  in place: $*"; }
skip() { SKIPPED+=("$*"); say "  skipped: $*"; }
warn() { say "  warning: $*"; }

# ask <question>: true only for an answer starting with y or Y. No answer
# (end of input) counts as no.
ask() {
  local ans=""
  printf '  %s [y/N] ' "$1"
  read -r ans || ans=""
  [[ "$ans" == [yY]* ]]
}

# pkg_install_cmd <package>: the package-manager command for this machine, or
# nothing when none is known.
pkg_install_cmd() {
  if [[ "$(uname -s)" == Darwin ]]; then
    command -v brew >/dev/null 2>&1 && printf 'brew install %s' "$1"
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    printf 'sudo apt-get install -y %s' "$1"
  elif command -v dnf >/dev/null 2>&1; then
    printf 'sudo dnf install -y %s' "$1"
  elif command -v pacman >/dev/null 2>&1; then
    printf 'sudo pacman -S --noconfirm %s' "$1"
  fi
  return 0
}

# install_cmd <tool>: the command that installs the tool, or nothing.
install_cmd() {
  case "$1" in
    hc) printf '%s' "$CORE_INSTALL" ;;
    herdr-app) printf '%s' "$APP_INSTALL" ;;
    claude) printf '%s' "$CLAUDE_INSTALL" ;;
    git | jq | gh) pkg_install_cmd "$1" ;;
  esac
}

# version_of <tool>: the last word of `<tool> --version`, or nothing.
version_of() {
  local out
  out=$("$1" --version 2>/dev/null | head -1) || return 0
  printf '%s' "${out##* }"
}

# check_tool <tool> <tested-version or "">
check_tool() {
  local tool="$1" tested="$2" cmd ver
  if ! command -v "$tool" >/dev/null 2>&1; then
    cmd=$(install_cmd "$tool")
    if [[ -z "$cmd" ||
      ( "$cmd" == curl* && ! -x "$(command -v curl 2>/dev/null)" ) ]]; then
      say "  $tool is missing, and its install can't be scripted here. Install it yourself, then run install.sh again."
      skip "$tool (not installed; no scripted install on this machine)"
      return 0
    fi
    say "  $tool is missing. Install command:"
    [[ "$tool" != herdr-app ]] ||
      say "  Note: this installs the latest herdr-app; $TESTED_APP is the tested version."
    say "    $cmd"
    if ask "Run it now?"; then
      if bash -c "$cmd"; then
        did "installed $tool"
      else
        skip "$tool (the install command failed)"
        return 0
      fi
    else
      skip "$tool (not installed; run: $cmd)"
      return 0
    fi
    if ! command -v "$tool" >/dev/null 2>&1; then
      say "  $tool is installed but not on PATH yet. Open a new shell, then run install.sh again."
      return 0
    fi
  else
    had "$tool found"
  fi
  if [[ -n "$tested" ]]; then
    ver=$(version_of "$tool")
    if [[ -n "$ver" && "$ver" != "$tested" ]]; then
      warn "$tool is $ver; the tested version is $tested. Nothing was changed."
    fi
  fi
}

say "Prerequisites"
check_tool git ""
check_tool jq ""
check_tool gh ""
check_tool claude ""
check_tool hc "$TESTED_HC"
check_tool herdr-app "$TESTED_APP"

say "GitHub login"
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    had "gh is logged in"
  elif gh auth login; then
    did "logged in with gh auth login"
  else
    skip "gh login (gh auth login did not finish)"
  fi
else
  skip "gh login (gh is not installed)"
fi

say "Claude Code plugin"
print_plugin_steps() {
  say "  In Claude Code, run:"
  say "    /plugin marketplace add $REPO"
  say "    /plugin install $PLUGIN"
}
plugin_step() {
  local changed=0
  if ! command -v claude >/dev/null 2>&1; then
    skip "plugin (claude is not installed; run the two slash commands below once it is)"
    print_plugin_steps
    return 0
  fi
  if ! claude plugin marketplace list --json 2>/dev/null | grep -Eq "\"name\": *\"$MARKET\""; then
    if ! claude plugin marketplace add "$REPO" >/dev/null 2>&1; then
      skip "plugin (claude plugin could not add the marketplace without prompting)"
      print_plugin_steps
      return 0
    fi
    changed=1
  fi
  if ! claude plugin list --json 2>/dev/null | grep -Eq "\"id\": *\"$PLUGIN\""; then
    if ! claude plugin install "$PLUGIN" >/dev/null 2>&1; then
      skip "plugin (claude plugin could not install it without prompting)"
      print_plugin_steps
      return 0
    fi
    changed=1
  fi
  if ((changed)); then
    did "added the marketplace and installed $PLUGIN"
  else
    had "$PLUGIN is installed"
  fi
}
plugin_step

say "PATH"
path_step() {
  local rc line
  case "${SHELL##*/}" in
    zsh) rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *)
      skip "PATH (unknown shell '${SHELL:-}'; add this to your shell's rc file: export PATH=\"$REPO/bin:\$PATH\")"
      return 0
      ;;
  esac
  line="export PATH=\"$REPO/bin:\$PATH\""
  if [[ -f "$rc" ]] && grep -Fxq "$line" "$rc"; then
    had "PATH line in $rc"
    return 0
  fi
  [[ ! -s "$rc" ]] || printf '\n' >>"$rc"
  printf '# Added by loh install.sh\n%s\n' "$line" >>"$rc"
  did "added $REPO/bin to PATH in $rc"
  RELOAD_RC="$rc"
}

# link_step: when ~/.local/bin is on this shell's PATH, link bin/loh into it so
# loh works at once. A different loh already there is left alone.
link_step() {
  local dir="$HOME/.local/bin" target="$HOME/.local/bin/loh" d on=0
  local -a dirs
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [[ "$d" == "$dir" ]] && on=1
  done
  ((on)) || return 0
  if [[ -L "$target" && "$(readlink "$target")" == "$REPO/bin/loh" ]]; then
    had "loh linked at $target"
  elif [[ -e "$target" || -L "$target" ]]; then
    skip "loh link ($target is not this repo's loh; leaving it alone)"
  elif ln -s "$REPO/bin/loh" "$target"; then
    did "linked $target to $REPO/bin/loh"
  else
    skip "loh link (could not link $target)"
  fi
}

# loh_here: true when `loh` in this shell is this repo's bin/loh.
loh_here() {
  local p
  p=$(command -v loh) || return 1
  [[ ! -L "$p" ]] || p=$(readlink "$p")
  [[ "$p" == "$REPO/bin/loh" ]]
}
path_step
link_step

say "Office mod"
mod_step() {
  local mods="${HERDR_APP_HOME:-$HOME/.config/herdr-app}/mods"
  local target="$mods/crew-office" src="$REPO/office/crew-office"
  if [[ -L "$target" && "$(readlink "$target")" == "$src" ]]; then
    had "office mod linked at $target"
  elif [[ -e "$target" || -L "$target" ]]; then
    skip "office mod ($target already exists and is not this repo's crew-office; leaving it alone)"
    say "  $target already exists and does not point at $src, so leaving it alone."
  else
    if mkdir -p "$mods" && ln -s "$src" "$target"; then
      did "linked $target to $src"
    else
      skip "office mod (could not link $target)"
    fi
  fi
}
mod_step

say ""
say "Report"
if ((${#DID[@]})); then
  say "Did:"
  printf '  - %s\n' "${DID[@]}"
fi
if ((${#HAD[@]})); then
  say "Already in place:"
  printf '  - %s\n' "${HAD[@]}"
fi
if ((${#SKIPPED[@]})); then
  say "Skipped:"
  printf '  - %s\n' "${SKIPPED[@]}"
fi
if ((${#DID[@]} == 0 && ${#SKIPPED[@]} == 0)); then
  say "Nothing to do: everything is in place."
fi
say ""
if [[ -n "$RELOAD_RC" ]] && ! loh_here; then
  say "Next:"
  say "  1. Run 'source $RELOAD_RC' (or open a new terminal), so this shell finds loh."
  say "  2. In a repo, run 'loh init' (or 'loh init --new <owner>/<name>' for a new project)."
else
  say "Next: in a repo, run 'loh init' (or 'loh init --new <owner>/<name>' for a new project)."
fi
say "Remember:"
say "  - Start herdr-core from a normal terminal, never from inside Claude Code."
say "  - Decline herdr core updates until they are tested here."
exit 0
