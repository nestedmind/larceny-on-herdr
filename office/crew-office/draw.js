// Drawing for the crew office: the prototype's canvas shapes ported onto herdr-app's PathBuilder.
// Every shape is one `window.paint_path(path, colour)` element whose path is in pixels, relative to
// the element's own box. A Layer is such a box with its shapes in world units (the prototype's
// units: the floor is 288 high). No state lives here: main.js passes everything in, and the pure
// placement logic is in crew.js.
//
// Motion is native only: .loop() for gaits, typing and the ball, .transition() on the wrapper that
// moves a person. What the API cannot do is listed in office/README.md.

import { div, PathBuilder } from "gpui-kit";
import { look, hash } from "./crew.js";

// The prototype's floor palette (its --fl-* and --st-* tokens). The same in light and dark: dark
// mode darkens the floor with the night shading instead.
export const PAL = {
  wall: "#2b2f3a", window: "#a9d8f2", oak: "#d8a874", oakLine: "#c8965f", corr: "#c99a68", corrLine: "#b98a5a",
  runner: "#c0504a", runnerEdge: "#8f3530", slate: "#5a7a9a", slateLine: "#52708e", rugRed: "#b8433c", rugIn: "#e9dcc4",
  woodDark: "#5a3c2a", chair: "#2e3340", screen: "#1d2230", screenInk: "#a9d8f2", cream: "#f3ead6", cream2: "#e4d6b8",
  counter: "#7f8b9b", counterTop: "#d8dde4", appliance: "#2e3340", fridge: "#eef2f6", sage: "#9cb89a", table: "#b98a5e",
  green: "#5f9a6a", greenLine: "#568d60", pong: "#2f7d4f", white: "#ffffff", purple: "#8a7aa8", purpleLine: "#7f6f9d",
  orange: "#e58a3a", sofa: "#4f78b8", sofaDark: "#3d6299", pouf1: "#e8b94a", pouf2: "#d9607a", pouf3: "#4fb3a6",
  teal: "#6f9e9c", tealLine: "#67928f", bean: "#ece0c6", mats: ["#b8a7dd", "#a6d2a4", "#e0c48f", "#9cc3d9"],
  desk: "#f6f1e8", deskEdge: "#d9cfbf", monitor: "#262a35", plant: "#4f9a55", plant2: "#6dbb5f", pot: "#c46a3c",
  books: ["#d9534f", "#f0ad4e", "#5bc0de", "#5cb85c", "#8e6bbf"], shelf: "#6b4a32",
  dogbed: "#c0504a", dogbedIn: "#f0e0c8", dog: "#d9a066", dogDark: "#8a5a2b", shade: "#0000002e", ball: "#ffffff",
  paddle: "#d9483b", eye: "#1c1c22", accent: "#d9573b",
  work: "#3fae69", perm: "#e7a43a", q: "#4f8ff0", esc: "#d0509f", red: "#d9483b", idle: "#aab2bf",
  label: "#2b2f3ac7", labelInk: "#f6f3ec", chip: "#2b2f3a", chipInk: "#f6f3ec",
};

export const BLOCKED = { permission: [PAL.perm, "allow?"], question: [PAL.q, "?"], other: [PAL.esc, "!"] };
const STATE_RING = { working: PAL.work, done: PAL.work };
const BOX = 30; // half the side of a person's box, in world units: room for a bubble and a flag

const TAU = Math.PI * 2;

