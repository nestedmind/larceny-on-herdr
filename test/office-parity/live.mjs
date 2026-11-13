#!/usr/bin/env node
// The live part of the office parity check: measures a real shot of the herdr-app window against the floor plan the
// office's own layout makes for the crew that is really running. It finds the floor, the wall gaps (doors), the desks and
// each person (by the prototype's colour for them) in the pixels, and compares each with where it should be. Each person
// is compared with their OWN place in the plan, not with the nearest seat. A person who cannot be found is a finding.
// A floor and people on different scales show as a sideways offset that grows with x; the report prints it as a share of x.
//
// The crew comes from `hc` (hc ls --json, hc get for the labels) and the repos from `loh status --repos`, or from a file
// given with --crew: { "terminals": [ ...as herdr gives them: address, name, state, agent, cwd, labels, status ], "repos": [ ... ] }.
//
// Exit 0: everything within the limit. 1: something is off (or a person was not found). 2: could not run. 3: the window is
// not repainting: two shots a second apart show the same floor (the rest of the window is not compared), so they are not
// live frames. Bring the herdr window to the front and run it again.
//
//   node test/office-parity/live.mjs [--shot FILE | --frames A B] [--crew FILE] [--workspace NAME] [--mod DIR] [--proto FILE]
//                                    [--tol PX] [--tol-y PX] [--out DIR] [--all]
//
// --shot analyses one file (not checked for being live; it needs --crew). --frames checks two files for a repaint, as live does.
// Light theme only (the dark theme dims the floor). Someone who is walking is not on their seat and shows as off.

import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Chrome } from "./chrome.mjs";
import { loadOffice } from "./office.mjs";
import { DEFAULT_PROTO, openPrototype, paletteOf } from "./proto.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf("--" + name); return i >= 0 ? args[i + 1] : fallback; };
const flag = (name) => args.includes("--" + name);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const TOL = parseFloat(opt("tol", "2")); // px in the shot: a person's centre is measured by colour, so 1 px is below its noise
// Vertical positions are looser: they hang on a floor top that is worked out from the corridor when the stage crops it off, and a typing person's arms pull the shirt-coloured centre towards the desk.
const TOL_Y = parseFloat(opt("tol-y", "20"));
const WALL = [0x2b, 0x2f, 0x3a];
const DESK = [0xf6, 0xf1, 0xe8];
const RUNNER = [0xc0, 0x50, 0x4a];
const MIN_PEOPLE = 3; // fewest people that give a sideways trend

