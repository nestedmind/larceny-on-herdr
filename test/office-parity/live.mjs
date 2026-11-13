#!/usr/bin/env node
// The live part of the office parity check: measures a real shot of the herdr-app window. It finds the floor's edges,
// the wall gaps (doors), the desks and each person's centre by colour in the pixels, and compares them with the floor plan
// the office's own crew.js makes for that floor. Where the floor and the people disagree, that is the fault: a person
// drawn off their seat, by an amount that grows with x when the floor and the people are on different scales.
//
// Exits 0 when everything is within --tol px, 1 when something is off, 2 when it could not run, 3 when the window is
// not repainting (two shots a second apart are identical): bring the herdr window to the front and run it again.
//
//   node test/office-parity/live.mjs [--shot FILE] [--mod DIR] [--proto FILE] [--tol PX] [--tol-y PX] [--out DIR] [--all]
//
// Light theme only (the dark theme dims the floor). People who are walking are not on a seat and show as off.

import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Chrome } from "./chrome.mjs";
import { loadOffice } from "./office.mjs";
import { DEFAULT_PROTO, openPrototype } from "./proto.mjs";

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

// In the page: the shot is decoded once (window.S), then asked questions.
const PAGE = `
window.load = async (url) => {
  const img = new Image(); img.src = url; await img.decode();
  const c = document.createElement("canvas"); c.width = img.width; c.height = img.height;
  const x = c.getContext("2d", { willReadFrequently: true }); x.drawImage(img, 0, 0);
  window.S = { w: img.width, h: img.height, d: x.getImageData(0, 0, img.width, img.height).data };
  return { w: S.w, h: S.h };
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
  if (above === undefined || below === undefined) return { r, u0, bands, error: "the walls above and below the corridor are not both in view" };
  const H = ((below - above) / u0 + 1) * 288 / 40;
  // The outer walls, on a row through the top rooms just above the corridor: the first and last wall pieces 3 to 5 units wide.
  const y = Math.round(above - 8 * u0);
  const walls = runs(y, wall, 2, 0, S.w).filter((q) => q[1] - q[0] >= 3 * u0 && q[1] - q[0] <= 5 * u0);
  if (walls.length < 2) return { r, u0, bands, error: "the floor outer walls are not both in view (u0 " + u0.toFixed(2) + ", row " + y + ", runs " + JSON.stringify(runs(y, wall, 2, 0, S.w).slice(0, 4)) + ", bands " + JSON.stringify(bands) + ", runner " + JSON.stringify(r) + ")" };
  return { r, u0, bands, above, below, H, x: walls[0][0], w: walls[walls.length - 1][1] - walls[0][0], row: y, hpx: H * u0 };
};
// Wall pieces 1.5 to 4 world units wide along row y: the walls between rooms.
window.dividers = (y, u, f, wall) => runs(y, wall, 2, f.x + 6 * u, f.x + f.w - 6 * u).filter((q) => q[1] - q[0] >= 1.5 * u && q[1] - q[0] <= 4 * u).map((q) => (q[0] + q[1]) / 2);
window.gaps = (y, u, f, wall) => runs(y, wall, 2, f.x + 5 * u, f.x + f.w - 5 * u, true).filter((q) => q[1] - q[0] >= 10 * u).map((q) => (q[0] + q[1]) / 2);
// Connected pieces of colour c inside the floor, as boxes.
window.pieces = (c, t, f, minArea) => {
  const W = S.w, mark = new Uint8Array(W * S.h), out = [];
  const X0 = Math.max(0, f.x), X1 = Math.min(S.w, f.x + f.w), Y0 = Math.max(0, f.y), Y1 = Math.min(S.h, f.y + f.h);
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

function takeShot(file) {
  execFileSync("herdr-app", ["shot", file], { stdio: "ignore" });
}

async function main() {
  const out = opt("out", mkdtempSync(join(tmpdir(), "office-parity-live-")));
  mkdirSync(out, { recursive: true });
  let shot = opt("shot", null);
  let live = false;
  if (!shot) {
    const a = join(out, "shot-a.png"), b = join(out, "shot-b.png");
    takeShot(a); await sleep(1200); takeShot(b);
    if (readFileSync(a).equals(readFileSync(b))) {
      console.error("The window is not repainting: two shots a second apart are identical, so they are not live frames. Bring the herdr window to the front and run this again.");
      return 3;
    }
    shot = b; live = true;
  } else console.log("analysing " + shot + " (a file you gave: not checked for being live)");

  const office = await loadOffice(resolve(opt("mod", join(here, "..", "..", "office", "crew-office"))));
  const chrome = await Chrome.launch({ width: 800, height: 600 });
  try {
    await chrome.open("about:blank");
    await chrome.eval(PAGE);
    const size = await chrome.eval(`load("data:image/png;base64,${readFileSync(shot).toString("base64")}")`);
    const wall = JSON.stringify(WALL);
    const loc = await chrome.eval(`locate(${JSON.stringify([0xc0, 0x50, 0x4a])}, ${wall})`);
    if (!loc || loc.error) { console.error("Could not place the floor in the shot: " + (loc ? loc.error : "no corridor runner found") + ". Is the office tab showing, in the light theme?"); return 2; }
    // The floor's height in px, then its shape: crew.js makes the floor's W/H the pane's aspect, so the same aspect gives the same plan.
    const fh = loc.hpx;
    const aspect = loc.w / fh;
    // The room dividers on a row through the top rooms give the number of repos: rooms = repos + 2, dividers = rooms - 1.
    const rough = { x: loc.x, y: 0, w: loc.w, h: fh };
    const divs = await chrome.eval(`dividers(${loc.row}, ${loc.u0}, ${JSON.stringify(rough)}, ${wall})`);
    if (flag("debug")) console.log("dividers", JSON.stringify(divs), "u0", loc.u0, "row", loc.row, JSON.stringify(await chrome.eval(`runs(${loc.row}, ${wall}, 2, 0, S.w).slice(0, 12)`)));
    const n = Math.max(1, divs.length - 1);
    const names = Array.from({ length: n }, (_, i) => "r" + i);
    const W = office.crew.worldFor(names, aspect);
    const u = loc.w / W.W;
    // The floor's top: the wall band above the corridor sits at the end of the top rooms.
    const f = { x: loc.x, y: Math.round(loc.above - W.corr.y * u), w: Math.round(loc.w), h: Math.round(W.H * u) };
    const world = (px, py) => ({ x: (px - f.x) / u, y: (py - f.y) / u });
    console.log(`shot ${size.w}x${size.h}${live ? " (live: two shots differed)" : ""}`);
    console.log(`floor: ${f.w} x ${f.h} px at (${f.x}, ${f.y}); ${n} repos; plan ${W.W.toFixed(1)} x ${W.H.toFixed(1)} units; ${u.toFixed(3)} px a unit`);

    const findings = [];
    const note = (group, id, off, text) => { if (Math.abs(off) > (/ y$/.test(id) ? TOL_Y : TOL)) findings.push({ group, id, off: +off.toFixed(1), text }); };

    // Doors: gaps in the wall between each row of rooms and the corridor.
    const rows = [["top", W.corr.y], ["bottom", W.corr.y + W.corr.h - 1.2]];
    for (const [row, wy] of rows) {
      const got = (await chrome.eval(`gaps(${Math.round(f.y + wy * u)}, ${u}, ${JSON.stringify(f)}, ${wall})`)).map((c) => world(c, 0).x);
      const want = W.rooms.filter((r) => r.row === row).map((r) => r.door);
      for (const w of want) {
        const near = got.reduce((b, g) => (b === null || Math.abs(g - w) < Math.abs(b - w) ? g : b), null);
        if (near === null) { findings.push({ group: "doors", id: row + "@" + w.toFixed(0), off: Infinity, text: "no gap found" }); continue; }
        note("doors", row + " door at " + w.toFixed(1), (near - w) * u, `gap centre ${near.toFixed(1)} units, plan ${w.toFixed(1)}`);
      }
    }

    // Desks: pieces of desk colour, each matched to the nearest desk of the plan.
    const pieces = await chrome.eval(`pieces(${JSON.stringify(DESK)}, 2, ${JSON.stringify(f)}, ${Math.round(u * u * 40)})`);
    for (const d of [...W.desks, W.mattDesk]) {
      const cx = d.x + d.w / 2, cy = d.y + d.h / 2;
      let best = null;
      for (const p of pieces) {
        const c = world((p.x0 + p.x1) / 2, (p.y0 + p.y1) / 2);
        const dist = Math.hypot(c.x - cx, c.y - cy);
        if (dist < 12 && (!best || dist < best.dist)) best = { dist, c, p };
      }
      if (!best) { findings.push({ group: "desks", id: d.key, off: Infinity, text: "no desk found near " + cx.toFixed(0) + "," + cy.toFixed(0) }); continue; }
      note("desks", d.key + " x", (best.c.x - cx) * u, `centre ${best.c.x.toFixed(1)}, plan ${cx.toFixed(1)}`);
      note("desks", d.key + " y", (best.c.y - cy) * u, `centre ${best.c.y.toFixed(1)}, plan ${cy.toFixed(1)}`);
    }

    // People: the biggest piece of each person's shirt colour. Each is compared with the seat or spot of the plan
    // nearest to it (up and down count three times: the offset being looked for is sideways).
    const places = [...W.desks, W.mattDesk].map((d) => d.seat).concat(Object.values(W.spots).flat(), Object.values(W.meetSeats), [W.bed]);
    const fit = [];
    for (const c of office.crew.CAST.filter((q) => q.id !== "dog")) {
      const shirt = office.crew.look(c.id)[2];
      const rgb = [1, 3, 5].map((i) => parseInt(shirt.slice(i, i + 2), 16));
      const found = (await chrome.eval(`pieces(${JSON.stringify(rgb)}, 3, ${JSON.stringify(f)}, ${Math.round(u * u * 12)})`)).sort((a, b) => b.n - a.n)[0];
      if (!found) continue;
      const at = world((found.x0 + found.x1) / 2, (found.y0 + found.y1) / 2);
      let best = null;
      for (const p of places) { const dist = Math.abs(at.x - p.x) + 3 * Math.abs(at.y - p.y); if (!best || dist < best.dist) best = { dist, p }; }
      const dx = (at.x - best.p.x) * u, dy = (at.y - best.p.y) * u;
      fit.push({ id: c.id, x: best.p.x, dx: at.x - best.p.x });
      note("people", c.id + " x", dx, `centre ${at.x.toFixed(1)}, nearest place ${best.p.x.toFixed(1)}`);
      note("people", c.id + " y", dy, `centre ${at.y.toFixed(1)}, nearest place ${best.p.y.toFixed(1)}`);
    }
    // dx = slope * x + base, by least squares: a scale difference between the floor and the people shows as slope.
    if (fit.length >= 3) {
      const mx = fit.reduce((s, p) => s + p.x, 0) / fit.length, my = fit.reduce((s, p) => s + p.dx, 0) / fit.length;
      const sxx = fit.reduce((s, p) => s + (p.x - mx) ** 2, 0);
      const slope = sxx ? fit.reduce((s, p) => s + (p.x - mx) * (p.dx - my), 0) / sxx : 0;
      const base = my - slope * mx;
      console.log(`people: sideways offset = ${(slope * 100).toFixed(1)}% of x ${base < 0 ? "-" : "+"} ${Math.abs(base).toFixed(1)} units (${fit.length} people; at the plan's right edge ${(slope * W.W + base).toFixed(1)} units, ${((slope * W.W + base) * u).toFixed(0)} px)`);
    }

    const shown = flag("all") ? Infinity : 10;
    const groups = new Map();
    for (const x of findings) (groups.get(x.group) || groups.set(x.group, []).get(x.group)).push(x);
    for (const [g, list] of groups) {
      console.log(`${g}: ${list.length} off by more than the limit (${TOL} px across, ${TOL_Y} px down)`);
      for (const x of list.slice(0, shown)) console.log(`    ${x.id}: off ${x.off} px (${x.text})`);
      if (list.length > shown) console.log(`    ... ${list.length - shown} more (--all lists them)`);
    }

    // The prototype at 50% over the shot's floor, and the two differenced.
    const proto = await openPrototype(opt("proto", DEFAULT_PROTO));
    try {
      const canvas = await proto.canvas({});
      copyFileSync(shot, join(out, "shot.png"));
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
    } finally { proto.close(); }
    console.log(`images (overlay: the prototype at 50% over the floor in the shot; diff): ${out}`);
    console.log(findings.length ? `\nFAIL: ${findings.length} measurements off by more than the limit` : "\nPASS: the shot matches the plan within the limit");
    return findings.length ? 1 : 0;
  } finally { chrome.close(); }
}

main().then((c) => process.exit(c), (e) => { console.error("office-parity live could not run: " + e.message); process.exit(2); });