/** A box on the floor holding shapes in world units; each shape is its own paint_path element. */
export class Layer {
  constructor(k, x, y, w, h, alpha = "") {
    this.k = k; this.x = x; this.y = y; this.w = w; this.h = h; this.alpha = alpha; this.ops = [];
  }
  X(x) { return (x - this.x) * this.k; }
  Y(y) { return (y - this.y) * this.k; }
  c(fill) { return this.alpha && fill.length === 7 ? fill + this.alpha : fill; }
  add(path, fill) { this.ops.push([path, this.c(fill)]); return this; }
  rect(x, y, w, h, fill) {
    const X = this.X(x), Y = this.Y(y), W = w * this.k, H = h * this.k;
    return this.add(PathBuilder.fill().move_to(X, Y).line_to(X + W, Y).line_to(X + W, Y + H).line_to(X, Y + H).close().build(), fill);
  }
  rr(x, y, w, h, r, fill) {
    const X = this.X(x), Y = this.Y(y), W = w * this.k, H = h * this.k;
    const R = Math.min(r * this.k, W / 2, H / 2);
    const b = PathBuilder.fill().move_to(X + R, Y).line_to(X + W - R, Y).arc_to(R, R, 0, false, true, X + W, Y + R)
      .line_to(X + W, Y + H - R).arc_to(R, R, 0, false, true, X + W - R, Y + H)
      .line_to(X + R, Y + H).arc_to(R, R, 0, false, true, X, Y + H - R)
      .line_to(X, Y + R).arc_to(R, R, 0, false, true, X + R, Y).close();
    return this.add(b.build(), fill);
  }
  ell(x, y, rx, ry, fill) {
    const X = this.X(x), Y = this.Y(y), RX = rx * this.k, RY = ry * this.k;
    return this.add(PathBuilder.fill().move_to(X + RX, Y).arc_to(RX, RY, 0, false, true, X - RX, Y).arc_to(RX, RY, 0, false, true, X + RX, Y).close().build(), fill);
  }
  circ(x, y, r, fill) { return this.ell(x, y, r, r, fill); }
  ring(x, y, r, stroke, lw) {
    const X = this.X(x), Y = this.Y(y), R = r * this.k;
    return this.add(PathBuilder.stroke(lw * this.k).move_to(X + R, Y).arc_to(R, R, 0, false, true, X - R, Y).arc_to(R, R, 0, false, true, X + R, Y).close().build(), stroke);
  }
  line(x1, y1, x2, y2, stroke, lw) {
    return this.add(PathBuilder.stroke(lw * this.k).move_to(this.X(x1), this.Y(y1)).line_to(this.X(x2), this.Y(y2)).build(), stroke);
  }
  poly(points, fill) {
    return this.add(PathBuilder.fill().add_polygon(points.map(([x, y]) => [this.X(x), this.Y(y)]), true).build(), fill);
  }
  // A circular sector of the head, as the prototype's hair: arc a0 to a1 (radians, clockwise on screen).
  fan(cx, cy, r, a0, a1, fill, from) {
    const p = (a) => [this.X(cx + Math.cos(a) * r), this.Y(cy + Math.sin(a) * r)];
    const [sx, sy] = p(a0), [ex, ey] = p(a1);
    const R = r * this.k;
    const b = PathBuilder.fill().move_to(...(from ? [this.X(from[0]), this.Y(from[1])] : [sx, sy]));
    if (from) b.line_to(sx, sy);
    b.arc_to(R, R, 0, a1 - a0 > Math.PI, true, ex, ey);
    return this.add(b.close().build(), fill);
  }
  /** The box as an element. Its shapes are absolute children that each fill it. */
  el() {
    return div().absolute().left(this.x * this.k).top(this.y * this.k).w(this.w * this.k).h(this.h * this.k)
      .children(this.ops.map(([path, fill]) => window.paint_path(path, fill).absolute().left(0).top(0).size_full()));
  }
}

// ---------- the floor ----------

function planks(g, r, base, line, step) {
  g.rect(r.x, r.y, r.w, r.h, base);
  for (let y = r.y + step, i = 0; y < r.y + r.h; y += step, i++) {
    g.rect(r.x, y, r.w, 0.5, line);
    for (let x = r.x + ((i * 17) % 36); x < r.x + r.w; x += 36) g.rect(x, y - step, 0.5, step, line);
  }
}
function grid(g, r, base, line, step) {
  g.rect(r.x, r.y, r.w, r.h, base);
  for (let y = r.y + step; y < r.y + r.h; y += step) g.rect(r.x, y, r.w, 0.5, line);
  for (let x = r.x + step; x < r.x + r.w; x += step) g.rect(x, r.y, 0.5, r.h, line);
}
function plant(g, x, y, r) {
  g.circ(x, y, r, PAL.pot);
  g.circ(x, y, r * 0.78, PAL.plant);
  g.circ(x - r * 0.35, y - r * 0.3, r * 0.45, PAL.plant2);
  g.circ(x + r * 0.4, y + r * 0.2, r * 0.4, PAL.plant2);
}
function shelf(g, x, y, w, h) {
  g.rr(x, y, w, h, 1.5, PAL.shelf);
  let bx = x + 1.5, i = 0;
  while (bx < x + w - 3) {
    const bw = 2.2 + ((i * 7) % 3) * 0.7;
    g.rr(bx, y + 1, bw, h - 2, 0.5, PAL.books[i % 5]);
    bx += bw + 0.6; i++;
  }
}
const chairDot = (g, x, y) => g.circ(x, y, 4.6, PAL.chair);