// In the page: the shots are decoded once (window.IMG.a, .b; S is the one analysed), then asked questions.
const PAGE = `
window.IMG = {};
window.load = async (url, key) => {
  const img = new Image(); img.src = url; await img.decode();
  const c = document.createElement("canvas"); c.width = img.width; c.height = img.height;
  const x = c.getContext("2d", { willReadFrequently: true }); x.drawImage(img, 0, 0);
  IMG[key] = { w: img.width, h: img.height, d: x.getImageData(0, 0, img.width, img.height).data };
  if (key === "b") window.S = IMG.b;
  return { w: img.width, h: img.height };
};
// How many pixels inside box f differ between the two shots.
window.changed = (f) => {
  const A = IMG.a, B = IMG.b;
  if (!A || A.w !== B.w || A.h !== B.h) return -1;
  let n = 0;
  for (let y = Math.max(0, f.y); y < Math.min(B.h, f.y + f.h); y++) for (let x = Math.max(0, f.x); x < Math.min(B.w, f.x + f.w); x++) {
    const i = (y * B.w + x) * 4;
    if (A.d[i] !== B.d[i] || A.d[i + 1] !== B.d[i + 1] || A.d[i + 2] !== B.d[i + 2]) n++;
  }
  return n;
};
const near = (i, c, t) => Math.abs(S.d[i] - c[0]) <= t && Math.abs(S.d[i + 1] - c[1]) <= t && Math.abs(S.d[i + 2] - c[2]) <= t;
// Runs of pixels matching colour c (or not matching, when inv) along row y between x0 and x1.
window.runs = (y, c, t, x0, x1, inv) => {
  y = Math.round(y); x0 = Math.max(0, Math.round(x0)); x1 = Math.min(S.w, Math.round(x1));
  const out = []; let s = -1;
  for (let x = x0; x <= x1; x++) {
    const hit = x < x1 && near((y * S.w + x) * 4, c, t) !== !!inv;
    if (hit && s < 0) s = x; else if (!hit && s >= 0) { out.push([s, x]); s = -1; }
  }
  return out;
};
// The floor can run off the stage (its top may be cropped), so its box is built from what is always in view: the corridor.
// The runner down the corridor is 13 units tall (that gives the scale roughly), the wall bands above and below the
// corridor are (corridor height - 1) units apart, and the corridor is 40/288 of the floor's height; the left and right
// outer walls give the width.
window.locate = (edge, wall) => {
  const r = pieces(edge, 2, { x: 0, y: 0, w: S.w, h: S.h }, 400).sort((a, b) => (b.x1 - b.x0) - (a.x1 - a.x0))[0];
  if (!r) return null;
  const u0 = (r.y1 - r.y0) / 13;
  const lo = Math.max(0, Math.round(r.y0 - 40 * u0)), hi = Math.min(S.h, Math.round(r.y1 + 40 * u0));
  const bands = []; let s = -1;
  for (let y = lo; y <= hi; y++) {
    const long = y < hi && runs(y, wall, 2, r.x0, r.x1).some((q) => q[1] - q[0] > 10 * u0);
    if (long && s < 0) s = y; else if (!long && s >= 0) { bands.push((s + y) / 2); s = -1; }
  }
  const mid = (r.y0 + r.y1) / 2;
  const above = bands.filter((b) => b < mid).pop(), below = bands.filter((b) => b > mid)[0];
  if (above === undefined || below === undefined) return { error: "the walls above and below the corridor are not both in view" };
  const H = ((below - above) / u0 + 1) * 288 / 40;
  // The outer walls, on a row through the top rooms just above the corridor: the first and last wall pieces 3 to 5 units wide.
  const y = Math.round(above - 8 * u0);
  const walls = runs(y, wall, 2, 0, S.w).filter((q) => q[1] - q[0] >= 3 * u0 && q[1] - q[0] <= 5 * u0);
  if (walls.length < 2) return { error: "the floor's outer walls are not both in view" };
  return { u0, above, x: walls[0][0], w: walls[walls.length - 1][1] - walls[0][0], hpx: H * u0 };
};
window.gaps = (y, u, f, wall) => runs(y, wall, 2, f.x + 5 * u, f.x + f.w - 5 * u, true).filter((q) => q[1] - q[0] >= 10 * u).map((q) => (q[0] + q[1]) / 2);
// Connected pieces of colour c inside box f, as boxes.
window.pieces = (c, t, f, minArea) => {
  const W = S.w, mark = new Uint8Array(W * S.h), out = [];
  const X0 = Math.max(0, Math.round(f.x)), X1 = Math.min(S.w, Math.round(f.x + f.w)), Y0 = Math.max(0, Math.round(f.y)), Y1 = Math.min(S.h, Math.round(f.y + f.h));
  for (let y = Y0; y < Y1; y++) for (let x = X0; x < X1; x++) {
    const p = y * W + x;
    if (mark[p] || !near(p * 4, c, t)) continue;
    const stack = [p]; mark[p] = 1;
    let x0 = x, x1 = x, y0 = y, y1 = y, n = 0;
    while (stack.length) {
      const q = stack.pop(); n++;
      const qx = q % W, qy = (q - qx) / W;
      if (qx < x0) x0 = qx; if (qx > x1) x1 = qx; if (qy < y0) y0 = qy; if (qy > y1) y1 = qy;
      for (const m of [q - 1, q + 1, q - W, q + W]) {
        const mx = m % W, my = (m - mx) / W;
        if (mx < X0 || mx >= X1 || my < Y0 || my >= Y1 || mark[m] || !near(m * 4, c, t)) continue;
        mark[m] = 1; stack.push(m);
      }
    }
    if (n >= minArea) out.push({ x0, y0, x1: x1 + 1, y1: y1 + 1, n });
  }
  return out;
};
`;

const takeShot = (file) => execFileSync("herdr-app", ["shot", file], { stdio: "ignore" });
const dataUrl = (file) => "data:image/png;base64," + readFileSync(file).toString("base64");
const run = (cmd, argv, cwd) => execFileSync(cmd, argv, { encoding: "utf8", cwd, timeout: 8000, stdio: ["ignore", "pipe", "ignore"] });

