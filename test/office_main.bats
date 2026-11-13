#!/usr/bin/env bats
# main.js under node, with gpui-kit, gpui-base and herdr replaced by recorders: what the office draws
# for a crew, what a click does, how a walk is described, and how the floor sits beside the panel.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

# Runs $1 as module code with `office` (a started CrewOffice), `find`, `all`, `render`, `terms` and `timers` in scope.
office_js() {
  command -v node >/dev/null || skip "node not installed"
  local d="$BATS_TEST_TMPDIR/main"
  mkdir -p "$d/node_modules/gpui-kit" "$d/node_modules/gpui-base" "$d/node_modules/herdr"
  cat > "$d/node_modules/gpui-kit/index.js" <<'EOF'
function el() {
  const node = { kids: [], props: {} };
  const p = new Proxy(node, { get(t, k) {
    if (k === "node") return t;
    return (...a) => {
      if (k === "child") t.kids.push(a[0]);
      else if (k === "children") t.kids.push(...a[0]);
      else if (k === "when") return a[0] ? a[1](p) : p;
      else if (k === "transition") (t.props.transitions ||= []).push(a);
      else t.props[k] = a;
      return p;
    };
  } });
  return p;
}
export const div = el;
export const View = class {};
globalThis.window = { paint_path: (path, fill) => { const e = el(); e.node.fill = fill; return e; }, toggle_fullscreen() {} };
const mk = () => { const b = new Proxy({}, { get: (t, k) => k === "build" ? () => ({}) : () => b }); return b; };
export const PathBuilder = { fill: mk, stroke: mk };
EOF
  cat > "$d/node_modules/gpui-base/index.js" <<'EOF'
import { div } from "gpui-kit";
export const v_flex = div, h_flex = div;
export const InputState = { new: () => ({ set_value() {}, value: () => "", on() {}, focus() {} }) };
export const Input = { new: () => div() };
export const ScrollHandle = { new: () => ({}) };
EOF
  cat > "$d/node_modules/herdr/index.js" <<'EOF'
const mk = (n, status) => ({ address: "t" + n, name: n, state: "live", agent: "claude", status, labels: { crew: "sandbox", role: n === "scofield" ? "coordinator" : "coder", task: n === "scofield" ? "" : "api#" + n.length, step: "reading" } });
globalThis.TERMS = [mk("scofield", "working"), mk("sheba", "working"), mk("sucre", "idle")];
globalThis.SELECTED = [];
export const terminals = () => globalThis.TERMS;
export const panes = () => [{ pane: "p1", tab: "t", mod: "crew-office", focused: true }];
export const run = () => {}; export const exec = () => new Promise(() => {}); export const notify = () => {};
export const props = () => ({ crew: "sandbox" });
export const theme = () => new Proxy({}, { get: () => "#808080" });
export const settings = () => ({ dark: !!globalThis.DARK });
export const layout = () => ({}); export const shared = () => null; export const setShared = () => {};
export const window = () => ({ fullscreen: false });
EOF
  echo '{"type":"module"}' > "$d/package.json"
  for f in crew draw panel chat main; do sed -E 's#from "\./([a-z]+)\.js"#from "./\1.mjs"#' "$(mod_dir)/$f.js" > "$d/$f.mjs"; done
  cat > "$d/run.mjs" <<EOF
const { default: Office } = await import("./main.mjs");
const timers = [];
const cx = { focus_handle: () => ({ focus() {}, is_focused: () => true }), timer: { after: (ms, fn) => { const t = { ms, fn, cancelled: false, cancel() { t.cancelled = true; } }; timers.push(t); return t; } }, notify() {} };
let office;
// A started office whose stage has been measured. Most tests start from one that has finished its first floor.
const fresh = () => { office = new Office({}, cx); office.init({}, cx); office.size = { width: 1990, height: 1000 }; office.measured = true; timers.length = 0; return office; };
const render = () => office.render(cx);
fresh();
for (let i = 0; i < 40 && !office.shown; i++) render();
timers.length = 0;
const all = (node, out = []) => { out.push(node); for (const k of node.kids) if (k && k.node) all(k.node, out); return out; };
const id = (n) => (n.props.id ? n.props.id[0] : undefined);
const find = (root, name) => all(root.node).find((n) => id(n) === name);
const terms = () => globalThis.TERMS;
$1
EOF
  (cd "$d" && node run.mjs)
}

@test "clicking a running agent's figure selects it in the panel, as its tag does" {
  run office_js '
const calls = [];
office.panel.select = (a) => calls.push(a.name);
const root = render();
find(root, "hit-sheba").props.on_click[0]({}, cx);
find(root, "tag-tsheba").props.on_click[0]({}, cx);
console.log(calls.join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "sheba,sheba" ]
}