function deskArt(g, d, mat) {
  g.rr(d.x, d.y, d.w, d.h, 2, PAL.desk);
  g.rect(d.x + 1, d.side === "n" ? d.y + d.h - 1 : d.y, d.w - 2, 1, PAL.deskEdge);
  const my = d.side === "n" ? d.y + d.h - 5 : d.y + 2;
  g.rr(d.cx - 7, my, 14, 3, 1, PAL.monitor);
  const ky = d.side === "n" ? d.y + 3 : d.y + d.h - 5;
  g.rr(d.cx - 5, ky, 10, 2.4, 0.8, PAL.counterTop);
  const props = [PAL.books[0], PAL.books[1], PAL.books[2], PAL.books[4]];
  const ph = hash(d.key);
  g.circ(d.x + (ph % 2 ? 4 : d.w - 4), ky + 1.2, 1.6, props[ph % 4]);
  if (mat) g.rr(d.x + (ph % 2 ? d.w - 8 : 3), ky - 0.2, 5, 3, 0.6, props[(ph >> 3) % 4]);
}

/** The rooms, walls, furniture and floors: everything that does not move. Built once per scale and plan. */
export function floorLayer(world, k) {
  const { W, H } = world;
  const g = new Layer(k, 0, 0, W, H);
  const R = (kind) => world.rooms.find((r) => r.kind === kind);
  const repos = world.rooms.filter((r) => r.kind === "repo");
  const leads = R("leads"), meet = R("meet"), matt = R("matt"), kitchen = R("kitchen"), lounge = R("lounge"), pong = R("pong"), rest = R("rest");
  const e = pong.x - 300;
  const topW = meet.x + meet.w;
  g.rect(0, 0, W, H, PAL.wall);
  [...repos, leads].forEach((r) => planks(g, r, PAL.oak, PAL.oakLine, 6));
  planks(g, matt, PAL.oak, PAL.oakLine, 6);
  grid(g, meet, PAL.slate, PAL.slateLine, 10);
  g.rect(kitchen.x, kitchen.y, kitchen.w, kitchen.h, PAL.cream);
  for (let y = kitchen.y; y < kitchen.y + kitchen.h; y += 8) {
    for (let x = kitchen.x; x < kitchen.x + kitchen.w; x += 8) {
      if (((x - kitchen.x) / 8 + (y - kitchen.y) / 8) % 2 === 0) g.rect(x, y, 8, 8, PAL.cream2);
    }
  }
  grid(g, pong, PAL.green, PAL.greenLine, 12);
  planks(g, lounge, PAL.purple, PAL.purpleLine, 8);
  grid(g, rest, PAL.teal, PAL.tealLine, 12);
  // corridor with its runner
  planks(g, { x: 0, y: 120, w: W, h: 40 }, PAL.corr, PAL.corrLine, 5);
  g.rr(6, 132, W - 12, 16, 3, PAL.runnerEdge);
  g.rr(7.5, 133.5, W - 15, 13, 2, PAL.runner);
  // walls
  const T = 4, t = 2.4;
  g.rect(0, 0, W, T, PAL.wall); g.rect(0, H - T, W, T, PAL.wall); g.rect(W - T, 0, T, H, PAL.wall);
  g.rect(0, 0, T, 126, PAL.wall); g.rect(0, 154, T, H - 154, PAL.wall);
  if (topW < W) g.rect(topW, 0, W - topW, 120, PAL.wall);
  [[[...repos, leads, meet], 118.8], [[matt, kitchen, lounge, pong, rest], 159.2 - t + 1]].forEach(([row, wy]) => {
    row.forEach((r) => {
      g.rect(r.x, wy, r.door - 9 - r.x, t, PAL.wall);
      g.rect(r.door + 9, wy, r.x + r.w - r.door - 9, t, PAL.wall);
      if (r.x > 0) g.rect(r.x - t / 2, r.y, t, r.h, PAL.wall);
    });
  });
  // windows on the outer walls
  [...repos, leads, meet].forEach((r) => g.rect(r.x + 14, 1.2, r.w - 28, 1.6, PAL.window));
  [matt, kitchen, lounge, pong, rest].forEach((r) => g.rect(r.x + 14, H - 2.8, r.w - 28, 1.6, PAL.window));
  g.rect(W - 2.8, 14, 1.6, 90, PAL.window); g.rect(W - 2.8, 176, 1.6, 96, PAL.window);
  g.rect(1.2, 14, 1.6, 90, PAL.window); g.rect(1.2, 176, 1.6, 96, PAL.window);
  g.rr(0, 128, 10, 24, 2, PAL.runnerEdge); // entrance
  // repo rooms: a pod mat under four desks, plants and shelves
  repos.forEach((r, i) => {
    const px = r.x + 75;
    g.rr(px - 44, 18, 88, 80, 10, PAL.mats[i % PAL.mats.length]);
    world.desks.filter((d) => d.room === r.key).forEach((d) => { chairDot(g, d.seat.x, d.seat.y); deskArt(g, d, true); });
    plant(g, r.x + 12, 108, 5); plant(g, r.x + 138, 12, 5);
    if (i % 2 === 0) shelf(g, r.x + 12, 6, 22, 7); else shelf(g, r.x + 112, 106, 26, 7);
  });
  // leads
  world.desks.filter((d) => d.room === "leads").forEach((d) => { chairDot(g, d.seat.x, d.seat.y); deskArt(g, d, false); });
  shelf(g, leads.x + 6, 6, 30, 7); plant(g, leads.x + 80, 108, 5); plant(g, leads.x + 8, 108, 4);
  // meeting room
  g.rr(meet.x + 12, 26, 66, 72, 6, PAL.rugRed); g.rr(meet.x + 15, 29, 60, 66, 4, PAL.rugIn);
  [[20, 50], [20, 66], [70, 50], [70, 66], [34, 32], [56, 32], [34, 86], [56, 86]].forEach(([x, y]) => chairDot(g, meet.x + x, y));
  g.rr(meet.x + 25, 40, 40, 36, 6, PAL.woodDark);
  g.rr(meet.x + 26, 6, 38, 11, 2, PAL.screen);
  plant(g, meet.x + 82, 108, 4.5);
  // Matt's desk near the entrance
  const md = world.mattDesk;
  g.rr(8, 240, 50, 36, 6, PAL.sage); g.rr(13, 245, 40, 26, 4, PAL.cream);
  chairDot(g, md.seat.x, md.seat.y);
  g.rr(md.x, md.y, md.w, md.h, 2, PAL.desk);
  g.rr(md.cx - 16, md.y + 2, 14, 3, 1, PAL.monitor); g.rr(md.cx + 2, md.y + 2, 14, 3, 1, PAL.monitor);
  g.rr(md.cx - 6, md.y + 10, 12, 2.4, 0.8, PAL.counterTop);
  g.circ(md.x + 4, md.y + 11, 1.7, PAL.books[1]);
  plant(g, 88, 278, 5); plant(g, 10, 170, 4);
  // kitchen
  [[99, 163, 39], [154, 163, 40]].forEach(([x, y, w]) => { g.rr(x, y, w, 11, 1.5, PAL.counter); g.rr(x + 1, y + 1, w - 2, 9, 1, PAL.counterTop); });
  g.circ(108, 168.5, 3, PAL.counter); g.circ(108, 168.5, 2, PAL.fridge);
  g.rr(118, 165, 9, 7, 1.2, PAL.appliance); g.circ(122.5, 168.5, 1.2, PAL.accent);
  g.circ(164, 168.5, 2.2, PAL.appliance); g.circ(172, 168.5, 2.2, PAL.appliance); g.rr(180, 165, 9, 7, 1.2, PAL.appliance);
  g.rr(175, 262, 18, 22, 2, PAL.fridge); g.rect(176, 270, 16, 0.6, PAL.counter); g.rect(189, 264, 0.8, 4, PAL.counter);
  g.circ(146, 231, 24, PAL.sage); g.circ(146, 231, 11, PAL.table); g.circ(146, 231, 2, PAL.fridge);
  plant(g, 102, 280, 4.5);
  // lounge
  g.rr(202, 168, 62, 14, 4, PAL.sofaDark); g.rr(204, 174, 58, 10, 3, PAL.sofa);
  g.ell(241, 228, 30, 19, PAL.orange); g.rr(228, 220, 26, 15, 4, PAL.table);
  g.circ(236, 226, 1.6, PAL.fridge); g.rr(242, 225, 7, 5, 0.8, PAL.books[2]);
  [[210, 228, PAL.pouf1], [272, 228, PAL.pouf2], [226, 258, PAL.pouf3], [254, 258, PAL.pouf1], [284, 200, PAL.pouf2]].forEach(([x, y, c]) => g.circ(x, y, 5.6, c));
  g.ell(world.bed.x, world.bed.y, 11, 8, PAL.dogbed); g.ell(world.bed.x, world.bed.y, 8, 5.6, PAL.dogbedIn);
  plant(g, 205, 278, 5); shelf(g, 222, 279, 30, 6);
  // ping pong
  g.rr(327 + e, 213, 42, 24, 2, PAL.pong);
  [[327, 213, 42, 0.7], [327, 236.3, 42, 0.7], [327, 213, 0.7, 24], [368.3, 213, 0.7, 24], [327, 224.7, 42, 0.5], [347.5, 210, 1.2, 30]].forEach(([x, y, w, h]) => g.rect(x + e, y, w, h, PAL.white));
  shelf(g, 306 + e, 276, 46, 7); shelf(g, 356 + e, 276, 34, 7);
  plant(g, 388 + e, 170, 4.5);
  // rest room
  world.spots.rest.forEach((p) => { g.rr(p.x - 12, p.y - 9, 24, 15, 4, PAL.bean); g.rr(p.x - 11, p.y - 8, 7, 13, 3, PAL.fridge); });
  plant(g, 470 + e, 278, 5); g.circ(438 + e, 226, 4, PAL.books[1]); g.circ(438 + e, 226, 2.4, PAL.fridge);
  return g;
}

