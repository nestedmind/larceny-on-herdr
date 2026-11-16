#!/usr/bin/env bats
# Yoda and Sara wander while they have no session, Waffles wakes now and then, and a click starts a persona.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

# A seeded random source, a simulated hour stepped by each render's own wakeIn, and a few lookups.
HELPERS='
const T = (name, status, labels = {}, extra = {}) => ({address: "t-" + name, name, state: "live", status, cwd: "/ws/" + name, labels: {crew: "w", ...labels}, ...extra});
const P = (L, id) => L.people.find((p) => p.id === id);
const seeded = (seed) => () => { seed |= 0; seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const MIN = 60000;
// Render again whenever the last render asked for it, for `hours` hours; call `see(L, now)` at each render.
const hour = (ts, seed, see, hours = 1) => {
  const mem = crew.newMemory(), rand = seeded(seed), t0 = 1000000;
  let now = t0, n = 0;
  while (now - t0 <= hours * 60 * MIN && n++ < 5000) {
    const L = crew.layoutCrew(crew.crewOf(ts, "w"), ["api"], 0, {mem, now, rand});
    see(L, now);
    now += Math.max(1, L.wakeIn === null ? 60 * MIN : L.wakeIn);
  }
};
const where = (L, p) => { const r = crew.roomAt(L, p.x, p.y); return r ? r.kind : "corridor"; };
'

@test "Yoda and Sara are drawn at full colour with no session, and so are Maya and Opemipo" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api"]);
console.log(["yoda", "sara", "maya", "opemipo", "scofield"].map((id) => id + ":" + P(L, id).dim).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "yoda:false sara:false maya:false opemipo:false scofield:true" ]
}

@test "with no session Yoda and Sara move between the lounge, the kitchen and ping pong every 5 to 15 minutes, and never enter the meeting room" {
  run crew_js "$HELPERS"'
const out = [];
for (const id of ["yoda", "sara"]) {
  const seen = new Set(); const moves = []; let last = null;
  hour([], 7, (L, now) => { const w = where(L, P(L, id)); seen.add(w); if (last !== null && w !== last.w) moves.push(now - last.at); if (last === null || w !== last.w) last = {w, at: now}; });
  const gaps = moves.slice(1);
  out.push(id, [...seen].sort().join("/"), moves.length >= 3, gaps.every((g) => g >= 5 * MIN && g <= 15 * MIN));
}
console.log(out.join(" "));'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^yoda\ .*\ true\ true\ sara\ .*\ true\ true$ ]]
  [[ "$output" != *meet* ]]
  [[ "$output" != *rest* ]]
  [[ "$output" != *corridor* ]]
}

@test "every move of Yoda or Sara goes to a different one of the three rooms, and the choice follows the random source" {
  run crew_js "$HELPERS"'
const trace = (seed) => { const r = []; hour([], seed, (L) => { const w = where(L, P(L, "yoda")); if (r[r.length - 1] !== w) r.push(w); }, 2); return r; };
const a = trace(1), b = trace(2);
console.log(a.length > 3, a.every((w) => ["lounge", "kitchen", "pong"].includes(w)), a.join() === trace(1).join(), a.join() !== b.join());'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true" ]
}

@test "once Yoda has a session the usual rules place him, and the wandering is forgotten" {
  run crew_js "$HELPERS"'
const mem = crew.newMemory(), rand = seeded(3);
crew.layoutCrew([], ["api"], 0, {mem, now: 1000, rand});
const L = crew.layoutCrew(crew.crewOf([T("yoda", "idle", {role: "advisor"})], "w"), ["api"], 0, {mem, now: 2000, rand});
console.log(P(L, "yoda").place, mem.wander.has("yoda"));'
  [ "$status" -eq 0 ]
  [ "$output" = "meeting false" ]
}

@test "Waffles leaves her bed every 5 to 15 minutes, visits one or two spots and goes back to sleep" {
  run crew_js "$HELPERS"'
const departures = []; const stops = []; let prev = "sleep", cur = null;
hour([], 11, (L, now) => {
  const d = P(L, "dog");
  if (d.state !== "sleep" && prev === "sleep") { departures.push(now); cur = new Set(); }
  if (d.state !== "sleep") cur.add(Math.round(d.x) + "," + Math.round(d.y));
  if (d.state === "sleep" && prev !== "sleep") stops.push(cur.size);
  prev = d.state;
}, 2);
const gaps = departures.slice(1).map((t, i) => t - departures[i]);
console.log(departures.length >= 6, gaps.every((g) => g >= 5 * MIN && g <= 15 * MIN), stops.length >= 5, stops.every((n) => n === 1 || n === 2), prev);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true sleep" ]
}