/** The crew as the office's herdr module gives it: from a file, or from hc and loh. */
function readCrew(office) {
  const file = opt("crew", null);
  if (file) { const j = JSON.parse(readFileSync(file, "utf8")); return { terminals: j.terminals || j, repos: j.repos || [] }; }
  const list = JSON.parse(run("hc", ["ls", "--json"])).terminals || [];
  const terminals = list.filter((t) => t.state === "live").map((t) => {
    const g = JSON.parse(run("hc", ["get", t.address]));
    return { address: t.address, name: t.name, state: t.state, agent: t.agent, cwd: t.cwd, labels: g.labels || {}, status: g.status };
  });
  const ws = office.crew.pickWorkspace(terminals, opt("workspace", null));
  const lead = office.crew.crewOf(terminals, ws).find((a) => a.cwd);
  let repos = [];
  try { repos = office.crew.repoNames(run(join(here, "..", "..", "bin", "loh"), ["status", "--repos"], lead && lead.cwd)); } catch (_) { console.error("loh status --repos failed: repo rooms come from the coders' tasks only"); }
  return { terminals, repos };
}

async function main() {
  const out = opt("out", mkdtempSync(join(tmpdir(), "office-parity-live-")));
  mkdirSync(out, { recursive: true });
  let a = null, b = opt("shot", null), live = false;
  if (flag("frames")) { a = args[args.indexOf("--frames") + 1]; b = args[args.indexOf("--frames") + 2]; }
  else if (!b) {
    a = join(out, "shot-a.png"); b = join(out, "shot-b.png");
    takeShot(a); await sleep(1200); takeShot(b);
    live = true;
  } else console.log("analysing " + b + " (a file you gave: not checked for being live)");
  const stale = "The window is not repainting: the floor is the same in two shots a second apart, so they are not live frames. Bring the herdr window to the front and run this again.";
  if (a && readFileSync(a).equals(readFileSync(b))) { console.error(stale); return 3; }
  if (!live && !a && !opt("crew", null)) { console.error("--shot needs --crew FILE: who should be where comes from the crew"); return 2; }

  const office = await loadOffice(resolve(opt("mod", join(here, "..", "..", "office", "crew-office"))));
  const proto = await openPrototype(opt("proto", DEFAULT_PROTO));
  const chrome = await Chrome.launch({ width: 800, height: 600 });
  try {
    await chrome.open("about:blank");
    await chrome.eval(PAGE);
    const size = await chrome.eval(`load(${JSON.stringify(dataUrl(b))}, "b")`);
    if (a) await chrome.eval(`load(${JSON.stringify(dataUrl(a))}, "a")`);
    const wall = JSON.stringify(WALL);
    const loc = await chrome.eval(`locate(${JSON.stringify(RUNNER)}, ${wall})`);
    if (!loc || loc.error) { console.error("Could not place the floor in the shot: " + (loc ? loc.error : "no corridor runner found") + ". Is the office tab showing, in the light theme?"); return 2; }
    // Is the floor repainting? Only the floor's own area is compared, so another pane's cursor cannot make a stale floor look live.
    if (a) {
      const box = { x: loc.x, y: Math.round(loc.above - loc.hpx * 120 / 288), w: loc.w, h: Math.round(loc.hpx) };
      if ((await chrome.eval(`changed(${JSON.stringify(box)})`)) === 0) { console.error(stale); return 3; }
    }

    // Who should be where: the office's own layout for the crew that is really there, on a floor of the shot's shape.
    const { terminals, repos } = readCrew(office);
    const workspace = office.crew.pickWorkspace(terminals, opt("workspace", null));
    const crew = office.crew.crewOf(terminals, workspace);
    if (!crew.length) { console.error("No crew found" + (workspace ? " in workspace " + workspace : "") + ": nobody to look for."); return 2; }
    const L = office.crew.layoutCrew(crew, repos, loc.w / loc.hpx);
    const u = loc.w / L.W;
    const f = { x: loc.x, y: Math.round(loc.above - L.corr.y * u), w: Math.round(loc.w), h: Math.round(L.H * u) };
    const world = (px, py) => ({ x: (px - f.x) / u, y: (py - f.y) / u });
    console.log(`shot ${size.w}x${size.h}${live ? " (live: the floor changed between two shots)" : ""}`);
    console.log(`floor: ${f.w} x ${f.h} px at (${f.x}, ${f.y}); ${L.rooms.filter((r) => r.kind === "repo").length} repos; plan ${L.W.toFixed(1)} x ${L.H.toFixed(1)} units; ${u.toFixed(3)} px a unit; crew of ${crew.length} in ${workspace}`);

    const findings = [];
    const note = (group, id, off, text) => { if (Math.abs(off) > (/ y$/.test(id) ? TOL_Y : TOL)) findings.push({ group, id, off: +off.toFixed(1), text }); };
    const lost = (group, id, text) => findings.push({ group, id, off: Infinity, text });

    // Doors: gaps in the wall between each row of rooms and the corridor.
    for (const [row, wy] of [["top", L.corr.y], ["bottom", L.corr.y + L.corr.h - 1.2]]) {
      const got = (await chrome.eval(`gaps(${Math.round(f.y + wy * u)}, ${u}, ${JSON.stringify(f)}, ${wall})`)).map((c) => world(c, 0).x);
      for (const w of L.rooms.filter((r) => r.row === row).map((r) => r.door)) {
        const nearest = got.reduce((best, g) => (best === null || Math.abs(g - w) < Math.abs(best - w) ? g : best), null);
        if (nearest === null) lost("doors", row + " door at " + w.toFixed(1), "no gap found");
        else note("doors", row + " door at " + w.toFixed(1), (nearest - w) * u, `gap centre ${nearest.toFixed(1)} units, plan ${w.toFixed(1)}`);
      }
    }

    // Desks: pieces of desk colour, each matched to the nearest desk of the plan.
    const pieces = await chrome.eval(`pieces(${JSON.stringify(DESK)}, 2, ${JSON.stringify(f)}, ${Math.round(u * u * 40)})`);
    for (const d of [...L.desks, L.mattDesk]) {
      const cx = d.x + d.w / 2, cy = d.y + d.h / 2;
      let best = null;
      for (const p of pieces) {
        const c = world((p.x0 + p.x1) / 2, (p.y0 + p.y1) / 2);
        const dist = Math.hypot(c.x - cx, c.y - cy);
        if (dist < 12 && (!best || dist < best.dist)) best = { dist, c };
      }
      if (!best) { lost("desks", d.key, "no desk found near " + cx.toFixed(0) + "," + cy.toFixed(0)); continue; }
      note("desks", d.key + " x", (best.c.x - cx) * u, `centre ${best.c.x.toFixed(1)}, plan ${cx.toFixed(1)}`);
      note("desks", d.key + " y", (best.c.y - cy) * u, `centre ${best.c.y.toFixed(1)}, plan ${cy.toFixed(1)}`);
    }

    // People: each by their own colour (the prototype's shirt colour), looked for round where the plan puts them.
    // Someone not found is a finding; so is finding fewer than MIN_PEOPLE, which is too few to see a trend.
    const colours = paletteOf(proto.data.pal).people || {};
    const fit = [];
    for (const p of L.people.filter((q) => q.id !== "dog")) {
      const shirt = (colours[p.id] && colours[p.id].shirt) || office.crew.look(p.id.startsWith("x:") ? p.name : p.id)[2];
      const rgb = [1, 3, 5].map((i) => parseInt(shirt.slice(i, i + 2), 16));
      // Someone not running is drawn at 70%: the shirt is mixed with whatever floor or furniture is under them, so it is
      // looked for mixed with each colour their room has.
      const PAL = office.draw.PAL;
      const unders = { lounge: ["purple", "pouf1", "pouf2", "pouf3", "orange", "table", "sofa", "sofaDark"], kitchen: ["cream", "cream2", "sage", "table"], rest: ["teal", "bean", "fridge"], pong: ["green", "pong", "white"] };
      const wanted = p.dim ? (unders[p.place] || ["oak"]).map((k) => rgb.map((v, i) => Math.round(0.702 * v + 0.298 * parseInt(PAL[k].slice(1 + 2 * i, 3 + 2 * i), 16)))) : [rgb];
      const R = Math.max(40, 0.2 * p.x + 20); // units: room for a 20% offset at this x
      const win = { x: f.x + (p.x - R) * u, y: f.y + (p.y - R) * u, w: 2 * R * u, h: 2 * R * u };
      // Of the pieces of that colour, the one nearest to where the plan puts them.
      let found = null, nearest = Infinity;
      for (const c of wanted) {
        for (const m of await chrome.eval(`pieces(${JSON.stringify(c)}, ${p.dim ? 8 : 3}, ${JSON.stringify(win)}, ${Math.round(u * u * (p.dim ? 6 : 12))})`)) {
          const at = world((m.x0 + m.x1) / 2, (m.y0 + m.y1) / 2);
          const dist = Math.hypot(at.x - p.x, at.y - p.y);
          if (dist < nearest) { nearest = dist; found = m; }
        }
      }
      if (!found) { lost("people", p.id, `not found: no ${shirt} within ${R} units of the plan's ${p.x.toFixed(1)},${p.y.toFixed(1)}`); continue; }
      const at = world((found.x0 + found.x1) / 2, (found.y0 + found.y1) / 2);
      fit.push({ id: p.id, x: p.x, dx: at.x - p.x });
      note("people", p.id + " x", (at.x - p.x) * u, `centre ${at.x.toFixed(1)}, plan ${p.x.toFixed(1)}`);
      note("people", p.id + " y", (at.y - p.y) * u, `centre ${at.y.toFixed(1)}, plan ${p.y.toFixed(1)}`);
    }
    if (fit.length < MIN_PEOPLE) lost("people", "trend", `only ${fit.length} of ${L.people.length - 1} found: too few to measure the sideways offset`);
    else {
      // dx = slope * x + base, by least squares: a scale difference between the floor and the people shows as slope.
      const mx = fit.reduce((s, q) => s + q.x, 0) / fit.length, my = fit.reduce((s, q) => s + q.dx, 0) / fit.length;
      const sxx = fit.reduce((s, q) => s + (q.x - mx) ** 2, 0);
      const slope = sxx ? fit.reduce((s, q) => s + (q.x - mx) * (q.dx - my), 0) / sxx : 0;
      const base = my - slope * mx;
      console.log(`people: sideways offset = ${(slope * 100).toFixed(1)}% of x ${base < 0 ? "-" : "+"} ${Math.abs(base).toFixed(1)} units (${fit.length} of ${L.people.length - 1} found; at the plan's right edge ${(slope * L.W + base).toFixed(1)} units, ${((slope * L.W + base) * u).toFixed(0)} px)`);
    }

    const shown = flag("all") ? Infinity : 10;
    const groups = new Map();
    for (const x of findings) (groups.get(x.group) || groups.set(x.group, []).get(x.group)).push(x);
    for (const [g, list] of groups) {
      console.log(`${g}: ${list.length} off by more than the limit (${TOL} px across, ${TOL_Y} px down) or not found`);
      for (const x of list.slice(0, shown)) console.log(`    ${x.id}: ${x.off === Infinity ? "not found" : "off " + x.off + " px"} (${x.text})`);
      if (list.length > shown) console.log(`    ... ${list.length - shown} more (--all lists them)`);
    }

    // The prototype at 50% over the shot's floor, and the two differenced.
    const canvas = await proto.canvas({});
    copyFileSync(b, join(out, "shot.png"));
    const crop = (extra) => `<!doctype html><meta charset="utf-8"><body style="margin:0"><div style="position:relative;width:${f.w}px;height:${f.h}px;background:url(shot.png) -${f.x}px -${f.y}px;overflow:hidden">${extra}</div>`;
    const img = (style) => `<img src="${canvas}" style="position:absolute;left:0;top:0;width:${f.w}px;height:${f.h}px;${style}">`;
    const view = await Chrome.launch({ width: f.w, height: f.h });
    try {
      for (const [kind, html] of [["overlay", crop(img("opacity:.5"))], ["diff", crop(img("mix-blend-mode:difference"))]]) {
        writeFileSync(join(out, kind + ".html"), html);
        await view.open("file://" + join(out, kind + ".html"));
        await view.shot(join(out, `live-${kind}.png`), f.w, f.h);
      }
    } finally { view.close(); }
    console.log(`images (overlay: the prototype at 50% over the floor in the shot; diff): ${out}`);
    console.log(findings.length ? `\nFAIL: ${findings.length} measurements off by more than the limit or not found` : "\nPASS: the shot matches the plan within the limit");
    return findings.length ? 1 : 0;
  } finally { chrome.close(); proto.close(); }
}

main().then((c) => process.exit(c), (e) => { console.error("office-parity live could not run: " + e.message); process.exit(2); });