// ---------- room labels and the wall screen (text, so plain elements) ----------

const pill = (text, x, y, k, bg, ink, size, center) => {
  const w = text.length * size * 0.62 + 12;
  return div().absolute().left(x * k - (center ? w / 2 : 0)).top(y * k).h(size + 5).px(6).rounded_full().bg(bg)
    .text_size(size).font_semibold().text_color(ink).whitespace_nowrap().child(text);
};

export function labels(world, k, crewCount) {
  const out = [];
  const size = Math.max(8, Math.min(11, 5 * k));
  const at = { meet: [6, 20], kitchen: [6, 178], lounge: [8, 161.5], leads: [6, 16], matt: [18, 172], pong: [6, 166], rest: [6, 166] };
  for (const r of world.rooms) {
    if (r.kind === "repo") { // the repo's chip sits under its pod
      out.push(pill(r.label, r.x + 75, 100, k, PAL.chip, PAL.chipInk, size, true));
      continue;
    }
    const [dx, dy] = at[r.kind] || [6, 6];
    out.push(pill(r.label.toUpperCase(), r.x + dx, dy, k, PAL.label, PAL.labelInk, Math.max(7, size - 1)));
  }
  const meet = world.rooms.find((r) => r.kind === "meet");
  out.push(div().absolute().left((meet.x + 30) * k).top(7.5 * k).text_size(Math.max(6, 5 * k)).font_semibold().text_color(PAL.screenInk).whitespace_nowrap().child(`${crewCount} on the crew`));
  return out;
}

