#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  # shellcheck source=../lib/loh/common.sh
  source "$REPO_ROOT/lib/loh/common.sh"
  unset LOH_WORKSPACE
}

@test "die prints the message to stderr and exits 1" {
  run --separate-stderr die "boom"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "loh: boom" ]
}

@test "need succeeds for a command on PATH" {
  run need bash
  [ "$status" -eq 0 ]
}

@test "need dies naming the missing command" {
  run --separate-stderr need no-such-command-xyz
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no-such-command-xyz"* ]]
}

@test "hc_json runs hc with --json appended and returns its output" {
  use_fake_hc
  printf '{"terminals":[]}\n' >"$BATS_TEST_TMPDIR/canned.json"
  export FAKE_HC_JSON="$BATS_TEST_TMPDIR/canned.json"
  run hc_json ls --label crew=x
  [ "$status" -eq 0 ]
  [ "$output" = '{"terminals":[]}' ]
  [ "$(cat "$FAKE_HC_LOG")" = $'ls\t--label\tcrew=x\t--json' ]
}

@test "hc_json passes through a failing exit status from hc" {
  use_fake_hc
  export FAKE_HC_EXIT=3
  run hc_json ls
  [ "$status" -eq 3 ]
}

@test "hc_json fails clearly when hc is missing" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/empty" "$BASH" -c \
    'source "$1"; hc_json ls' _ "$REPO_ROOT/lib/loh/common.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"hc"* ]]
  [[ "$stderr" == *"not found"* ]]
}

@test "workspace_root walks up to the folder holding .loh/workspace.md" {
  ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/.loh" "$ws/repo/deep/er"
  : >"$ws/.loh/workspace.md"
  cd "$ws/repo/deep/er"
  run workspace_root
  [ "$status" -eq 0 ]
  [ "$output" = "$ws" ]
}

@test "workspace_root finds the manifest in the current directory" {
  ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/.loh"
  : >"$ws/.loh/workspace.md"
  cd "$ws"
  run workspace_root
  [ "$status" -eq 0 ]
  [ "$output" = "$ws" ]
}

@test "manifest_path prints the .loh manifest and nothing on stderr" {
  ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/.loh"
  : >"$ws/.loh/workspace.md"
  cd "$ws"
  run --separate-stderr manifest_path
  [ "$status" -eq 0 ]
  [ "$output" = "$ws/.loh/workspace.md" ]
  [ -z "$stderr" ]
}

@test "workspace_root dies when no manifest is found" {
  mkdir -p "$BATS_TEST_TMPDIR/bare/sub"
  cd "$BATS_TEST_TMPDIR/bare/sub"
  run --separate-stderr workspace_root
  [ "$status" -eq 1 ]
  [[ "$stderr" == *".loh/workspace.md"* ]]
}

@test "LOH_WORKSPACE overrides the walk" {
  ws="$BATS_TEST_TMPDIR/override"
  mkdir -p "$ws" "$BATS_TEST_TMPDIR/elsewhere"
  cd "$BATS_TEST_TMPDIR/elsewhere"
  LOH_WORKSPACE="$ws" run workspace_root
  [ "$status" -eq 0 ]
  [ "$output" = "$ws" ]
}

@test "LOH_WORKSPACE naming a missing directory dies" {
  LOH_WORKSPACE="$BATS_TEST_TMPDIR/nope" run --separate-stderr workspace_root
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"LOH_WORKSPACE"* ]]
}
