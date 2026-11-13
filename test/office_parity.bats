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
  PROTO="${PARITY_PROTO:-$main/.larceny/office/crew-office.html}"
  [ -f "$PROTO" ] || skip "the prototype page is not available (PARITY_PROTO)"
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

@test "Scofield and Amy swapped between their desks is reported: the prototype says who sits where" {
  copy_mod
  sed -i 's/else sit(p, deskBy.get(homes\[p.id\] || p.id));/else sit(p, deskBy.get(p.id === "scofield" ? "amy" : p.id === "amy" ? "scofield" : homes[p.id] || p.id));/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"scofield desk: office \"amy\", prototype \"scofield\""* ]]
}

@test "seating: people who do not leave their desks after the idle time are reported against the prototype's lounge" {
  copy_mod
  sed -i 's/export const IDLE_MS = 3 \* 60 \* 1000;/export const IDLE_MS = 3e9;/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case idle-3-minutes
  [ "$status" -eq 1 ]
  [[ "$output" == *"scofield place: office \"desk\", prototype \"lounge (the prototype's lounge)\""* ]]
}

@test "seating: someone who leaves the desk when the turn ends, before the idle time, is reported" {
  copy_mod
  sed -i 's/export const IDLE_MS = 3 \* 60 \* 1000;/export const IDLE_MS = 1000;/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case seated-after-turn
  [ "$status" -eq 1 ]
  [[ "$output" == *"scofield place"* ]]
}

@test "seating: a coder waiting on a review who never goes to ping pong is reported" {
  copy_mod
  sed -i 's/export const PONG_AFTER = 15000;/export const PONG_AFTER = 1e9;/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case ping-pong-after-15s
  [ "$status" -eq 1 ]
  [[ "$output" == *"sucre place: office \"kitchen\""* ]]
}

@test "seating: Matt at his desk when he is not typing is reported" {
  copy_mod
  sed -i 's/mattTyping: mattTypingAt(now, this.mattUntil),/mattTyping: true,/' "$MOD/main.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case rest-room-and-away
  [ "$status" -eq 1 ]
  [[ "$output" == *"matt place"* ]]
}

@test "a person drawn in a colour the prototype does not give them is reported" {
  copy_mod
  sed -i 's/#3f5f93/#3f5f99/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"scofield.shirt: office #3f5f99, prototype #3f5f93"* ]]
}

@test "name tags 12 px low are reported" {
  copy_mod
  sed -i 's/this.tag(s.p, off.x, off.y, s.w/this.tag(s.p, off.x, off.y + 12, s.w/; s/this.chip(s.p, off.x, off.y, slide)/this.chip(s.p, off.x, off.y + 12, slide)/' "$MOD/main.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *" y: office"* ]]
}

@test "a click target that is missing is reported" {
  copy_mod
  sed -i 's/hitBox(p.id, k, (_e, c) => this.pick(p, c))/div()/' "$MOD/main.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"click-target-missing"* ]]
}

@test "a click target with no size is reported" {
  copy_mod
  sed -i 's/\.left(-7 \* k)\.top(-8 \* k)\.w(14 \* k)\.h(16 \* k)/.left(0).top(0).w(0).h(0)/' "$MOD/draw.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"hit"* && "$output" == *" w: office 0"* ]]
}

@test "a name tag that is missing is reported" {
  copy_mod
  sed -i 's/const tags = sized.map((s) => {/const tags = sized.filter((s) => s.id !== "sucre").map((s) => {/' "$MOD/main.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag-missing"* ]]
}

@test "a --case that names no case exits 2 and says which cases there are" {
  run node "$TOOL/run.mjs" --case two-repos-nativ
  [ "$status" -eq 2 ]
  [[ "$output" == *"no case named two-repos-nativ"* && "$output" == *"two-repos-native"* ]]
}

# The live part, on stand-ins for a shot of the window (synth.mjs draws the office's own floor and people at 4 px a unit).
synth() { node "$TOOL/synth.mjs" --crew "$TOOL/fixtures/crew.json" --out "$BATS_TEST_TMPDIR/$1.png" "${@:2}"; }
live() { node "$TOOL/live.mjs" --crew "$TOOL/fixtures/crew.json" --out "$BATS_TEST_TMPDIR/live" "$@"; }

@test "live: a shot where every person is where the plan puts them passes" {
  synth ok
  run live --shot "$BATS_TEST_TMPDIR/ok.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sideways offset = 0.0% of x"* ]]
}

@test "live: people drawn 10 percent too far across, Scofield and Amy at their desks included, show an offset growing with x" {
  synth fault --fault 1.1
  run live --shot "$BATS_TEST_TMPDIR/fault.png" --all
  [ "$status" -eq 1 ]
  [[ "$output" =~ sideways\ offset\ =\ (9\.[5-9]|10\.[0-4])%\ of\ x ]]
  [[ "$output" == *"scofield x: off 129"* ]]
  [[ "$output" == *"amy x: off 147"* ]]
}

