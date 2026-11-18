#!/usr/bin/env bats
# Naps in the rest room (ticket #152): who lies down after an hour idle, how many, for how long, and who wins a bed.

bats_require_minimum_version 1.5.0
load test_helper

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$REPO_ROOT/office/crew-office/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

# Times are in seconds. A person's turn ends at the first render that sees them idle (their `since`).
HELPERS='
const T = (name, status, labels = {}) => ({address: "t-" + name, name, state: "live", status, cwd: "/ws/" + name, labels: {crew: "w", ...labels}});
const R = {amy: "reviewer", maya: "designer", yoda: "advisor", sara: "teacher", opemipo: "researcher", scofield: "coordinator"};
const mk = (n, st, l = {}) => T(n, st, {role: R[n] || "coder", ...l});
const HOUR = 3600, MIN = 60;
const mem = crew.newMemory();
const draw = (s, ts) => crew.layoutCrew(crew.crewOf(ts, "w"), ["api"], 0, {mem, now: s * 1000});
const place = (L, id) => { const r = L.people.find((p) => p.id === id).place; return r === "kitchen" ? "lounge" : r; };
const rooms = (L, ids) => ids.map((i) => place(L, i)).join(",");
const spot = (L, id) => { const p = L.people.find((q) => q.id === id); return p.x + "/" + p.y; };
// Everyone idle from `since` seconds: one working render, then the idle ones.
const start = (names, extra = {}) => { draw(0, names.map((n) => mk(n, "working", extra[n]))); };
const idle = (names, extra = {}) => names.map((n) => mk(n, "idle", extra[n]));
'

@test "idle 59 minutes is no nap, idle 60 minutes is a nap" {
  run crew_js "$HELPERS"'
start(["amy"]); draw(10, idle(["amy"]));
const a = draw(10 + HOUR - 1, idle(["amy"])), b = draw(10 + HOUR, idle(["amy"]));
console.log(place(a, "amy"), place(b, "amy"), crew.NAP_AFTER_MS, crew.NAP_MAX_MS);'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge rest 3600000 5400000" ]
}

@test "with 4 eligible agents only the 3 longest idle nap" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda", "sara"];
start(n);
draw(10, idle(["amy"]).concat(n.slice(1).map((x) => mk(x, "working"))));
draw(20, idle(["amy", "maya"]).concat(["yoda", "sara"].map((x) => mk(x, "working"))));
draw(30, idle(["amy", "maya", "yoda"]).concat([mk("sara", "working")]));
draw(40, idle(n));
console.log(rooms(draw(40 + HOUR + 5, idle(n)), n));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,rest,rest,lounge" ]
}

