#!/usr/bin/env bats

# install.sh runs against a stubbed PATH (a folder of symlinks to the few system
# tools it needs, plus one stub per external command) and a temp HOME. No test
# installs anything or touches the real rc files or the real ~/.config.

bats_require_minimum_version 1.5.0
load test_helper

# stub <name> <body>: an executable stub that logs its argv, then runs <body>.
stub() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "%s $*" >>"$STUB_LOG"\n' "$1"
    printf '%s\n' "$2"
  } >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

# inst: run install.sh with the restricted PATH; stdin is the caller's.
inst() {
  env PATH="$INSTALL_PATH" bash "$INSTALL"
}

# stub_all: every prerequisite present at the tested version, gh logged in,
# no marketplace or plugin yet.
stub_all() {
  stub hc 'echo "hc 0.1.20"'
  stub herdr-app 'echo "herdr-app 0.1.15"'
  stub git 'echo "git version 2.0.0"'
  stub jq 'echo "jq-1.7"'
  stub gh 'case "$1 $2" in "auth status") [[ -e "$STATE/gh-authed" ]] ;; "auth login") touch "$STATE/gh-authed" ;; esac'
  stub claude '
case "$*" in
  "plugin marketplace list --json") if [[ -e "$STATE/market" ]]; then echo "[{\"name\": \"larceny-on-herdr\"}]"; else echo "[]"; fi ;;
  "plugin marketplace add "*) touch "$STATE/market" ;;
  "plugin list --json") if [[ -e "$STATE/plugin" ]]; then echo "[{\"id\": \"larceny-on-herdr@larceny-on-herdr\"}]"; else echo "[]"; fi ;;
  "plugin install "*) touch "$STATE/plugin" ;;
  --version) echo "2.1.0 (Claude Code)" ;;
esac'
  touch "$STATE/gh-authed"
}

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset HERDR_APP_HOME
  export SHELL=/bin/bash
  STUBS="$BATS_TEST_TMPDIR/stubs"
  SYS="$BATS_TEST_TMPDIR/sys"
  export STATE="$BATS_TEST_TMPDIR/state"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  mkdir -p "$STUBS" "$SYS" "$STATE"
  : >"$STUB_LOG"
  local t p
  for t in bash sh grep mkdir ln readlink cat dirname basename uname sed tr head touch rm; do
    p=$(command -v "$t") && ln -s "$p" "$SYS/$t"
  done
  INSTALL_PATH="$STUBS:$SYS"
  INSTALL="$REPO_ROOT/install.sh"
}

@test "a fresh run adds the marketplace, installs the plugin, edits the rc file and links the mod" {
  stub_all
  run inst </dev/null
  [ "$status" -eq 0 ]
  grep -Fq "claude plugin marketplace add $REPO_ROOT" "$STUB_LOG"
  grep -Fq "claude plugin install larceny-on-herdr@larceny-on-herdr" "$STUB_LOG"
  grep -Fxq "export PATH=\"$REPO_ROOT/bin:\$PATH\"" "$HOME/.bashrc"
  grep -Fq "loh" <(grep -B1 '^export PATH=' "$HOME/.bashrc" | head -1)
  [ "$(readlink "$HOME/.config/herdr-app/mods/crew-office")" = "$REPO_ROOT/office/crew-office" ]
  [[ "$output" == *"loh init"* ]]
  [[ "$output" == *"loh init --new <owner>/<name>"* ]]
  [[ "$output" == *"normal terminal"* ]]
  [[ "$output" == *"herdr core updates"* ]]
  [[ "$output" == *"source"* ]]
}

@test "a fresh run writes no token file and does not run gh auth setup-git" {
  stub_all
  run inst </dev/null
  [ "$status" -eq 0 ]
  ! grep -Fq "setup-git" "$STUB_LOG"
  [ ! -e "$HOME/.config/larceny" ]
  [ ! -e "$HOME/.claude" ]
}

