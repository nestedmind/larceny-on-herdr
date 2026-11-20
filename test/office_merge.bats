#!/usr/bin/env bats
# A coder's pull request merging (ticket #70): one confetti burst and one toast on the change from open to merged,
# nothing for a pull request that was already merged, and no rest room for the merger.

bats_require_minimum_version 1.5.0
load test_helper

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$REPO_ROOT/office/crew-office/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

HELPERS='
const T = (name, status, labels = {}) => ({address: "t-" + name, name, state: "live", status, cwd: "/ws/" + name, labels: {crew: "w", role: "coder", task: "api#4", ...labels}});
const idle = (name, labels) => T(name, {state: "idle"}, labels);
const open = (name = "sucre") => idle(name, {pr: "9"});
const merged = (name = "sucre") => idle(name, {prdone: "1", prstate: "merged"});
const closed = (name = "sucre") => idle(name, {prdone: "1", prstate: "closed"});
const agents = (...ts) => crew.crewOf(ts, "w");
const show = (l) => l.map((x) => [x.kind, x.head, x.body, x.who].join("|")).join(";");
const play = (steps) => {
  const m = crew.newToasts(); const out = [];
  for (const [s, ts] of steps) out.push(crew.toastStep(m, agents(...ts), s * 1000));
  return out;
};
const lay = (steps) => {
  const mem = crew.newMemory(); const out = [];
  for (const [s, ts] of steps) out.push(crew.layoutCrew(agents(...ts), ["api"], 0, {mem, now: s * 1000}));
  return out;
};
const P = (L, id) => L.people.find((p) => p.id === id);
'

@test "a pull request going from open to merged gives one burst and one toast" {
  run crew_js "$HELPERS"'
const r = play([[0, [open()]], [1, [open()]], [2, [merged()]]]);
console.log(r.map((x) => x.bursts.length).join(","), show(r[2].list));'
  [ "$status" -eq 0 ]
  [ "$output" = "0,0,1 done|api PR #9 merged|Sucre merged it|t-sucre" ]
}

@test "the burst and the toast are not repeated by later renders" {
  run crew_js "$HELPERS"'
const r = play([[0, [open()]], [1, [merged()]], [2, [merged()]], [3, [merged()]]]);
console.log(r.map((x) => x.bursts.length).join(","), r[3].list.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "0,1,0,0 1" ]
}

@test "a pull request already merged when the office opens gives nothing" {
  run crew_js "$HELPERS"'
const r = play([[0, [merged()]], [1, [merged()]]]);
console.log(r.map((x) => x.bursts.length + "/" + x.list.length).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "0/0,0/0" ]
}

@test "a pull request closed without merging gives nothing" {
  run crew_js "$HELPERS"'
const r = play([[0, [open()]], [1, [closed()]]]);
console.log(r.map((x) => x.bursts.length + "/" + x.list.length).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "0/0,0/0" ]
}

@test "a coder that appears already merged after the office opened gives nothing" {
  run crew_js "$HELPERS"'
const r = play([[0, [open("whip")]], [1, [open("whip"), merged()]]]);
console.log(r.map((x) => x.bursts.length + "/" + x.list.length).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "0/0,0/0" ]
}

@test "two coders merging in one render give two bursts at their own desks" {
  run crew_js "$HELPERS"'
const r = play([[0, [open("sucre"), open("whip")]], [1, [merged("sucre"), merged("whip")]]]);
console.log(r[1].bursts.map((b) => b.who).join(","), r[1].list.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "t-sucre,t-whip 2" ]
}

@test "a burst is 40 pieces in five colours that live 2 to 3 s" {
  run crew_js "$HELPERS"'
const p = crew.confettiPieces(crew.seededRand(7));
const cols = new Set(p.map((x) => x.c));
console.log(p.length, [...cols].sort().join(""), p.every((x) => x.life >= 2000 && x.life <= 3000), crew.BURST_MS);'
  [ "$status" -eq 0 ]
  [ "$output" = "40 01234 true 3000" ]
}

