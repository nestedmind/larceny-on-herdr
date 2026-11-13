#!/usr/bin/env bats
# The office fills its pane: the floor follows the pane's aspect ratio, and full-screen mode
# plans which chrome to hide and what to give back.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

HELPERS='
const room = (L, kind) => L.rooms.find((r) => r.kind === kind);
'

@test "floorSize grows the short side for 16:9, 4:3, square, ultrawide and tall panes" {
  run crew_js '
const f = (w, a) => { const s = crew.floorSize(w, a); return s.W + "x" + Math.round(s.H); };
console.log([f(480, 16 / 9), f(480, 4 / 3), f(480, 1), f(480, 32 / 9), f(480, 9 / 16), f(630, 2.5), f(630, 1.5)].join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "512x288 480x360 480x480 1024x288 480x853 720x288 630x420" ]
}

@test "no aspect keeps the prototype's 480 by 288 floor" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web"]);
console.log(L.W, L.H);'
  [ "$status" -eq 0 ]
  [ "$output" = "480 288" ]
}

@test "extra width is shared across the rooms of each row (16:9)" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web"], 16 / 9);
const w = (row) => L.rooms.filter((r) => r.row === row).map((r) => r.w.toFixed(1)).join(",");
console.log(L.W, L.H, w("top"), w("bottom"));'
  [ "$status" -eq 0 ]
  # 32 extra: 8 to each of the four top rooms, 6.4 to each of the five below
  [ "$output" = "512 288 158.0,158.0,98.0,98.0 102.4,106.4,110.4,102.4,90.4" ]
}

@test "extra height is shared across the two rows and the corridor (4:3)" {
  run crew_js "$HELPERS"'
const L = crew.layoutCrew([], ["api", "web"], 4 / 3);
const r = room(L, "repo"), m = room(L, "matt");
console.log(L.W, L.H, r.h, L.corr.y, L.corr.h, m.y, m.h);'
  [ "$status" -eq 0 ]
  [ "$output" = "480 360 150 150 50 200 160" ]
}

