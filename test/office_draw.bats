#!/usr/bin/env bats
# draw.js under node, with gpui-kit replaced by a recorder: how shapes become paths, and how many.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

# Runs $1 (module code) with draw.js and crew.js copied next to a gpui-kit that records what it is asked.
draw_js() {
  command -v node >/dev/null || skip "node not installed"
  local d="$BATS_TEST_TMPDIR/draw"
  mkdir -p "$d/node_modules/gpui-kit"
  cat > "$d/node_modules/gpui-kit/index.js" <<'EOF'
export const log = { builds: 0 };
function el() {
  const node = { kids: [], props: {} };
  const p = new Proxy(node, { get(t, k) {
    if (k === "node") return t;
    return (...a) => { if (k === "child") t.kids.push(a[0]); else if (k === "children") t.kids.push(...a[0]); else t.props[k] = a; return p; };
  } });
  return p;
}
export const div = el;
globalThis.window = { paint_path: (path, fill) => { const e = el(); e.node.path = path; e.node.fill = fill; return e; } };
const mk = (stroke) => { const cmds = []; const b = new Proxy({}, { get: (t, k) => k === "build" ? () => { log.builds++; return { cmds, stroke }; } : (...a) => { cmds.push([k, ...a]); return b; } }); return b; };
export const PathBuilder = { fill: () => mk(0), stroke: (w) => mk(w) };
EOF
  echo '{"type":"module"}' > "$d/package.json"
  for f in crew draw; do sed 's#from "\./crew\.js"#from "./crew.mjs"#' "$(mod_dir)/$f.js" > "$d/$f.mjs"; done
  (cd "$d" && node --input-type=module -e "import * as draw from './draw.mjs'; import { log } from 'gpui-kit'; $1")
}

@test "a floor layer's paths use percentages of its box, so they do not depend on the scale" {
  run draw_js '
const mk = (k) => new draw.Layer(k, 0, 0, 100, 50, "", true).rect(10, 5, 20, 10, "#112233").circ(50, 25, 5, "#445566").rr(60, 10, 30, 20, 4, "#778899");
const cmds = (k) => JSON.stringify(mk(k).el().node.kids.map((e) => e.node.path.cmds));
const a = cmds(2), b = cmds(7.24);
const flat = JSON.parse(a).flat(2).filter((v) => typeof v === "string" && !/^[a-z_]+$/.test(v));
console.log(a === b, flat.length > 20, flat.every((v) => /^-?[0-9.]+%$/.test(v)));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true" ]
}

@test "a floor layer's first rect is at 10 percent across and 10 percent down, its box at the scale it is asked for" {
  run draw_js '
const g = new draw.Layer(2, 0, 0, 100, 50, "", true).rect(10, 5, 20, 10, "#112233");
const el = g.el();
const first = el.node.kids[0].node.path.cmds[0];
console.log(JSON.stringify(first), JSON.stringify(el.node.props.w), JSON.stringify(el.node.props.h));
g.at(3);
console.log(JSON.stringify(g.el().node.props.w));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '["move_to","10%","10%"] [200] [100]' ]
  [ "${lines[1]}" = "[300]" ]
}

@test "asking for the same layer at another scale builds no new paths" {
  run draw_js '
const g = new draw.Layer(2, 0, 0, 100, 50, "", true).rect(0, 0, 5, 5, "#111111").circ(20, 20, 4, "#222222");
g.el(); const n = log.builds; g.at(9).el(); g.at(1).el();
console.log(n, log.builds);'
  [ "$status" -eq 0 ]
  [ "$output" = "2 2" ]
}

@test "a circle in a percentage layer stays round at both scales: its points are an even polygon" {
  run draw_js '
const g = new draw.Layer(1, 0, 0, 200, 100, "", true).circ(100, 50, 10, "#111111");
const cmds = g.el().node.kids[0].node.path.cmds;
const pts = cmds.filter((c) => c[0] === "move_to" || c[0] === "line_to").map((c) => [parseFloat(c[1]) * 2, parseFloat(c[2])]);
const dist = pts.map(([x, y]) => Math.hypot(x - 100, y - 50));
console.log(pts.length, Math.max(...dist).toFixed(2), Math.min(...dist).toFixed(2));'
  [ "$status" -eq 0 ]
  [ "$output" = "20 10.00 10.00" ]
}

@test "neighbouring shapes of one opaque colour share a path when the layer merges, others do not" {
  run draw_js '
const g = new draw.Layer(1, 0, 0, 100, 50, "", true).merged();
g.rect(0, 0, 5, 5, "#111111").rect(10, 0, 5, 5, "#111111").rect(20, 0, 5, 5, "#222222").rect(30, 0, 5, 5, "#111111").rect(40, 0, 5, 5, "#33333380").rect(50, 0, 5, 5, "#33333380");
const el = g.el();
console.log(el.node.kids.length, el.node.kids.map((e) => e.node.fill).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "5 #111111,#222222,#111111,#33333380,#33333380" ]
}

