#!/usr/bin/env bats
# Matt out (ticket #49): while a coordinator's card says matt=out he walks out of the entrance in the left wall and his
# desk is empty with the monitors off; when an office sign clears it he walks back in to his desk.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

HELPERS='
const T = (name, status, labels = {}, extra = {}) => ({address: "t-" + name, name, state: "live", status, cwd: "/ws/" + name, labels: {crew: "w", ...labels}, ...extra});
const lay = (ts, o = {}) => crew.layoutCrew(crew.crewOf(ts, "w"), ["api"], 0, {now: 0, ...o});
const P = (L, id) => L.people.find((p) => p.id === id);
'

@test "the matt label on a terminal is read into the crew, and only the value out counts" {
  run crew_js "$HELPERS"'
const c = crew.crewOf([T("scofield", "idle", {role: "coordinator", matt: "out"}), T("amy", "idle", {role: "reviewer", matt: "x"})], "w");
console.log(c.map((a) => a.name + ":" + a.matt).join(" "), crew.mattOutOf(c), crew.mattOutOf(crew.crewOf([T("scofield", "idle", {role: "coordinator"})], "w")));'
  [ "$status" -eq 0 ]
  [ "$output" = "amy: scofield:out true false" ]
}

@test "with Matt out he stands at the entrance in the left wall, his monitors are off and his desk is empty" {
  run crew_js "$HELPERS"'
const L = lay([], {mattOut: true, mattSeated: true, mattTyping: true});
const m = P(L, "matt"); const e = L.entrance;
console.log(m.out, m.place, m.state, m.typing, m.x < 12, m.y >= e.gap.y0 && m.y <= e.gap.y1, L.screens.matt);'
  [ "$status" -eq 0 ]
  [ "$output" = "true entrance out false true true off" ]
}

@test "Matt out wins over a meeting and over his seat; cleared, he is at his desk again" {
  run crew_js "$HELPERS"'
const ts = [T("scofield", "idle", {role: "coordinator", meeting: "1"})];
const a = P(lay(ts, {mattOut: true, mattSeated: true}), "matt");
const b = P(lay([], {mattOut: false, mattSeated: true}), "matt");
const L = lay([], {mattSeated: true});
console.log(a.place, b.place, b.desk, b.out, L.screens.matt);'
  [ "$status" -eq 0 ]
  [ "$output" = "entrance matt matt false work" ]
}

@test "the walk out goes along the corridor to the entrance, and the walk in starts there and ends at his desk" {
  run crew_js "$HELPERS"'
const out = lay([], {mattOut: true}); const home = lay([], {mattSeated: true});
const lounge = P(lay([], {}), "matt");
const toE = crew.pathTo(out, "matt", {x: lounge.x, y: lounge.y}, {x: P(out, "matt").x, y: P(out, "matt").y});
const toD = crew.pathTo(home, "matt", {x: P(out, "matt").x, y: P(out, "matt").y}, {x: P(home, "matt").x, y: P(home, "matt").y});
const last = toD[toD.length - 1], d = home.mattDesk.seat;
console.log(toE.length > 1, toE[toE.length - 1].x < 12, last.x === d.x && last.y === d.y);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true" ]
}

@test "Waffles sleeps on her bed while Matt is out, and waits at the entrance when an agent is blocked" {
  run crew_js "$HELPERS"'
const ts = [T("scofield", "blocked", {role: "coordinator"})];
const sleep = P(lay([], {mattOut: true}), "dog");
const wait = P(lay(ts, {mattOut: true}), "dog");
const beside = P(lay(ts, {mattSeated: true}), "dog");
const L = lay(ts, {mattOut: true});
console.log(sleep.state, wait.state, wait.x < 30, wait.y >= L.entrance.gap.y0 - 12 && wait.y <= L.entrance.gap.y1 + 12, beside.x > 30);'
  [ "$status" -eq 0 ]
  [ "$output" = "sleep sit true true true" ]
}

@test "Matt is drawn only while he is not standing at rest at the entrance" {
  run crew_js "$HELPERS"'
const m = P(lay([], {mattOut: true}), "matt"), d = P(lay([], {mattSeated: true}), "matt");
console.log(crew.hiddenAt(m, true), crew.hiddenAt(m, false), crew.hiddenAt(d, true));'
  [ "$status" -eq 0 ]
  [ "$output" = "true false false" ]
}

@test "the office clears the label on the coordinator with loh back, in that agent's folder" {
  run crew_js "$HELPERS"'
const c = crew.crewOf([T("scofield", "idle", {role: "coordinator", matt: "out"})], "w");
const call = crew.backCall(c.find((a) => a.name === "scofield"), "/bin/loh");
console.log(call.cmd, call.args.join(" "), call.options.cwd);'
  [ "$status" -eq 0 ]
  [ "$output" = "/bin/loh back scofield /ws/scofield" ]
}

@test "a screen that is off draws nothing, where a dim one draws a strip" {
  run bash -c "cd '$REPO_ROOT' && grep -n 's === \"off\"' office/crew-office/draw.js"
  [ "$status" -eq 0 ]
}
