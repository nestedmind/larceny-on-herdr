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

@test "Scofield and Amy swapped between their desks is reported: the prototype says who sits where" {
  copy_mod
  sed -i 's/sit(p, deskBy.get(p.id)); continue; }/sit(p, deskBy.get(p.id === "scofield" ? "amy" : "scofield")); continue; }/' "$MOD/crew.js"
  run node "$TOOL/run.mjs" --mod "$MOD" --case two-repos-native
  [ "$status" -eq 1 ]
  [[ "$output" == *"scofield desk: office \"amy\", prototype \"scofield\""* ]]
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

@test "the live part refuses two identical shots, says the window is not repainting, and exits 3" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n# fake herdr-app: every shot is the same bytes\nprintf same > "$2"\n' > "$BATS_TEST_TMPDIR/bin/herdr-app"
  chmod +x "$BATS_TEST_TMPDIR/bin/herdr-app"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run node "$TOOL/live.mjs" --out "$BATS_TEST_TMPDIR/live"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not repainting"* ]]
}
