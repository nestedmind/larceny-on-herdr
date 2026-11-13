// What the office drew, against what the prototype says. Every check is a function in CHECKS that gets the
// prototype's data (P), what the office drew (r) and the case, and reports differences through `diff`.
// A difference over LIMIT px in a position or size is a finding. Positions are px at the scale the office fitted.
//
// A thing in a room may sit anywhere the room's growth allows (crew.js grows rooms to match the pane): its expected
// position is a range, [prototype position + the room's shift, + the room's growth]. On the prototype-sized floor
// the growth is nil, so the range is one point.

export const LIMIT = 1;

const worldOf = (P, n) => {
  const a = P.ROOMS.api;
  const rooms = new Map();
  for (let i = 0; i < n; i++) rooms.set("#" + i, { ...a, x: a.x + i * a.w, door: a.door + i * a.w });
  const moved = (n - 2) * a.w;
  for (const k of ["leads", "meet"]) rooms.set(k, { ...P.ROOMS[k], x: P.ROOMS[k].x + moved, door: P.ROOMS[k].door + moved });
  for (const k of ["matt", "kitchen", "lounge", "pong", "rest"]) rooms.set(k, P.ROOMS[k]);
  // Desks, by the office's room key: repo rooms repeat the prototype's api pod; leads moves with its room.
  const desks = new Map();
  const pod = P.DESKS.filter((d) => d.room === "api");
  for (let i = 0; i < n; i++) pod.forEach((d, j) => desks.set(`#${i}:${j + 1}`, { ...d, x: d.x + i * a.w, cx: d.cx + i * a.w, seat: { x: d.seat.x + i * a.w, y: d.seat.y } }));
  for (const key of ["scofield", "amy"]) {
    const d = P.DESKS.find((q) => q.key === key);
    desks.set(key, { ...d, x: d.x + moved, cx: d.cx + moved, seat: { x: d.seat.x + moved, y: d.seat.y } });
  }
  desks.set("matt", P.MATT_DESK);
  const shift = (o) => ({ ...o, x: o.x + moved });
  return { rooms, desks, spots: P.SPOTS, meetSeats: { yoda: shift(P.MEET_SEATS.yoda), sara: shift(P.MEET_SEATS.sara) }, bed: P.DOG_BED };
};

/** Where an item may be, in world units: [lo, hi] on each axis. `room` carries the shift and growth (crew.js mkRoom). */
const rangeIn = (room, x, y) => ({ x: [x + room.sx, x + room.sx + room.gw], y: [y + room.sy, y + room.sy + room.gh] });

class Findings {
  constructor(k) { this.k = k; this.list = []; this.counted = 0; }
  /** `lo`..`hi` is the range the prototype allows (world units); `got` the office's value (world units). Compared in px. */
  axis(check, id, field, got, [lo, hi], extra = {}) {
    this.counted++;
    const px = (got - (got < lo ? lo : got > hi ? hi : got)) * this.k;
    if (Math.abs(px) > LIMIT) this.list.push({ check, id, field, got: +(got * this.k).toFixed(2), want: [+(lo * this.k).toFixed(2), +(hi * this.k).toFixed(2)], off: +px.toFixed(2), ...extra });
  }
  point(check, id, got, range, extra) { this.axis(check, id, "x", got.x, range.x, { ...extra, y: got.y }); this.axis(check, id, "y", got.y, range.y, { ...extra, x: got.x }); }
  px(check, id, field, got, want) { this.axis(check, id, field, got / this.k, [want / this.k, want / this.k]); }
}

const roomsOf = (L) => {
  const repos = L.rooms.filter((r) => r.kind === "repo");
  return { repos, byKind: (kind) => L.rooms.find((r) => r.kind === kind), keyed: (key) => (key.startsWith("#") ? repos[+key.slice(1)] : L.rooms.find((r) => r.kind === key)) };
};