// ---------- the moving parts ----------

const blink = (el) => el.loop("opacity", { from: 0.35, to: 0.95, period: 1000 });

/** The lit strip on a desk's monitor. `s` is work, perm, q, esc or dim. */
export function glow(d, s, k) {
  const col = s === "work" ? PAL.work : s === "dim" ? PAL.screen : PAL[s];
  const y = d.side === "n" ? d.y + d.h - 6.6 : d.y + 5;
  const g = new Layer(k, d.cx - 6.5, y, 13, 1.6, s === "dim" ? "e6" : "f2").rr(d.cx - 6.5, y, 13, 1.6, 0.8, col);
  const out = [s === "q" || s === "perm" || s === "esc" ? blink(g.el()) : g.el()];
  if (s === "work") {
    // a cursor that walks along the line, as the prototype's
    const c = new Layer(k, d.cx - 6, y, 3, 1.6, "e6").rect(d.cx - 6, y + 0.4, 3, 0.8, PAL.screenInk);
    out.push(c.el().loop("left", { from: (d.cx - 6) * k, to: (d.cx + 2) * k, period: 1920, easing: "linear" }));
  }
  return out;
}

/** The ping-pong ball: a rally across the table while two people play, else resting in the middle. */
export function ball(world, k, rally) {
  const e = world.rooms.find((r) => r.kind === "pong").x - 300;
  if (!rally) return [new Layer(k, 346.7 + e, 228.7, 2.6, 2.6).circ(348 + e, 230, 1.3, PAL.ball).el()];
  const b = new Layer(k, 0, 0, 2.6, 2.6).circ(1.3, 1.3, 1.3, PAL.ball);
  return [b.el().left((325 + e) * k).top(222.7 * k)
    .loop("left", { from: (325 + e) * k, to: (369 + e) * k, period: 1300, easing: "linear" })
    .loop("top", { from: 223.7 * k, to: 219.7 * k, period: 650 })];
};