@test "rooms tile the floor edge to edge in both rows for several aspect ratios" {
  run crew_js "$HELPERS"'
const bad = [];
for (const a of [0.5625, 1, 4 / 3, 16 / 9, 21 / 9, 32 / 9]) for (const repos of [[], ["a"], ["a", "b"], ["a", "b", "c", "d"]]) {
  const L = crew.layoutCrew([], repos, a);
  for (const row of ["top", "bottom"]) {
    const rs = L.rooms.filter((r) => r.row === row).sort((p, q) => p.x - q.x);
    let x = 0;
    for (const r of rs) { if (Math.abs(r.x - x) > 1e-6) bad.push(["gap", a, row, r.key]); x = r.x + r.w; }
    if (Math.abs(x - L.W) > 1e-6) bad.push(["width", a, row, x, L.W]);
  }
  const top = room(L, "leads"), bot = room(L, "matt");
  if (Math.abs(top.h + L.corr.h + bot.h - L.H) > 1e-6 || Math.abs(L.corr.y - top.h) > 1e-6 || Math.abs(bot.y - (L.corr.y + L.corr.h)) > 1e-6) bad.push(["height", a]);
}
console.log(JSON.stringify(bad));'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "desks keep their size and their pod stays centred in the room" {
  run crew_js "$HELPERS"'
const bad = [];
for (const a of [1, 4 / 3, 16 / 9, 32 / 9]) {
  const L = crew.layoutCrew([], ["api", "web"], a);
  for (const r of L.rooms.filter((x) => x.kind === "repo")) {
    const d = L.desks.filter((x) => x.room === r.key);
    if (d.some((x) => x.w !== 28 || x.h !== 16)) bad.push(["size", a]);
    const cx = d.reduce((s, x) => s + x.cx, 0) / d.length;
    if (Math.abs(cx - (r.x + r.w / 2)) > 1e-6) bad.push(["pod x", a, r.key]);
    const rows = (Math.min(...d.map((x) => x.y)) + Math.max(...d.map((x) => x.y + x.h))) / 2;
    if (Math.abs(rows - (r.y + 58 + (r.h - 120) / 2)) > 1e-6) bad.push(["pod y", a, r.key, rows]);
    if (d.some((x) => Math.abs(x.seat.x - x.cx) > 1e-6 || Math.abs(Math.abs(x.seat.y - (x.y + 8)) - 14) > 1e-6)) bad.push(["seat", a]);
  }
}
console.log(JSON.stringify(bad));'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "everyone stands inside a room, and every spot inside its room, at any aspect" {
  run crew_js "$HELPERS"'
const bad = [];
const ts = ["sucre", "mahone", "sheba", "whip", "scofield", "amy", "yoda", "sara", "maya", "opemipo"].map((n, i) => ({ address: "t" + i, name: n, state: "live", status: ["working", "idle", "done", "blocked"][i % 4], cwd: "/w", labels: { crew: "w", task: "api#" + (i + 1) } }));
for (const a of [0.5625, 1, 4 / 3, 16 / 9, 21 / 9, 32 / 9]) {
  const L = crew.layoutCrew(crew.crewOf(ts, "w"), ["api", "web"], a);
  for (const p of L.people) { if (p.id !== "dog" && crew.roomAt(L, p.x, p.y) === null) bad.push([a, p.id, "corridor"]); if (p.x < 0 || p.x > L.W || p.y < 0 || p.y > L.H) bad.push([a, p.id, "outside"]); }
  for (const [k, list] of Object.entries(L.spots)) {
    const r = room(L, k);
    for (const s of list) if (s.x < r.x || s.x > r.x + r.w || s.y < r.y || s.y > r.y + r.h) bad.push([a, k, "spot"]);
  }
}
console.log(JSON.stringify(bad));'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a walk between rooms uses a lane inside the corridor at any aspect" {
  run crew_js "$HELPERS"'
const bad = [];
for (const a of [1, 4 / 3, 32 / 9]) {
  const L = crew.layoutCrew([], ["api", "web"], a);
  for (const id of ["sucre", "mahone", "sheba", "whip", "x"]) {
    const lane = crew.laneFor(id, L);
    if (lane < L.corr.y || lane > L.corr.y + L.corr.h) bad.push([a, id, "lane"]);
  }
  const pts = crew.pathTo(L, "sucre", { x: room(L, "repo").x + 10, y: room(L, "repo").y + 60 }, { x: room(L, "lounge").x + 10, y: room(L, "lounge").y + 60 });
  for (const p of pts) if (p.x < 0 || p.x > L.W || p.y < 0 || p.y > L.H) bad.push([a, "outside", p.x, p.y]);
  const lane = crew.laneFor("sucre", L);
  if (!pts.some((p) => p.y === lane)) bad.push([a, "no lane"]);
}
console.log(JSON.stringify(bad));'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "the scaled floor reaches the stage edges in 16:9, 4:3, square and wide windows, within the padding" {
  run crew_js "$HELPERS"'
const out = [];
for (const [w, h] of [[1920, 1000], [1600, 1200], [1000, 1000], [2400, 700]]) {
  const size = { width: w, height: h };
  const L = crew.layoutCrew([], ["api", "web"], crew.aspectOf(size));
  const { k, fits } = crew.fitScale(size, L);
  const mx = w - L.W * k, my = h - L.H * k;
  out.push([fits, mx <= 2 * crew.PAD + 0.5 && my <= 2 * crew.PAD + 0.5].join(","));
}
console.log(out.join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "true,true true,true true,true true,true" ]
}

@test "the scale is one number for both axes, so nothing is stretched" {
  run crew_js "$HELPERS"'
const size = { width: 1920, height: 1000 };
const L = crew.layoutCrew([], ["api", "web"], crew.aspectOf(size));
const { k } = crew.fitScale(size, L);
console.log(Math.abs(L.W * k - (1920 - 2 * crew.PAD)) < 0.5, Math.abs(L.H * k - (1000 - 2 * crew.PAD)) < 0.5);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true" ]
}

@test "stage colours are the prototype's, one for light and one for dark" {
  run crew_js 'console.log(crew.stageBg(false), crew.stageBg(true));'
  [ "$status" -eq 0 ]
  [ "$output" = "#d5dae3 #0b0e14" ]
}

@test "full screen hides only the chrome that is visible and remembers it" {
  run crew_js '
const tree = { id: "root", children: [
  { id: "sidebar", children: [{ id: "agents" }] },
  { id: "main", children: [{ id: "tabs", hidden: true }, { id: "body" }, { id: "panel", hidden: false }, { id: "status" }] } ] };
console.log(JSON.stringify(crew.fullscreenPlan(tree, { fullscreen: false, zoomed: false, siblings: true })));'
  [ "$status" -eq 0 ]
  [ "$output" = '{"zoom":true,"hide":["sidebar","panel","status"],"window":true}' ]
}