@test "clicking a running agent's figure moves an open chat to that agent, as its tag does" {
  run office_js '
const opened = [];
office.chat = { pane: "p1", office: "p1", address: "tscofield", name: "scofield", agent: {} };
office.open = (a) => opened.push(a.name);
office.panel.select = () => {};
const root = render();
find(root, "hit-sheba").props.on_click[0]({}, cx);
find(root, "tag-tsheba").props.on_click[0]({}, cx);
console.log(opened.join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "sheba,sheba" ]
}

@test "clicking the figure of someone not running opens the start offer, as their tag does" {
  run office_js '
const root = render();
const before = office.offer;
find(root, "hit-whip").props.on_click[0]({}, cx);
const fromFigure = office.offer && office.offer.person.id;
office.offer = null;
find(root, "tag-whip").props.on_click[0]({}, cx);
console.log(before, fromFigure, office.offer && office.offer.person.id, office.offer.plan.kind);'
  [ "$status" -eq 0 ]
  [ "$output" = "null whip whip spawn" ]
}

@test "Matt and Waffles have no figure to click, and no tag action" {
  run office_js '
const root = render();
console.log(find(root, "hit-matt") === undefined, find(root, "hit-dog") === undefined, find(root, "tag-matt").props.on_click === undefined);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true" ]
}

@test "the figure's click target is small and centred on the person, not across the whole drawing box" {
  run office_js '
const root = render();
const hit = find(root, "hit-sheba").props, box = find(root, "person-sheba").props;
console.log(hit.w[0] < box.w[0] / 3, hit.h[0] < box.h[0] / 3, hit.left[0] < 0, hit.top[0] < 0, hit.left[0] + hit.w[0] > 0, hit.top[0] + hit.h[0] > 0);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true true true" ]
}

@test "the name tag sits inside a chain of movers that matches its person's, link for link" {
  run office_js '
const root = render();
const chain = (prefix) => { const out = []; let n = find(root, prefix); while (n) { out.push(n.props.id[0]); n = n.kids.map((k) => k.node).find((k) => k.props.id && k.props.id[0].startsWith(prefix + "-")); } return out.length; };
const insideTag = find(root, "tm-sheba") && all(find(root, "tm-sheba")).some((n) => id(n) === "tag-tsheba");
const insideFigure = all(find(root, "m-sheba")).some((n) => id(n) === "person-sheba");
console.log(chain("m-sheba"), chain("tm-sheba"), insideTag, insideFigure);'
  [ "$status" -eq 0 ]
  [ "$output" = "7 7 true true" ]
}

@test "a walk is handed over in one render: every link has its own start time, and the next render repeats it exactly" {
  run office_js '
const sig = (root, who) => JSON.stringify(all(find(root, who)).filter((n) => n.props.transitions).map((n) => [id(n), n.props.transitions.map((t) => [t[0], t[1].duration, t[1].delay, t[1].easing]), n.props.left[0], n.props.top[0]]));
render();
terms()[1].status = "done";
const a = render();
const b = render();
const mine = sig(a, "m-sheba");
const links = JSON.parse(mine);
const real = links.filter((l) => l[1][0][1] > 1);
const delays = real.map((l) => l[1][0][2]);
console.log(real.length > 1, delays[0] === 0, delays.slice(1).every((d, i) => d > delays[i]), mine === sig(b, "m-sheba"));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true" ]
}

@test "the tag's chain carries the same transitions as the figure's during a walk" {
  run office_js '
const sig = (root, who) => JSON.stringify(all(find(root, who)).filter((n) => n.props.transitions && /^t?m-/.test(id(n))).map((n) => [id(n).replace(/^tm-/, "m-"), n.props.transitions, n.props.left[0], n.props.top[0]]));
render();
terms()[1].status = "done";
const a = render();
console.log(sig(a, "m-sheba") === sig(a, "tm-sheba"), sig(a, "m-sheba").length > 10);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true" ]
}

@test "someone who is not walking has a one millisecond transition on every mover, so a change is a jump and the next walk still animates" {
  run office_js '
const root = render();
const t = all(find(root, "m-sheba")).filter((x) => x.props.transitions && /^m-/.test(id(x)));
console.log(t.length, t.every((x) => x.props.transitions.every((a) => a[1].duration === 1 && !a[1].delay)));'
  [ "$status" -eq 0 ]
  [ "$output" = "7 true" ]
}