@test "Waffles' stops are Matt's room, the kitchen and the lounge" {
  run crew_js "$HELPERS"'
const rooms = new Set();
hour([], 5, (L) => { const d = P(L, "dog"); if (d.state !== "sleep") rooms.add(where(L, d)); }, 4);
console.log([...rooms].sort().join());'
  [ "$status" -eq 0 ]
  [ "$output" = "kitchen,lounge,matt" ]
}

@test "while an agent is blocked Waffles is beside Matt, even on a walk, and then goes on as before" {
  run crew_js "$HELPERS"'
const bad = []; const blocked = [T("sucre", "blocked", {role: "coder", task: "api#1"})];
const mem = crew.newMemory(), rand = seeded(2);
let now = 1000000;
for (let i = 0; i < 400; i++) {
  const L = crew.layoutCrew(crew.crewOf(blocked, "w"), ["api"], 0, {mem, now, rand});
  const d = P(L, "dog"), m = P(L, "matt");
  if (d.state !== "sit" || d.x - m.x !== 11 || d.y - m.y !== 5) bad.push(i);
  now += 30000;
}
const after = crew.layoutCrew([], ["api"], 0, {mem, now, rand});
console.log(bad.length, ["sleep", "sit"].includes(P(after, "dog").state));'
  [ "$status" -eq 0 ]
  [ "$output" = "0 true" ]
}

@test "the office asks to render again for each next move (wakeIn), with no repeating timer" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api"], 0, {mem: crew.newMemory(), now: 5000, rand: seeded(4)});
console.log(L.wakeIn !== null && L.wakeIn >= 30000 && L.wakeIn <= 15 * MIN);'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "a click on Yoda, Sara, Maya or Opemipo with no session offers loh start, after asking, in the workspace folder" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api"]);
const out = ["yoda", "sara", "maya", "opemipo"].map((id) => { const p = crew.startPlan(P(L, id), [], "/ws/demo"); return [id, p.kind, p.ask, p.hint].join("|"); });
console.log(out.join("\n"));
console.log(crew.startPlan(P(L, "yoda")).ask);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "yoda|start|Start Yoda in /ws/demo?|loh start yoda" ]
  [ "${lines[1]}" = "sara|start|Start Sara in /ws/demo?|loh start sara" ]
  [ "${lines[2]}" = "maya|start|Start Maya in /ws/demo?|loh start maya" ]
  [ "${lines[3]}" = "opemipo|start|Start Opemipo in /ws/demo?|loh start opemipo" ]
  [ "${lines[4]}" = "Start Yoda with loh start?" ]
}

@test "Start runs loh start <name> in the workspace folder, and nothing else can reach it" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api"]);
const c = crew.startCall(crew.startPlan(P(L, "yoda"), [], "/ws"), "/ws/x", "/opt/loh");
console.log(c.cmd, c.args.join(" "), c.options.cwd, c.options.timeout);
console.log(crew.startCall(crew.startPlan(P(L, "matt")), "/ws/x", "loh"), crew.startPlan(P(L, "dog")).kind, crew.startPlan(P(L, "scofield")).kind);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "/opt/loh start yoda /ws/x 120000" ]
  [ "${lines[1]}" = "null none up" ]
}

@test "with configured crew names the advisor and teacher seats still wander, are drawn at full colour and offer loh start" {
  run crew_js "$HELPERS"'
const names = {coordinator: "Mia", reviewer: "Rex", advisor: "Rey", teacher: "Ada", coders: ["Ana", "Bo"], person: "Dana"};
const rooms = new Set(); const dims = [];
hour([], 7, (L) => { rooms.add(where(L, P(L, "yoda"))); }, 1);
const L = crew.layoutCrew([], ["api"], 0, {names, mem: crew.newMemory(), now: 1000, rand: seeded(7)});
const y = P(L, "yoda"), s = P(L, "sara");
console.log([y.name, s.name, y.dim, s.dim, crew.startPlan(y, [], "/ws", names).ask, crew.startPlan(s, [], "/ws", names).hint].join("|"));
const wander = new Set();
const mem = crew.newMemory(), rand = seeded(5); let now = 1000000;
for (let i = 0; i < 40; i++) { const M = crew.layoutCrew([], ["api"], 0, {names, mem, now, rand}); wander.add(where(M, P(M, "yoda"))); wander.add(where(M, P(M, "sara"))); now += Math.max(1, M.wakeIn || 60000); }
console.log([...wander].sort().join());'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Rey|Ada|false|false|Start Rey in /ws?|loh start sara" ]
  [[ "${lines[1]}" != *meet* && "${lines[1]}" != *corridor* && "${lines[1]}" != *matt* ]]
}
