#!/usr/bin/env bats
# Naps in the rest room (tickets #152, #167): who lies down after an hour idle, how many, for how long, and who wins a bed.

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
mem.born = 1e15; // as if the office started far in the future: people with no session never nap here, unless a test sets mem.born
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

@test "a compaction while 3 nap gets a bed; the napper who lay down last gets up (the cap of 3 counts it)" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda"];
start(n);
draw(10, idle(["amy"]).concat([mk("maya", "working"), mk("yoda", "working")]));
draw(20, idle(["amy", "maya"]).concat([mk("yoda", "working")]));
draw(30, idle(n));
draw(10 + HOUR, idle(n)); draw(20 + HOUR, idle(n));
const before = draw(30 + HOUR, idle(n));
const c = [mk("sara", "working", {ctx: "compact"})];
const L = draw(31 + HOUR, idle(n).concat(c));
console.log(rooms(before, n), rooms(L, ["amy", "maya", "yoda", "sara"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,rest,rest rest,rest,lounge,rest" ]
}

@test "two compactions with 3 napping: the 2 napper who lay down last get up" {
  run crew_js "$HELPERS"'
start(["amy", "maya", "yoda"]);
draw(10, idle(["amy"]).concat([mk("maya", "working"), mk("yoda", "working")]));
draw(20, idle(["amy", "maya"]).concat([mk("yoda", "working")]));
draw(30, idle(["amy", "maya", "yoda"]));
draw(10 + HOUR, idle(["amy", "maya", "yoda"]));
draw(20 + HOUR, idle(["amy", "maya", "yoda"]));
draw(30 + HOUR, idle(["amy", "maya", "yoda"]));
const c = ["sara", "opemipo"].map((x) => mk(x, "working", {ctx: "compact"}));
const L = draw(31 + HOUR, idle(["amy", "maya", "yoda"]).concat(c));
console.log(rooms(L, ["amy", "maya", "yoda", "sara", "opemipo"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,lounge,lounge,rest,rest" ]
}

@test "a place=rest agent counts toward the 3 and is never bumped" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda", "sara"];
start(n.concat(["opemipo"]));
const ts = () => idle(n.concat(["opemipo"]), {opemipo: {place: "rest"}});
draw(10, ts()); draw(10 + HOUR, ts());
const a = draw(11 + HOUR, ts());
console.log(rooms(a, ["amy", "maya", "yoda", "sara", "opemipo"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,rest,lounge,lounge,rest" ]
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

@test "after waking, a nap again 60 minutes later with no turn; a turn restarts the hour" {
  run crew_js "$HELPERS"'
start(["amy"]); draw(10, idle(["amy"]));
const t = 10 + HOUR;
draw(t, idle(["amy"]));
const a = draw(t + 90 * MIN, idle(["amy"])), b = draw(t + 150 * MIN - 1, idle(["amy"])), c = draw(t + 150 * MIN, idle(["amy"]));
const d = draw(t + 150 * MIN + 90 * MIN, idle(["amy"]));
draw(t + 400 * MIN, [mk("amy", "working")]);
draw(t + 401 * MIN, idle(["amy"]));
const e = draw(t + 401 * MIN + HOUR - 1, idle(["amy"])), f = draw(t + 401 * MIN + HOUR, idle(["amy"]));
console.log([a, b, c, d, e, f].map((L) => place(L, "amy")).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge,lounge,rest,lounge,lounge,rest" ]
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

@test "Scofield and coders with a ticket or a PR nap after an hour idle" {
  run crew_js "$HELPERS"'
const c = {sucre: {task: "api#4"}, mahone: {task: "api#5", pr: "9", round: "1"}};
const names = ["sucre", "mahone", "scofield"];
start(names, c); draw(10, idle(names, c));
const a = draw(10 + HOUR - 1, idle(names, c)), L = draw(10 + HOUR, idle(names, c));
const w = draw(11 + HOUR, [mk("sucre", "working", c.sucre), ...idle(["mahone", "scofield"], c)]);
console.log(rooms(a, names), rooms(L, names), place(w, "sucre"), place(w, "mahone"));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk,pong,lounge rest,rest,rest desk rest" ]
}

@test "4 reach an hour at different times: the first 3 sleep, the 4th takes the bed when one wakes" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda", "scofield"];
start(n);
draw(10, idle(["amy"]).concat(n.slice(1).map((x) => mk(x, "working"))));
draw(20, idle(["amy", "maya"]).concat(["yoda", "scofield"].map((x) => mk(x, "working"))));
draw(30, idle(["amy", "maya", "yoda"]).concat([mk("scofield", "working")]));
draw(40, idle(n));
const a = draw(40 + HOUR, idle(n));
const b = draw(41 + HOUR, [mk("amy", "working"), ...idle(["maya", "yoda", "scofield"])]);
console.log(rooms(a, n), rooms(b, n));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,rest,rest,lounge desk,rest,rest,rest" ]
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

@test "when one napper wakes, the others keep their beds" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda"];
start(n); draw(10, idle(n));
const a = draw(10 + HOUR, idle(n));
const b = draw(11 + HOUR, [mk("amy", "working"), ...idle(["maya", "yoda"])]);
console.log(spot(a, "maya") === spot(b, "maya"), spot(a, "yoda") === spot(b, "yoda"), place(b, "amy"), place(b, "maya"), place(b, "yoda"));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true desk rest rest" ]
}

@test "a merger never takes a bed, so 3 nappers keep theirs" {
  run crew_js "$HELPERS"'
const n = ["amy", "maya", "yoda"];
const pr = (x) => ({task: "api#" + x, pr: "9", round: "1"});
const open = (st) => [mk("sucre", st, pr(1)), mk("mahone", st, pr(2))];
start(n);
draw(10, idle(n).concat(open("working")));
draw(10 + HOUR, idle(n).concat(open("working")));
const merged = ["sucre", "mahone"].map((x, i) => mk(x, "idle", {task: "api#" + (i + 1), prdone: "1", prstate: "merged"}));
draw(11 + HOUR, idle(n).concat(merged));
crew.cheerDone(mem, "sucre"); crew.cheerDone(mem, "mahone"); // their confetti went off
const L = draw(12 + HOUR, idle(n).concat(merged));
console.log(rooms(L, ["amy", "maya", "yoda", "sucre", "mahone"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest,rest,rest,lounge,lounge" ]
}

# Ticket #176: with no session, from the last turn the office saw, else from when the office started.
@test "no session: Yoda and a released coder sleep an hour after their last turn" {
  run crew_js "$HELPERS"'
draw(0, [mk("yoda", "working"), mk("sucre", "working", {repo: "api", task: "api#1"})]);
draw(10, idle(["yoda"]).concat([mk("sucre", "idle", {repo: "api", task: "api#1"})]));
draw(20, []); // both sessions are gone
const a = draw(10 + HOUR - 1, []), b = draw(10 + HOUR, []);
console.log(place(a, "yoda"), place(a, "sucre"), place(b, "yoda"), place(b, "sucre"));'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge lounge rest rest" ]
}

@test "no session, never seen: sleeps an hour after the office started, 3 at most" {
  run crew_js "$HELPERS"'
mem.born = 500 * 1000;
const n = (L) => L.people.filter((p) => p.place === "rest").length;
const a = draw(500 + HOUR - 1, []), b = draw(500 + HOUR, []);
console.log(n(a), n(b), rooms(b, ["amy", "mahone", "maya", "opemipo"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "0 3 rest,rest,rest,lounge" ]
}

@test "no session: wakes at 90 minutes, sleeps again 60 minutes later, and the cap of 3 holds across both kinds" {
  run crew_js "$HELPERS"'
mem.born = 0;
draw(0, [mk("amy", "working")]); draw(10, idle(["amy"]));
// amy has a session; yoda, sara, maya, opemipo, scofield have none (never seen): all reach the hour at 3600 s, amy at 3610
const names = ["amy", "yoda", "sara", "maya"];
const a = draw(HOUR, idle(["amy"])), b = draw(HOUR + 10, idle(["amy"]));
const c = draw(HOUR + 90 * MIN, idle(["amy"])), d = draw(HOUR + 150 * MIN, idle(["amy"]));
const n = (L) => L.people.filter((p) => p.place === "rest").length;
console.log(n(a), n(b), n(c), n(d), place(b, "amy"));'
  [ "$status" -eq 0 ]
  [ "$output" = "3 3 3 3 lounge" ]
}

@test "a sleeper with no session is woken at once by a session that starts, and the hour restarts" {
  run crew_js "$HELPERS"'
draw(0, [mk("yoda", "working")]); draw(10, idle(["yoda"])); draw(20, []);
const a = draw(10 + HOUR, []);
const b = draw(4000, [mk("yoda", "working")]);
draw(4010, idle(["yoda"]));
const c = draw(4010 + HOUR - 1, idle(["yoda"])), d = draw(4010 + HOUR, idle(["yoda"]));
console.log(a.people.find((p) => p.id === "yoda").place, place(b, "yoda"), place(c, "yoda"), place(d, "yoda"));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest meeting lounge rest" ]
}

@test "no session, one person: wakes at 90 minutes, sleeps again 60 minutes later (and not before)" {
  run crew_js "$HELPERS"'
draw(0, [mk("yoda", "working")]); draw(10, idle(["yoda"])); draw(20, []);
const t = 10 + HOUR;
const at = (s) => (place(draw(s, []), "yoda") === "rest" ? "rest" : "up"); // Yoda wanders when awake
console.log([at(t - 1), at(t), at(t + 90 * MIN - 1), at(t + 90 * MIN), at(t + 150 * MIN - 1), at(t + 150 * MIN), at(t + 240 * MIN)].join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "up,rest,rest,up,up,rest,up" ]
}

@test "woken from a nap, a short meeting with no turn does not bring the second nap forward" {
  run crew_js "$HELPERS"'
start(["amy"]); draw(10, idle(["amy"]));
const t = 10 + HOUR;
draw(t, idle(["amy"]));
draw(t + 90 * MIN, idle(["amy"])); // awake
const m = draw(t + 100 * MIN, [mk("amy", "idle", {meeting: "1"})]);
const a = draw(t + 110 * MIN, idle(["amy"])), b = draw(t + 150 * MIN - 1, idle(["amy"])), c = draw(t + 150 * MIN, idle(["amy"]));
console.log([m, a, b, c].map((L) => place(L, "amy")).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "meeting,lounge,lounge,rest" ]
}
