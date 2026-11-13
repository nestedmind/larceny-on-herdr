#!/usr/bin/env bats
# The office world: the prototype's floor plan, the whole cast, and where each person stands.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

# JS helper text: a terminal record and a quick lookup of one person.
HELPERS='
const T = (name, status, labels = {}, extra = {}) => ({address: "t-" + name, name, state: "live", status, cwd: "/ws/" + name, labels: {crew: "w", ...labels}, ...extra});
const lay = (ts, repos) => crew.layoutCrew(crew.crewOf(ts, "w"), repos);
const P = (L, id) => L.people.find((p) => p.id === id);
const room = (L, kind) => L.rooms.find((r) => r.kind === kind);
const inRoom = (r, p) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
'

@test "the floor is the prototype's 480 by 288 with two repos" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web"]);
console.log(L.W, L.H, L.rooms.map((r) => r.kind + ":" + r.x + "," + r.y + "," + r.w + "," + r.h).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "480 288 repo:0,0,150,120 repo:150,0,150,120 leads:300,0,90,120 meet:390,0,90,120 matt:0,160,96,128 kitchen:96,160,100,128 lounge:196,160,104,128 pong:300,160,96,128 rest:396,160,84,128" ]
}

@test "a third repo widens the floor, the lounge takes the width and pong and rest move over" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web", "docs"]);
const at = (k) => room(L, k);
console.log(L.W, at("leads").x, at("meet").x, at("kitchen").x, at("lounge").w, at("pong").x, at("rest").x + at("rest").w);'
  [ "$status" -eq 0 ]
  [ "$output" = "630 450 540 96 254 450 630" ]
}

@test "each repo room has the prototype's pod of four desks" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web"]);
const d = L.desks.filter((x) => x.room === "repo:api");
console.log(d.map((x) => [x.x, x.y, x.w, x.h, x.side, x.seat.x, x.seat.y].join(",")).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "46,42,28,16,n,60,36 76,42,28,16,n,90,36 46,58,28,16,s,60,80 76,58,28,16,s,90,80" ]
}

@test "the leads room has a desk each for Scofield and Amy and Matt has his own" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web"]);
const d = (k) => L.desks.find((x) => x.key === k);
console.log(d("scofield").x, d("scofield").w, d("amy").seat.x, d("amy").seat.y, L.mattDesk.seat.x, L.mattDesk.seat.y, L.mattDesk.w);'
  [ "$status" -eq 0 ]
  [ "$output" = "306 32 368 52 36 216 46" ]
}

@test "all twelve are drawn with no terminals, none of the ten agents at a desk" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web"]);
const ids = L.people.map((p) => p.id).join(",");
const agents = L.people.filter((p) => p.agent === null && p.id !== "matt" && p.id !== "dog");
const rooms = new Set(agents.map((p) => p.place));
console.log(ids);
console.log(agents.length, [...rooms].sort().join(","), agents.every((p) => p.state === "off"));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "scofield,sucre,mahone,sheba,whip,amy,maya,opemipo,yoda,sara,matt,dog" ]
  [ "${lines[1]}" = "10 kitchen,lounge true" ]
}

@test "Matt is at his desk and Waffles sleeps on her bed" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api"]);
const m = P(L, "matt"), d = P(L, "dog");
console.log(m.x, m.y, m.face, m.place, d.x, d.y, d.state);'
  [ "$status" -eq 0 ]
  [ "$output" = "36 216 n matt 284 270 sleep" ]
}

@test "a working or blocked coder is at its desk in its task's repo room" {
  run crew_js "$HELPERS"'
const L = lay([T("sucre", "working", {role: "coder", task: "web#2", step: "editing"}), T("whip", "blocked", {role: "coder", task: "api#1"})], ["api", "web"]);
const a = P(L, "sucre"), b = P(L, "whip");
console.log(a.place, a.desk, a.agent.step, a.face, b.place, b.state, b.kind, inRoom(room(L, "repo"), b));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk repo:web:1 editing s desk blocked other true" ]
}

@test "a done coder is in the kitchen, an idle one with a task is at ping pong, one with no task is in the lounge" {
  run crew_js "$HELPERS"'
const L = lay([T("sucre", "done", {role: "coder", task: "api#1"}), T("mahone", "idle", {role: "coder", task: "api#2"}), T("sheba", "idle", {role: "coder", task: "web#3"}), T("whip", "idle", {role: "coder"})], ["api", "web"]);
console.log(["sucre", "mahone", "sheba", "whip"].map((id) => P(L, id).place).join(" "), L.rally);'
  [ "$status" -eq 0 ]
  [ "$output" = "kitchen pong pong lounge true" ]
}

@test "no rally when only one coder is waiting at ping pong" {
  run crew_js "$HELPERS"'
const L = lay([T("mahone", "idle", {role: "coder", task: "api#2"})], ["api"]);
console.log(P(L, "mahone").place, L.rally);'
  [ "$status" -eq 0 ]
  [ "$output" = "pong false" ]
}

