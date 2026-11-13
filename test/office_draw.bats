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

@test "the live crew's layers still use pixel coordinates, scaled when drawn" {
  run draw_js '
const g = new draw.Layer(3, 0, 0, 10, 10).rect(1, 2, 3, 4, "#111111");
console.log(JSON.stringify(g.el().node.kids[0].node.path.cmds[0]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["move_to",3,6]' ]
}
