#!/usr/bin/env bats
# Tests for loh lock, unlock, open and close, with fake hc and herdr-app.

bats_require_minimum_version 1.5.0
load test_helper
load crew_helper

setup() {
  use_routed_hc
  LOH="$REPO_ROOT/bin/loh"
  add_terminal sucre t9 '{"crew":"sandbox","role":"coder","task":"api#3"}'
  add_terminal locked t10 '{"crew":"sandbox","role":"coder","with_matt":"1"}'
  add_terminal other t11 '{"crew":"elsewhere","role":"coder"}'
  add_terminal plain t12 '{"role":"coder"}'
}

hc_log() { cat "$FAKE_HC_LOG"; }
app_log() { cat "$FAKE_APP_LOG"; }

@test "lock sets with_matt=1 on the agent" {
  run "$LOH" lock sucre
  [ "$status" -eq 0 ]
  [ "$(grep -c '^label' "$FAKE_HC_LOG")" -eq 1 ]
  grep -qx $'label\tsucre\twith_matt=1' "$FAKE_HC_LOG"
}

@test "lock on an agent that is already locked succeeds and changes nothing" {
  run "$LOH" lock locked
  [ "$status" -eq 0 ]
  ! grep -q '^label' "$FAKE_HC_LOG"
}

@test "unlock removes the with_matt label" {
  run "$LOH" unlock locked
  [ "$status" -eq 0 ]
  grep -qx $'label\tlocked\twith_matt=' "$FAKE_HC_LOG"
}

@test "unlock on an agent that is not locked succeeds and changes nothing" {
  run "$LOH" unlock sucre
  [ "$status" -eq 0 ]
  ! grep -q '^label' "$FAKE_HC_LOG"
}

@test "lock refuses a terminal of another crew" {
  run --separate-stderr "$LOH" lock other
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"other"*"sandbox"* ]]
  ! grep -q '^label' "$FAKE_HC_LOG"
}

@test "unlock refuses a terminal with no crew label" {
  run --separate-stderr "$LOH" unlock plain
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"plain"* ]]
  ! grep -q '^label' "$FAKE_HC_LOG"
}

@test "lock refuses a name hc does not know" {
  run --separate-stderr "$LOH" lock ghost
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"ghost"* ]]
  ! grep -q '^label' "$FAKE_HC_LOG"
}

@test "lock without a name prints usage and exits 2" {
  run --separate-stderr "$LOH" lock
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh lock <name>"* ]]
}

@test "lock outside a workspace fails clearly" {
  unset LOH_WORKSPACE
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr "$LOH" lock sucre
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"workspace.md"* ]]
}

@test "lock reads the crew name from the manifest" {
  printf 'name: elsewhere\n' >"$WS/.loh/workspace.md"
  run "$LOH" lock other
  [ "$status" -eq 0 ]
  run --separate-stderr "$LOH" lock sucre
  [ "$status" -eq 1 ]
}

@test "lock strips one pair of double or single quotes from the manifest name" {
  printf 'name: "sandbox"\n' >"$WS/.loh/workspace.md"
  run "$LOH" lock sucre
  [ "$status" -eq 0 ]
  printf "name:   'sandbox'  \n" >"$WS/.loh/workspace.md"
  run "$LOH" unlock locked
  [ "$status" -eq 0 ]
}

@test "status finds the crew when the manifest name is quoted" {
  printf 'name: "sandbox"\n' >"$WS/.loh/workspace.md"
  run "$LOH" status
  grep -qx $'ls\t--label\tcrew=sandbox\t--json' "$FAKE_HC_LOG"
}

@test "open locks the agent and keeps its terminal in a tab the first time" {
  run "$LOH" open sucre
  [ "$status" -eq 0 ]
  grep -qx $'label\tsucre\twith_matt=1' "$FAKE_HC_LOG"
  [ "$(app_log)" = $'status\ndo\tterminal.keep\t--terminal\tt9\t--place\ttab' ]
}

@test "open focuses the agent when it already has a pane in the app" {
  add_terminal shown t13 '{"crew":"sandbox","role":"reviewer","herdr.tab":"tb1"}'
  run "$LOH" open shown
  [ "$status" -eq 0 ]
  [ "$(app_log)" = $'status\ndo\tagent.focus\t--terminal\tt13' ]
}

@test "open passes the address to herdr-app, never the name" {
  run "$LOH" open sucre
  ! grep -q 'sucre' "$FAKE_APP_LOG"
}

@test "open without a running app still locks and prints hc attach" {
  export FAKE_APP_RUNNING=0
  run "$LOH" open sucre
  [ "$status" -eq 0 ]
  grep -qx $'label\tsucre\twith_matt=1' "$FAKE_HC_LOG"
  [[ "$output" == *"hc attach sucre"* ]]
  [ "$(app_log)" = "status" ]
}

@test "open still locks and prints hc attach when herdr-app fails" {
  export FAKE_APP_EXIT=1
  run "$LOH" open sucre
  [ "$status" -eq 0 ]
  grep -qx $'label\tsucre\twith_matt=1' "$FAKE_HC_LOG"
  [[ "$output" == *"hc attach sucre"* ]]
}

@test "open refuses a terminal of another crew and does not touch the app" {
  run "$LOH" open other
  [ "$status" -eq 1 ]
  ! grep -q '^label' "$FAKE_HC_LOG"
  [ ! -s "$FAKE_APP_LOG" ]
}

@test "close unlocks the agent" {
  run "$LOH" close locked
  [ "$status" -eq 0 ]
  grep -qx $'label\tlocked\twith_matt=' "$FAKE_HC_LOG"
}

@test "close refuses a terminal of another crew" {
  run "$LOH" close other
  [ "$status" -eq 1 ]
  ! grep -q '^label' "$FAKE_HC_LOG"
}

@test "lock files are not commands that run when sourced" {
  # open.sh and close.sh reuse lock.sh's functions; sourcing must not run it.
  run bash -c 'set -euo pipefail; source "$1/lib/loh/lock.sh"; declare -F set_lock' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "set_lock" ]
}
