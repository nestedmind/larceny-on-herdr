#!/usr/bin/env bats
# chrome.mjs ends the headless Chrome it started, with its children, and removes its profile folder, on every path.
# Each test counts only its own Chrome: the process group it recorded, and the folders under its own PARITY_TMP.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  command -v node >/dev/null || skip "node not installed"
  [ -x "${PARITY_CHROME:-/usr/bin/google-chrome}" ] || skip "headless Chrome not installed"
  TOOL="$REPO_ROOT/test/office-parity"
  parity_setup
}

teardown() { parity_teardown; }

# Runs a node script that launches a Chrome, prints "pgid <pid>", then runs $1 (a JS statement).
chrome_script() {
  cat <<JS
import { Chrome } from "$TOOL/chrome.mjs";
const c = await Chrome.launch({});
console.log("pgid " + c.proc.pid);
$1
JS
}

# The members of a process group; empty once it is gone.
group_members() { ps -o pid= -g "$1" 2>/dev/null | tr -d ' ' | grep . || true; }

# Waits until the script has launched its Chrome and printed the group id.
wait_up() {
  local i
  for i in $(seq 200); do grep -q '^pgid ' "$BATS_TEST_TMPDIR/out" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}

assert_clean() {
  [ -z "$(group_members "$1")" ]
  ! compgen -G "$PARITY_TMP/parity-chrome-*" >/dev/null
}

pgid_of() { sed -n 's/^pgid //p' <<<"$output" | head -1; }

@test "a run that finishes and closes leaves no Chrome and no profile folder" {
  run node --input-type=module -e "$(chrome_script 'c.close();')"
  [ "$status" -eq 0 ]
  assert_clean "$(pgid_of)"
}

@test "a run that throws without closing leaves no Chrome and no profile folder" {
  run node --input-type=module -e "$(chrome_script 'throw new Error("forced failure");')"
  [ "$status" -ne 0 ]
  assert_clean "$(pgid_of)"
}

@test "a run that calls process.exit without closing leaves no Chrome and no profile folder" {
  run node --input-type=module -e "$(chrome_script 'process.exit(1);')"
  [ "$status" -eq 1 ]
  assert_clean "$(pgid_of)"
}

@test "a launch that cannot get a debugging port ends the Chrome it started and removes its folder" {
  # A wrapper that starts a lingering child and never opens a port.
  printf '#!/bin/sh\nsleep 300 &\nsleep 300\n' >"$BATS_TEST_TMPDIR/fake-chrome"
  chmod +x "$BATS_TEST_TMPDIR/fake-chrome"
  run env PARITY_CHROME="$BATS_TEST_TMPDIR/fake-chrome" node --input-type=module -e "
import { Chrome } from '$TOOL/chrome.mjs';
await Chrome.launch({}).catch((e) => console.log('failed: ' + e.message));
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not open a debugging port"* ]]
  ! compgen -G "$PARITY_TMP/parity-chrome-*" >/dev/null
  local pg
  while read -r pg; do [ -z "$(group_members "$pg")" ]; done <"$PARITY_PIDS"
}

@test "a run ended by SIGTERM mid-run leaves no Chrome and no profile folder" {
  node --input-type=module -e "$(chrome_script 'await new Promise((r) => setTimeout(r, 60000));')" >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local node_pid=$!
  wait_up
  local pgid
  pgid="$(sed -n 's/^pgid //p' "$BATS_TEST_TMPDIR/out")"
  [ -n "$pgid" ]
  kill -TERM "$node_pid"
  wait "$node_pid" || true
  assert_clean "$pgid"
}

@test "a run ended by SIGINT mid-run leaves no Chrome and no profile folder" {
  node --input-type=module -e "$(chrome_script 'await new Promise((r) => setTimeout(r, 60000));')" >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local node_pid=$!
  wait_up
  local pgid
  pgid="$(sed -n 's/^pgid //p' "$BATS_TEST_TMPDIR/out")"
  [ -n "$pgid" ]
  kill -INT "$node_pid"
  wait "$node_pid" || true
  assert_clean "$pgid"
}

@test "a run killed with SIGKILL is cleaned up by the bats teardown, and only its own group" {
  node --input-type=module -e "$(chrome_script 'await new Promise((r) => setTimeout(r, 60000));')" >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local node_pid=$!
  wait_up
  local pgid
  pgid="$(sed -n 's/^pgid //p' "$BATS_TEST_TMPDIR/out")"
  kill -KILL "$node_pid"
  wait "$node_pid" || true
  [ -n "$(group_members "$pgid")" ]
  parity_teardown
  [ -z "$(group_members "$pgid")" ]
}
