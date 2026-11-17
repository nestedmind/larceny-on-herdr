#!/usr/bin/env bats
# `loh office-ping` and the open-office check `loh watch` uses (office_open in common.sh).

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  make_plugin_tree
  cp "$REPO_ROOT/lib/loh/office-ping.sh" "$PLUGIN_TREE/lib/loh/office-ping.sh"
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS/.loh" "$WS/api/deep"
  printf 'name: demo\nrepos:\n  - name: api\n    path: ./api\n    branch: main\n    github: acme/api\n' >"$WS/.loh/workspace.md"
}

@test "office-ping writes the time in seconds to .loh/office-open of the workspace" {
  before=$(date +%s)
  LOH_WORKSPACE="$WS" run "$LOH" office-ping
  [ "$status" -eq 0 ]
  t="$(cat "$WS/.loh/office-open")"
  [[ "$t" =~ ^[0-9]+$ ]]
  [ "$t" -ge "$before" ]
  [ "$t" -le "$(date +%s)" ]
}

@test "office-ping finds the workspace from a folder below it" {
  cd "$WS/api/deep"
  run "$LOH" office-ping
  [ "$status" -eq 0 ]
  [ -s "$WS/.loh/office-open" ]
}

@test "office-ping outside a workspace fails and writes nothing" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr "$LOH" office-ping
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"no .loh/workspace.md"* ]]
}

@test "office-ping takes no argument" {
  LOH_WORKSPACE="$WS" run --separate-stderr "$LOH" office-ping now
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh office-ping"* ]]
}

office_open_in() {
  LOH_WORKSPACE="$WS" bash -c 'source "$1/lib/loh/common.sh"; office_open "$2"' _ "$PLUGIN_TREE" "$WS"
}

@test "office_open: a ping from 29 s ago is open, one from 31 s ago is closed" {
  echo $(($(date +%s) - 29)) >"$WS/.loh/office-open"
  run office_open_in
  [ "$status" -eq 0 ]
  echo $(($(date +%s) - 31)) >"$WS/.loh/office-open"
  run office_open_in
  [ "$status" -eq 1 ]
}

@test "office_open: LOH_OFFICE_FRESH changes the window" {
  echo $(($(date +%s) - 31)) >"$WS/.loh/office-open"
  LOH_OFFICE_FRESH=60 run office_open_in
  [ "$status" -eq 0 ]
}

@test "office_open: no file, an empty file and text are all closed" {
  run office_open_in
  [ "$status" -eq 1 ]
  : >"$WS/.loh/office-open"
  run office_open_in
  [ "$status" -eq 1 ]
  echo "1e9" >"$WS/.loh/office-open"
  run office_open_in
  [ "$status" -eq 1 ]
}

@test "office_open: a time far in the future is closed" {
  echo $(($(date +%s) + 3600)) >"$WS/.loh/office-open"
  run office_open_in
  [ "$status" -eq 1 ]
}
