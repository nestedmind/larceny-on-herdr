// The office's own drawing, under node: main.js's real render() with gpui-kit, gpui-base and herdr replaced by
// recorders, then a walk of the element tree it returns. Nothing here knows where anything should be; compare.mjs
// holds that. Positions are px at the scale (k) the office fitted, from the floor's top left corner.
// What node cannot see is herdr's own layout: the box the retained floor view is given. It is taken to be the
// floor element's size; the live part (live.mjs) measures the real window.

import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const KIT = `
function el() {
  const node = { kids: [], props: {} };
  const p = new Proxy(node, { get(t, k) {
    if (k === "node") return t;
    return (...a) => {
      if (k === "child") t.kids.push(a[0]);
      else if (k === "children") t.kids.push(...a[0]);
      else if (k === "when") return a[0] ? a[1](p) : p;
      else if (k === "transition" || k === "loop") (t.props[k] ||= []).push(a);
      else t.props[k] = a;
      return p;
    };
  } });
  return p;
}
export const div = el;
export const View = class { constructor(p) { this.props = p; } };
globalThis.window = { paint_path: (path, fill) => { const e = el(); e.node.fill = fill; return e; }, toggle_fullscreen() {} };
const mk = () => { const b = new Proxy({}, { get: (t, k) => k === "build" ? () => ({}) : () => b }); return b; };
export const PathBuilder = { fill: mk, stroke: mk };
`;
const BASE = `import { div } from "gpui-kit";
export const v_flex = div, h_flex = div, h_resizable = (id) => div().id(id), resizable_panel = div;
export const InputState = { new: () => ({ set_value() {}, value: () => "", on() {}, focus() {} }) };
export const Input = { new: () => div() };
export const ScrollHandle = { new: () => ({}) };
`;
const HERDR = `
export const terminals = () => globalThis.TERMS;
export const panes = () => [{ pane: "p1", tab: "t", mod: "crew-office", focused: true }];
export const run = () => {};
export const exec = () => new Promise(() => {});
export const notify = () => {};
export const props = () => ({ crew: "parity" });
export const theme = () => new Proxy({}, { get: () => "#808080" });
export const settings = () => ({ dark: false });
export const layout = () => ({}); export const shared = () => null; export const setShared = () => {};
export const openOverlay = () => "o1"; export const closeOverlay = () => null;
export const window = () => ({ fullscreen: false });
export const focused = () => null;
`;
const FILES = ["crew", "draw", "panel", "chat", "main"];

/** Copies the mod next to the stubs in a temp folder and loads its modules from there. */
export async function loadOffice(modDir) {
  const d = mkdtempSync(join(tmpdir(), "office-parity-"));
  for (const [name, src] of [["gpui-kit", KIT], ["gpui-base", BASE], ["herdr", HERDR]]) {
    mkdirSync(join(d, "node_modules", name), { recursive: true });
    writeFileSync(join(d, "node_modules", name, "index.js"), src);
  }
  writeFileSync(join(d, "package.json"), '{"type":"module"}');
  for (const f of FILES) {
    cpSync(join(modDir, f + ".js"), join(d, f + ".mjs"));
    writeFileSync(join(d, f + ".mjs"), readFileSync(join(d, f + ".mjs"), "utf8").replace(/from "\.\/([a-z]+)\.js"/g, 'from "./$1.mjs"'));
  }
  const load = (f) => import("file://" + join(d, f + ".mjs"));
  const [main, crew, draw] = await Promise.all([load("main"), load("crew"), load("draw")]);
  return { Office: main.default, crew, draw };
}

const all = (node, out = []) => { out.push(node); for (const k of node.kids) if (k && k.node) all(k.node, out); return out; };
const v = (n, key) => (n.props[key] ? n.props[key][0] : undefined);

/**
 * Draws one crew in a stage of `stage` px (the area the office fits the floor into, padding included).
 * `agents` are {name, role, status, repo, ticket, kind, pr, round, ctx}. `typing` is whether Matt is typing, and `advance` how
 * many ms pass with the crew as it is before it is drawn (the idle time, a wait for a review): the office first sees the crew
 * at time 0, so what changes with time changes in that gap, and the people walk to where it puts them.
 * Returns the layout (the office's own, from its last render) and scale the office chose, and each figure, click target and
 * tag as drawn, in px from the floor's corner.
 */
export async function drawOffice({ Office, crew, draw }, { agents, repos, stage, typing = false, advance = 0 }) {
  globalThis.TERMS = agents.map((a, i) => ({
    address: "t" + i, name: a.name, state: "live", agent: "claude", status: a.kind ? { state: a.status, kind: a.kind } : a.status || "idle",
    labels: { crew: "parity", role: a.role || "coder", task: a.repo ? a.repo + "#" + (a.ticket || 1) : "", step: a.step || "", pr: a.pr || "", round: a.round || "", ctx: a.ctx || "" },
  }));
  const realNow = Date.now;
  let clock = 1e12;
  Date.now = () => clock;
  try {
    const cx = { spawn: (fn) => { fn(cx); }, focus_handle: () => ({ focus() {}, is_focused: () => true }), timer: { after: () => ({ cancel() {} }) }, notify() {},
      new: (C, p) => { const inst = new C(p); if (inst.init) inst.init(p, cx); return { inst, get node() { return inst.render(cx).node; }, set_props() {}, release: () => true }; } };
    const office = new Office({}, cx);
    office.init({}, cx);
    office.size = { width: stage.w, height: stage.h };
    office.measured = true;
    office.loadRepos = () => {};
    office.repos = repos;
    let root;
    // Matt types for as long as the case runs.
    if (typing) office.mattUntil = clock + 1e9;
    for (let i = 0; i < 60; i++) { root = office.render(cx); if (office.shown) break; }
    // Time passes with the crew as it is: what it changes is seen, held for the office's hold time, and walked to.
    if (advance) { clock += advance; root = office.render(cx); }
    clock += 3000;
    root = office.render(cx);
    const L = office.layoutNow;
    const fit = crew.fitScale(office.size, L);
    const floor = all(root.node).find((n) => "relative" in n.props && v(n, "w") !== undefined && all(n).some((m) => String(v(m, "id") || "").startsWith("m-")));
    if (!floor) throw new Error("the floor element was not found in the office's tree");
    const out = { L, k: fit.k, fits: fit.fits, floorBox: { w: v(floor, "w"), h: v(floor, "h") }, people: {}, hits: {}, tags: {}, ops: draw.floorLayer(L, fit.k).ops };
    const walk = (n, ox, oy) => {
      const x = ox + (v(n, "left") || 0), y = oy + (v(n, "top") || 0);
      const id = String(v(n, "id") || "");
      const w = v(n, "w"), h = v(n, "h");
      if (id.startsWith("person-")) out.people[id.slice(7)] = { x: x + w / 2, y: y + h / 2 };
      else if (id.startsWith("hit-")) out.hits[id.slice(4)] = { x, y, w, h };
      else if (id.startsWith("tag-")) out.tags[id.slice(4)] = { x, y, w, h };
      for (const kid of n.kids) if (kid && kid.node) walk(kid.node, x, y);
    };
    for (const kid of floor.kids) if (kid && kid.node) walk(kid.node, 0, 0);
    return out;
  } finally { Date.now = realNow; }
}
