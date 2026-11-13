#!/usr/bin/env bats
# Smooth walking and the stage beside the panel: the pure parts of the office's motion.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

@test "a walk becomes one chain of offsets, each starting when the one before it ends" {
  run crew_js '
const legs = [{x: 10, y: 0, face: "e", ms: 1000}, {x: 10, y: 30, face: "s", ms: 500}, {x: 4, y: 30, face: "w", ms: 250}];
const c = crew.walkChain({x: 0, y: 0}, legs, 5);
console.log(JSON.stringify(c.links.map((l) => [l.dx, l.dy, l.delay, l.ms])));'
  [ "$status" -eq 0 ]
  [ "$output" = "[[10,0,0,1000],[0,30,1000,500],[-6,0,1500,250],[0,0,0,1],[0,0,0,1]]" ]
}

@test "the offsets of a walk add up to the distance from start to goal, however many legs" {
  run crew_js '
const legs = [{x: 5, y: 5, face: "s", ms: 100}, {x: 9, y: -3, face: "e", ms: 100}, {x: 2, y: 8, face: "w", ms: 100}, {x: 7, y: 7, face: "e", ms: 100}];
let out = [];
for (const slots of [6, 4, 2, 1]) {
  const c = crew.walkChain({x: 1, y: 1}, legs, slots);
  out.push(c.links.length + ":" + (1 + c.links.reduce((s, l) => s + l.dx, 0)) + "," + (1 + c.links.reduce((s, l) => s + l.dy, 0)) + ":" + c.links.reduce((s, l) => Math.max(s, l.delay + l.ms), 0));
}
console.log(out.join(" "));'
  [ "$status" -eq 0 ]
  # the last link always ends at 400 ms, the walk's length, and at (7, 7)
  [ "$output" = "6:7,7:400 4:7,7:400 2:7,7:400 1:7,7:400" ]
}

@test "no legs gives a chain that goes nowhere" {
  run crew_js '
const c = crew.walkChain({x: 3, y: 4}, [], 3);
console.log(JSON.stringify(c.links.map((l) => [l.dx, l.dy])), crew.walkMs([]));'
  [ "$status" -eq 0 ]
  [ "$output" = "[[0,0],[0,0],[0,0]] 0" ]
}

@test "where a walker is after some time follows the legs and stops at the goal" {
  run crew_js '
const legs = [{x: 10, y: 0, face: "e", ms: 1000}, {x: 10, y: 20, face: "s", ms: 1000}];
const at = (t) => { const p = crew.posAt({x: 0, y: 0}, legs, t); return p.x + "," + p.y + "," + p.i; };
console.log([at(0), at(500), at(1000), at(1500), at(2000), at(9000)].join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "0,0,0 5,0,0 10,0,1 10,10,1 10,20,2 10,20,2" ]
}

@test "walkMs is the sum of the legs" {
  run crew_js 'console.log(crew.walkMs([{ms: 120}, {ms: 30}, {ms: 1}]));'
  [ "$status" -eq 0 ]
  [ "$output" = "151" ]
}

@test "a stage measured before the panel opened loses the panel's width, and gets it back when the panel closes" {
  run crew_js '
const s = { width: 1990, height: 900 };
const f = (measuredWith, show) => crew.stageSize(s, measuredWith, show, 360).width;
console.log([f(false, false), f(true, true), f(false, true), f(true, false)].join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "1990 1990 1630 2350" ]
}

@test "a stage never comes out narrower than one pixel" {
  run crew_js 'console.log(crew.stageSize({width: 200, height: 100}, false, true, 360).width);'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "the floor fitted to a stage beside the panel is narrower than the stage" {
  run crew_js '
const L = crew.layoutCrew([], ["api", "web"], 1);
const stage = crew.stageSize({width: 3840, height: 2100}, false, true, 360);
const s = crew.fitScale(stage, L);
console.log(L.W * s.k + 16 <= stage.width + 0.5, stage.width);'
  [ "$status" -eq 0 ]
  [ "$output" = "true 3480" ]
}