@test "the merger goes to its desk when its turn ends, then to the lounge or kitchen once its confetti went off, never the rest room; the desk is free after that" {
  run crew_js "$HELPERS"'
const mem = crew.newMemory();
const at = (s, ts) => crew.layoutCrew(agents(...ts), ["api"], 0, {mem, now: s * 1000});
const a = at(0, [open()]), b = at(10, [merged()]), c = at(13, [merged()]);
crew.cheerDone(mem, "sucre");
const d = at(14, [merged()]), e = at(16, [merged()]);
const w = (l) => P(l, "sucre").mode + ":" + (P(l, "sucre").place === "kitchen" ? "lounge" : P(l, "sucre").place);
console.log([a, b, c, d, e].map(w).join(" "), P(d, "sucre").desk);'
  [ "$status" -eq 0 ]
  [ "$output" = "wait:lounge deskfree:desk deskfree:desk away:lounge away:lounge null" ]
}

@test "a merger whose confetti never goes off goes to the lounge or kitchen after CHEER_MAX_MS" {
  run crew_js "$HELPERS"'
const mem = crew.newMemory();
const at = (s, ts) => crew.layoutCrew(agents(...ts), ["api"], 0, {mem, now: s * 1000});
at(0, [open()]); at(10, [merged()]);
const a = at(10 + crew.CHEER_MAX_MS / 1000 - 1, [merged()]), b = at(10 + crew.CHEER_MAX_MS / 1000, [merged()]);
console.log(P(a, "sucre").mode, P(b, "sucre").mode, a.wakeIn);'
  [ "$status" -eq 0 ]
  [ "$output" = "deskfree away 1000" ]
}

@test "a merger still working keeps its desk, and (once its turn ends and its confetti went off) goes to the lounge" {
  run crew_js "$HELPERS"'
const mem = crew.newMemory();
const at = (s, ts) => crew.layoutCrew(agents(...ts), ["api"], 0, {mem, now: s * 1000});
const w = T("sucre", {state: "working"}, {prdone: "1", prstate: "merged"});
const L = [at(0, [open()]), at(5, [w]), at(20, [w]), at(30, [merged()])];
crew.cheerDone(mem, "sucre");
L.push(at(32, [merged()]));
console.log(L.map((l) => P(l, "sucre").mode).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "wait deskfree deskfree deskfree away" ]
}

@test "a pull request already merged when the office opens sends nobody away" {
  run crew_js "$HELPERS"'
const L = lay([[0, [merged()]], [1, [merged()]]]);
console.log(L.map((l) => P(l, "sucre").mode).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "deskfree deskfree" ]
}

@test "a pull request closed without merging sends nobody away" {
  run crew_js "$HELPERS"'
const L = lay([[0, [open()]], [1, [closed()]]]);
console.log(L.map((l) => P(l, "sucre").mode).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "wait deskfree" ]
}

@test "a merge wins over a nap: a napping merger gets up and goes to its desk for its confetti, and does not nap again at once" {
  run crew_js "$HELPERS"'
const mem = crew.newMemory();
mem.born = 1e15; // people with no session do not nap here
const at = (s, ts) => crew.layoutCrew(agents(...ts), ["api"], 0, {mem, now: s * 1000});
const HOUR = 3600;
at(0, [T("sucre", {state: "working"}, {pr: "9"})]);
const wait = idle("sucre", {pr: "9"});
at(10, [wait]);
const nap = at(10 + HOUR, [wait]);               // asleep in the rest room
const m1 = at(10 + HOUR + 5, [merged()]);          // the merge is seen
const m2 = at(10 + HOUR + 10, [merged()]);
crew.cheerDone(mem, "sucre");
const m3 = at(10 + HOUR + 11, [merged()]);
console.log([nap, m1, m2, m3].map((l) => P(l, "sucre").mode + ":" + (P(l, "sucre").place === "kitchen" ? "lounge" : P(l, "sucre").place)).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "rest:rest deskfree:desk deskfree:desk away:lounge" ]
}
