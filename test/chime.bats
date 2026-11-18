#!/usr/bin/env bats
# `loh chime [on|off]` and the chime_setting / chime_state helpers in common.sh.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  make_plugin_tree
  cp "$REPO_ROOT/lib/loh/chime.sh" "$PLUGIN_TREE/lib/loh/chime.sh"
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS/.loh" "$WS/api/deep"
  printf 'name: demo\nrepos:\n  - name: api\n    path: ./api\n    branch: main\n    github: acme/api\n' >"$WS/.loh/workspace.md"
  export LOH_WORKSPACE="$WS"
  unset LOH_CHIME
}

@test "chime with no argument prints on when nothing was set" {
  run "$LOH" chime
  [ "$status" -eq 0 ]
  [ "$output" = on ]
}

@test "chime off writes .loh/chime and chime on writes it back" {
  run "$LOH" chime off
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/.loh/chime")" = off ]
  run "$LOH" chime
  [ "$output" = off ]
  run "$LOH" chime on
  [ "$(cat "$WS/.loh/chime")" = on ]
  run "$LOH" chime
  [ "$output" = on ]
  [ -z "$(ls "$WS/.loh" | grep 'chime\.tmp')" ]
}

@test "chime off in the workspace manifest is the default when there is no .loh/chime, and the file wins over it" {
  printf 'name: demo\nchime: off\nrepos:\n  - name: api\n    path: ./api\n    branch: main\n    github: acme/api\n' >"$WS/.loh/workspace.md"
  run "$LOH" chime
  [ "$output" = off ]
  "$LOH" chime on
  run "$LOH" chime
  [ "$output" = on ]
}

@test "chime works from a folder below the workspace" {
  unset LOH_WORKSPACE
  cd "$WS/api/deep"
  run "$LOH" chime off
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/.loh/chime")" = off ]
}

@test "chime with another argument prints usage and exits 2, writing nothing" {
  run --separate-stderr "$LOH" chime loud
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh chime [on|off]"* ]]
  run --separate-stderr "$LOH" chime on now
  [ "$status" -eq 2 ]
  [ ! -e "$WS/.loh/chime" ]
}

state_of() {
  bash -c 'source "$1/lib/loh/common.sh"; chime_state "$2"' _ "$PLUGIN_TREE" "$WS"
}

@test "chime_state: LOH_CHIME=0 and =1 override the file and the manifest, and 1 wins over both" {
  printf 'off\n' >"$WS/.loh/chime"
  printf 'name: demo\nchime: off\nrepos:\n  - name: api\n    path: ./api\n    branch: main\n    github: acme/api\n' >"$WS/.loh/workspace.md"
  [ "$(state_of)" = off ]
  [ "$(LOH_CHIME=1 state_of)" = on ]
  printf 'on\n' >"$WS/.loh/chime"
  [ "$(LOH_CHIME=0 state_of)" = off ]
  [ "$(LOH_CHIME=maybe state_of)" = on ]
}

@test "chime_state: a file that holds anything but on or off is ignored" {
  printf 'loud\n' >"$WS/.loh/chime"
  [ "$(state_of)" = on ]
}
