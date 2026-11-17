#!/usr/bin/env bats
# main.js under node, with gpui-kit, gpui-base and herdr replaced by recorders: what the office draws
# for a crew, what a click does, how a walk is described, and how the floor sits beside the panel.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

# Runs $1 as module code with `office` (a started CrewOffice), `find`, `all`, `render`, `terms` and `timers` in scope.
office_js() {
  command -v node >/dev/null || skip "node not installed"
  local d="$BATS_TEST_TMPDIR/crew-office"
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
export const image = (p) => { (globalThis.IMAGES ||= []).push(p); return div(); };
export const svg = () => div();
export const View = class { constructor(p) { this.props = p; } };
globalThis.window = { paint_path: (path, fill) => { const e = el(); e.node.fill = fill; return e; }, toggle_fullscreen() {} };
const mk = () => { const b = new Proxy({}, { get: (t, k) => k === "build" ? () => ({}) : () => b }); return b; };
export const PathBuilder = { fill: mk, stroke: mk };
EOF
  cat > "$d/node_modules/gpui-base/index.js" <<'EOF'
import { div } from "gpui-kit";
export const v_flex = div, h_flex = div, h_resizable = (id) => div().id(id), resizable_panel = div;
export const TextareaState = { new: () => ({ set_value() {}, value: () => "", on() {}, focus() {}, set_soft_wrap() {}, set_auto_grow() {} }) };
export const Textarea = { new: () => div() };
export const TextView = { markdown: () => div() };
export const ScrollHandle = { new: () => ({}) };
EOF
  cat > "$d/node_modules/herdr/index.js" <<'EOF'
const mk = (n, status) => ({ address: "t" + n, name: n, state: "live", agent: "claude", status, labels: { crew: "sandbox", role: n === "scofield" ? "coordinator" : "coder", task: n === "scofield" ? "" : "api#" + n.length, step: "reading" } });
globalThis.TERMS = [mk("scofield", "working"), mk("sheba", "working"), mk("sucre", "idle")];
globalThis.SELECTED = [];
export const home = () => "/nohome";
export const terminals = () => globalThis.TERMS;
export const panes = () => (globalThis.PANES ||= [{ pane: "p1", tab: "t", mod: "crew-office", focused: true }]);
export const run = (c, a) => { (globalThis.RUNS ||= []).push([c, a]); if (c === "pane.split") globalThis.PANES.push({ pane: "s" + globalThis.PANES.length + a.pane, tab: (globalThis.PANES.find((p) => p.pane === a.pane) || {}).tab }); };
export const appHome = () => globalThis.APP_HOME || "/h/herdr-app";
export const exec = (c, a, o) => globalThis.EXEC_HOOK ? globalThis.EXEC_HOOK(c, a, o) : (a[0] === "-c" ? Promise.resolve({ code: 1, stdout: "", stderr: "" }) : a[0] === "lock" || a[0] === "unlock" ? ((globalThis.EXECS ||= []).push(a[0]), Promise.resolve({ code: 0 })) : new Promise(() => {}));
export const notify = (n) => { (globalThis.NOTES ||= []).push(n); };
export const props = () => globalThis.PROPS || { crew: "sandbox" };
export const theme = () => new Proxy({}, { get: () => "#808080" });
export const settings = () => ({ dark: !!globalThis.DARK });
const SH = globalThis.SHARED = {};
export const layout = () => ({}); export const shared = (k) => (k in SH ? SH[k] : null); export const setShared = (k, v) => { SH[k] = v; };
export const openOverlay = (s) => { (globalThis.OVERLAYS ||= []).push(s); return "o1"; }; export const closeOverlay = () => null;
export const window = () => ({ fullscreen: false });
export const focused = () => globalThis.FOCUS || null;
EOF
  echo '{"type":"module"}' > "$d/package.json"
  for f in crew draw panel chat photos reactions main; do sed -E 's#from "\./([a-z]+)\.js"#from "./\1.mjs"#' "$(mod_dir)/$f.js" > "$d/$f.mjs"; done
  cat > "$d/run.mjs" <<EOF
const { default: Office } = await import("./main.mjs");
const timers = [];
// A retained nested view: its node is what its render gives, so a walk of the office's tree goes into it as into any element.
const cx = { spawn: (fn) => { fn(cx); }, focus_handle: () => ({ focus() {}, is_focused: () => true }), new: (C, p) => { const inst = new C(p); if (inst.init) inst.init(p, cx); return { inst, get node() { return inst.render(cx).node; }, set_props() {}, release: () => true }; }, timer: { after: (ms, fn) => { const t = { ms, fn, at: typeof clock === 'number' ? clock : 0, cancelled: false, cancel() { t.cancelled = true; } }; timers.push(t); return t; } }, notify() {} };
let office;
// A started office whose stage has been measured. Most tests start from one that has finished its first floor.
// herdr hands a cx to one host call, and using it after the call returns throws. A strict cx does the same for the
// calls a test makes: its functions, and those of its timer, throw once alive is false, so a view that keeps a cx and
// uses it later fails here. Each render below gets one and ends it when it returns. The cx of init is an AsyncContext in herdr (it may be held), so init gets the plain one.
const strictCx = () => {
  const s = { alive: true };
  const guard = (o, name) => new Proxy(o, { get: (t, k) => {
    const v = t[k], n = name + "." + String(k);
    if (typeof v === "function") return (...a) => { if (!s.alive) throw new Error("cx is no longer valid: " + n); return v.apply(t, a); };
    return k === "timer" ? guard(v, n) : v;
  } });
  s.cx = guard(cx, "cx");
  return s;
};
const fresh = () => { office = new Office({}, cx); office.init({}, cx); office.size = { width: 1990, height: 1000 }; office.measured = true; timers.length = 0; return office; };
const render = () => { const s = strictCx(); try { return office.render(s.cx); } finally { s.alive = false; } };
// A clock a test moves by hand: the hold before a walk and the time a walk has run are read from Date.now.
let clock = 1e12;
Date.now = () => clock;
const later = (ms) => { clock += ms; };
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

@test "clicking Yoda with no session offers loh start with Start and Cancel, and Cancel starts nothing" {
  run office_js '
const root = render();
find(root, "hit-yoda").props.on_click[0]({}, cx);
const o = office.offer;
const bar = render();
console.log(o.plan.kind, o.plan.hint, find(bar, "offer-yes") !== undefined, find(bar, "offer-no") !== undefined);
find(bar, "offer-no").props.on_click[0]({}, cx);
console.log(office.offer);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "start loh start yoda true true" ]
  [ "${lines[1]}" = "null" ]
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
  [ "$output" = "10 10 true true" ]
}

@test "a walk is handed over in one render: every link has its own start time, and the next render repeats it exactly" {
  run office_js '
const sig = (root, who) => JSON.stringify(all(find(root, who)).filter((n) => n.props.transitions).map((n) => [id(n), n.props.transitions.map((t) => [t[0], t[1].duration, t[1].delay, t[1].easing]), n.props.left[0], n.props.top[0]]));
render();
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render(); later(3000); render(); later(100);
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
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render(); later(3000); render(); later(100);
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
  [ "$output" = "10 true" ]
}