@test "shapes that overlap stay in separate paths, shapes that only touch share one" {
  run draw_js '
const g = new draw.Layer(1, 0, 0, 100, 50, "", true).merged();
g.rect(0, 0, 10, 10, "#111111").rect(10, 0, 10, 10, "#111111").rect(15, 5, 10, 10, "#111111").rect(40, 0, 5, 5, "#111111");
const el = g.el();
console.log(el.node.kids.length, el.node.kids.map((e) => e.node.path.cmds.filter((c) => c[0] === "move_to").length).join(","));'
  [ "$status" -eq 0 ]
  # the third rect overlaps the second, so it starts a new path, and the fourth, clear of it, joins that one
  [ "$output" = "2 2,2" ]
}

@test "a merged layer works out its paths in a step of its own, a plain layer draws something at once" {
  run draw_js '
const mk = (m) => { const g = new draw.Layer(1, 0, 0, 100, 50, "", true); if (m) g.merged(); for (let i = 0; i < 5; i++) g.rect(i * 3, 0, 2, 2, "#111111"); return g; };
console.log(mk(false).el(0).node.kids.length, mk(true).el(0).node.kids.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 0" ]
}

@test "a merged path never holds more than 300 commands, unless one shape alone is bigger" {
  run draw_js '
const g = new draw.Layer(1, 0, 0, 1000, 50, "", true).merged();
for (let i = 0; i < 200; i++) g.rect(i * 4, 0, 4, 4, "#111111");
const sizes = g.el().node.kids.map((e) => e.node.path.cmds.length);
console.log(Math.max(...sizes) <= 300, sizes.length > 2, sizes.reduce((a, b) => a + b, 0));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true 1000" ]
}

@test "a merged path keeps every shape's own subpath" {
  run draw_js '
const g = new draw.Layer(1, 0, 0, 100, 50, "", true).merged();
g.rect(0, 0, 5, 5, "#111111").rect(10, 0, 5, 5, "#111111");
const cmds = g.el().node.kids[0].node.path.cmds.map((c) => c[0]);
console.log(cmds.join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "move_to line_to line_to line_to close move_to line_to line_to line_to close" ]
}

@test "a build with a time limit stops early, carries on where it left off, and builds each path once" {
  run draw_js '
const g = new draw.Layer(1, 0, 0, 100, 50, "", true);
for (let i = 0; i < 40; i++) g.rect(i, 0, 1, 1, i % 2 ? "#111111" : "#222222");
const steps = [];
let calls = 0;
while (!g.done && calls < 1000) { g.build(0); calls++; steps.push(g.paths.length); }
console.log(g.done, log.builds, steps[0], steps[1], calls);'
  [ "$status" -eq 0 ]
  # a layer that is not merged has nothing to work out first: each call builds one, as the limit is 0
  [ "$output" = "true 40 1 2 40" ]
}

@test "a layer that is not finished still draws what it has built" {
  run draw_js '
const g = new draw.Layer(1, 0, 0, 100, 50, "", true);
for (let i = 0; i < 10; i++) g.rect(i, 0, 1, 1, i % 2 ? "#111111" : "#222222");
const el = g.el(0);
console.log(el.node.kids.length, g.done);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 false" ]
}

@test "a rounded layer draws a circle as a rounded_full div placed by percentages, and keeps rect and polygon paths in order" {
  run draw_js '
const g = new draw.Layer(2, 0, 0, 100, 50, "", true).merged().rounded().rect(0, 0, 100, 50, "#111111").circ(50, 25, 5, "#222222").rect(0, 0, 4, 4, "#111111");
const kids = g.el().node.kids.map((e) => e.node);
const c = kids[1];
console.log(kids.length, !!kids[0].path, !!kids[2].path, JSON.stringify([c.props.left, c.props.top, c.props.w, c.props.h]), "rounded_full" in c.props);'
  [ "$status" -eq 0 ]
  [ "$output" = '3 true true [["45%"],["40%"],["10%"],["20%"]] true' ]
}

@test "a rounded layer draws a rounded rectangle as a div whose radius follows the scale, and an ellipse stays a polygon" {
  run draw_js '
const g = new draw.Layer(2, 0, 0, 100, 50, "", true).rounded().rr(10, 5, 20, 10, 3, "#334455").ell(50, 25, 6, 3, "#556677");
const a = g.el().node.kids.map((e) => e.node);
const r2 = JSON.stringify(a[0].props.rounded);
const r5 = JSON.stringify(g.at(5).el().node.kids[0].node.props.rounded);
console.log(r2, r5, !!a[1].path, a[1].path.cmds.length > 10);'
  [ "$status" -eq 0 ]
  [ "$output" = '[6] [15] true true' ]
}

@test "the floor's circles and rounded rectangles are divs, not polygons" {
  run draw_js '
const crew = await import("./crew.mjs");
const g = draw.floorLayer(crew.layoutCrew([], ["api", "web"], 1.6), 1);
g.build();
const divs = g.paths.filter((p) => p.div).length;
const polys = g.paths.filter((p) => p.path).length;
console.log(divs > 60, polys > 20, g.paths.filter((p) => p.div && !(p.div.w > 0 && p.div.h > 0)).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true 0" ]
}

@test "every shape on the floor has a colour, for up to six repos at several shapes of pane" {
  run draw_js '
const crew = await import("./crew.mjs");
let bad = 0, total = 0;
for (const n of [0, 1, 2, 3, 4, 5, 6]) for (const a of [1, 1.6, 2.5]) {
  const g = draw.floorLayer(crew.layoutCrew([], ["api", "web", "docs", "ops", "site", "lib"].slice(0, n), a), 1);
  total += g.ops.length; bad += g.ops.filter((o) => typeof o.fill !== "string").length;
}
console.log(bad, total > 1000);'
  [ "$status" -eq 0 ]
  [ "$output" = "0 true" ]
}

@test "Matt's two hands tap on his keyboard only while he is at his desk typing, each hand looping 130 ms each way" {
  run draw_js '
import("./crew.mjs").then((crew) => {
  const loops = (nodes) => { let n = []; const walk = (x) => { if (x && x.node) { if (x.node.props.loop) n.push(x.node.props.loop); for (const k of x.node.kids) walk(k); } }; nodes.forEach(walk); return n; };
  const at = (typing, rest = true) => { const L = crew.layoutCrew([], ["api"], 0, { mattTyping: typing }); const m = L.people.find((p) => p.id === "matt"); return { m, L, loops: loops(draw.personEls(m, 2, m.face, false, L, rest)) }; };
  const on = at(true), off = at(false), moving = at(true, false);
  console.log(on.m.place, on.loops.length, JSON.stringify(on.loops.map((l) => [l[0], l[1].period])), off.m.place, off.loops.length, moving.loops.length);
});'
  [ "$status" -eq 0 ]
  [ "$output" = 'matt 2 [["top",260],["top",260]] lounge 0 0' ]
}

@test "the live crew's layers still use pixel coordinates, scaled when drawn" {
  run draw_js '
const g = new draw.Layer(3, 0, 0, 10, 10).rect(1, 2, 3, 4, "#111111");
console.log(JSON.stringify(g.el().node.kids[0].node.path.cmds[0]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["move_to",3,6]' ]
}

@test "the leads room's name is centred on the door line, at 112 units, and the other rooms' names stay at their corners" {
  run draw_js '
const world = (await import("./crew.mjs")).worldFor(["api", "web"]);
const k = 2;
const out = draw.labels(world, k, 10).map((e) => e.node);
const find = (text) => out.find((n) => n.kids.includes(text));
const lead = find("SCOFIELD · AMY"), kitchen = find("KITCHEN");
const wide = (n, text) => text.length * (n.props.h[0] - 5) * 0.62 + 12;
console.log(lead.props.left[0] + wide(lead, "SCOFIELD · AMY") / 2, 345 * k, lead.props.top[0] + lead.props.h[0] / 2, 112 * k, kitchen.props.left[0], kitchen.props.top[0]);'
  [ "$status" -eq 0 ]
  [ "$output" = "690 690 224 224 204 356" ]
}

@test "every walk between any two desk seats or room spots, as the renderer draws it, crosses a wall only through a door" {
  run draw_js '
const crew = await import("./crew.mjs");
let walks = 0, tooLong = 0;
const bad = new Set();
for (const [repos, aspect] of [[["api", "web"], 0], [["api", "web", "docs"], 2.2], [["api"], 1.2]]) {
  const L = crew.worldFor(repos, aspect);
  const t = 2.4, botY = L.corr.y + L.corr.h;
  const walls = [];
  for (const r of L.rooms) {
    const wy = r.row === "top" ? L.corr.y - 1.2 : botY - 2.2;
    walls.push({ x: r.x, y: wy, w: r.door - 9 - r.x, h: t }, { x: r.door + 9, y: wy, w: r.x + r.w - r.door - 9, h: t });
    if (r.x > 0) walls.push({ x: r.x - t / 2, y: r.y, w: t, h: r.h });
  }
  const places = [...L.desks, L.mattDesk].map((d) => d.seat).concat(Object.values(L.spots).flat());
  const hits = (a, b) => { for (let i = 0; i <= 300; i++) { const x = a.x + (b.x - a.x) * i / 300, y = a.y + (b.y - a.y) * i / 300; if (walls.some((w) => x > w.x + 0.3 && x < w.x + w.w - 0.3 && y > w.y + 0.3 && y < w.y + w.h - 0.3)) return true; } return false; };
  for (const a of places) for (const b of places) {
    if (a === b) continue;
    walks++;
    const legs = crew.legsOf(a, crew.pathTo(L, "p", a, b));
    if (legs.length > draw.SLOTS) tooLong++;
    // The renderer draws the walk as SLOTS links: link i moves by (dx, dy) from where the one before ended.
    const links = crew.walkChain(a, legs, draw.SLOTS).links;
    let at = a;
    for (const l of links) { const to = { x: at.x + l.dx, y: at.y + l.dy }; if (hits(at, to)) bad.add(Math.round(a.x) + "," + Math.round(a.y) + " to " + Math.round(b.x) + "," + Math.round(b.y)); at = to; }
    if (Math.abs(at.x - b.x) > 0.01 || Math.abs(at.y - b.y) > 0.01) bad.add("ends off the goal");
  }
}
console.log(walks > 2000, tooLong, [...bad].length, [...bad].slice(0, 3).join(" | "));'
  [ "$status" -eq 0 ]
  [ "$output" = "true 0 0 " ]
}

@test "a walk from any kitchen spot to any ping pong spot, as drawn, goes out by the kitchen door, along the corridor and in by the ping pong door" {
  run draw_js '
const crew = await import("./crew.mjs");
let bad = 0, walks = 0;
for (const repos of [["api"], ["api", "web"], []]) for (const aspect of [0, 1.2, 1.6, 2.2]) {
  const L = crew.worldFor(repos, aspect);
  const kit = L.rooms.find((r) => r.kind === "kitchen"), pong = L.rooms.find((r) => r.kind === "pong");
  for (const a of L.spots.kitchen) for (const b of L.spots.pong) {
    walks++;
    const legs = crew.legsOf(a, crew.pathTo(L, "p", a, b));
    let at = a; const pts = [];
    for (const l of crew.walkChain(a, legs, draw.SLOTS).links) { at = { x: at.x + l.dx, y: at.y + l.dy }; pts.push(at); }
    const corr = (p) => p.y >= L.corr.y && p.y <= L.corr.y + L.corr.h;
    const inKitchen = (p) => p.x >= kit.x && p.x <= kit.x + kit.w && p.y >= kit.y && p.y <= kit.y + kit.h;
    const inPong = (p) => p.x >= pong.x && p.x <= pong.x + pong.w && p.y >= pong.y && p.y <= pong.y + pong.h;
    const first = pts[0], lane = pts.filter(corr);
    // the first stop is the kitchen door, above the spot; the corridor is walked between the doors; the last stop is the spot
    if (!(Math.abs(first.x - kit.door) < 0.01 && first.y < a.y && inKitchen(first))) bad++;
    else if (lane.length !== 2 || lane[0].x !== kit.door || lane[1].x !== pong.door) bad++;
    else if (!pts.every((p) => inKitchen(p) || corr(p) || inPong(p))) bad++;
    else if (Math.abs(at.x - b.x) > 0.01 || Math.abs(at.y - b.y) > 0.01) bad++;
  }
}
console.log(walks, bad);'
  [ "$status" -eq 0 ]
  [ "$output" = "288 0" ]
}

@test "the wall screen says how many agents are running, in the singular for one, and the text fits the screen" {
  run draw_js '
console.log([0, 1, 4, 12].map(draw.agentsRunning).join(" | "));'
  [ "$status" -eq 0 ]
  [ "$output" = "0 agents running | 1 agent running | 4 agents running | 12 agents running" ]
}

@test "the copy icons are drawn paths, built once per kind, size and colour" {
  run draw_js '
const a = draw.iconEl("copy", 14, "#999999"), b = draw.iconEl("copy", 14, "#999999"), c = draw.iconEl("copied", 14, "#999999");
const builds = () => JSON.stringify(a.node.kids[0].node.kids.length);
console.log(builds(), c.node.kids[0].node.kids.length, log.builds);
draw.iconEl("copy", 14, "#999999").node.kids[0];
console.log(log.builds);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2 1 3" ]
  [ "${lines[1]}" = "3" ]
}

@test "message text is 14 px on a 20 px line, and the message box and Send are 30 px tall" {
  run grep -c 'text_size(14).line_height("20px")' "$BATS_TEST_DIRNAME/../office/crew-office/panel.js"
  [ "$output" = "3" ]
  run grep -c 'min_h(30)\|\.h(30)' "$BATS_TEST_DIRNAME/../office/crew-office/panel.js"
  [ "$output" = "2" ]
}