@test "a second run changes nothing and says everything is in place" {
  stub_all
  inst </dev/null
  cp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/rc.before"
  : >"$STUB_LOG"
  run inst </dev/null
  [ "$status" -eq 0 ]
  cmp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/rc.before"
  ! grep -Fq "marketplace add" "$STUB_LOG"
  ! grep -Fq "plugin install" "$STUB_LOG"
  [[ "$output" == *"everything is in place"* ]]
}

@test "the PATH line is added once, also when it is already in the rc file" {
  stub_all
  printf '# mine\nexport PATH="%s/bin:$PATH"\n' "$REPO_ROOT" >"$HOME/.bashrc"
  run inst </dev/null
  inst </dev/null
  [ "$(grep -Fc "export PATH=\"$REPO_ROOT/bin:\$PATH\"" "$HOME/.bashrc")" -eq 1 ]
}

@test "zsh users get ~/.zshrc" {
  stub_all
  SHELL=/usr/bin/zsh run inst </dev/null
  [ "$status" -eq 0 ]
  grep -Fq "$REPO_ROOT/bin" "$HOME/.zshrc"
  [ ! -e "$HOME/.bashrc" ]
}

@test "a missing prerequisite is installed only after a yes" {
  stub_all
  rm "$STUBS/hc"
  stub curl 'echo "touch $STATE/core-installer-ran"'
  run inst <<<"y"
  [ "$status" -eq 0 ]
  grep -Fq "curl -fsSL https://releases.herdr.dev/core/install.sh" "$STUB_LOG"
  [[ "$output" == *"HC_VERSION=0.1.20 sh"* ]]
  [ -e "$STATE/core-installer-ran" ]
}

@test "herdr-app's install is shown with a note that it installs the latest, not the tested 0.1.15" {
  stub_all
  rm "$STUBS/herdr-app"
  stub curl 'echo true'
  run inst <<<"n"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://releases.herdr.dev/app/install.sh | sh"* ]]
  [[ "$output" == *"installs the latest herdr-app"*"0.1.15"*"tested"* ]]
  ! grep -Fq "curl" "$STUB_LOG"
}

@test "a declined install runs nothing, says what was skipped and carries on" {
  stub_all
  rm "$STUBS/hc"
  stub curl 'echo "touch $STATE/core-installer-ran"'
  run inst <<<"n"
  [ "$status" -eq 0 ]
  ! grep -Fq "curl" "$STUB_LOG"
  [ ! -e "$STATE/core-installer-ran" ]
  [[ "$output" == *"curl -fsSL https://releases.herdr.dev/core/install.sh | HC_VERSION=0.1.20 sh"* ]]
  [[ "$output" == *"skipped"* ]]
  grep -Fq "claude plugin install" "$STUB_LOG"
}

@test "no answer at all counts as no" {
  stub_all
  rm "$STUBS/jq"
  stub curl 'echo true'
  run inst </dev/null
  [ "$status" -eq 0 ]
  ! grep -Fq "curl" "$STUB_LOG"
  [[ "$output" == *"jq"* ]]
}

@test "a version that differs from the tested one is a warning, and nothing is changed" {
  stub_all
  stub hc 'echo "hc 0.2.0"'
  run inst </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"*"0.2.0"*"0.1.20"* ]]
  ! grep -Eq "update|install.sh" "$STUB_LOG"
}

@test "gh auth login runs when gh is not logged in" {
  stub_all
  rm "$STATE/gh-authed"
  run inst </dev/null
  [ "$status" -eq 0 ]
  grep -Fq "gh auth login" "$STUB_LOG"
}

@test "gh auth login is skipped when gh is logged in" {
  stub_all
  run inst </dev/null
  ! grep -Fq "gh auth login" "$STUB_LOG"
}

