#!/usr/bin/env bats
# The office parity tool (test/office-parity): the geometry part against the prototype, no window needed. It needs node,
# headless Chrome and the prototype page; without one of them these tests skip. The live part's stale-frame refusal is
# tested with a fake herdr-app. Each mutation test breaks one thing in a copy of the mod and expects the tool to say so.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  command -v node >/dev/null || skip "node not installed"
  [ -x "${PARITY_CHROME:-/usr/bin/google-chrome}" ] || skip "headless Chrome not installed"
  local main
  main="$(dirname "$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)")"
  [ -f "${PARITY_PROTO:-$main/.larceny/office/crew-office.html}" ] || skip "the prototype page is not available (PARITY_PROTO)"
  TOOL="$REPO_ROOT/test/office-parity"
}

# A copy of the mod in the test's temp dir, for a test to break.
copy_mod() {
  MOD="$BATS_TEST_TMPDIR/crew-office"
  cp -r "$REPO_ROOT/office/crew-office" "$MOD"
}

@test "the office as it is matches the prototype within 1 px, with the same colours, in every case" {
  run node "$TOOL/run.mjs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" == *"two-repos-native"* && "$output" == *"six-repos"* ]]
}

@test "a spot moved 10 units in the kitchen is reported by name and exits non-zero" {
  copy_mod
  sed -i 's/\[\[126, 216\], \[166, 216\]/[[136, 216], [166, 216]/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"kitchen:0"* ]]
  [[ "$output" == *"FAIL"* ]]
}

@test "a colour that differs from the prototype's palette is reported" {
  copy_mod
  sed -i 's/oak: "#d8a874"/oak: "#d8a875"/' "$MOD/draw.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"colours: 1 differ"* ]]
  [[ "$output" == *"oak: office #d8a875, prototype #d8a874"* ]]
}

@test "figures drawn 10 percent off their places, a scale fault in the render, are reported on every person" {
  copy_mod
  sed -i 's/\.left(at\.x \* k)\.top(at\.y \* k)\.w(0)\.h(0)\.child(inner)/.left(at.x * k * 1.1).top(at.y * k).w(0).h(0).child(inner)/' "$MOD/draw.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"figure-x"* ]]
  [[ "$output" == *"sucre figure-x"* ]]
}

@test "a route that does not go by the doors is reported against the prototype's pathTo" {
  copy_mod
  sed -i 's/pts.push(d, { x: d.x, y: lane });/pts.push({ x: d.x + 20, y: lane });/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"route"* ]]
}

@test "--images writes an overlay and a diff for each case" {
  run node "$TOOL/run.mjs" --case two-repos-native --images --out "$BATS_TEST_TMPDIR/img"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/img/two-repos-native-overlay.png" ]
  [ -s "$BATS_TEST_TMPDIR/img/two-repos-native-diff.png" ]
}

@test "the prototype's path can be given as an argument or PARITY_PROTO, and a missing one is a setup error (exit 2)" {
  run node "$TOOL/run.mjs" --proto "$BATS_TEST_TMPDIR/none.html"
  [ "$status" -eq 2 ]
  [[ "$output" == *"the prototype is not at"* ]]
}

@test "the live part refuses two identical shots, says the window is not repainting, and exits 3" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n# fake herdr-app: every shot is the same bytes\nprintf same > "$2"\n' > "$BATS_TEST_TMPDIR/bin/herdr-app"
  chmod +x "$BATS_TEST_TMPDIR/bin/herdr-app"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run node "$TOOL/live.mjs" --out "$BATS_TEST_TMPDIR/live"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not repainting"* ]]
}