@test "a walk's timers only turn the walker or end the gait, and a walk ends after its last leg" {
  run office_js '
render();
terms()[1].status = "done";
render();
const walk = office.walks.get("sheba");
const total = walk.legs.reduce((s, l) => s + l.ms, 0);
const ms = timers.filter((t) => !t.cancelled && t.ms > 1).map((t) => t.ms);
console.log(walk.legs.length > 1, Math.max(...ms) > total, Math.max(...ms) <= total + 100, ms.length === walk.legs.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true" ]
}

@test "when the walk is over, the person is drawn at the goal on one millisecond transitions" {
  run office_js '
render();
terms()[1].status = "done";
render();
const goal = { x: office.walks.get("sheba").goal.x, y: office.walks.get("sheba").goal.y };
timers.filter((t) => !t.cancelled).sort((a, b) => a.ms - b.ms).forEach((t) => t.fn({ notify() {} }));
const root = render();
const w = office.walks.get("sheba");
const m = find(root, "m-sheba");
const t = all(m).filter((x) => x.props.transitions && /^m-/.test(id(x)));
console.log(w.legs.length, w.at.x === goal.x && w.at.y === goal.y, t.length, t.every((x) => x.props.transitions.every((a) => a[1].duration === 1)));'
  [ "$status" -eq 0 ]
  [ "$output" = "0 true 7 true" ]
}

@test "with the panel open and the stage not yet re-measured, the floor is fitted to the room beside it" {
  run office_js '
office.panel.select(terms().length && { address: "tsheba", name: "sheba", status: "working" }, cx);
const root = render();
const floor = find(root, "stage").kids[0].node;
const stageW = office.size.width - 360;
console.log(office.panel.open, floor.props.w[0] <= stageW - 16 + 0.5, floor.props.w[0] > stageW / 2);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true" ]
}

@test "with the panel closed, the floor fills the stage again" {
  run office_js '
const root = render();
const floor = find(root, "stage").kids[0].node;
console.log(floor.props.w[0] <= office.size.width - 16 + 0.5, floor.props.w[0] > (office.size.width - 360) * 0.9);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true" ]
}

@test "the stage cuts off anything that spills over it, so it is never drawn under the panel" {
  run office_js '
const root = render();
console.log(find(root, "stage").props.overflow_hidden !== undefined);'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "a new scale at the same shape builds no new floor paths, and a new plan builds them again" {
  run office_js '
for (let i = 0; i < 12; i++) render();
const layer = office.floor.layer;
const n = layer.paths.length, done = layer.done;
office.size = { width: 1003, height: 508 };
for (let i = 0; i < 3; i++) render();
const same = office.floor.layer === layer && layer.paths.length === n;
office.repos = ["api", "web", "docs"];
render();
console.log(done, same, office.floor.layer !== layer);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true" ]
}

@test "going back to an earlier plan (the panel closing again) reuses its finished floor" {
  run office_js '
for (let i = 0; i < 12; i++) render();
const first = office.floor.layer;
office.repos = ["api", "web", "docs"];
for (let i = 0; i < 3; i++) render();
office.repos = [];
render();
console.log(first.done, office.floor.layer === first, office.floor.layer.done);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true" ]
}

@test "the first render of a new plan draws no floor, so a start after a reload stays short; the second makes the drawing list" {
  run office_js '
fresh();
render();
const a = office.floor.layer;
render();
const b = office.floor.layer;
console.log(a === null, b !== null && !b.done);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true" ]
}

@test "a floor still being built asks for another render, and stops asking once it is done" {
  run office_js '
fresh();
render();
const first = timers.filter((t) => !t.cancelled).length;
let renders = 1;
while (renders < 60) { const t = timers.pop(); if (!t) break; t.fn({ notify() {} }); render(); renders++; }
console.log(first >= 1, office.floor.layer.done, renders < 60, timers.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true 0" ]
}

# dark mode, and the order of what is drawn on the floor
DARK='globalThis.DARK = true;'

@test "in dark mode the night shading is still there on the first render after a screen changes state" {
  run office_js "$DARK"'
for (let i = 0; i < 14; i++) render();
const dim = (root) => all(find(root, "stage")).filter((n) => n.fill === "#060a24a8").length;
const before = dim(render());
terms()[1].status = "blocked";
const after = dim(render());
terms()[1].status = "idle";
const after2 = dim(render());
console.log(before, after, after2);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1" ]
}

@test "a figure's click target is drawn above the night layers and below the tags and room labels" {
  run office_js "$DARK"'
for (let i = 0; i < 14; i++) render();
const root = render();
const floor = find(root, "stage").kids[0].node;
const idx = (pred) => floor.kids.findIndex((k) => pred(k.node));
const has = (k, pred) => all(k).some(pred);
const night = idx((k) => has(k, (n) => n.fill === "#060a24a8"));
const hit = idx((k) => has(k, (n) => id(n) === "hit-sheba"));
const tag = idx((k) => has(k, (n) => id(n) === "tag-tsheba"));
const label = idx((k) => has(k, (n) => n.kids.some((c) => c === "API" || c === "api")));
console.log(night >= 0, hit > night, tag > hit, label > hit, label < tag);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true true" ]
}

@test "a walker's tag has a transition on its own body, so settling into its stacked place slides" {
  run office_js '
const tr = (root) => (find(root, "tag-tsheba").props.transitions || []).map((a) => a[1].duration);
const rest = tr(render());
terms()[1].status = "done";
const walking = tr(render());
console.log(rest.length, walking.length, walking.includes(220));'
  [ "$status" -eq 0 ]
  [ "$output" = "2 2 true" ]
}

@test "while a new plan builds, the last finished floor stays on screen" {
  run office_js '
const shapes = (root) => all(find(root, "stage")).filter((n) => n.fill && n.fill.length === 7).length;
for (let i = 0; i < 14; i++) render();
const full = shapes(render());
office.size = { width: 1630, height: 1000 };
const during = [];
for (let i = 0; i < 4; i++) during.push(shapes(render()));
console.log(full > 100, during.every((n) => n > 100));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true" ]
}

@test "dragging the window through many shapes does not push the panel-open and panel-closed plans out of the cache" {
  run office_js '
const rounds = (n) => { for (let i = 0; i < n; i++) render(); };
rounds(14);
const closed = office.floor.layer;
office.size = { width: 1630, height: 1000 };
rounds(14);
const open = office.floor.layer;
for (const w of [1250, 1300, 1350, 1400, 1450, 1500, 1550]) { office.size = { width: w, height: 1000 }; rounds(1); }
office.size = { width: 1990, height: 1000 };
render();
const a = office.floor.layer === closed && closed.done;
office.size = { width: 1630, height: 1000 };
render();
console.log(a, office.floor.layer === open && open.done);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true" ]
}

# a cold start: nothing sized from the floor is drawn until the stage's real size is known and the first floor is complete

@test "before herdr has measured the stage, only the bar and a waiting line are drawn" {
  run office_js '
fresh();
office.measured = false;
const root = render();
const stage = find(root, "stage");
const drawn = all(stage).filter((n) => n.fill || /^(person|tag|m|hm|tm)-/.test(id(n) || ""));
console.log(drawn.length, all(stage).some((n) => n.kids.includes("Setting up the office…")), find(root, "totals") !== undefined, office.floor === null || office.floor.layer === null);'
  [ "$status" -eq 0 ]
  [ "$output" = "0 true true true" ]
}

@test "the stage reports its size even while it shows only the waiting line, and that ends the wait" {
  run office_js '
fresh();
office.measured = false;
const stage = find(render(), "stage");
stage.props.on_size_change[0]({ width: 1500, height: 900 }, cx);
console.log(office.measured, office.size.width, office.size.height);'
  [ "$status" -eq 0 ]
  [ "$output" = "true 1500 900" ]
}

@test "once measured, nothing but the waiting line is drawn until the first floor is complete, then floor, people and tags arrive together" {
  run office_js '
fresh();
const stage = (root) => all(find(root, "stage"));
const state = (root) => ({ shapes: stage(root).filter((n) => n.fill && n.fill.length === 7).length, people: stage(root).filter((n) => /^person-/.test(id(n) || "")).length, tags: stage(root).filter((n) => /^tag-/.test(id(n) || "")).length, wait: stage(root).some((n) => n.kids.includes("Setting up the office…")) });
const seen = [];
for (let i = 0; i < 30; i++) seen.push(state(render()));
const firstFull = seen.findIndex((x) => x.shapes > 100);
const before = seen.slice(0, firstFull);
console.log(firstFull > 1, before.every((x) => x.shapes === 0 && x.people === 0 && x.tags === 0 && x.wait), seen[firstFull].people > 5, seen[firstFull].tags > 5, !seen[firstFull].wait);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true true" ]
}

@test "a new plan after the first does not bring the waiting line back" {
  run office_js '
for (let i = 0; i < 20; i++) render();
office.size = { width: 1630, height: 1000 };
const wait = [];
for (let i = 0; i < 4; i++) wait.push(all(find(render(), "stage")).some((n) => n.kids.includes("Setting up the office…")));
console.log(wait.join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "false,false,false,false" ]
}