function bubble(g, x, y, label, fill, ink, k) {
  const w = Math.max(9, label.length * 3 + 6);
  g.rr(x - w / 2, y - 5, w, 9, 4.5, fill);
  g.poly([[x - 2, y + 3.5], [x + 2, y + 3.5], [x, y + 6.5]], fill);
  return div().absolute().left((x - w / 2 - g.x) * k).top((y - 5 - g.y) * k).w(w * k).h(9 * k).flex().items_center().justify_center()
    .text_size(Math.max(5, 5 * k)).font_semibold().text_color(ink).child(label);
}

const TYPING = (p) => p.id === "matt" || (p.state === "working" && p.place === "desk");

/**
 * One person, seen from above: the prototype's person(). `face` is where they look (n, s, e, w) and
 * `walking` swings their arms and bobs them. Returns the elements to put in the person's wrapper.
 */
export function personEls(p, k, face, walking, world) {
  const [hair, skin, shirt] = look(p.id.startsWith("x:") ? p.name : p.id);
  const B = BOX;
  const x = B, y = B;
  const a = p.dim ? "b3" : "";
  const out = [];
  const shade = new Layer(k, 0, 0, 2 * B, 2 * B).ell(x, y + 4.4, 6.4, 2.4, PAL.shade);
  out.push(shade.el());
  const fig = new Layer(k, 0, 0, 2 * B, 2 * B, a);
  const ringCol = p.state === "blocked" ? BLOCKED[p.kind || "other"][0] : STATE_RING[p.state];
  if (ringCol) fig.ring(x, y, 8.4, ringCol, 1.5);
  const fy = face === "n" ? -1 : 1;
  const side = face === "e" ? 1 : face === "w" ? -1 : 0;
  const hands = [];
  if (TYPING(p) && !walking) {
    // Both hands on the keyboard of this person's own desk, tapping in turn.
    const d = p.id === "matt" ? world.mattDesk : world.desks.find((q) => q.key === p.desk);
    const kbY = !d ? y : p.id === "matt" ? d.y + 11.2 : d.side === "n" ? d.y + 4.2 : d.y + d.h - 3.8;
    const reach = d ? Math.abs(kbY - p.y) : 4.6;
    const hl = { x: x - 2.6, y: y + fy * reach }, hr = { x: x + 2.6, y: y + fy * (reach - 0.7) };
    fig.line(x - 4.2, y + fy * 1.5, hl.x, hl.y - fy * 1.2, shirt, 1.8);
    fig.line(x + 4.2, y + fy * 1.5, hr.x, hr.y - fy * 1.2, shirt, 1.8);
    for (const [h, other] of [[hl, hr.y], [hr, hl.y]]) {
      const hand = new Layer(k, 0, 0, 3.2, 3.2, a).circ(1.6, 1.6, 1.4, skin);
      hands.push(hand.el().left((h.x - 1.6) * k).top((h.y - 1.6) * k)
        .loop("top", { from: (h.y - 1.6) * k, to: (other - 1.6) * k, period: 260, easing: "linear" }));
    }
  }
  if (walking) {
    // The arms swing against each other in step with the bob (the prototype's gait).
    const swing = (cx, cy, ax, ay, rev) => {
      const hand = new Layer(k, 0, 0, 3.2, 3.2, a).circ(1.6, 1.6, 1.4, skin);
      const [fx, tx] = rev ? [cx + ax, cx - ax] : [cx - ax, cx + ax];
      const [fyy, tyy] = rev ? [cy + ay, cy - ay] : [cy - ay, cy + ay];
      return hand.el().left((fx - 1.6) * k).top((fyy - 1.6) * k)
        .loop("left", { from: (fx - 1.6) * k, to: (tx - 1.6) * k, period: 534 })
        .loop("top", { from: (fyy - 1.6) * k, to: (tyy - 1.6) * k, period: 534 });
    };
    if (side) hands.push(swing(x, y - 5.4, 1.28, 0, false), swing(x, y + 5.4, 1.28, 0, true));
    else hands.push(swing(x - 5.4, y, 0, 0.96, false), swing(x + 5.4, y, 0, 0.96, true));
  }
  // body, long hair behind the head, head, hair on top
  if (side) fig.ell(x, y, 4.8, 6.2, shirt); else fig.ell(x, y, 6.2, 4.8, shirt);
  if (p.long) { if (side) fig.circ(x - side * 1.2, y, 4.3, hair); else fig.circ(x, y - fy * 0.8, 4.3, hair); }
  fig.circ(x, y, 3.7, skin);
  if (side) {
    const back = side > 0 ? Math.PI : 0;
    fig.fan(x, y, 3.8, back - Math.PI * 0.62, back + Math.PI * 0.62, hair, [x + side * 1.2, y]);
  } else if (face === "n") {
    fig.circ(x, y, 3.8, hair);
  } else {
    fig.fan(x, y - 0.4, 3.8, Math.PI * 0.95, Math.PI * 2.05, hair);
    fig.poly([[x + 3.6, y - 1], [x - 3.6, y - 1], [x - 3.5, y - 0.4], [x + 3.5, y - 0.4]], hair);
  }
  if (face === "n") fig.circ(x, y - 2.4, 1.6, skin);
  if (p.headset) fig.ring(x, y, 4.1, PAL.monitor, 0.8);
  if (p.mug) { fig.circ(x + 6.6, y + 1, 1.9, PAL.fridge); fig.circ(x + 6.6, y + 1, 1.1, PAL.shelf); }
  if (p.paddle) fig.circ(x + p.paddle * 6, y - 1.5, 2.4, PAL.paddle);
  if (p.state === "blocked") { fig.circ(x + 6, y - 7.5, 1.7, skin); fig.line(x + 4, y - 2, x + 5.6, y - 6.4, shirt, 1.6); }
  const body = fig.el();
  out.push(walking ? body.loop("top", { from: -0.5 * k, to: 0.5 * k, period: 534 }) : body);
  out.push(...hands);
  // the bubble over a blocked or finished agent; it clears the top row's name tag by sitting higher
  const up = p.place === "desk" && world.desks.find((q) => q.key === p.desk)?.side === "n" ? 11 : 0;
  if (p.state === "blocked" || p.state === "done") {
    const [bg, label, ink] = p.state === "done" ? [PAL.work, "✓", PAL.white] : [...BLOCKED[p.kind || "other"], p.kind === "permission" ? PAL.eye : PAL.white];
    const bl = new Layer(k, 0, 0, 2 * B, 2 * B);
    const text = bubble(bl, x + 7, y - 15 - up, label, bg, ink, k);
    out.push(bl.el(), text);
  }
  return out;
}