@test "a coder away from its desk keeps the desk slot, so the others do not move" {
  run crew_js "$HELPERS"'
const mk = (st) => [T("sucre", st, {role: "coder", task: "api#1"}), T("mahone", "working", {role: "coder", task: "api#2"})];
const a = lay(mk("working"), ["api"]), b = lay(mk("done"), ["api"]);
const pos = (L) => P(L, "mahone").x + "," + P(L, "mahone").y;
console.log(pos(a) === pos(b), P(b, "sucre").place);'
  [ "$status" -eq 0 ]
  [ "$output" = "true kitchen" ]
}

@test "Maya and Opemipo keep their home desks and coders never take them" {
  run crew_js "$HELPERS"'
const ts = [T("maya", "idle", {role: "advisor"}), T("opemipo", "working", {role: "advisor"}),
  ...[1, 2, 3, 4, 5].map((n) => T("c" + n, "working", {role: "coder", task: (n < 4 ? "api#" : "web#") + n}))];
const L = lay(ts, ["api", "web"]);
const keys = L.people.filter((p) => p.desk).map((p) => p.id + ":" + p.desk);
console.log(P(L, "maya").desk, P(L, "opemipo").desk, new Set(L.people.filter((p) => p.desk && p.id !== "matt").map((p) => p.desk)).size, L.people.filter((p) => p.desk && p.id !== "matt").length);'
  [ "$status" -eq 0 ]
  [ "$output" = "repo:web:3 repo:api:4 7 7" ]
}

@test "a fifth coder in a repo with no free desk waits in the lounge" {
  run crew_js "$HELPERS"'
const ts = [1, 2, 3, 4, 5].map((n) => T("c" + n, "working", {role: "coder", task: "web#" + n}));
const L = lay(ts, ["web"]);
const pl = L.people.filter((p) => p.id.startsWith("x:")).map((p) => p.place);
console.log(pl.filter((x) => x === "desk").length, pl.filter((x) => x === "lounge").length);'
  [ "$status" -eq 0 ]
  [ "$output" = "2 3" ]
}

@test "Yoda and Sara sit at the meeting table while running and Scofield and Amy at their desks" {
  run crew_js "$HELPERS"'
const L = lay([T("yoda", "idle", {role: "advisor"}), T("sara", "working", {role: "teacher"}), T("scofield", "idle", {role: "coordinator"}), T("amy", "working", {role: "reviewer"})], ["api", "web"]);
const f = (id) => { const p = P(L, id); return [p.place, p.x, p.y, p.face].join(","); };
console.log(f("yoda"), f("sara"), f("scofield"), f("amy"));'
  [ "$status" -eq 0 ]
  [ "$output" = "meeting,410,50,e meeting,460,50,w desk,322,52,n desk,368,52,n" ]
}

@test "Scofield and Amy are in the lounge when they have no terminal" {
  run crew_js "$HELPERS"'
const L = lay([], ["api"]);
console.log(P(L, "scofield").place, P(L, "amy").place, P(L, "amy").agent);'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge lounge null" ]
}

@test "a cast member is found by name, and by role when the name is not in the cast" {
  run crew_js "$HELPERS"'
const c = crew.crewOf([T("sheba", "idle", {role: "coder"}), T("boss", "idle", {role: "coordinator"}), T("owl", "idle", {role: "advisor"}), T("zed", "idle", {role: "coder"})], "w");
console.log(c.map((a) => a.name + ":" + crew.castKey(a, c)).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "boss:scofield,owl:yoda,sheba:sheba,zed:null" ]
}

@test "an agent outside the cast is drawn as an extra person in the lounge" {
  run crew_js "$HELPERS"'
const L = lay([T("zed", "idle", {role: "coder"})], ["api"]);
const z = L.people.find((p) => p.name === "Zed" || p.name === "zed");
console.log(L.people.length, z.place, z.running);'
  [ "$status" -eq 0 ]
  [ "$output" = "13 lounge true" ]
}

@test "Waffles keeps Matt company while an agent is blocked, then goes back to her bed" {
  run crew_js "$HELPERS"'
const a = lay([T("sucre", "blocked", {role: "coder", task: "api#1"})], ["api"]), b = lay([T("sucre", "working", {role: "coder", task: "api#1"})], ["api"]);
const d = P(a, "dog"), m = P(a, "matt");
console.log(d.state, d.x - m.x, d.y - m.y, P(b, "dog").state);'
  [ "$status" -eq 0 ]
  [ "$output" = "sit 11 5 sleep" ]
}

@test "the summary counts the ten agents and a missing terminal counts as idle" {
  run crew_js "$HELPERS"'
const L = lay([T("sucre", "working", {role: "coder", task: "api#1"}), T("whip", "blocked", {role: "coder", task: "api#2"})], ["api"]);
console.log(JSON.stringify(L.totals));'
  [ "$status" -eq 0 ]
  [ "$output" = '{"working":1,"blocked":1,"done":0,"idle":8}' ]
}