@test "full screen leaves alone a window that is already full screen, a pane already zoomed and a lone pane" {
  run crew_js '
const tree = { id: "root", children: [{ id: "sidebar" }] };
console.log(JSON.stringify(crew.fullscreenPlan(tree, { fullscreen: true, zoomed: true, siblings: true })), JSON.stringify(crew.fullscreenPlan(tree, { fullscreen: false, zoomed: false, siblings: false })));'
  [ "$status" -eq 0 ]
  [ "$output" = '{"zoom":false,"hide":["sidebar"],"window":false} {"zoom":false,"hide":["sidebar"],"window":true}' ]
}

@test "a layout that cannot be read plans no chrome hiding" {
  run crew_js 'console.log(JSON.stringify(crew.fullscreenPlan(null, { fullscreen: false, zoomed: false, siblings: true })));'
  [ "$status" -eq 0 ]
  [ "$output" = '{"zoom":true,"hide":[],"window":true}' ]
}

@test "restoring undoes exactly the plan, in reverse, and a plan that did nothing restores nothing" {
  run crew_js '
const plan = { zoom: true, hide: ["sidebar", "status"], window: true };
console.log(JSON.stringify(crew.restoreSteps(plan)), JSON.stringify(crew.restoreSteps({ zoom: false, hide: [], window: false })));'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"window":true},{"show":"status"},{"show":"sidebar"},{"zoom":true}] []' ]
}

@test "the floor cache key changes when only the height changes, and not with the scale" {
  run crew_js '
const a = crew.layoutCrew([], ["api", "web"], 1.2), b = crew.layoutCrew([], ["api", "web"], 1.1);
const k = 1.5;
console.log(a.W === b.W, a.H !== b.H, crew.floorKey(a, k) !== crew.floorKey(b, k), crew.floorKey(a, k) === crew.floorKey(a, k), crew.floorKey(a, k) === crew.floorKey(a, 1.6));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true true" ]
}

@test "the entrance mat, its light and the gap in the outer wall share the corridor's middle at every aspect" {
  run crew_js "$HELPERS"'
const bad = [];
for (const a of [9 / 16, 1, 4 / 3, 16 / 9, 32 / 9]) {
  const L = crew.layoutCrew([], ["api", "web"], a);
  const e = L.entrance, mid = L.corr.y + L.corr.h / 2;
  if (Math.abs(e.y + e.h / 2 - mid) > 1e-6) bad.push([a, "mat"]);
  if (Math.abs(e.light.y + e.light.h / 2 - mid) > 1e-6) bad.push([a, "light"]);
  if (Math.abs(e.gap.y0 - (e.y - 2)) > 1e-6 || Math.abs(e.gap.y1 - (e.y + e.h + 2)) > 1e-6) bad.push([a, "gap"]);
}
console.log(JSON.stringify(bad), JSON.stringify(crew.layoutCrew([], ["a", "b"]).entrance));'
  [ "$status" -eq 0 ]
  [ "$output" = '[] {"y":128,"h":24,"light":{"y":136,"h":8},"gap":{"y0":126,"y1":154}}' ]
}

@test "startup recovery: adopt your own pane's plan, undo one whose pane is gone, leave a live one alone" {
  run crew_js '
const saved = { plan: { zoom: false, hide: ["sidebar"], window: false }, pane: "p1" };
const r = (s, panes, own) => crew.recoveryFor(s, panes, own);
console.log([r(saved, ["p1", "p2"], "p1"), r(saved, ["p1", "p2"], "p2"), r(saved, ["p2"], "p2"), r(saved, [], null), r(null, ["p1"], "p1"), r({ pane: "p1" }, ["p1"], "p1")].join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "adopt leave undo undo none none" ]
}

@test "a saved plan with no pane is live: adopted by recovery and by the Full screen button, never entered over" {
  run crew_js '
const plan = { zoom: false, hide: ["sidebar"], window: false };
const s = { plan, pane: null };
console.log([crew.recoveryFor(s, ["p1"], "p1"), crew.recoveryFor(s, [], null), crew.recoveryFor({ plan }, ["p1", "p2"], "p2", ["p1", "p2"]), crew.entryFor(s, ["p1"], "p1", ["p1"]), crew.entryFor(s, [], null, [])].join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "adopt adopt adopt adopt adopt" ]
}

