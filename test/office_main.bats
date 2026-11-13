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
globalThis.window = { paint_path: () => el(), toggle_fullscreen() {} };
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
const office = new Office({}, cx);
office.init({}, cx);
office.size = { width: 1990, height: 1000 };
const render = () => office.render(cx);
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

@test "the figure's click target is small and sits on the body, not across its whole drawing box" {
  run office_js '
const root = render();
const hit = find(root, "hit-sheba").props, box = find(root, "person-sheba").props;
console.log(hit.w[0] < box.w[0] / 3, hit.h[0] < box.h[0] / 3, hit.left[0] > 0, hit.top[0] > 0);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true" ]
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

@test "someone who is not walking has no transitions on their movers, so a change is a plain jump" {
  run office_js '
const root = render();
const n = all(find(root, "m-sheba")).filter((x) => x.props.transitions).length;
console.log(n);'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
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

@test "when the walk is over, the person is drawn at the goal with no transitions" {
  run office_js '
render();
terms()[1].status = "done";
render();
const goal = { x: office.walks.get("sheba").goal.x, y: office.walks.get("sheba").goal.y };
timers.filter((t) => !t.cancelled).sort((a, b) => a.ms - b.ms).forEach((t) => t.fn({ notify() {} }));
const root = render();
const w = office.walks.get("sheba");
const m = find(root, "m-sheba");
console.log(w.legs.length, w.at.x === goal.x && w.at.y === goal.y, all(m).filter((x) => x.props.transitions).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "0 true 0" ]
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

@test "a floor still being built asks for another render, and stops asking once it is done" {
  run office_js '
render();
const first = timers.filter((t) => !t.cancelled).length;
let renders = 1;
while (renders < 60) { const t = timers.pop(); if (!t) break; t.fn({ notify() {} }); render(); renders++; }
console.log(first >= 1, office.floor.layer.done, renders < 60, timers.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true 0" ]
}