export const CHECKS = {
  /** Each room's place, size and door in the prototype's own coordinates, and that a row of rooms fills the floor. */
  rooms(f, { P, r }) {
    const { L } = r;
    const n = L.rooms.filter((q) => q.kind === "repo").length;
    const W = worldOf(P, n);
    const { keyed } = roomsOf(L);
    for (const [key, e] of W.rooms) {
      const q = keyed(key);
      const id = q ? q.key : key;
      if (!q) { f.list.push({ check: "rooms", id, field: "missing", got: null, want: key, off: Infinity }); continue; }
      const door0 = q.door - (q.sx + 0.5 * q.gw);
      for (const [field, got, want] of [["x0", q.x0, e.x], ["y0", q.y0, e.y], ["w0", q.w0, e.w], ["h0", q.h0, e.h], ["door0", door0, e.door]]) f.axis("rooms", id, field, got, [want, want]);
    }
    for (const row of ["top", "bottom"]) {
      const rs = L.rooms.filter((q) => q.row === row).sort((a, b) => a.x - b.x);
      let x = 0;
      for (const q of rs) { f.axis("rooms", q.key, "row-contiguous", q.x, [x, x]); x = q.x + q.w; }
      f.axis("rooms", row + "-row", "fills-floor", x, [L.W, L.W]);
    }
    f.axis("rooms", "floor", "width-at-least-prototype", Math.max(L.W, P.W), [L.W, L.W]);
  },

  /** Desks, their seats, Matt's desk, the standing spots, the meeting seats and the dog's bed. */
  furniture(f, { P, r }) {
    const { L } = r;
    const n = L.rooms.filter((q) => q.kind === "repo").length;
    const W = worldOf(P, n);
    const { repos } = roomsOf(L);
    const roomOf = (d) => (d.room === "leads" || d.room === "matt" ? L.rooms.find((q) => q.kind === d.room) : L.rooms.find((q) => q.key === d.room));
    const mapKey = (d) => { const i = repos.findIndex((q) => q.key === d.room); return i >= 0 ? `#${i}:${d.key.slice(d.key.lastIndexOf(":") + 1)}` : d.key; };
    for (const d of [...L.desks, L.mattDesk]) {
      const e = W.desks.get(mapKey(d));
      if (!e) { f.list.push({ check: "desks", id: d.key, field: "missing", got: null, want: mapKey(d), off: Infinity }); continue; }
      const q = roomOf(d);
      f.point("desks", d.key, { x: d.x, y: d.y }, rangeIn(q, e.x, e.y));
      f.point("seats", d.key, d.seat, rangeIn(q, e.seat.x, e.seat.y));
      f.axis("desks", d.key, "w", d.w, [e.w, e.w]); f.axis("desks", d.key, "h", d.h, [e.h, e.h]);
    }
    for (const [room, list] of Object.entries(L.spots)) {
      const q = L.rooms.find((x) => x.kind === room);
      list.forEach((p, i) => f.point("spots", `${room}:${i}`, p, rangeIn(q, W.spots[room][i].x, W.spots[room][i].y)));
    }
    const meet = L.rooms.find((q) => q.kind === "meet");
    for (const id of ["yoda", "sara"]) f.point("seats", "meet:" + id, L.meetSeats[id], rangeIn(meet, W.meetSeats[id].x, W.meetSeats[id].y));
    f.point("furniture", "dog-bed", L.bed, rangeIn(L.rooms.find((q) => q.kind === "lounge"), W.bed.x, W.bed.y));
  },

  /** Where each person stands: at a desk's seat, on one of a room's spots, at a meeting seat, at Matt's desk. */
  people(f, { P, r }) {
    const { L } = r;
    const n = L.rooms.filter((q) => q.kind === "repo").length;
    const W = worldOf(P, n);
    const { repos } = roomsOf(L);
    const deskBy = new Map(L.desks.concat([L.mattDesk]).map((d) => [d.key, d]));
    for (const p of L.people) {
      if (p.id === "dog") { if (p.state === "sleep") f.point("people", p.id, p, rangeIn(L.rooms.find((q) => q.kind === "lounge"), W.bed.x, W.bed.y)); continue; }
      if (p.place === "desk" || p.place === "matt") {
        const d = deskBy.get(p.desk);
        const i = repos.findIndex((q) => q.key === d.room);
        const e = W.desks.get(i >= 0 ? `#${i}:${d.key.slice(d.key.lastIndexOf(":") + 1)}` : d.key);
        const q = i >= 0 ? repos[i] : L.rooms.find((x) => x.kind === d.room);
        f.point("people", p.id, p, rangeIn(q, e.seat.x, e.seat.y), { place: p.place + ":" + p.desk });
      } else if (p.place === "meeting") {
        const e = W.meetSeats[p.id];
        f.point("people", p.id, p, rangeIn(L.rooms.find((q) => q.kind === "meet"), e.x, e.y), { place: "meeting" });
      } else {
        const q = L.rooms.find((x) => x.kind === p.place);
        const spots = W.spots[p.place] || [];
        // The spot is the one nearest to where the person stands; the distance from it is the finding.
        let best = null;
        const out = (v, [lo, hi]) => (v < lo ? lo - v : v > hi ? v - hi : 0);
        for (const s of spots) { const g = rangeIn(q, s.x, s.y); const d = Math.hypot(out(p.x, g.x), out(p.y, g.y)); if (!best || d < best.d) best = { d, g }; }
        if (!best) f.list.push({ check: "people", id: p.id, field: "place", got: p.place, want: "a room with spots", off: Infinity });
        else f.point("people", p.id, p, best.g, { place: p.place });
      }
    }
  },

  /** What the render drew: each figure on its person, the floor element at the size the office fitted, each click target on its figure. */
  render(f, { r }) {
    const { L, k } = r;
    f.px("render", "floor", "w", r.floorBox.w, L.W * k);
    f.px("render", "floor", "h", r.floorBox.h, L.H * k);
    for (const p of L.people) {
      const d = r.people[p.id];
      if (!d) { f.list.push({ check: "render", id: p.id, field: "figure-missing", got: null, want: [p.x * k, p.y * k], off: Infinity }); continue; }
      f.px("render", p.id, "figure-x", d.x, p.x * k); f.px("render", p.id, "figure-y", d.y, p.y * k);
      const h = r.hits[p.id];
      if (!h) continue;
      f.px("hit", p.id, "centre-x", h.x + h.w / 2, p.x * k); f.px("hit", p.id, "centre-y", h.y + h.h / 2, p.y * k);
      // The prototype opens an agent for a click within 8 units of them: the target is no bigger than that circle's square.
      for (const [field, size] of [["w", h.w], ["h", h.h]]) f.axis("hit", p.id, field, size / k, [0, 16]);
    }
  },

  /** Name tags: inside the floor, centred on their person unless the floor's edge stops them. */
  tags(f, { r }) {
    const { L, k } = r;
    for (const p of L.people) {
      const t = r.tags[p.agent ? p.agent.address : p.id];
      const d = r.people[p.id];
      if (!t || !d) continue;
      const fw = r.floorBox.w;
      const w = t.w;
      if (w !== undefined) {
        const centred = t.x + w / 2;
        const clamped = t.x <= 2.5 || t.x + w >= fw - 2.5;
        if (!clamped) f.px("tags", p.id, "centre-x", centred, d.x);
        f.axis("tags", p.id, "inside-floor-x", (t.x + w / 2) / k, [w / 2 / k, (fw - w / 2) / k]);
      } else f.axis("tags", p.id, "left-of-person", t.x / k, [0, d.x / k]);
    }
  },

  /** One walk, kitchen to leads: the office's route is the prototype's pathTo, and every sample along it is on that route. */
  async route(f, { P, r, crew, proto, route }) {
    if (!route) return;
    const { L, k } = r;
    const n = L.rooms.filter((q) => q.kind === "repo").length;
    if (n !== 2) return; // the prototype has two repos: no route of its own to compare with
    const from = P.SPOTS[route.from.room][route.from.spot];
    const toDesk = P.DESKS.find((d) => d.key === route.to.desk);
    const to = toDesk.seat;
    const theirs = await proto.pathTo(route.id, from, to);
    const mine = crew.pathTo(L, route.id, from, to);
    f.axis("route", route.id, "points", mine.length, [theirs.length, theirs.length]);
    theirs.forEach((p, i) => { if (mine[i]) f.point("route", route.id + ":" + i, mine[i], { x: [p.x, p.x], y: [p.y, p.y] }); });
    // Samples along the walk the office would make: each must lie on a leg of the prototype's route.
    const legs = crew.legsOf(from, mine);
    const total = legs.reduce((s, l) => s + l.ms, 0);
    const poly = [from, ...theirs];
    for (let i = 0; i <= route.samples; i++) {
      const pos = crew.posAt(from, legs, (total * i) / route.samples);
      let best = Infinity;
      for (let j = 1; j < poly.length; j++) best = Math.min(best, distToSegment(pos, poly[j - 1], poly[j]));
      f.axis("route", route.id, `sample-${i}-off-route`, best, [0, 0]);
    }
  },
};