@test "a walk's timers only turn the walker or end the gait, and a walk ends after its last leg" {
  run office_js '
render();
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render(); later(3000); render(); later(100); timers.length = 0;
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
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render(); later(3000); render(); later(100); timers.length = 0;
render();
const goal = { x: office.walks.get("sheba").goal.x, y: office.walks.get("sheba").goal.y };
timers.filter((t) => !t.cancelled).sort((a, b) => a.ms - b.ms).forEach((t) => t.fn({ notify() {} }));
const root = render();
const w = office.walks.get("sheba");
const m = find(root, "m-sheba");
const t = all(m).filter((x) => x.props.transitions && /^m-/.test(id(x)));
console.log(w.legs.length, w.at.x === goal.x && w.at.y === goal.y, t.length, t.every((x) => x.props.transitions.every((a) => a[1].duration === 1)));'
  [ "$status" -eq 0 ]
  [ "$output" = "0 true 10 true" ]
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
// The wake for Yoda, Sara and Waffles (minutes away) is always pending; only the short timers that build the floor are the point here.
const building = () => timers.filter((t) => !t.cancelled && t.ms < 60000);
while (renders < 60) { const t = building().pop(); if (!t) break; timers.splice(timers.indexOf(t), 1); t.fn({ notify() {} }); render(); renders++; }
console.log(first >= 1, office.floor.layer.done, renders < 60, building().length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true 0" ]
}

# the lights, and the order of what is drawn on the floor
DARK='globalThis.SHARED["crew-office.lights"] = "off"; fresh();'

@test "with the lights off the night shading is still there on the first render after a screen changes state" {
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
terms()[1].labels.pr = "9"; terms()[1].status = "done";
const walking = tr(render());
console.log(rest.length, walking.length, walking.includes(220));'
  [ "$status" -eq 0 ]
  [ "$output" = "2 2 true" ]
}

@test "a state that flips back within the hold moves nobody, and its render is asked for again only to find out" {
  run office_js '
const walk = () => office.walks.get("sheba");
render();
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render();
const wake = timers.filter((t) => !t.cancelled && !(office.wake && t === office.wake.task)).map((t) => t.ms);
later(500);
terms()[1].status = "working";
render();
later(5000);
render();
console.log(wake.length, wake[0] > 900 && wake[0] < 1100, walk().legs.length, walk().goal === walk().at || (walk().goal.x === walk().at.x && walk().goal.y === walk().at.y));'
  [ "$status" -eq 0 ]
  [ "$output" = "1 true 0 true" ]
}

@test "a walk on its way is not redirected by a flip back: its movers stay as handed over, and the way back starts after it ends" {
  run office_js '
const sig = (root) => JSON.stringify(all(find(root, "m-sheba")).filter((n) => n.props.transitions).map((n) => [id(n), n.props.transitions, n.props.left[0], n.props.top[0]]));
const walk = () => office.walks.get("sheba");
render();
const home = { x: walk().goal.x, y: walk().goal.y };
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render(); later(3000); render(); later(100);
const first = sig(render());
const legs = walk().legs;
terms()[1].status = "working";
later(500); render();
later(4000); const mid = sig(render());
const same = mid === first && walk().legs === legs;
// the walk ends: the timers run, one render at rest follows, and the next sees the old place wanted again, held long enough
later(60000);
timers.filter((t) => !t.cancelled).sort((a, b) => a.ms - b.ms).forEach((t) => t.fn({ notify() {} }));
render(); later(60); timers.filter((t) => !t.cancelled).forEach((t) => t.fn({ notify() {} })); render(); later(60); render();
const back = walk();
console.log(same, back.legs.length > 0, back.goal.x === home.x && back.goal.y === home.y, back.from.x !== home.x || back.from.y !== home.y);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true" ]
}

@test "a whole walk, from the hold to the last timer, runs with every render and timer callback on a cx of its own" {
  run office_js '
render();
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render(); later(3000); render(); later(100);
render();
timers.filter((t) => !t.cancelled).sort((a, b) => a.ms - b.ms).forEach((t) => t.fn({ notify() {} }));
render();
console.log(office.walks.get("sheba").legs.length, office.walks.get("sheba").goal === office.walks.get("sheba").at || office.walks.get("sheba").goal.x === office.walks.get("sheba").at.x);'
  [ "$status" -eq 0 ]
  [ "$output" = "0 true" ]
}

@test "officeLog in the props logs each render's figure order and places, and is silent without it" {
  run office_js '
const lines = []; console.error = (x) => lines.push(String(x));
render();
const quiet = lines.length;
globalThis.PROPS = { crew: "sandbox", officeLog: true };
render();
console.log(quiet, lines.length > 0 && lines[0].startsWith("office render "));'
  [ "$status" -eq 0 ]
  [ "$output" = "0 true" ]
}

@test "one render that reads someone's labels or status wrongly draws nobody away from where they stand, and the next render is as before" {
  run office_js '
const fire = () => { const ts = timers.filter((t) => !t.cancelled).sort((a, b) => a.ms - b.ms); timers.length = 0; ts.forEach((t) => t.fn({ notify() {} })); };
const drawn = (root) => { const o = find(root, "m-scofield"); return JSON.stringify([o.props.left, o.props.top, office.walks.get("scofield").at, office.walks.get("scofield").legs.length]); };
const sc = () => terms().find((t) => t.name === "scofield");
sc().status = "idle"; render(); later(3000); render();
sc().labels.place = "kitchen"; render(); later(3000); render(); later(60000); fire(); render(); later(100); fire(); render(); later(5000); render();
const base = drawn(render());
const was = terms();
const strip = (f) => was.map((t) => (t.name === "scofield" ? f({ ...t, labels: { ...t.labels } }) : t));
const variants = {
  noPlace: () => strip((t) => { delete t.labels.place; return t; }),
  noLabels: () => strip((t) => ({ ...t, labels: {} })),
  onlyCrew: () => strip((t) => ({ ...t, labels: { crew: t.labels.crew } })),
  working: () => strip((t) => ({ ...t, status: "working" })),
  gone: () => was.filter((t) => t.name !== "scofield"),
  empty: () => [],
};
const out = [];
for (const [n, f] of Object.entries(variants)) {
  globalThis.TERMS = f();
  const during = drawn(render());
  globalThis.TERMS = was;
  const after = drawn(render());
  out.push(n + ":" + (during === base) + ":" + (after === base));
}
console.log(out.join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "noPlace:true:true noLabels:true:true onlyCrew:true:true working:true:true gone:true:true empty:true:true" ]
}

@test "every mover is back at zero in the render before any walk is handed over, also for the walk back after a flip and a walk right after another" {
  run office_js '
const links = (root) => all(find(root, "m-sheba")).filter((n) => /^m-sheba-(g[0-9]+-)?[0-9]/.test(id(n))).map((n) => [n.props.left[0], n.props.top[0], n.props.transitions[0][1].duration]);
const going = (l) => l.some((x) => x[0] !== 0 || x[1] !== 0);
const rest = (l) => l.every((x) => x[0] === 0 && x[1] === 0);
let prev = null, walks = 0, bad = 0;
const R = () => { const l = links(render()); if (going(l) && !(prev && going(prev) && JSON.stringify(l) === JSON.stringify(prev))) { walks++; if (!(prev && rest(prev))) bad++; } prev = l; };
const fire = () => { const ts = timers.filter((t) => !t.cancelled).sort((a, b) => a.ms - b.ms); timers.length = 0; ts.forEach((t) => t.fn({ notify() {} })); };
R();
// out to the desk, and back to the kitchen while still on the way
terms()[1].labels.pr = "9"; terms()[1].status = "done"; R(); later(3000); R(); later(100); R();
later(1000); terms()[1].status = "working"; R();
later(60000); fire(); R(); later(60); fire(); R(); later(100); R();
// the walk back, and out again as soon as it has begun
terms()[1].labels.pr = "9"; terms()[1].status = "done"; R();
later(60000); fire(); R(); later(60); fire(); R(); later(100); R();
later(60000); fire(); R(); later(60); fire(); R(); later(100); R();
console.log(walks, bad);'
  [ "$status" -eq 0 ]
  [ "$output" = "3 0" ]
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

@test "with the panel open the stage and panel sit in a resizable group, and a drag's end sets the width, within the limits" {
  run office_js '
office.panel.select(office.crewNow.find((a) => a.name === "sheba"), cx);
let root = render();
const g = find(root, "panel");
const split = all(root.node).find((n) => n.props.on_resize);
console.log(!!g, !!split, office.panelW);
split.props.on_resize[0]([1600, 500], cx);
console.log(office.panelW);
split.props.on_resize[0]([1600, 5000], cx);
console.log(office.panelW);
split.props.on_resize[0]([1600, 40], cx);
console.log(office.panelW);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "true true 360" ]
  [ "${lines[1]}" = "500" ]
  [ "${lines[2]}" = "3300" ]
  [ "${lines[3]}" = "260" ]
}

@test "the panel's Full terminal button opens the agent's own terminal in an overlay window and locks it" {
  run office_js '
const a = office.crewNow.find((c) => c.name === "sheba");
office.panel.select(a, cx);
const btn = find(render(), "panel-full-terminal");
btn.props.on_click[0]({}, cx);
const o = globalThis.OVERLAYS[0];
console.log(!!btn, o.kind, o.layout.children[1].content.terminal === a.address);'
  [ "$status" -eq 0 ]
  [ "$output" = "true window true" ]
}

@test "Full terminal gives the terminal the keyboard, holds the lock once, and a second click opens no second window" {
  run office_js '
const a = office.crewNow.find((c) => c.name === "sheba");
office.panel.select(a, cx);
office.fullTerminal(a, cx);
office.fullTerminal(a, cx);
const focus = (globalThis.RUNS || []).filter(([c, x]) => c === "pane.focus" && x.terminal === a.address).length;
console.log(globalThis.OVERLAYS.length, focus >= 1, /^term-/.test(globalThis.OVERLAYS[0].layout.children[0].content.props.termId), office.panel.host.busy());'
  [ "$status" -eq 0 ]
  [ "$output" = "1 true true true" ]
}

@test "Esc does nothing in the office while a full-terminal window is open" {
  run office_js '
const a = office.crewNow.find((c) => c.name === "sheba");
office.panel.select(a, cx);
office.fullTerminal(a, cx);
const root = render();
let closed = false;
office.panel.close = () => { closed = true; };
root.node.props.on_key_down[0]({ key: "escape" }, { stop_propagation() {}, notify() {} });
console.log(closed);'
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "the full-terminal bar stops a press anywhere on it, so the window cannot be dragged" {
  run office_js '
globalThis.PROPS = { terminalBar: true, agent: { name: "sheba" } };
const bar = new Office({}, cx); bar.init({}, cx);
const root = bar.render(cx);
console.log(id(root.node), !!root.node.props.on_mouse_down, typeof find(root, "term-back").props.on_mouse_down[1]);'
  [ "$status" -eq 0 ]
  [ "$output" = "term-bar true function" ]
}

@test "each office pane has its own divider, the width is kept per picked crew, and the log can shrink so the message box stays" {
  run office_js '
office.panel.select(office.crewNow.find((a) => a.name === "sheba"), cx);
const root = render();
const grp = all(root.node).find((n) => n.props.on_resize);
const log = find(root, "panel-log");
console.log(id(grp), office.panelKey, log.props.min_h[0]);'
  [ "$status" -eq 0 ]
  [ "$output" = "office-split-p1 crew-office.panel-width.sandbox 0" ]
}

@test "the divider's limit comes from the group's own width and stays put while the stage resizes" {
  run office_js '
office.panel.select(office.crewNow.find((a) => a.name === "sheba"), cx);
const max = () => all(render().node).find((n) => n.props.size_range && n.props.size_range.length === 2).props.size_range[1];
const wrap = (r) => all(r.node).find((n) => id(n) === "split-box");
const r = render();
wrap(r).props.on_size_change[0]({ width: 1200, height: 800 }, cx);
const before = max();
office.size = { width: 650, height: 800 };
console.log(before, max());'
  [ "$status" -eq 0 ]
  [ "$output" = "600 600" ]
}

@test "a full-terminal window whose bar never comes up is let go: the keyboard and the lock come back" {
  run office_js '
const a = office.crewNow.find((c) => c.name === "sheba");
office.panel.select(a, cx);
office.fullTerminal(a, cx);
const tick = () => new Promise((r) => setTimeout(r, 5));
render(); const during = office.termOpen;
later(1000); render(); const soon = office.termOpen;
later(5000); render(); await tick();
console.log(during, soon, office.termOpen, office.panel.host.busy(), (globalThis.EXECS || []).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true false false lock,unlock" ]
}

@test "a full-terminal window whose bar is up keeps its hold past the grace time, and Back lets it go" {
  run office_js '
const { default: Same } = await import("./main.mjs");
const a = office.crewNow.find((c) => c.name === "sheba");
office.panel.select(a, cx);
office.fullTerminal(a, cx);
const barProps = { terminalBar: true, termId: globalThis.OVERLAYS[0].layout.children[0].content.props.termId, loh: "loh", agent: { address: a.address, name: a.name } };
const tick = () => new Promise((r) => setTimeout(r, 5));
globalThis.PROPS = barProps;
const bar = new Same({}, cx); bar.init({}, cx);
globalThis.PROPS = { crew: "sandbox" };
later(9000); render(); const held = office.termOpen;
globalThis.PROPS = barProps;
await bar.close(cx); await tick();
globalThis.PROPS = { crew: "sandbox" };
render();
console.log(held, office.termOpen);'
  [ "$status" -eq 0 ]
  [ "$output" = "true false" ]
}

@test "a reloaded full-terminal bar holds the agent again: a chat closing meanwhile does not unlock it, and Back does" {
  run office_js '
const { default: Reloaded } = await import("./main.mjs?reload");
const a = office.crewNow.find((c) => c.name === "sheba");
const barProps = { terminalBar: true, termId: "term-x", loh: "loh", agent: { address: a.address, name: a.name } };
globalThis.PROPS = barProps;
const bar = new Reloaded({}, cx); bar.init({}, cx);
const tick = () => new Promise((r) => setTimeout(r, 5));
await tick();
const afterInit = (globalThis.EXECS || []).join(",");
globalThis.PROPS = { crew: "sandbox" };
const o = new Reloaded({}, cx); o.init({}, cx);
o.open(a, cx); await tick();
o.closeChat(cx); await tick();
const afterChat = (globalThis.EXECS || []).join(",");
globalThis.PROPS = barProps;
await bar.close(cx); await tick();
console.log(afterInit, "|", afterChat, "|", (globalThis.EXECS || []).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "lock | lock | lock,unlock" ]
}

@test "two office panes docking the same agent: the agent is unlocked only when both chats are closed" {
  run office_js '
const a = office.crewNow.find((c) => c.name === "sheba");
office.open(a, cx);
const first = office.chat;
const p1 = globalThis.PANES;
globalThis.PANES = [{ pane: "p2", tab: "u", mod: "crew-office", focused: true }];
const two = new Office({}, cx); two.init({}, cx); two.crewNow = office.crewNow;
two.open(a, cx);
const tick = () => new Promise((r) => setTimeout(r, 5));
await tick();
two.closeChat(cx);
await tick();
const mid = globalThis.EXECS.join(",");
globalThis.PANES = p1;
office.closeChat(cx);
await tick();
console.log(!!two.chat, !!first, mid, globalThis.EXECS.join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "false true lock lock,unlock" ]
}

@test "an office run as a layout block adopts a saved plan that has no pane, and Full screen never writes over it" {
  run office_js '
const plan = { zoom: false, hide: ["sidebar"], window: false };
const saved = { plan, pane: null };
globalThis.PROPS = { crew: "sandbox" };
globalThis.PANES = [];
globalThis.SHARED["crew-office.fullscreen"] = saved;
const o = new Office({}, cx); o.init({}, cx);
await new Promise((r) => setTimeout(r, 0));
const adopted = o.fs === saved;
o.fs = null;
o.enterFullscreen({ mine: null, zoomed: false }, cx);
console.log(adopted, o.fs === saved, globalThis.SHARED["crew-office.fullscreen"] === saved, (globalThis.RUNS || []).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true 0" ]
}

@test "the blocked Full screen toast says an office is in full screen and how to take it back" {
  run office_js '
globalThis.PANES = [{ pane: "p1", tab: "t", mod: "crew-office", focused: true }, { pane: "p2", tab: "t", mod: "crew-office", focused: false }];
globalThis.PROPS = { crew: "sandbox", pane: "p1" };
globalThis.SHARED["crew-office.fullscreen"] = { plan: { zoom: false, hide: ["sidebar"], window: false }, pane: "p2" };
const o = new Office({}, cx); o.init({}, cx);
o.enterFullscreen({ mine: "p1", zoomed: false }, cx);
console.log(globalThis.NOTES.map((n) => n.body).join("|"));'
  [ "$status" -eq 0 ]
  [ "$output" = "An office is in full screen. Click this office to take it back, or close the other office pane." ]
}

# the floor is a retained view of its own: herdr runs its render when it is told to, not with every render of the office

@test "the office's own render holds no floor shapes: they are in a retained view of their own" {
  run office_js '
for (let i = 0; i < 14; i++) render();
const root = render();
const isEnt = (k) => k && typeof k.inst === "object";
const raw = (n, out = []) => { out.push(n); for (const k of n.kids) if (k && k.node && !isEnt(k)) raw(k.node, out); return out; };
const mine = raw(root.node);
const entity = mine.flatMap((n) => n.kids).filter(isEnt);
const floorNode = entity[0] && entity[0].node;
console.log(entity.length, Math.max(...mine.map((n) => n.kids.length)) < 100, floorNode.kids.length > 100, floorNode.props.size_full !== undefined);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 true true true" ]
}

@test "the floor view fills the floor box with percentage paths, so a new scale needs no new render of it" {
  run office_js '
for (let i = 0; i < 14; i++) render();
const a = office.floorView.inst.render().node;
console.log(JSON.stringify(a.props.left), JSON.stringify(a.props.top), a.props.w, a.props.h);'
  [ "$status" -eq 0 ]
  [ "$output" = "[0] [0] undefined undefined" ]
}

@test "the floor view sits in a box of the floor's own size, the one the people and click targets use" {
  run office_js '
for (let i = 0; i < 14; i++) render();
const root = render();
const stage = find(root, "stage");
const floor = all(stage)[1];
const wrap = floor.kids.map((k) => k.node).find((n) => id(n) === "floor-box");
const fl = floor.props;
const person = find(root, "m-sheba");
console.log(wrap !== undefined, JSON.stringify(wrap.props.w) === JSON.stringify(fl.w), JSON.stringify(wrap.props.h) === JSON.stringify(fl.h), wrap.props.absolute !== undefined, wrap.kids.includes(office.floorView), fl.flex_none !== undefined, fl.w[0] > 0);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true true true true" ]
}

@test "steady renders do not ask the floor view to render again" {
  run office_js '
for (let i = 0; i < 14; i++) render();
all(find(render(), "stage"));
const notified = [];
timers.length = 0;
for (let i = 0; i < 6; i++) render();
for (const t of timers.splice(0)) t.fn({ notify: (x) => notified.push(x) });
console.log(notified.includes(office.floorView));'
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "a finished new plan is handed to the floor view, which is asked to render once" {
  run office_js '
for (let i = 0; i < 14; i++) render();
all(find(render(), "stage"));
const first = office.floorView.inst.layer;
office.size = { width: 1630, height: 1000 };
for (let i = 0; i < 16; i++) render();
const notified = [];
for (const t of timers.splice(0)) t.fn({ notify: (x) => notified.push(x) });
office.floorView.inst.render();
console.log(first !== undefined, office.floorView.inst.layer === office.shown.layer, office.shown.layer !== first, notified.filter((x) => x === office.floorView).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true 1" ]
}

@test "the repo list is read and applied though the cx the render passed is long dead (strict cx)" {
  run office_js '
const resolvers = [];
globalThis.PROPS = { crew: "sandbox", dir: "/ws" };
globalThis.EXEC_HOOK = () => new Promise((r) => { resolvers.push(r); });
const kids = [], tasks = [], errors = [];
const mk = () => { const c = { alive: true, notified: 0, dead: [],
  notify() { if (!c.alive) { c.dead.push("notify"); throw new Error("cx is no longer valid"); } c.notified++; },
  spawn(fn) { const child = mk(); kids.push(child); tasks.push(new Promise((ok) => ok(fn(child))).catch((e) => errors.push(e.message)).then(() => { child.alive = false; })); } }; return c; };
const strict = mk();
office.repos = []; office.reposKey = null;
office.loadRepos([], "sandbox", strict);
strict.alive = false;
resolvers[0]({ code: 0, stdout: JSON.stringify([{ name: "api" }, { name: "web" }]) });
await new Promise((r) => setTimeout(r, 0));
resolvers[1]({ code: 0, stdout: JSON.stringify({ idle_minutes: 2 }) });
await new Promise((r) => setTimeout(r, 0));
resolvers[2]({ code: 0, stdout: JSON.stringify({ coordinator: "Mia", reviewer: "Rex", advisor: "Ada", teacher: "Tom", coders: ["Ana"], person: "Dana" }) });
await new Promise((r) => setTimeout(r, 0));
resolvers[3]({ code: 0, stdout: "/ws/.loh/reactions\n" });
await Promise.all(tasks);
console.log(JSON.stringify([office.repos, errors, strict.dead, kids.map((k) => k.notified), office.idleMinutes, office.names.coordinator, office.names.person, office.reactDir]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["api","web"],[],[],[4],2,"Mia","Dana","/ws/.loh/reactions"]' ]
}

# Scofield's turn ends; nothing in herdr changes after that, so a timer has to bring the office back for the idle time to end.
@test "Scofield stays at his desk after his turn ends and goes to the lounge when the idle time is over, brought back by a timer" {
  run office_js '
const place = () => { const q = office.layoutNow.people.find((p) => p.id === "scofield").place; return q === "kitchen" || q === "lounge" ? "away" : q; };
render();
terms()[0].status = "done";
render();
const at0 = place();
const wake = timers.filter((t) => !t.cancelled && t.ms > 100000).map((t) => t.ms);
later(179000); render();
const before = place();
later(1000); render();
console.log(at0, wake.length, wake[0] > 179000 && wake[0] < 181000, before, place());'
  [ "$status" -eq 0 ]
  [ "$output" = "desk 1 true desk away" ]
}

@test "the idleMinutes prop sets the idle time, and the workspace's setting is used without it" {
  run office_js '
globalThis.PROPS = { crew: "sandbox", idleMinutes: 1 };
const place = () => { const q = office.layoutNow.people.find((p) => p.id === "scofield").place; return q === "kitchen" || q === "lounge" ? "away" : q; };
render();
terms()[0].status = "idle";
render();
later(61000); render();
const withProp = place();
globalThis.PROPS = { crew: "sandbox" };
office.idleMinutes = 5;
later(1000); render();
const settingHolds = place();
later(300000); render();
console.log(withProp, settingHolds, place());'
  [ "$status" -eq 0 ]
  [ "$output" = "away desk away" ]
}

@test "Matt is away until he types in the message box, at his desk for 3 minutes after, with a timer for each hold's end, and away again" {
  run office_js '
const matt = () => office.layoutNow.people.find((p) => p.id === "matt");
render();
const away = matt().place;
office.typed({ notify() {} });
render();
const typing = matt().place;
const wake = timers.filter((t) => !t.cancelled).map((t) => t.ms);
later(19000); render();
const still = matt().place;
later(2000);
office.wake.task.fn({ notify() {} }); render();
const idle = matt().place;
const seatWake = timers.filter((t) => !t.cancelled).map((t) => t.ms).some((m) => m > 158000 && m <= 160100);
later(160000); render();
console.log(away, typing, still, idle, matt().place, wake.some((m) => m > 19000 && m <= 20100), seatWake);'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge matt matt matt lounge true true" ]
}

@test "Matt is at his desk for 3 minutes after focus arrives on a terminal opened from the office, and goes away though it stays focused" {
  run office_js '
const matt = () => office.layoutNow.people.find((p) => p.id === "matt").place;
office.chat = { pane: "p1", office: "p1", address: "tsheba", name: "sheba", agent: {} };
globalThis.FOCUS = { terminal: "tsheba" };
render();
const focused = matt();
later(19000); render();
const still = matt();
later(2000); render();
const mid = matt();
later(160000); render();
const stays = matt();
globalThis.FOCUS = { terminal: "tscofield" }; render();
globalThis.FOCUS = { terminal: "tsheba" }; render();
console.log(focused, still, mid, stays, matt());'
  [ "$status" -eq 0 ]
  [ "$output" = "matt matt matt lounge matt" ]
}

# Hands tapping on a person's figure: the loops of period 260 inside their mover.
HANDS='
const hands = (name) => all(find(render(), "m-" + name)).filter((n) => n.props.loop && n.props.loop[1] && n.props.loop[1].period === 260).length;
const settle = () => { for (let i = 0; i < 6; i++) { timers.filter((t) => !t.cancelled).sort((a, b) => a.ms - b.ms).forEach((t) => { t.cancelled = true; t.fn({ notify() {} }); }); render(); } };
'

@test "an agent summoned from the lounge has no hands on the keys during the hold or the walk, and types once seated" {
  run office_js "$HANDS"'
office.idleMinutes = 1;
terms()[0].status = "idle";
render(); later(120000); render(); later(3000); render(); settle();
const lounge = office.walks.get("scofield").at;
terms()[0].status = "working";
render();
const hold = hands("scofield");
later(3000); render();
const walking = hands("scofield") + ":" + office.walks.get("scofield").legs.length;
const desk = { x: office.layoutNow.people.find((p) => p.id === "scofield").x, y: office.layoutNow.people.find((p) => p.id === "scofield").y };
settle();
const w = office.walks.get("scofield");
console.log(hold, walking.split(":")[0], walking.split(":")[1] > 0, w.at.x === desk.x && w.at.y === desk.y && (lounge.x !== desk.x || lounge.y !== desk.y), hands("scofield"));'
  [ "$status" -eq 0 ]
  [ "$output" = "0 0 true true 2" ]
}

@test "Matt sits and types for 20 s, sits on without typing to 3 minutes with his monitors lit, then dims them on the way to the lounge" {
  run office_js "$HANDS"'
const matt = () => office.screensNow.matt;
render();
const away = hands("matt") + matt();
office.mattLast = clock; render();
const hold = hands("matt") + matt();
later(3000); render(); const walking = hands("matt") + matt();
settle();
const seated = hands("matt") + matt();
later(25000); render();
const idle = hands("matt") + matt();
later(150000); render();
const late = hands("matt") + matt();
later(10000); render();
const leaving = hands("matt") + matt();
later(3000); render(); settle();
const gone = hands("matt") + matt() + office.layoutNow.people.find((p) => p.id === "matt").place;
console.log([away, hold, walking, seated, idle, late, leaving, gone].join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "0dim 0dim 0dim 2work 0work 0work 0dim 0dimlounge" ]
}

dim_count='const dim = (root) => all(find(root, "stage")).filter((n) => n.fill === "#060a24a8").length;'

@test "lights start on: no night layers in herdr's dark mode" {
  run office_js 'globalThis.DARK = true; fresh();
for (let i = 0; i < 14; i++) render();
'"$dim_count"'
console.log(office.lights, dim(render()));'
  [ "$status" -eq 0 ]
  [ "$output" = "true 0" ]
}

@test "lights off in herdr's light mode draws the night layers" {
  run office_js 'globalThis.DARK = false; globalThis.SHARED["crew-office.lights"] = "off"; fresh();
for (let i = 0; i < 14; i++) render();
'"$dim_count"'
console.log(office.lights, dim(render()));'
  [ "$status" -eq 0 ]
  [ "$output" = "false 1" ]
}

@test "the toggle flips the lights and the button and L both use it, and the choice is saved" {
  run office_js '
for (let i = 0; i < 14; i++) render();
const label = () => find(render(), "lights").kids.join("");
const a = label();
find(render(), "lights").props.on_click[0]({}, cx);
const b = [office.lights, label(), globalThis.SHARED["crew-office.lights"]];
find(render(), "root").props.on_key_down[0]({ key: "l", modifiers: {} }, { stop_propagation() {}, notify() {} });
console.log(a, b.join("/"), office.lights, globalThis.SHARED["crew-office.lights"]);'
  [ "$status" -eq 0 ]
  [ "$output" = "Lights off false/Lights on/off true on" ]
}

@test "the remembered lights value is read back at start" {
  run office_js 'globalThis.SHARED["crew-office.lights"] = "off"; fresh(); const off = office.lights;
globalThis.SHARED["crew-office.lights"] = "on"; fresh(); const on = office.lights;
delete globalThis.SHARED["crew-office.lights"]; fresh();
console.log(off, on, office.lights);'
  [ "$status" -eq 0 ]
  [ "$output" = "false true true" ]
}

# The repo list is read again every minute, not only when the workspace, folder or crew size changes.
repos_probe='
globalThis.PROPS = { crew: "sandbox", dir: "/ws" };
const calls = []; let reply = { code: 0, stdout: JSON.stringify([{ name: "api" }]) };
globalThis.EXEC_HOOK = (c, a) => { calls.push(a.join(" ")); return Promise.resolve(a.includes("--repos") ? reply : { code: 1 }); };
const tasks = [];
const cx2 = { notify() {}, spawn(fn) { tasks.push(fn({ notify() {}, spawn: cx2.spawn })); } };
const ask = async () => { office.loadRepos([], "sandbox", cx2); await Promise.all(tasks.splice(0)); };
const asks = () => calls.filter((x) => x.includes("--repos")).length;
office.repos = []; office.reposKey = null; office.reposAt = 0;'

@test "a repo added to the manifest is picked up once the minute is up, and a removed one is dropped" {
  run office_js "$repos_probe"'
await ask();
reply = { code: 0, stdout: JSON.stringify([{ name: "api" }, { name: "mieru" }]) };
later(60000); await ask();
const added = office.repos.join(",");
reply = { code: 0, stdout: JSON.stringify([{ name: "mieru" }]) };
later(60000); await ask();
console.log(added, office.repos.join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "api,mieru mieru" ]
}

@test "no repo call is made before the minute is up, and a change of crew size asks at once" {
  run office_js "$repos_probe"'
await ask();
later(59000); await ask(); await ask();
const early = asks();
office.loadRepos([{ name: "x", cwd: "/ws" }], "sandbox", cx2); await Promise.all(tasks.splice(0));
const resized = asks();
later(1000); await ask();
console.log(early, resized);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 2" ]
}

@test "a failed repo call keeps the last list, and is tried again a minute later" {
  run office_js "$repos_probe"'
await ask();
reply = { code: 1, stdout: "" };
later(60000); await ask();
const kept = office.repos.join(",");
reply = { code: 0, stdout: JSON.stringify([{ name: "api" }, { name: "web" }]) };
later(60000); await ask();
console.log(kept, office.repos.join(","), asks());'
  [ "$status" -eq 0 ]
  [ "$output" = "api api,web 3" ]
}

@test "a render before the minute is up asks for a render at its end" {
  run office_js "$repos_probe"'
await ask();
timers.length = 0; office.wake = null;
later(20000); office.loadRepos([], "sandbox", cx2);
const t = timers.filter((x) => !x.cancelled).map((x) => x.ms);
console.log(t.some((ms) => ms > 39000 && ms <= 41000), asks());'
  [ "$status" -eq 0 ]
  [ "$output" = "true 1" ] || { echo "GOT: $output" >&2; false; }
}

@test "no walk reuses the link elements of the walk before it, and its links already exist at rest, so each one animates from zero" {
  run office_js '
const ids = (root, who) => all(find(root, who)).map(id).filter((x) => x && x !== who && x.startsWith(who + "-")).sort().join(",");
render();
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render(); later(3000); timers.length = 0;
render(); later(100);
const one = render();
const a = ids(one, "m-sheba"), ta = ids(one, "tm-sheba");
timers.filter((t) => !t.cancelled).sort((x, y) => x.ms - y.ms).forEach((t) => t.fn({ notify() {} }));
const rest = render(); later(2000); const rest2 = render();
const b = ids(rest2, "m-sheba");
terms()[1].labels.note = "escalation:x";
render(); later(3000);
render(); later(100);
const two = render();
const c = ids(two, "m-sheba"), tc = ids(two, "tm-sheba");
const share = (x, y) => x.split(",").filter((i) => y.split(",").includes(i)).length;
console.log(a.split(",").length, share(a, c), share(ids(rest2, "m-sheba"), c) === c.split(",").length, share(ta, tc), ids(rest, "m-sheba") === b);'
  [ "$status" -eq 0 ]
  [ "$output" = "9 0 true 0 true" ]
}

@test "a copy whose source reports its real folder finds its own pane under the mods/ entry that leads to it" {
  run office_js '
globalThis.PANES = [{ pane: "p1", tab: "t", mod: "crew-office", focused: false }, { pane: "p9", tab: "t", mod: "crew-office-test", focused: true }];
globalThis.EXEC_HOOK = (c, a) => Promise.resolve(c === "sh" ? { code: 0, stdout: "own\t/x\ncrew-office-test\t/x\ncrew-office\t/y\n", stderr: "" } : { code: 0 });
fresh();
await new Promise((r) => setTimeout(r, 0));
office.open(terms()[1], cx);
console.log(office.chat && office.chat.office);'
  [ "$status" -eq 0 ]
  [ "$output" = "p9" ]
}

@test "full-screen recovery waits for the name: a copy named by a scan does not adopt another mod's saved plan" {
  run office_js '
globalThis.PANES = [{ pane: "p1", tab: "t", mod: "crew-office", focused: true }, { pane: "p9", tab: "t", mod: "crew-office-test", focused: false }];
globalThis.PROPS = { crew: "sandbox" };
globalThis.SHARED["crew-office.fullscreen"] = { plan: { zoom: false, hide: ["sidebar"], window: false }, pane: "p1" };
globalThis.EXEC_HOOK = (c) => Promise.resolve(c === "sh" ? { code: 0, stdout: "own\t/x\ncrew-office-test\t/x\ncrew-office\t/y\n", stderr: "" } : { code: 0 });
const o = new Office({}, cx); o.init({}, cx);
const before = o.fs;
await new Promise((r) => setTimeout(r, 0));
console.log(before, o.fs, (globalThis.RUNS || []).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "null null 0" ]
}

@test "a coder leaving the kitchen for ping pong keeps its mug until it sets off, though the layout already says ping pong" {
  run office_js '
const fire = () => { for (const t of timers.slice()) if (!t.cancelled && !t.done && t.at + t.ms <= clock) { t.done = true; t.fn(cx); } };
const paths = (root) => all(find(root, "person-sheba")).filter((n) => n.props.size_full).length;
const spot = () => office.layoutNow.people.find((p) => p.id === "sheba").place;
render();
terms()[1].labels.pr = "9"; terms()[1].status = "done";
let kitchen = 0, flipped = 0, drawn = new Set();
for (let i = 0; i < 80; i++) {
  later(500); fire();
  const r = render(), w = office.walks.get("sheba");
  const standing = w.legs.length === 0 && !w.settling && !w.arming;
  if (standing && spot() === "kitchen" && w.at.y > 150) { kitchen++; drawn.add(paths(r)); }
  if (standing && spot() === "pong" && w.at.x < 250) { flipped++; drawn.add(paths(r)); }
}
console.log(kitchen > 0, flipped > 0, drawn.size);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true 1" ]
}

@test "a rest render that was cut off hands over no walk: the render after it draws the rest frame and the one after that hands the walk over" {
  run office_js '
const fire = () => { for (const t of timers.slice()) if (!t.cancelled && !t.done && t.at + t.ms <= clock) { t.done = true; t.fn(cx); } };
const w = () => office.walks.get("sheba");
render();
terms()[1].labels.pr = "9"; terms()[1].status = "done";
let n = 0;
while (!(w().legs.length > 0) && n++ < 200) { later(250); fire(); render(); }
terms()[1].status = "working";
while (!w().settling && n++ < 600) { later(250); fire(); if (!w().settling) render(); }
const arrived = w().settling;
// The render that draws the rest frame is cut off at the deadline: it ran motion() and never finished.
const frame = office.frame; office.frame = () => { throw new Error("deadline"); };
try { render(); } catch (_) { /* cut off */ }
office.frame = frame;
later(1); render();
const afterCutOff = w().legs.length + (w().arming ? 1 : 0);
later(1); render();
const armed = !!w().arming && w().legs.length === 0;
later(1); render();
console.log(arrived, afterCutOff, armed, w().legs.length > 0);'
  [ "$status" -eq 0 ]
[ "$output" = "true 0 true true" ]
}

@test "someone whose place changes in the same render as a new scale and floor stays where they stood, carried with their room, then walks there once the rest frame was drawn" {
  run office_js '
const fire = () => { for (const t of timers.slice()) if (!t.cancelled && !t.done && t.at + t.ms <= clock) { t.done = true; t.fn(cx); } };
const w = () => office.walks.get("sheba");
render(); later(3000); render();
const before = { ...w().at };
const goalBefore = { ...w().goal };
const roomOf = (L, p) => L.rooms.find((q) => p.x >= q.x && p.x <= q.x + q.w && p.y >= q.y && p.y <= q.y + q.h);
const roomBefore = roomOf(office.motionL, before);
const offBefore = { x: before.x - (roomBefore.x + roomBefore.w / 2), y: before.y - (roomBefore.y + roomBefore.h / 2) };
// The chat closes as she leaves: a new scale and floor, and a new place, in one render.
office.size = { width: 1600, height: 1000 };
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render();
const rn = office.motionL.rooms.find((q) => q.key === roomBefore.key);
const off = { x: w().at.x - (rn.x + rn.w / 2), y: w().at.y - (rn.y + rn.h / 2) };
const stayed = Math.abs(off.x - offBefore.x) < 0.01 && Math.abs(off.y - offBefore.y) < 0.01 && w().legs.length === 0 && !w().arming;
const restDrawnAfterSnap = w().restDrawn;
let armedBeforeDrawn = false, walked = false, n = 0;
while (!walked && n++ < 200) {
  later(100); fire();
  const wasDrawn = w().restDrawn;
  render();
  if (w().arming && !wasDrawn && w().resting === false && n === 1) armedBeforeDrawn = true;
  if (w().legs.length > 0) walked = true;
}
const goal = office.layoutNow.people.find((p) => p.id === "sheba");
const last = w().legs[w().legs.length - 1];
const end = last ? { x: last.x !== undefined ? last.x : last.to.x, y: last.y !== undefined ? last.y : last.to.y } : null;
console.log(stayed, restDrawnAfterSnap, armedBeforeDrawn, walked, goal.x !== goalBefore.x || goal.y !== goalBefore.y);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true false true true" ] || { echo "GOT: $output" >&2; false; }
}

@test "a new scale alone still puts everyone in place without a walk" {
  run office_js '
const w = () => office.walks.get("sheba");
render(); later(3000); render();
office.size = { width: 1600, height: 1000 };
render();
const goal = office.layoutNow.people.find((p) => p.id === "sheba");
console.log(w().at.x === goal.x && w().at.y === goal.y, w().legs.length, !!w().arming, w().resting);'
  [ "$status" -eq 0 ]
  [ "$output" = "true 0 false false" ]
}

@test "a walk's transition policies are drawn on zeroed movers one render before its offsets, so no mover changes policy and value together" {
  run office_js '
const links = (root) => all(find(root, "m-sheba")).filter((n) => /^m-sheba-g[0-9]+-[0-9]/.test(id(n))).map((n) => ({ id: id(n), off: [n.props.left[0], n.props.top[0]], pol: JSON.stringify(n.props.transitions) }));
const base = (r) => { const n = find(r, "m-sheba"); return n.props.left[0] + "," + n.props.top[0]; };
let r0 = render(); const origin = base(r0); let rest = links(r0);
terms()[1].labels.pr = "9"; terms()[1].status = "done";
render(); later(3000);
const frames = [], bases = [];
for (let i = 0; i < 4; i++) { const r = render(); frames.push(links(r)); bases.push(base(r)); later(100); }
const moving = (l) => l.some((x) => x.off[0] !== 0 || x.off[1] !== 0);
const timed = (l) => l.some((x) => JSON.parse(x.pol)[0][1].duration > 1);
const go = frames.find(moving), arm = frames.find((l) => timed(l) && !moving(l));
const zero = (l) => l.every((x) => x.off[0] === 0 && x.off[1] === 0);
const samePol = (a, b) => a.every((x, i) => x.id === b[i].id && x.pol === b[i].pol);
const gi = frames.indexOf(go);
console.log(bases.slice(0, gi).every((b) => b === origin), !!arm, !!go, arm && zero(arm), arm && go && samePol(arm, go), arm && !samePol(rest, arm));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true true true" ] || { echo "GOT: $output" >&2; false; }
}

@test "the floor is drawn as a picture once its SVG is written to herdr's folder, and by the floor view until then or if it cannot be" {
  run office_js '
const fs = await import("node:fs/promises");
const os = await import("node:os");
const home = await fs.mkdtemp(os.tmpdir() + "/loh-home-");
const views = (root) => all(root.node).filter((n) => id(n) === "floor-box").map((n) => n.kids.length + ":" + (n.kids[0] && n.kids[0].node ? "div" : "?"));
// A home it cannot write to (a file where the folder should go): the floor view keeps drawing.
await fs.writeFile(home + "/afile", "x");
office.pics.clear(); globalThis.APP_HOME = home + "/afile"; globalThis.IMAGES = [];
const tick = () => { for (const t of timers.splice(0)) if (!t.cancelled && t.ms === 1) t.fn(cx); };
render(); tick(); await new Promise((r) => setTimeout(r, 30)); render();
const noFile = globalThis.IMAGES.length;
// A home it can write to: the first render asks for the file, a later one draws it.
office.pics.clear(); globalThis.APP_HOME = home; globalThis.IMAGES = [];
render();
const before = globalThis.IMAGES.length;
tick();
await new Promise((r) => setTimeout(r, 80));
render();
const names = (await fs.readdir(home + "/crew-office-floors/crew-office")).filter((f) => /^crew-office-floor-[0-9a-f]{8}\.svg$/.test(f));
const text = names.length ? await fs.readFile(home + "/crew-office-floors/crew-office/" + names[0], "utf8") : "";
// The picture is drawn at its own size, a whole number of pixels a world unit, 2 to 6.
const size = /width="([0-9.]+)" height="([0-9.]+)"/.exec(text);
const per = size ? Number(size[1]) / Number(/viewBox="0 0 ([0-9.]+) /.exec(text)[1]) : 0;
console.log(noFile, before, globalThis.IMAGES.length, names.length, globalThis.IMAGES[0] === "crew-office-floors/crew-office/" + names[0], text.startsWith("<svg") && text.endsWith("</svg>"), Math.abs(per - Math.round(per)) < 0.01 && per >= 2 && per <= 6);'
  [ "$status" -eq 0 ]
  [ "$output" = "0 0 1 1 true true true" ]
}

@test "no more than a dozen floor pictures stay in this copy's folder, the one just written among them, and nothing else, another copy's folder included, is touched" {
  run office_js '
const fs = await import("node:fs/promises");
const os = await import("node:os");
const home = await fs.mkdtemp(os.tmpdir() + "/loh-home-");
await fs.mkdir(home + "/crew-office-floors/crew-office", { recursive: true });
await fs.mkdir(home + "/crew-office-floors/other-copy", { recursive: true });
await fs.writeFile(home + "/crew-office-floors/other-copy/crew-office-floor-00000000.svg", "theirs");
for (let i = 0; i < 20; i++) await fs.writeFile(home + "/crew-office-floors/crew-office/crew-office-floor-" + String(i).padStart(8, "0") + ".svg", "old");
await fs.writeFile(home + "/crew-office-floors/crew-office/notes.txt", "mine");
office.pics.clear(); globalThis.APP_HOME = home; globalThis.IMAGES = [];
render();
for (const t of timers.splice(0)) if (!t.cancelled && t.ms === 1) t.fn(cx);
await new Promise((r) => setTimeout(r, 120));
const names = await fs.readdir(home + "/crew-office-floors/crew-office");
const theirs = await fs.readdir(home + "/crew-office-floors/other-copy");
const svgs = names.filter((f) => f.endsWith(".svg"));
console.log(svgs.length <= 12, svgs.filter((f) => !/^crew-office-floor-0000/.test(f)).length === 1, names.includes("notes.txt"), theirs.length === 1);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true" ]
}

# ---- toasts (ticket #93) ----

TOAST_HELPERS='
const text = (n) => n.kids.filter((k) => typeof k === "string");
const toasts = (root) => all(root.node).filter((n) => /^toast-/.test(id(n) || ""));
const lines = (n) => all(n).flatMap(text);
const block = (i, kind, msg) => { terms()[i].status = { state: "blocked", kind, msg }; };
'

@test "a coder that blocks on a permission gets a toast with its name, the whole text and the permission colour" {
  run office_js "$TOAST_HELPERS"'
render();
const msg = "Bash: " + "x".repeat(150);
block(1, "permission", msg);
const t = toasts(render());
console.log(t.length, lines(t[0]).join("|") === "Sheba needs you|permission: " + msg + "|Toast, no sound · click to open", t[0].props.border_color[0]);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 true #e7a43a" ]
}

@test "a question is blue, an escalation pink, and the toasts are the newest first" {
  run office_js "$TOAST_HELPERS"'
render();
block(2, "question", "Which?");
render();
terms()[1].labels.note = "escalation:stuck on review";
const t = toasts(render());
console.log(t.map((n) => lines(n)[0] + "@" + n.props.border_color[0]).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "Sheba escalates@#d0509f,Sucre needs you@#4f8ff0" ]
}

@test "no toast shows for what was already pending when the office opened" {
  run office_js "$TOAST_HELPERS"'
fresh();
block(1, "permission", "Bash: ls");
console.log(toasts(render()).length, toasts(render()).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "0 0" ]
}

@test "a toast goes 7 s after it came, and the office asks to be drawn again then" {
  run office_js "$TOAST_HELPERS"'
render();
block(1, "question", "A?");
timers.length = 0;
const a = toasts(render()).length;
// (One timer is kept, the earliest wanted: a render for any reason asks for the next again.)
const wake = office.wake ? [office.wake.at - Date.now()].filter((ms) => ms <= 7005) : [];
const solid = () => toasts(render()).filter((n) => n.props.opacity[0] === 1).length;
later(6999); const b = solid();
later(1); const c = solid();
later(249); const d = toasts(render()).length;
later(1); const e = toasts(render()).length;
console.log(a, wake.length > 0, b, c, d, e);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 true 1 0 1 0" ]
}

@test "at most 3 toasts show at once" {
  run office_js "$TOAST_HELPERS"'
terms().push(...["amy", "bo", "cy"].map((n) => ({ address: "t" + n, name: n, state: "live", agent: "claude", status: "working", labels: { crew: "sandbox", role: "reviewer" } })));
render();
for (const t of terms()) t.status = { state: "blocked", kind: "question", msg: "?" };
const at = toasts(render()).length;
later(300);
console.log(office.toasts.list.length, at, toasts(render()).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "3 6 3" ]
}

@test "clicking a toast opens that agent's chat, as clicking the person does, and the toast goes" {
  run office_js "$TOAST_HELPERS"'
const opened = [];
office.panel.select = (a) => opened.push("select:" + a.name);
office.open = (a) => opened.push("open:" + a.name);
office.chat = { pane: "p1", office: "p1", address: "tscofield", name: "scofield", agent: {} };
render();
block(1, "permission", "Bash: ls");
const root = render();
const t = toasts(root)[0];
t.props.on_click[0]({}, cx);
console.log(opened.join(","), toasts(render()).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "select:sheba,open:sheba 0" ]
}

@test "the office tells loh it is open at once, then every 5 s, from the agents' folder" {
  run office_js '
const calls = [];
globalThis.EXEC_HOOK = (c, a, o) => { calls.push([a[0], o && o.cwd]); return Promise.resolve({ code: 0, stdout: "", stderr: "" }); };
for (const t of terms()) t.cwd = "/ws/" + t.name;
office.pingAt = 0;
render(); render();
const first = calls.filter((c) => c[0] === "office-ping").length;
later(4999); render();
const mid = calls.filter((c) => c[0] === "office-ping").length;
later(1); render();
const last = calls.filter((c) => c[0] === "office-ping");
console.log(first, mid, last.length, last[0][1]);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 2 /ws/scofield" ]
}

@test "a toast has the prototype's .toast metrics: 280 wide, a 4px edge, 8px radius, padding 7px 10px, 12.5px text on a 1.35 line, a bold head, an 11.5px hint" {
  run office_js "$TOAST_HELPERS"'
render();
block(1, "question", "Which?");
render(); later(100);
const t = toasts(render())[0];
const p = t.props;
const [head, body, hint] = t.kids.map((k) => k.node.props);
console.log(p.w[0], p.border_l[0], p.rounded[0], p.px[0], p.py[0], p.gap[0], p.shadow_lg !== undefined);
console.log(head.text_size[0], head.line_height[0], head.font_bold !== undefined, body.text_size[0], body.line_height[0], body.font_bold === undefined, hint.text_size[0], hint.line_height[0]);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "280 4 8 10 7 1 true" ]
  [ "${lines[1]}" = "12.5 16.875px true 12.5 16.875px true 11.5 15.525px" ]
}

@test "the toast takes the prototype's --toast-bg, --toast-ink and --toast-muted in the light theme and in the dark" {
  run office_js "$TOAST_HELPERS"'
const colours = () => { const t = toasts(render())[0]; const k = t.kids.map((x) => x.node.props.text_color[0]); return [t.props.bg[0], ...k].join(" "); };
render();
block(1, "question", "Which?");
render(); later(100);
const light = colours();
globalThis.DARK = true;
const dark = colours();
console.log(light); console.log(dark);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "#ffffff #151a24 #151a24 #5b6272" ]
  [ "${lines[1]}" = "#222937 #e3e8f0 #e3e8f0 #9ba5b8" ]
}

@test "the edge colours are the prototype's --st-q, --st-perm, --st-esc and --st-idle" {
  run office_js "$TOAST_HELPERS"'
terms().push(...["amy", "bo"].map((n) => ({ address: "t" + n, name: n, state: "live", agent: "claude", status: "working", labels: { crew: "sandbox", role: "reviewer" } })));
render();
block(1, "permission", "a"); block(2, "question", "b"); terms()[3].labels.note = "escalation:c"; terms()[4].labels.note = "undelivered:d";
console.log(toasts(render()).map((n) => n.props.border_color[0]).sort().join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "#4f8ff0 #aab2bf #d0509f #e7a43a" ]
}

@test "a toast slides and fades: it is drawn faded and 8px up when it comes, in place a moment later, and it fades out before it goes" {
  run office_js "$TOAST_HELPERS"'
render();
block(1, "question", "Which?");
const at = (ms) => { const t = toasts(render())[0]; return t ? [t.props.opacity[0], t.props.top[0]].join("/") : "none"; };
const first = at(); later(40); const settled = at(); later(7000); const out = at(); later(250); const gone = at();
const t = (render(), toasts(render())); 
console.log(first, settled, out, gone);'
  [ "$status" -eq 0 ]
  [ "$output" = "0/-8 1/0 0/-8 none" ]
}

@test "a toast's top and opacity animate natively: both have a transition, 220 ms ease-out" {
  run office_js "$TOAST_HELPERS"'
render();
block(1, "question", "Which?");
const t = toasts(render())[0];
console.log(JSON.stringify(t.props.transitions));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["top",{"duration":220,"easing":"ease-out"}],["opacity",{"duration":220,"easing":"ease-out"}]]' ]
}

@test "a new toast pushes the older ones down by its measured height and the gap, with the slide" {
  run office_js "$TOAST_HELPERS"'
terms().push({ address: "tamy", name: "amy", state: "live", agent: "claude", status: "working", labels: { crew: "sandbox", role: "reviewer" } });
render();
block(1, "question", "one"); render(); later(100); render();
for (const n of toasts(render())) n.props.on_size_change[0]({ width: 280, height: 50 }, cx);
block(2, "question", "two"); render(); later(100);
const root = render();
const before = toasts(root).map((n) => n.props.top[0]);
for (const n of toasts(root)) n.props.on_size_change[0]({ width: 280, height: 50 }, cx);
const after = toasts(render()).map((n) => n.props.top[0]);
console.log(before.join(","), after.join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "0,71 0,56" ]
}

@test "the toast stack sits inside the floor, as the prototype's .toasts sit in its stage: 58px under its top, 12px from its right edge, 280 wide, and not scaled with it" {
  run office_js "$TOAST_HELPERS"'
render();
block(1, "question", "Which?");
const root = render();
const floor = find(root, "floor");
const stack = find(root, "toasts");
console.log(all(floor).includes(stack), floor.props.relative !== undefined, stack.props.top[0], stack.props.right[0], stack.props.w[0], stack.props.left === undefined, floor.props.w[0] > 304);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true 58 12 280 true true" ]
}

@test "on a floor narrower than 304 px the toasts shrink to the floor less 24 px, so they never run off its edge (min(280px, 100% - 24px))" {
  run office_js "$TOAST_HELPERS"'
office.size = { width: 200, height: 600 };
render();
block(1, "question", "Which?");
const root = render();
const floorW = find(root, "floor").props.w[0];
const stack = find(root, "toasts");
console.log(floorW < 304, stack.props.w[0] === floorW - 24, toasts(root)[0].props.w[0] === floorW - 24);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true" ]
}

@test "with the chat panel open the toasts are in the floor, beside the panel and not under it" {
  run office_js "$TOAST_HELPERS"'
office.panel.select(office.crewNow.find((a) => a.name === "sheba"), cx);
render();
block(1, "question", "Which?");
const root = render();
const stack = find(root, "toasts");
console.log(office.panel.open, all(find(root, "floor")).includes(stack), all(find(root, "panel")).includes(stack));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true false" ]
}