/** Waffles, as the prototype's drawDog(): asleep with a slow "zz", or on her feet and wagging. */
export function dogEls(p, k, walking) {
  const B = BOX, x = B, y = B;
  const out = [new Layer(k, 0, 0, 2 * B, 2 * B).ell(x, y + 3, 7, 2.4, PAL.shade).el()];
  if (p.state === "sleep") {
    const g = new Layer(k, 0, 0, 2 * B, 2 * B);
    g.ell(x, y, 6.5, 4.6, PAL.dog); g.circ(x - 4, y + 1, 2.8, PAL.dog); g.ell(x - 5.4, y - 0.6, 1.4, 2, PAL.dogDark);
    g.add(PathBuilder.stroke(1.2 * k).move_to(...arcPt(g, x, y, 6, 0.2)).arc_to(6 * k, 6 * k, 0, false, true, ...arcPt(g, x, y, 6, 1.4)).build(), PAL.dogDark);
    out.push(g.el());
    out.push(div().absolute().left((x + 6) * k).top((y - 10) * k).text_size(Math.max(7, 5.5 * k)).font_semibold().text_color(PAL.white).child("zz")
      .loop("top", { from: (y - 7) * k, to: (y - 13) * k, period: 2100, easing: "linear" }));
    return out;
  }
  const f = p.dir < 0 ? -1 : 1;
  const g = new Layer(k, 0, 0, 2 * B, 2 * B);
  const legs = [[-3, -2.6], [3, -2.6], [-3, 2.6], [3, 2.6]].map(([lx, ly], i) => {
    const leg = new Layer(k, 0, 0, 2.4, 2.4).circ(1.2, 1.2, 1.1, PAL.dogDark).el();
    const el = leg.left((x + lx - 1.2) * k).top((y + ly - 1.2) * k);
    return walking ? el.loop("left", { from: (x + lx - 1.2 + (i % 2 ? -1 : 1)) * k, to: (x + lx - 1.2 + (i % 2 ? 1 : -1)) * k, period: 377 }) : el;
  });
  g.ell(x, y, 6, 3.6, PAL.dog);
  g.circ(x + f * 6, y - 0.4, 3, PAL.dog); g.ell(x + f * 6, y - 3, 1.2, 1.6, PAL.dogDark); g.circ(x + f * 7.6, y - 0.8, 0.6, PAL.eye);
  const tail = new Layer(k, 0, 0, 2 * B, 2 * B).line(x - f * 5.6, y, x - f * 8.6, y, PAL.dog, 1.4).el().loop("top", { from: -1.5 * k, to: 1.5 * k, period: 440 });
  out.push(...legs, g.el(), tail);
  return out;
}
const arcPt = (g, cx, cy, r, a) => [g.X(cx + Math.cos(a) * r), g.Y(cy + Math.sin(a) * r)];

