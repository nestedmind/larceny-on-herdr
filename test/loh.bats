#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  make_plugin_tree
}

@test "dispatch runs lib/loh/<cmd>.sh with the remaining arguments" {
  run "$LOH" hello a "b c"
  [ "$status" -eq 0 ]
  [ "$output" = "hello a b c" ]
}

@test "dispatch works through a symlink to bin/loh" {
  mkdir -p "$BATS_TEST_TMPDIR/linkdir"
  ln -s "$LOH" "$BATS_TEST_TMPDIR/linkdir/loh"
  run "$BATS_TEST_TMPDIR/linkdir/loh" hello x
  [ "$status" -eq 0 ]
  [ "$output" = "hello x" ]
}

@test "help lists the commands and not common" {
  run "$LOH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: loh <command>"* ]]
  [[ "$output" == *"hello"* ]]
  [[ "$output" != *"common"* ]]
}

@test "--help and -h behave like help" {
  run "$LOH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: loh <command>"* ]]
  run "$LOH" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: loh <command>"* ]]
}

@test "--version prints the plugin version from plugin.json" {
  run "$LOH" --version
  [ "$status" -eq 0 ]
  [ "$output" = "9.8.7" ]
}

@test "the real bin/loh reports version 0.1.0" {
  run "$REPO_ROOT/bin/loh" --version
  [ "$status" -eq 0 ]
  [ "$output" = "0.1.0" ]
}

@test "unknown command exits 2 with usage on stderr" {
  run --separate-stderr "$LOH" nosuchcmd
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown command: nosuchcmd"* ]]
  [[ "$stderr" == *"Usage: loh <command>"* ]]
}

@test "no arguments exits 2 with usage on stderr" {
  run --separate-stderr "$LOH"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Usage: loh <command>"* ]]
}

@test "common is not a command" {
  run --separate-stderr "$LOH" common
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown command: common"* ]]
}

@test "a command name with path characters is rejected, not executed" {
  printf 'echo escaped\n' >"$PLUGIN_TREE/escape.sh"
  run --separate-stderr "$LOH" ../../escape
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown command"* ]]
}