@test "live: a person who is not found fails the run" {
  synth nosco --hide scofield
  run live --shot "$BATS_TEST_TMPDIR/nosco.png"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scofield: not found"* ]]
}

@test "live: a shot with nobody in it fails" {
  synth nobody --hide scofield,amy,sucre,whip,mahone,yoda,sheba,maya,opemipo,sara,matt
  run live --shot "$BATS_TEST_TMPDIR/nobody.png" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"too few to measure"* ]]
}

@test "live: two shots that differ only outside the floor are not a repaint (exit 3)" {
  synth a
  synth b --mark
  run live --frames "$BATS_TEST_TMPDIR/a.png" "$BATS_TEST_TMPDIR/b.png"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not repainting"* ]]
}

@test "live: two shots that differ in the floor are a repaint, and the run goes on to measure" {
  synth a
  synth c --fault 1.1
  run live --frames "$BATS_TEST_TMPDIR/a.png" "$BATS_TEST_TMPDIR/c.png"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sideways offset"* ]]
}

# Fake hc and herdr-app first on PATH (see office-parity/fixtures), with their counters in a temp dir.
use_fakes() {
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/fake"
  ln -sf "$TOOL/fixtures/fake-hc" "$BATS_TEST_TMPDIR/bin/hc"
  ln -sf "$TOOL/fixtures/fake-herdr-app" "$BATS_TEST_TMPDIR/bin/herdr-app"
  export FAKE_DIR="$BATS_TEST_TMPDIR/fake" PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "the live part refuses two identical shots, says the window is not repainting, and exits 3" {
  use_fakes
  run node "$TOOL/live.mjs" --out "$BATS_TEST_TMPDIR/live"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not repainting"* ]]
}

@test "live: a crew that changed between the first read and the one after the shots is refused (exit 3), not judged" {
  use_fakes
  export FAKE_DIFFER=1 FAKE_CHANGE_AT=1
  run node "$TOOL/live.mjs" --out "$BATS_TEST_TMPDIR/live"
  [ "$status" -eq 3 ]
  [[ "$output" == *"crew changed"* ]]
}

@test "tags above and below their people swapped (the rule reversed in the office's layout) are reported" {
  copy_mod
  sed -i 's/up: !!d \&\& d.side === "n" }/up: !!d \&\& d.side === "s" }/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *" y: office"* ]]
}

@test "tags stacked with a 30 px gap instead of 1 px are reported" {
  copy_mod
  sed -i 's/hit.y - t.h - 1 : hit.y + hit.h + 1/hit.y - t.h - 30 : hit.y + hit.h + 30/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *" y: office"* ]]
}

@test "the known differences are exactly the ones listed (#29): 8, 1, 4 and 3 in the four cases, and 3, 5, 1, 2, 1 and 5 in the six seating cases" {
  run node "$TOOL/run.mjs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"two-repos-native"*"8 known"* && "$output" == *"two-repos-16x9"*"1 known"* ]]
  [[ "$output" == *"two-repos-narrow"*"4 known"* && "$output" == *"six-repos"*"3 known"* ]]
  [ "$(grep -c 'known (#29)' <<< "$output")" -eq 33 ]
}

# The tool in a temp dir, so a test can change its list of known differences.
copy_tool() {
  TOOLCOPY="$BATS_TEST_TMPDIR/tool"
  cp -r "$TOOL" "$TOOLCOPY"
}

@test "a difference that is not on the known list fails the run: take one off and it fails" {
  copy_tool
  sed -i 's/, \["dog", "y", 3\]//' "$TOOLCOPY/cases.mjs"
  run node "$TOOLCOPY/run.mjs" --mod "$REPO_ROOT/office/crew-office" --proto "$PROTO" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"dog y: office"* && "$output" == *"FAIL"* ]]
}

@test "a known difference that has gone fails the run until it is removed: an entry the office does not match is stale" {
  copy_tool
  sed -i 's/\["dog", "y", 3\]/["dog", "y", 3], ["whip", "x", 5]/' "$TOOLCOPY/cases.mjs"
  run node "$TOOLCOPY/run.mjs" --mod "$REPO_ROOT/office/crew-office" --proto "$PROTO" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE known entry (#29): tags whip x"* ]]
}

@test "a known difference that gets worse is not covered by its entry" {
  copy_tool
  sed -i 's/\["dog", "y", 3\]/["dog", "y", 4]/' "$TOOLCOPY/cases.mjs"
  run node "$TOOLCOPY/run.mjs" --mod "$REPO_ROOT/office/crew-office" --proto "$PROTO" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"dog y: office"* && "$output" == *"STALE known entry"* ]]
}