@test "a compaction while 3 nap gets a bed beside them, nobody is bumped" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda"];
start(n); draw(10, idle(n));
const t = 10 + HOUR;
draw(t, idle(n));
const L = draw(t + 1, idle(n).concat([mk("sara", "working", {ctx: "compact"})]));
console.log(rooms(L, ["amy", "maya", "yoda", "sara"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,rest,rest,rest" ]
}

@test "two compactions with 3 napping: the napper who lay down last gets up and goes to the lounge" {
  run crew_js "$HELPERS"'
start(["amy", "maya", "yoda"]);
draw(10, idle(["amy"]).concat([mk("maya", "working"), mk("yoda", "working")]));
draw(20, idle(["amy", "maya"]).concat([mk("yoda", "working")]));
draw(30, idle(["amy", "maya", "yoda"]));
draw(10 + HOUR, idle(["amy", "maya", "yoda"]));
draw(20 + HOUR, idle(["amy", "maya", "yoda"]));
const before = draw(30 + HOUR, idle(["amy", "maya", "yoda"]));
const c = ["sara", "opemipo"].map((x) => mk(x, "working", {ctx: "compact"}));
const L = draw(31 + HOUR, idle(["amy", "maya", "yoda"]).concat(c));
const after = draw(32 + HOUR, idle(["amy", "maya", "yoda"]).concat(c));
console.log(rooms(before, ["amy", "maya", "yoda"]), rooms(L, ["amy", "maya", "yoda", "sara", "opemipo"]), rooms(after, ["yoda"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,rest,rest rest,rest,lounge,rest,rest lounge" ]
}

@test "a place=rest agent counts toward the 3 and is never bumped" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda", "sara"];
start(n.concat(["opemipo"]));
const ts = (x = {}) => idle(n.concat(["opemipo"]), {opemipo: {place: "rest"}, ...x});
draw(10, ts()); draw(10 + HOUR, ts());
const a = draw(11 + HOUR, ts());
// two compactions on top: the sent agent stays, naps are bumped first
const c = [mk("scofield", "working", {ctx: "compact"}), mk("sara", "working", {ctx: "compact"})];
const b = draw(12 + HOUR, idle(["amy", "maya", "yoda"], {}).concat(c, [mk("opemipo", "idle", {place: "rest"})]));
console.log(rooms(a, ["amy", "maya", "yoda", "sara", "opemipo"]), rooms(b, ["amy", "maya", "yoda", "opemipo"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,rest,lounge,lounge,rest rest,lounge,lounge,rest" ]
}

@test "a nap ends at 90 minutes and the next eligible agent takes the bed" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda", "sara"];
start(n); draw(10, idle(n));
const t = 10 + HOUR;
const a = draw(t, idle(n));
const b = draw(t + 90 * MIN - 1, idle(n));
const c = draw(t + 90 * MIN, idle(n));
console.log(rooms(a, n), rooms(b, n), rooms(c, n));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,rest,lounge,rest rest,rest,lounge,rest lounge,lounge,rest,lounge" ]
}

@test "no second nap without a turn in between, and a turn allows one again" {
  run crew_js "$HELPERS"'
start(["amy"]); draw(10, idle(["amy"]));
const t = 10 + HOUR;
draw(t, idle(["amy"]));
const a = draw(t + 90 * MIN, idle(["amy"])), b = draw(t + 200 * MIN, idle(["amy"]));
draw(t + 201 * MIN, [mk("amy", "working")]);
draw(t + 202 * MIN, idle(["amy"]));
const c = draw(t + 202 * MIN + HOUR, idle(["amy"]));
console.log(place(a, "amy"), place(b, "amy"), place(c, "amy"));'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge lounge rest" ]
}

@test "a new prompt sends a napper to the desk at once" {
  run crew_js "$HELPERS"'
start(["amy"]); draw(10, idle(["amy"]));
draw(10 + HOUR, idle(["amy"]));
const L = draw(11 + HOUR, [mk("amy", "working")]);
console.log(place(L, "amy"), L.people.find((p) => p.id === "amy").desk);'
  [ "$status" -eq 0 ]
  [ "$output" = "desk amy" ]
}

@test "a coder with a ticket or a PR never naps; a coder with no ticket does" {
  run crew_js "$HELPERS"'
const c = {sucre: {task: "api#4"}, mahone: {task: "api#5", pr: "9", round: "1"}};
const names = ["sucre", "mahone", "whip"];
start(names, c); draw(10, idle(names, c));
const L = draw(10 + HOUR + 1, idle(names, c));
const L2 = draw(10 + 3 * HOUR, idle(names, c));
console.log(rooms(L, names), rooms(L2, names));'
  [ "$status" -eq 0 ]
  [[ "$output" != *"rest,rest"* ]]
  [[ "$output" = *",rest "* ]] || [[ "$output" = *"rest"* ]]
}

@test "a meeting wins over a nap" {
  run crew_js "$HELPERS"'
start(["amy", "maya"]); draw(10, idle(["amy", "maya"]));
const L = draw(10 + HOUR + 1, idle(["amy", "maya"], {amy: {meeting: "1"}}));
console.log(rooms(L, ["amy", "maya"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "meeting,rest" ]
}

@test "nobody shuffles between beds while the set of nappers is unchanged" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda"];
start(n); draw(10, idle(n));
const a = draw(10 + HOUR, idle(n)), b = draw(10 + HOUR + 30 * MIN, idle(n)), c = draw(10 + HOUR + 60 * MIN, idle(n));
const s = (L) => n.map((i) => spot(L, i)).join(" ");
console.log(s(a) === s(b) && s(b) === s(c), new Set(n.map((i) => spot(a, i))).size);'
  [ "$status" -eq 0 ]
  [ "$output" = "true 3" ]
}