/** The wrapper that carries a person across the floor. Its left and top slide; `ms` is the length of the step. */
export function wrapper(id, x, y, k, motion) {
  const el = div().id("person-" + id).absolute().left((x - BOX) * k).top((y - BOX) * k).w(2 * BOX * k).h(2 * BOX * k);
  return motion ? el.transition("left", motion).transition("top", motion) : el;
}

/** The dark of lights-off: the floor dimmed, each lit screen pooling light on its desk, the wall screen kept on. */
export function night(world, k, lit) {
  const out = [new Layer(k, 0, 0, world.W, world.H).rect(0, 0, world.W, world.H, "#060a24a8").el()];
  const pools = new Layer(k, 0, 0, world.W, world.H);
  for (const [d, s] of lit) {
    const col = s === "work" ? PAL.work : PAL[s];
    const y = d.side === "n" ? d.y + d.h - 6 : d.y + 6;
    [[22, "10"], [16, "18"], [11, "24"], [6, "34"]].forEach(([r, al]) => pools.circ(d.cx, y, r, col + al));
  }
  const meet = world.rooms.find((r) => r.kind === "meet");
  [[18, "0c"], [12, "18"], [7, "28"]].forEach(([r, al]) => pools.circ(meet.x + 45, 11, r, PAL.screenInk + al));
  out.push(pools.el());
  const keep = new Layer(k, 0, 0, world.W, world.H).rr(meet.x + 26, 6, 38, 11, 2, PAL.screen).rr(1, 136, 7, 8, 1, PAL.work);
  out.push(keep.el());
  return out;
}

export { BOX };