@test "an occupied mod path is reported and left alone" {
  stub_all
  mkdir -p "$HOME/.config/herdr-app/mods/crew-office"
  echo mine >"$HOME/.config/herdr-app/mods/crew-office/file"
  run inst </dev/null
  [ "$status" -eq 0 ]
  [ -d "$HOME/.config/herdr-app/mods/crew-office" ]
  [ ! -L "$HOME/.config/herdr-app/mods/crew-office" ]
  [ "$(cat "$HOME/.config/herdr-app/mods/crew-office/file")" = mine ]
  [[ "$output" == *"crew-office"*"leaving it alone"* ]]
}

@test "a link that points elsewhere is left alone" {
  stub_all
  mkdir -p "$HOME/.config/herdr-app/mods" "$BATS_TEST_TMPDIR/other"
  ln -s "$BATS_TEST_TMPDIR/other" "$HOME/.config/herdr-app/mods/crew-office"
  run inst </dev/null
  [ "$(readlink "$HOME/.config/herdr-app/mods/crew-office")" = "$BATS_TEST_TMPDIR/other" ]
  [[ "$output" == *"leaving it alone"* ]]
}

@test "without claude it prints the two slash commands" {
  stub_all
  rm "$STUBS/claude"
  run inst </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"/plugin marketplace add $REPO_ROOT"* ]]
  [[ "$output" == *"/plugin install larceny-on-herdr@larceny-on-herdr"* ]]
}

@test "when claude plugin fails it prints the two slash commands" {
  stub_all
  stub claude 'case "$*" in "plugin list --json"|"plugin marketplace list --json") echo "[]" ;; *) exit 1 ;; esac'
  run inst </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"/plugin marketplace add $REPO_ROOT"* ]]
}

# on_path: put ~/.local/bin on the PATH install.sh sees, as a real folder.
on_path() {
  mkdir -p "$HOME/.local/bin"
  INSTALL_PATH="$HOME/.local/bin:$INSTALL_PATH"
}

@test "loh is linked into ~/.local/bin when that folder is on PATH" {
  stub_all
  on_path
  run inst </dev/null
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/loh")" = "$REPO_ROOT/bin/loh" ]
  [[ "$output" != *"source "* ]]
}

@test "no symlink is made when ~/.local/bin is not on PATH" {
  stub_all
  mkdir -p "$HOME/.local/bin"
  run inst </dev/null
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/bin/loh" ]
  [ ! -L "$HOME/.local/bin/loh" ]
}

@test "a different loh in ~/.local/bin is left alone and reported" {
  stub_all
  on_path
  printf '#!/bin/sh\n' >"$HOME/.local/bin/loh"
  chmod +x "$HOME/.local/bin/loh"
  run inst </dev/null
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.local/bin/loh" ]
  [[ "$output" == *"$HOME/.local/bin/loh"*"not this repo's"* ]]
  [[ "$output" == *"source "* ]]
}

@test "the reload step comes first in Next when the PATH line was just added" {
  stub_all
  run inst </dev/null
  [ "$status" -eq 0 ]
  next=${output#*Next:}
  [[ "$next" == *"source $HOME/.bashrc"* ]]
  [[ "${next%%source*}" != *"loh init"* ]]
}

@test "no reload step when the PATH line was already there and loh resolves" {
  stub_all
  on_path
  printf 'export PATH="%s/bin:$PATH"\n' "$REPO_ROOT" >"$HOME/.bashrc"
  run inst </dev/null
  [ "$status" -eq 0 ]
  [[ "${output#*Next:}" != *"source "* ]]
}

@test "a second run with the link in place changes nothing" {
  stub_all
  on_path
  inst </dev/null
  cp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/rc.before"
  run inst </dev/null
  [ "$status" -eq 0 ]
  cmp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/rc.before"
  [ "$(readlink "$HOME/.local/bin/loh")" = "$REPO_ROOT/bin/loh" ]
  [[ "$output" == *"everything is in place"* ]]
}