function distToSegment(p, a, b) {
  const dx = b.x - a.x, dy = b.y - a.y;
  const len2 = dx * dx + dy * dy;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

/** Runs every check on one case. Returns { counted, findings }. */
export async function compareCase(ctx) {
  const f = new Findings(ctx.r.k);
  for (const [name, check] of Object.entries(CHECKS)) {
    const before = f.list.length;
    await check(f, ctx);
    for (let i = before; i < f.list.length; i++) f.list[i].group = f.list[i].check || name;
  }
  return { counted: f.counted, findings: f.list };
}

/** Colours the office draws with, against the prototype's tokens: any that differ, or are missing, as findings. */
export function comparePalette(officePal, protoPal) {
  const out = [];
  const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
  for (const [k, want] of Object.entries(protoPal)) {
    if (!(k in officePal)) continue; // a token the office does not draw with
    if (Array.isArray(want)) want.forEach((w, i) => { if (w && officePal[k][i] && !same(officePal[k][i], w)) out.push({ check: "palette", id: `${k}[${i}]`, field: "colour", got: officePal[k][i], want: w, off: Infinity }); });
    else if (!same(officePal[k], want)) out.push({ check: "palette", id: k, field: "colour", got: officePal[k], want, off: Infinity });
  }
  return out;
}