@test "everybody stands inside a room" {
  run crew_js "$HELPERS"'
const ts = [T("scofield", "working", {role: "coordinator"}), T("sucre", "done", {role: "coder", task: "api#1"}), T("mahone", "idle", {role: "coder", task: "api#2"}), T("sheba", "working", {role: "coder", task: "web#3"}), T("yoda", "idle", {role: "advisor"}), T("zed", "idle", {role: "coder"})];
const L = lay(ts, ["api", "web"]);
const bad = L.people.filter((p) => crew.roomAt(L, p.x, p.y) === null).map((p) => p.id);
console.log(bad.length, bad.join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "0 " ]
}

@test "a walk inside one room goes straight to the spot" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web"]);
console.log(JSON.stringify(crew.pathTo(L, "sucre", {x: 60, y: 36}, {x: 90, y: 80})));'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"x":90,"y":80}]' ]
}

@test "a walk between rooms goes door to door through the corridor lane" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web"]);
const lane = crew.laneFor("sucre");
const pts = crew.pathTo(L, "sucre", {x: 60, y: 80}, {x: 232, y: 250});
console.log(JSON.stringify(pts), lane >= 134 && lane <= 146);'
  [ "$status" -eq 0 ]
  [[ "$output" == '[{"x":75,"y":110},{"x":75,"y":'*'},{"x":284,"y":'*'},{"x":284,"y":170},{"x":232,"y":250}] true' ]]
}

@test "the lane depends on the person, so two walkers do not overlap" {
  run crew_js "$HELPERS"'
const ids = ["scofield", "sucre", "mahone", "sheba", "whip", "amy"];
console.log(new Set(ids.map(crew.laneFor)).size > 2);'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "legs turn a path into timed steps with the way the walker faces" {
  run crew_js "$HELPERS"'
const legs = crew.legsOf({x: 0, y: 0}, [{x: 62, y: 0}, {x: 62, y: -31}], 62);
console.log(JSON.stringify(legs));'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"x":62,"y":0,"face":"e","ms":1000},{"x":62,"y":-31,"face":"n","ms":500}]' ]
}

@test "legs skip steps of no length" {
  run crew_js "$HELPERS"'
console.log(crew.legsOf({x: 5, y: 5}, [{x: 5, y: 5}, {x: 5, y: 15}], 62).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a person who is not running can be offered a start, and a running one cannot" {
  run crew_js "$HELPERS"'
const L = lay([T("sucre", "idle", {role: "coder"})], ["api"]);
const kinds = ["scofield", "amy", "whip", "yoda", "matt", "dog", "sucre"].map((id) => id + ":" + crew.startPlan(P(L, id)).kind);
console.log(kinds.join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "scofield:up amy:up whip:spawn yoda:none matt:none dog:none sucre:running" ]
}

@test "starting Scofield or Amy runs loh up, after asking" {
  run crew_js "$HELPERS"'
const L = lay([], ["api"]);
const p = crew.startPlan(P(L, "amy"), "/opt/loh");
const c = crew.startCall(p, "/ws/lead", "/opt/loh");
console.log(p.ask, c.cmd, c.args.join(" "), c.options.cwd, c.options.timeout);'
  [ "$status" -eq 0 ]
  [ "$output" = "Start Scofield and Amy with loh up? /opt/loh up /ws/lead 60000" ]
}

@test "a coder needs a repo and a ticket, so the office names the command and does not guess" {
  run crew_js "$HELPERS"'
const L = lay([], ["api"]);
const p = crew.startPlan(P(L, "sheba"));
console.log(p.kind, p.hint, crew.startCall(p, "/x", "loh"));'
  [ "$status" -eq 0 ]
  [ "$output" = "spawn loh spawn sheba <repo> <ticket> null" ]
}

@test "the folder loh runs in is a running agent's, else the dir prop" {
  run crew_js "$HELPERS"'
const c = crew.crewOf([T("sucre", "idle", {role: "coder"}), T("scofield", "idle", {role: "coordinator"})], "w");
console.log(crew.anchorCwd(c, {dir: "/d"}), crew.anchorCwd([], {dir: "/d"}), crew.anchorCwd([], {}) === "");'
  [ "$status" -eq 0 ]
  [ "$output" = "/ws/scofield /d true" ]
}

@test "people colours are the prototype's, and anyone else gets a stable colour by name" {
  run crew_js "$HELPERS"'
console.log(crew.look("sheba").join(","), crew.look("matt")[2], crew.look("zed").join() === crew.look("zed").join());'
  [ "$status" -eq 0 ]
  [ "$output" = "#4a2618,#8d5a3b,#8e4fa8 #e0603f true" ]
}

@test "name tags that would overlap are pushed apart, down for a tag below its person and up for one above" {
  run crew_js "$HELPERS"'
const r = crew.stackTags([
  {id: "a", x: 10, y: 100, w: 60, h: 17, up: false},
  {id: "b", x: 30, y: 105, w: 60, h: 17, up: false},
  {id: "c", x: 200, y: 50, w: 60, h: 17, up: true},
  {id: "d", x: 210, y: 45, w: 60, h: 17, up: true},
  {id: "e", x: 400, y: 10, w: 60, h: 17, up: false}]);
console.log(r.get("a"), r.get("b"), r.get("c"), r.get("d"), r.get("e"));'
  [ "$status" -eq 0 ]
  [ "$output" = "100 118 27 45 10" ]
}