@test "startup recovery with an unknown own pane: adopt when the saved pane is the only office pane, else leave" {
  run crew_js '
const saved = { plan: { zoom: false, hide: ["sidebar"], window: false }, pane: "p1" };
const r = (panes, offices) => crew.recoveryFor(saved, panes, null, offices);
console.log([r(["p1", "p2"], ["p1"]), r(["p1", "p2", "p3"], ["p1", "p3"]), r(["p1", "p2"], []), r(["p2"], ["p2"]), r(["p2"], [])].join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "adopt leave leave undo undo" ]
}

@test "pressing Full screen never overwrites a saved plan whose pane is still open" {
  run crew_js '
const saved = { plan: { zoom: false, hide: ["sidebar"], window: false }, pane: "p1" };
const e = (s, panes, mine, offices) => crew.entryFor(s, panes, mine, offices);
console.log([e(null, ["p1"], "p1", ["p1"]), e(saved, ["p1"], "p1", ["p1"]), e(saved, ["p1"], null, ["p1"]), e(saved, ["p1", "p2"], "p2", ["p1", "p2"]), e(saved, ["p1", "p2"], null, ["p1", "p2"]), e(saved, ["p2"], "p2", ["p2"])].join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "enter adopt adopt blocked blocked restore" ]
}

@test "full-screen restore as herdr-app commands, for use when the app quits" {
  run crew_js '
console.log(JSON.stringify(crew.doArgs({ show: "sidebar" }, "p1")), JSON.stringify(crew.doArgs({ zoom: true }, "p1")), JSON.stringify(crew.doArgs({ window: true }, "p1")));'
  [ "$status" -eq 0 ]
  [ "$output" = '["do","layout.show","--id","sidebar"] ["do","pane.zoom","--pane","p1"] null' ]
}

@test "clampPanelW keeps the panel between its minimum and half the office, and falls back to 360" {
  run crew_js '
const f = (w, total) => crew.clampPanelW(w, total);
console.log([f(100, 1600), f(500, 1600), f(900, 1600), f(undefined, 1600), f("x", 1600), f(null, 1600), f(399.6, 1600), f(300, 400), f(900, 1000)].join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "260 500 800 360 360 360 400 260 500" ]
}

@test "the panel width is saved per crew, and full terminal is a window with a bar over the agent's own terminal" {
  run crew_js '
console.log(crew.panelWidthKey("sandbox"), crew.panelWidthKey(undefined));
const o = crew.fullTerminalOverlay({ address: "t7", name: "amy", rawName: "amy", cwd: "/w/amy" }, "/bin/loh", "term-1");
console.log(JSON.stringify(o));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "crew-office.panel-width.sandbox crew-office.panel-width." ]
  [[ "${lines[1]}" == *'"kind":"window"'* ]]
  [[ "${lines[1]}" == *'"width":1,"height":1'* ]]
  [[ "${lines[1]}" == *'"content":{"terminal":"t7"}'* ]]
  [[ "${lines[1]}" == *'"terminalBar":true'* ]]
  [[ "${lines[1]}" == *'"rawName":"amy"'* ]]
  [[ "${lines[1]}" == *'"termId":"term-1"'* ]]
}

@test "lock holders: the agent is locked by the first holder and unlocked only when the last one goes" {
  run crew_js '
let s = {}, out = [];
const acq = (id) => { const r = crew.holdersAcquire(s, "t7", id); s = r.state; out.push("A" + id + ":" + r.lock); };
const rel = (id) => { const r = crew.holdersRelease(s, "t7", id); s = r.state; out.push("R" + id + ":" + r.unlock); };
acq("chat"); acq("term-1"); acq("term-1"); rel("chat"); rel("chat"); rel("term-1"); rel("term-1");
console.log(out.join(" "), JSON.stringify(s), crew.termHeld({ t7: ["chat"] }), crew.termHeld({ t7: ["chat", "term-2"] }));'
  [ "$status" -eq 0 ]
  [ "$output" = 'Achat:true Aterm-1:false Aterm-1:false Rchat:false Rchat:false Rterm-1:true Rterm-1:false {} false true' ]
}

@test "the lock queue runs one agent's calls in order, even when an earlier one is slow" {
  run crew_js '
const q = crew.serialQueue(), log = [];
const slow = (ms, n) => () => new Promise((r) => setTimeout(() => { log.push(n); r(); }, ms));
q("t7", slow(30, "lock")); q("t8", slow(1, "other")); await q("t7", slow(1, "unlock"));
await q("t7", () => { throw new Error("x"); }); await q("t7", slow(1, "after-error"));
console.log(log.join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "other,lock,unlock,after-error" ]
}
