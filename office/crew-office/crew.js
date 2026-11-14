// Pure placement logic for the crew office. No herdr imports: it takes the
// array that `terminals()` returns (the same shape as `hc ls --json`) and
// returns where everyone sits. All coordinates are in world units; main.js
// scales them to the pane.

// World units are the design prototype's: the floor is 288 high and at least 480 wide.
export const ROOM_H = 120;
export const DESK_H = 16;
export const REPO_W = 150;
export const WORLD_H = 288;
export const LANE_Y = 140;
export const WALK_SPEED = 62;
const BASE_W = 480;
const SIDE_W = 90;
const ROW_Y = 160;
const ROW_H = 128;

export const STATES = ["working", "blocked", "done", "idle"];

/** The agent state as a plain word: terminals() gives a word, hc get an object. */
export function statusOf(t) {
  const s = t && t.status;
  if (typeof s === "string") return s;
  if (s && typeof s.state === "string") return s.state;
  return "idle";
}

/** Why a blocked agent waits: permission, question or other. */
export function blockedKind(t) {
  const r = t && (t.report || t.status);
  const k = r && typeof r === "object" ? r.kind : null;
  if (k === "permission" || k === "question") return k;
  return "other";
}

/** Strip control characters and cut to n characters, so a label cannot wreck the layout. */
export function clean(value, n) {
  const s = String(value ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

/** Split a `task=<repo>#<n>` label. A label with no `#` is all repo. */
export function parseTask(task) {
  const s = String(task ?? "");
  if (!s) return { repo: "", number: "" };
  const i = s.lastIndexOf("#");
  if (i < 0) return { repo: s, number: "" };
  return { repo: s.slice(0, i), number: s.slice(i + 1) };
}

/** The workspace to show: the prop if given, else the one with the most live agents (ties: name order). */
export function pickWorkspace(terminals, wanted) {
  if (wanted) return wanted;
  const counts = new Map();
  for (const t of terminals) {
    const c = t.labels && t.labels.crew;
    if (c && t.state !== "finished") counts.set(c, (counts.get(c) || 0) + 1);
  }
  let best = null;
  for (const [name, n] of [...counts].sort((a, b) => a[0].localeCompare(b[0]))) {
    if (best === null || n > counts.get(best)) best = name;
  }
  return best;
}

/**
 * Only agents are people. The background notifier (role=watch) and any terminal that
 * reports a program other than a Claude agent (a shell, loh itself) are left out.
 */
export function isAgent(t) {
  const l = (t && t.labels) || {};
  if (l.role === "watch") return false;
  if (typeof t.agent === "string" && !/^claude/i.test(t.agent)) return false;
  return true;
}

/** The repo names in `loh status --repos` output (a JSON array). Anything else gives []. */
export function repoNames(text) {
  let list;
  try { list = JSON.parse(text); } catch { return []; }
  if (!Array.isArray(list)) return [];
  return list.map((r) => (r && typeof r.name === "string" ? clean(r.name, 24) : "")).filter(Boolean);
}

/** The command that lists the workspace's repos. It runs in an agent's folder, inside the workspace. */
export function reposCall(agent, loh) {
  return { cmd: loh || "loh", args: ["status", "--repos"], options: { cwd: (agent && agent.cwd) || undefined, timeout: 5000 } };
}

/** The crew: terminals labelled crew=<workspace>, as plain records. */
export function crewOf(terminals, workspace) {
  const out = [];
  for (const t of terminals) {
    const l = t.labels || {};
    if (!workspace || l.crew !== workspace) continue;
    if (t.state && t.state !== "live") continue;
    if (!isAgent(t)) continue;
    const task = parseTask(l.task);
    out.push({
      address: t.address,
      name: clean(t.name || t.address, 16),
      // The terminal's real name, for commands. `name` is for the screen only.
      rawName: String(t.name || t.address),
      cwd: typeof t.cwd === "string" ? t.cwd : "",
      role: l.role || "",
      repo: clean(task.repo, 24),
      ticket: clean(task.number, 8),
      status: statusOf(t),
      kind: statusOf(t) === "blocked" ? blockedKind(t) : null,
      step: clean(l.step, 60),
      pr: clean(l.pr, 8),
      // Set with the pr label cleared once the pull request merged or closed: the coder has no work in hand, whatever its ticket.
      prDone: l.prdone === "1",
      round: clean(l.round, 4),
      note: clean(l.note, 60),
      // Set by the hooks while the session compacts (compact) or has just been cleared (clear).
      ctx: l.ctx === "compact" || l.ctx === "clear" ? l.ctx : "",
      // When herdr says the status last changed (ms), if it says: a person first seen idle counts the idle time from then.
      statusMs: typeof t.status_ms === "number" && Number.isFinite(t.status_ms) ? t.status_ms : null,
      withMatt: l.with_matt === "1",
    });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name) || a.address.localeCompare(b.address, undefined, { numeric: true }));
}

/**
 * The command that sets the with-Matt lock on an agent. It runs in the agent's own
 * folder, because loh finds the workspace by walking up from there and herdr-app
 * itself runs outside any workspace. The raw terminal name is used, not the shortened one.
 */
export function lockCall(agent, loh) {
  return { cmd: loh || "loh", args: ["lock", agent.rawName], options: { cwd: agent.cwd || undefined, timeout: 5000 } };
}

/** The command that releases the lock when the chat closes. Same folder and name rules as lockCall. */
export function unlockCall(agent, loh) {
  return { cmd: loh || "loh", args: ["unlock", agent.rawName], options: { cwd: agent.cwd || undefined, timeout: 5000 } };
}

const MIN_SCALE = 0.2;

/**
 * Scale that fits the floor into the stage, the area main.js measures for it (the bar and the offer row are outside it; PAD px of padding all round).
 * It may drop below 1, so a narrow pane (the chat takes half the tab) shrinks the floor instead of
 * cutting it. `fits` is false only when even the smallest scale overflows: main.js then stops centring.
 */
export function fitScale(size, floor) {
  const raw = Math.min((size.width - 2 * PAD) / floor.W, (size.height - 2 * PAD) / floor.H);
  const k = Math.min(8, Math.max(MIN_SCALE, raw));
  return { k, fits: floor.W * k <= size.width - 2 * PAD + 0.5 };
}

// ---------- full-screen mode ----------

/** herdr's chrome, by the node ids in layouts/main.json. */
export const CHROME = ["sidebar", "tabs", "panel", "status"];

/** The node with this id in the shown layout, or null. */
export function findNode(node, id) {
  if (!node || typeof node !== "object") return null;
  if (node.id === id) return node;
  for (const c of Array.isArray(node.children) ? node.children : []) {
    const f = findNode(c, id);
    if (f) return f;
  }
  return null;
}

/**
 * What entering full screen does. `layout` is the shown layout (herdr's layout()), `fullscreen` the
 * window's state, `zoomed` whether the office pane is zoomed already, `siblings` whether another
 * pane shares its tab (a chat split: with none, zoom has nothing to hide). Only chrome that is
 * visible now is hidden, and only what the plan did is undone, so a bar the person had hidden
 * stays hidden. A layout that cannot be read hides nothing.
 */
export function fullscreenPlan(layout, { fullscreen, zoomed, siblings }) {
  const hide = CHROME.filter((id) => { const n = findNode(layout, id); return !!n && !n.hidden; });
  return { zoom: !!siblings && !zoomed, hide, window: !fullscreen };
}

/** The steps that undo a plan, last first: window, then each hidden node, then the zoom. */
export function restoreSteps(plan) {
  const out = [];
  if (plan.window) out.push({ window: true });
  for (const id of [...plan.hide].reverse()) out.push({ show: id });
  if (plan.zoom) out.push({ zoom: true });
  return out;
}

/**
 * What a copy of the office does at startup with a full-screen plan saved by an earlier one
 * ({ plan, pane }): "adopt" it when it is this copy's own pane (a reload), "undo" it when its pane
 * no longer exists (a crash or a restart), "leave" it when another live pane owns it, else "none".
 * A saved plan with no pane at all is "adopt"ed too: it belongs to an office run as a layout block, which has no pane.
 */
export function recoveryFor(saved, paneIds, ownPane, officeIds = []) {
  if (!saved || !saved.plan) return "none";
  // A plan with no pane belongs to an office run as a layout block, which has no pane of its own: it is live.
  if (!saved.pane) return "adopt";
  if (saved.pane === ownPane) return "adopt";
  if (!(paneIds || []).includes(saved.pane)) return "undo";
  // A copy that cannot tell which pane is its own may still be the owner's reload: it is when the
  // saved pane is the only office pane there is.
  if (!ownPane && officeIds.length === 1 && officeIds[0] === saved.pane) return "adopt";
  return "leave";
}

/**
 * What pressing Full screen does given the saved plan: "enter" with none, "adopt" a live one that
 * is this office's own (it is on already), "blocked" when another live office's plan is saved, and
 * "restore" when the saved plan's pane is gone (put its chrome back first, then press again).
 * Never "enter" over a saved plan, so the plan that knows what was hidden is not lost.
 */
export function entryFor(saved, paneIds, mine, officeIds = []) {
  const r = recoveryFor(saved, paneIds, mine, officeIds);
  return r === "none" ? "enter" : r === "adopt" ? "adopt" : r === "leave" ? "blocked" : "restore";
}

/** A restore step as the arguments of `herdr-app do`, or null for one with no command (the window). */
export function doArgs(step, pane) {
  if (step.show) return ["do", "layout.show", "--id", step.show];
  if (step.zoom && pane) return ["do", "pane.zoom", "--pane", pane];
  return null;
}

/** Everything the cached floor drawing depends on: change any of these and it is drawn again. The scale is not one of them. */
export function floorKey(L) {
  return `${L.W}|${L.H}|${L.pods.map((p) => p.repo).join(",")}`;
}

/** The pane this mod runs in: the one named in props, else the focused crew-office pane, else null. */
export function officePane(panes, props) {
  if (props && props.pane) return props.pane;
  const mine = (panes || []).find((p) => p.mod === "crew-office" && p.focused);
  return mine ? mine.pane : null;
}

/** True when an open chat's pane has gone (the person closed it): the lock must be released. */
export function chatGone(panes, chat) {
  return !!chat && !(panes || []).some((p) => p.pane === chat.pane);
}

export function totals(crew) {
  const n = { working: 0, blocked: 0, done: 0, idle: 0 };
  for (const a of crew) n[STATES.includes(a.status) ? a.status : "idle"] += 1;
  return n;
}
export function hash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

// ---------- the cast ----------

// Hair, skin and shirt, from the design prototype. Anyone else gets a shirt by name.
const LOOKS = {
  scofield: ["#2a211c", "#e8b98f", "#3f5f93"], sucre: ["#16130f", "#b97a50", "#c4533a"],
  mahone: ["#8c6c4c", "#efc9a3", "#6d7d40"], sheba: ["#4a2618", "#8d5a3b", "#8e4fa8"],
  whip: ["#d8b04a", "#f0c8a0", "#2f8f8a"], amy: ["#b8432f", "#f1cfb0", "#39404f"],
  matt: ["#3a2a1f", "#d9a27a", "#e0603f"], yoda: ["#e4e1d6", "#93b36c", "#8a6e4b"],
  sara: ["#2b1d14", "#c68a62", "#3f7fbf"], opemipo: ["#141110", "#6b4630", "#d2a03a"],
  maya: ["#6a2c4a", "#e0b08c", "#e46b8f"],
};
const SHIRTS = ["#c4533a", "#6d7d40", "#8e4fa8", "#2f8f8a", "#d2a03a", "#e46b8f"];

/** [hair, skin, shirt] for a name. */
export function look(name) {
  const k = String(name).toLowerCase();
  if (LOOKS[k]) return LOOKS[k];
  return ["#2a211c", "#d9a27a", SHIRTS[hash(k) % SHIRTS.length]];
}

/** The twelve who are always in the office, in the prototype's order. `role` is the office role. */
export const CAST = [
  { id: "scofield", name: "Scofield", title: "coordinator", role: "coordinator" },
  { id: "sucre", name: "Sucre", title: "coder", role: "coder" },
  { id: "mahone", name: "Mahone", title: "coder", role: "coder" },
  { id: "sheba", name: "Sheba", title: "coder", role: "coder", long: true },
  { id: "whip", name: "Whip", title: "coder", role: "coder" },
  { id: "amy", name: "Amy", title: "reviewer", role: "reviewer", long: true },
  { id: "maya", name: "Maya", title: "designer", role: "helper", long: true },
  { id: "opemipo", name: "Opemipo", title: "researcher", role: "helper" },
  { id: "yoda", name: "Yoda", title: "advisor", role: "advisor" },
  { id: "sara", name: "Sara", title: "teacher", role: "teacher", long: true },
  { id: "matt", name: "Matt", title: "owner", role: "owner", headset: true },
  { id: "dog", name: "Waffles", title: "office dog", role: "dog" },
];
const AGENT_IDS = CAST.filter((c) => c.role !== "owner" && c.role !== "dog").map((c) => c.id);
// A terminal whose name is not in the cast but whose role label is stands in for that cast member.
const ROLE_CAST = { coordinator: "scofield", reviewer: "amy", advisor: "yoda", teacher: "sara" };

const lower = (a) => String(a.rawName || a.name || "").toLowerCase();

/** The cast id for an agent: its name when that is in the cast, else its role's stand-in, else null. */
export function castKey(agent, all = [agent]) {
  const name = lower(agent);
  if (AGENT_IDS.includes(name)) return name;
  const target = ROLE_CAST[agent.role];
  if (!target) return null;
  if (all.some((a) => lower(a) === target)) return null;
  const first = all.find((a) => !AGENT_IDS.includes(lower(a)) && a.role === agent.role);
  return first === agent ? target : null;
}

// ---------- the world ----------

/** The padding the office leaves round the floor inside its stage, in pixels. */
export const PAD = 8;

/** The pane's width over its height, as the floor wants it: the stage's size less the padding. */
export function aspectOf(size) {
  const w = Math.max(1, size.width - 2 * PAD);
  const h = Math.max(1, size.height - 2 * PAD);
  return Math.round((w / h) * 1000) / 1000;
}

/**
 * The floor's size for a row `minW` wide at the least (the prototype's 480, or more with many
 * repos) and an `aspect` (width over height; none or 0 keeps the prototype's). The short side grows
 * and the long side stays at its least, so the floor is never smaller than the prototype's.
 */
export function floorSize(minW, aspect) {
  if (!(aspect > 0)) return { W: minW, H: WORLD_H };
  if (aspect >= minW / WORLD_H) return { W: WORLD_H * aspect, H: WORLD_H };
  return { W: minW, H: minW / aspect };
}

/** The stage behind the floor, in the prototype's two colours (never the theme's canvas). */
export function stageBg(dark) {
  return dark ? "#0b0e14" : "#d5dae3";
}

// A room's place in the prototype (x0, y0, w0, h0) and where it is now (x, y, w, h). Everything the
// prototype puts in a room is written in prototype coordinates and moved with shiftOf, so people,
// desks and furniture keep their size and their place in the room however the room grows.
const mkRoom = (key, kind, label, row, p, door) => ({ key, kind, label, row, x0: p[0], y0: p[1], w0: p[2], h0: p[3], door, x: p[0], y: p[1], w: p[2], h: p[3], sx: 0, sy: 0, gw: 0, gh: 0 });

/**
 * How far to move a point of the prototype's room to where it is now. `ax` and `ay` say which edge
 * it keeps: 0 the left or top, 1 the right or bottom, 0.5 (the default) the middle, so a group of
 * furniture and the people at it grow away from the middle together.
 */
export function shiftOf(room, ax = 0.5, ay = 0.5) {
  return { dx: room.sx + ax * room.gw, dy: room.sy + ay * room.gh };
}

/** Which edges a decoration at a prototype point keeps: the nearest third of the room, or the middle. */
export function anchorOf(room, x, y) {
  const third = (v, lo, size) => ((v - lo) < size / 3 ? 0 : (v - lo) > (2 * size) / 3 ? 1 : 0.5);
  return { ax: third(x, room.x0, room.w0), ay: third(y, room.y0, room.h0) };
}

const mkDesk = (key, room, cx, y, side, w = 28) => ({
  key, room, cx, x: cx - w / 2, y, w, h: DESK_H, side,
  seat: { x: cx, y: side === "n" ? y - 6 : y + DESK_H + 6 },
});

export function repoDesks(room) {
  const { dx, dy } = shiftOf(room);
  const px = room.x0 + REPO_W / 2 + dx;
  return [mkDesk(`${room.key}:1`, room.key, px - 15, 42 + dy, "n"), mkDesk(`${room.key}:2`, room.key, px + 15, 42 + dy, "n"),
    mkDesk(`${room.key}:3`, room.key, px - 15, 58 + dy, "s"), mkDesk(`${room.key}:4`, room.key, px + 15, 58 + dy, "s")];
}

/**
 * The floor plan, from the prototype: a row of repo rooms (one per repo, four desks each), then the
 * leads room and the meeting room; a corridor; then Matt's room, kitchen, lounge, ping pong and the
 * rest room. The prototype's floor is at least 480 wide and 288 high; `aspect` (the pane's width
 * over its height) makes it match the pane. Extra width is shared across the rooms of each row, and
 * extra height across the two rows and the corridor in proportion to their height.
 */
export function worldFor(repoNames = [], aspect = 0) {
  const repos = [...new Set(repoNames)];
  const n = repos.length;
  const topW = n * REPO_W + 2 * SIDE_W;
  const { W, H } = floorSize(Math.max(topW, BASE_W), aspect);
  const rooms = repos.map((r, i) => mkRoom("repo:" + r, "repo", r, "top", [i * REPO_W, 0, REPO_W, ROOM_H], i * REPO_W + REPO_W / 2));
  const leftEdge = n * REPO_W;
  rooms.push(mkRoom("leads", "leads", "Scofield · Amy", "top", [leftEdge, 0, SIDE_W, ROOM_H], leftEdge + 45));
  rooms.push(mkRoom("meet", "meet", "meeting", "top", [leftEdge + SIDE_W, 0, SIDE_W, ROOM_H], leftEdge + SIDE_W + 45));
  rooms.push(mkRoom("matt", "matt", "Matt", "bottom", [0, ROW_Y, 96, ROW_H], 50));
  rooms.push(mkRoom("kitchen", "kitchen", "kitchen", "bottom", [96, ROW_Y, 100, ROW_H], 146));
  rooms.push(mkRoom("lounge", "lounge", "lounge", "bottom", [196, ROW_Y, 104, ROW_H], 284));
  rooms.push(mkRoom("pong", "pong", "ping pong", "bottom", [300, ROW_Y, 96, ROW_H], 348));
  rooms.push(mkRoom("rest", "rest", "rest room", "bottom", [396, ROW_Y, 84, ROW_H], 438));

  // Grow the rooms: each row's extra width is shared out, then the extra height by row.
  const extra = H - WORLD_H;
  const topH = ROOM_H + (extra * ROOM_H) / WORLD_H;
  const corrH = (ROW_Y - ROOM_H) + (extra * (ROW_Y - ROOM_H)) / WORLD_H;
  const botH = ROW_H + (extra * ROW_H) / WORLD_H;
  for (const row of ["top", "bottom"]) {
    const rs = rooms.filter((r) => r.row === row);
    const gw = (W - rs.reduce((s, r) => s + r.w0, 0)) / rs.length;
    let x = 0;
    for (const r of rs) {
      r.gw = gw; r.gh = (row === "top" ? topH : botH) - r.h0;
      r.x = x; r.w = r.w0 + gw; r.sx = r.x - r.x0;
      r.y = row === "top" ? 0 : topH + corrH; r.h = row === "top" ? topH : botH; r.sy = r.y - r.y0;
      x += r.w;
    }
  }
  const at = (r, x, y, ax = 0.5, ay = 0.5) => { const s = shiftOf(r, ax, ay); return { x: x + s.dx, y: y + s.dy }; };
  const room = (k) => rooms.find((r) => r.kind === k);
  for (const r of rooms) r.door += shiftOf(r).dx;

  const desks = [];
  for (const r of rooms.filter((x) => x.kind === "repo")) desks.push(...repoDesks(r));
  const leads = room("leads");
  const ld = (x) => at(leads, leads.x0 + x, 30);
  desks.push(mkDesk("scofield", "leads", ld(22).x, ld(22).y, "s", 32), mkDesk("amy", "leads", ld(68).x, ld(68).y, "s", 32));
  const mattAt = at(room("matt"), 36, 194);
  const mattDesk = mkDesk("matt", "matt", mattAt.x, mattAt.y, "s", 46);

  const meet = room("meet");
  const seat = (id, x, face) => ({ ...at(meet, meet.x0 + x, 50), face });
  const pts = (key, list) => list.map(([x, y]) => at(room(key), x, y));
  const spots = {
    kitchen: pts("kitchen", [[126, 216], [166, 216], [126, 246], [166, 246], [146, 206], [146, 256]]),
    lounge: pts("lounge", [[214, 184], [232, 184], [250, 184], [210, 228], [272, 228], [226, 258], [254, 258], [284, 200]]),
    pong: pts("pong", [[318, 224], [378, 224], [332, 264], [364, 264]]),
    rest: pts("rest", [[418, 200], [458, 200], [418, 252], [458, 252]]),
  };
  return {
    W, H, rooms, desks, mattDesk, spots,
    corr: { y: topH, h: corrH },
    // The entrance in the outer left wall: its mat, the light over it and the gap in the wall,
    // all centred on the corridor.
    entrance: { y: topH + (corrH - 24) / 2, h: 24, light: { y: topH + corrH / 2 - 4, h: 8 }, gap: { y0: topH + (corrH - 24) / 2 - 2, y1: topH + (corrH + 24) / 2 + 2 } },
    bed: at(room("lounge"), 196 + 88, 270),
    meetSeats: { yoda: seat("yoda", 20, "e"), sara: seat("sara", 70, "w") },
    pods: rooms.filter((r) => r.kind === "repo").map((r) => ({ repo: r.label, px: r.x + r.w / 2 })),
  };
}

/** The room a point is in, or null in the corridor. */
export function roomAt(world, x, y) {
  if (y >= world.corr.y && y <= world.corr.y + world.corr.h) return null;
  return world.rooms.find((r) => x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) || null;
}

/** The point just inside a room's door. */
export function doorInner(room) {
  return { x: room.door, y: room.row === "top" ? room.y + room.h - 10 : room.y + 10 };
}

/** The corridor lane a walker uses: a little different for each person, so two do not overlap. */
export function laneFor(id, world) {
  const mid = world && world.corr ? world.corr.y + world.corr.h / 2 : LANE_Y;
  return mid + ((hash(String(id)) % 5) - 2) * 3;
}

/** Door-to-door waypoints from one point to another (the destination is the last one). */
export function pathTo(world, id, from, to) {
  const lane = laneFor(id, world);
  const rf = roomAt(world, from.x, from.y);
  const rt = roomAt(world, to.x, to.y);
  if (rf && rf === rt) return [{ x: to.x, y: to.y }];
  const pts = [];
  if (rf) { const d = doorInner(rf); pts.push(d, { x: d.x, y: lane }); } else pts.push({ x: from.x, y: lane });
  if (rt) { const d = doorInner(rt); pts.push({ x: d.x, y: lane }, d); } else pts.push({ x: to.x, y: lane });
  pts.push({ x: to.x, y: to.y });
  return pts;
}

/** Waypoints as timed steps: where to, which way the walker faces, and how long it takes at `speed` units a second. */
export function legsOf(from, points, speed = WALK_SPEED) {
  const legs = [];
  let at = from;
  for (const p of points) {
    const dx = p.x - at.x;
    const dy = p.y - at.y;
    const dist = Math.hypot(dx, dy);
    if (dist < 0.01) continue;
    const face = Math.abs(dy) > Math.abs(dx) ? (dy < 0 ? "n" : "s") : (dx < 0 ? "w" : "e");
    legs.push({ x: p.x, y: p.y, face, ms: Math.round((dist / speed) * 1000) });
    at = p;
  }
  return legs;
}

/** How long a new place has to hold before the person sets off for it, in ms. */
export const GOAL_HOLD = 2500;

/**
 * One render's decision about where someone goes. `planned` is the place they are at or walking to,
 * `goal` the place the crew's state gives them now, `pending` what an earlier render saw first
 * ({ goal, since } or null). Someone sets off only once the new place has held for GOAL_HOLD ms, so a
 * state that flips back within moments (a message answered in a few seconds) moves nobody, and never
 * while they are walking: a walk is not redirected, because its movers are already running in the
 * renderer. It ends, and the new walk starts from where it ended. `wakeIn` is when to render again
 * to find out, or null when something else (the end of the walk, another change) will.
 */
export function nextGoal(pending, planned, goal, now, walking) {
  if (goal.x === planned.x && goal.y === planned.y) return { pending: null, go: false, wakeIn: null };
  const p = pending && pending.goal.x === goal.x && pending.goal.y === goal.y ? pending : { goal, since: now };
  const left = GOAL_HOLD - (now - p.since);
  if (left > 0) return { pending: p, go: false, wakeIn: left };
  if (walking) return { pending: p, go: false, wakeIn: null };
  return { pending: null, go: true, wakeIn: null };
}

/** How long a whole walk takes, in ms. */
export function walkMs(legs) {
  return legs.reduce((s, l) => s + l.ms, 0);
}

/**
 * A walk as one chain of nested movers, so the whole walk can be handed to the renderer at once. Link i
 * moves by (dx, dy) from where link i-1 left it, `ms` long, starting `delay` ms in (the sum of the legs
 * before it). The links add up to the walk; the renderer's own clock times every corner, so no timer
 * has to land on time for the walker not to stop. There are always `slots` links, the spare ones
 * going nowhere, so the same elements are drawn whether or not someone is walking. A walk with more
 * legs than slots ends its last link at the goal in one go.
 */
export function walkChain(from, legs, slots = 6) {
  const links = [];
  let at = from, delay = 0;
  legs.forEach((leg, i) => {
    if (i < slots) {
      links.push({ dx: leg.x - at.x, dy: leg.y - at.y, delay, ms: leg.ms });
    } else {
      const last = links[slots - 1];
      last.dx = leg.x - (at.x - last.dx); last.dy = leg.y - (at.y - last.dy); last.ms += leg.ms;
    }
    at = leg; delay += leg.ms;
  });
  while (links.length < slots) links.push({ dx: 0, dy: 0, delay: 0, ms: 1 });
  return { from, links };
}

/** Where a walker is `elapsed` ms into a walk, and which leg `i` that is (legs.length once it has arrived). */
export function posAt(from, legs, elapsed) {
  let at = from, t = elapsed;
  for (let i = 0; i < legs.length; i++) {
    const l = legs[i];
    if (t < l.ms) {
      const f = Math.max(0, t) / l.ms;
      return { x: at.x + (l.x - at.x) * f, y: at.y + (l.y - at.y) * f, i };
    }
    t -= l.ms; at = l;
  }
  return { x: at.x, y: at.y, i: legs.length };
}

/**
 * The stage's size as the next render should see it. herdr reports a size only after a layout, so for
 * one render after the panel opens or closes the size is still the old one: it is out by the panel's
 * width. `measuredWith` is whether the panel was showing when the size was measured.
 */
export function stageSize(size, measuredWith, showPanel, panelW) {
  if (!!measuredWith === !!showPanel) return size;
  const width = Math.max(1, size.width + (showPanel ? -panelW : panelW));
  return { width, height: size.height };
}

export const PANEL_DEFAULT = 360;
export const PANEL_MIN = 260;

/** A panel width kept inside its limits: PANEL_MIN up to half of `total` (the office pane's width). Anything that is not a number is the default. */
export function clampPanelW(w, total) {
  if (typeof w !== "number" || !Number.isFinite(w)) return PANEL_DEFAULT;
  const max = Math.max(PANEL_MIN, Math.floor((total || 0) / 2));
  return Math.min(max, Math.max(PANEL_MIN, Math.round(w)));
}

/** Where a crew's panel width is kept (shared state, so a reload keeps it). */
export function panelWidthKey(crew) {
  return `crew-office.panel-width.${crew || ""}`;
}

/** Where the lights choice is kept (shared state, so a reload and a restart keep it). One for the office, not per crew. */
export const LIGHTS_KEY = "crew-office.lights";

/** The remembered lights choice, read back: on unless it was saved as off. */
export function lightsFrom(saved) {
  return saved !== "off";
}

/** The value to save for a lights choice. */
export function lightsValue(on) {
  return on ? "on" : "off";
}

/**
 * The window that shows an agent's own terminal over the whole herdr window: a slim bar from this
 * mod (its Back button, and the unlock when the window goes) above the terminal block.
 * Esc goes to the terminal, as herdr documents for windows with terminals, so the bar is the way back.
 */
export function fullTerminalOverlay(agent, loh, termId) {
  return {
    kind: "window",
    key: "crew-office-terminal",
    width: 1,
    height: 1,
    at: { x: 0, y: 0 },
    layout: {
      type: "column",
      children: [
        { type: "block", size: { px: 34 }, content: { mod: "crew-office", props: { terminalBar: true, termId: termId || null, loh: loh || null, agent: { address: agent.address, name: agent.name, rawName: agent.rawName, cwd: agent.cwd || null } } } },
        { type: "block", content: { terminal: agent.address } },
      ],
    },
  };
}

/**
 * Who holds an agent's with-Matt lock: the docked chat and a full-terminal window, each by an id. The first
 * holder sets the lock and the last one to go releases it. `state` is { address: [ids] }, kept in module state (main.js holds it), shared by every copy of this source.
 */
const idsOf = (state, address) => {
  const v = state && typeof state === "object" ? state[address] : null;
  return Array.isArray(v) ? v : [];
};

export function holdersAcquire(state, address, id) {
  const cur = idsOf(state, address);
  return { state: { ...(state || {}), [address]: cur.includes(id) ? cur : [...cur, id] }, lock: cur.length === 0 };
}

export function holdersRelease(state, address, id) {
  const cur = idsOf(state, address);
  const next = cur.filter((x) => x !== id);
  const out = { ...(state || {}) };
  if (next.length) out[address] = next; else delete out[address];
  return { state: out, unlock: cur.includes(id) && next.length === 0 };
}

/** Whether a full-terminal window is open (for `address`, or for anyone when it is left out). Its ids start with "term-". */
export function termHeld(state, address) {
  const lists = state && typeof state === "object" ? (address ? [state[address]] : Object.values(state)) : [];
  return lists.some((l) => Array.isArray(l) && l.some((i) => String(i).startsWith("term-")));
}

/** One queue per key: each call starts when the one before it has finished, and a failure does not stop the ones after. */
export function serialQueue() {
  const tails = new Map();
  return (key, fn) => {
    const next = (tails.get(key) || Promise.resolve()).then(fn).catch(() => {});
    tails.set(key, next);
    return next;
  };
}

// ---------- who stands where ----------


// How long someone sits at their desk after their turn ends before going to the kitchen or the lounge.
export const IDLE_MS = 3 * 60 * 1000;
// A coder waiting on a review sits in the kitchen this long before ping pong, or PONG_LONE when someone plays alone.
export const PONG_AFTER = 15000;
export const PONG_LONE = 2000;
// After a clear, someone rests this long (zz) and then goes to the lounge.
export const REST_MS = 4000;

/** The idle time in ms from a setting in minutes (a number or a numeric string). Anything else gives IDLE_MS. */
export function idleMsOf(minutes) {
  const n = typeof minutes === "string" && minutes.trim() !== "" ? Number(minutes) : minutes;
  return typeof n === "number" && Number.isFinite(n) && n > 0 ? Math.round(n * 60000) : IDLE_MS;
}

/** The idle time in ms: the mod's `idleMinutes` prop when it is a positive number, else the workspace's setting, else IDLE_MS. */
export function pickIdleMs(prop, setting) {
  const ok = (v) => (typeof v === "number" || (typeof v === "string" && v.trim() !== "")) && Number.isFinite(Number(v)) && Number(v) > 0;
  return idleMsOf(ok(prop) ? prop : setting);
}

/** `idle_minutes` from `loh status --settings` output (a JSON object), or undefined. */
export function idleMinutesOf(text) {
  let v;
  try { v = JSON.parse(text); } catch { return undefined; }
  const n = v && typeof v === "object" ? v.idle_minutes : undefined;
  return typeof n === "number" && Number.isFinite(n) && n > 0 ? n : undefined;
}

// Matt's hands are on the keys this long after his last sign of activity (the prototype's away time is 20 s), and he stays
// seated at his desk, not typing, until MATT_SEAT_HOLD after it, before he goes to the lounge.
export const TYPING_HOLD = 20000;
export const MATT_SEAT_HOLD = 180000;

/**
 * Whether Matt is typing in herdr: `last` is when his last sign of activity was (0 for none). A mod sees keys only in its
 * own views, so a sign is a key in the office's message box, a click on a person, or herdr's focus moving onto the
 * terminal of an agent he opened from the office (see main.js). Never a key typed in a terminal.
 */
export function mattTypingAt(now, last) {
  return typeof last === "number" && last > 0 && now - last < TYPING_HOLD;
}

/** Whether Matt is still at his desk: within MATT_SEAT_HOLD of his last sign, typing or not. */
export function mattSeatedAt(now, last) {
  return typeof last === "number" && last > 0 && now - last < MATT_SEAT_HOLD;
}

/** Whether someone is at rest on their goal: standing exactly on it and not walking. Where the layout puts someone is
 * where they are going; only this says they are there. */
export function restAt(at, goal, walking) {
  return !walking && !!at && !!goal && at.x === goal.x && at.y === goal.y;
}

/**
 * The screens as they are seen: a desk's screen is lit as `work` only while its owner is at rest on their seat (`rest` is
 * a set of person ids to true), dim otherwise. Matt's monitors (`screens.matt`) follow the same rule. Other states
 * (a blocked agent's perm, question or esc screen) stay as the layout gives them.
 */
export function screensSeen(L, rest) {
  const out = { ...L.screens };
  for (const p of L.people) {
    if (!p.desk || !(p.desk in out) || out[p.desk] !== "work") continue;
    if (!rest[p.id]) out[p.desk] = "dim";
  }
  if (out.matt === "work" && !rest.matt) out.matt = "dim";
  return out;
}

/** Whether herdr's focus has just moved onto one of `open` (addresses of terminals opened from the office): the last focus was elsewhere. */
export function focusArrived(focusedTerminal, lastFocus, open) {
  return !!focusedTerminal && focusedTerminal !== lastFocus && (open || []).includes(focusedTerminal);
}

/**
 * How often the office asks GitHub whether the waiting coders' pull requests are still open: one `gh pr view` per coder
 * with a pr label (none when nobody waits), every 2 minutes, in the background, never in a render. A pull request merged
 * or closed by someone else ends the wait within that time; the coder's own merge or close ends it at once (the hook).
 */
export const PRS_EVERY_MS = 120000;
// How often the repo list is read again, whatever else changed: a manifest edit changes no key the office sees.
export const REPOS_EVERY_MS = 60000;

/** The command that has loh clear the pr label of every coder whose pull request ended. Same folder rules as reposCall. */
export function prsCall(agent, loh) {
  return { cmd: loh || "loh", args: ["status", "--prs"], options: { cwd: (agent && agent.cwd) || undefined, timeout: 30000 } };
}

/** The command that reads the workspace's settings. Same folder rules as reposCall. */
export function settingsCall(agent, loh) {
  return { cmd: loh || "loh", args: ["status", "--settings"], options: { cwd: (agent && agent.cwd) || undefined, timeout: 5000 } };
}

/**
 * What layoutCrew remembers between renders, so that people keep their places: when each person's turn ended (the
 * idle time counts from there), when a waiting coder sat down, when a clear began, and the spot and desk each person
 * held last time. Whoever is no longer in the office is forgotten. Keep one per office, never share it.
 */
export function newMemory() {
  return { act: new Map(), wait: new Map(), cleared: new Map(), spots: new Map(), desks: new Map(), pos: new Map() };
}

const SLOT_HOME = { opemipo: { room: 0, slot: 3 }, maya: { room: 1, slot: 2 } };
const AWAY = ["lounge", "kitchen"];
const KITCHEN = ["kitchen", "lounge"];

/**
 * Everyone, placed from real state. All twelve are always there. Where each stands (ticket #26):
 *  - a session that is open: at its own desk while working, blocked, or after its turn ends. Scofield, Amy, Yoda,
 *    Sara and a coder with no ticket go to the lounge once idle for `idleMs` (the kitchen when the lounge is full);
 *    a coder with a ticket stays at its desk;
 *  - a coder with a PR and no work in hand is waiting on its review: in the kitchen with a mug, at ping pong after
 *    about 15 s (2 s when someone plays alone); one that has escalated (its note starts with "escalation:", set by `loh card`) is at ping pong at once;
 *  - compacting (label ctx=compact) or clearing (ctx=clear): the rest room, zz; a compaction ends at the desk, a
 *    clear ends in the lounge after REST_MS;
 *  - no session: the lounge. Maya and Opemipo sit at their home desks while they run;
 *  - Matt at his desk while `mattTyping`, else away in the lounge; Waffles on her bed, or beside Matt while an agent is blocked.
 * Places are kept: `opts.mem` (see newMemory) remembers every desk and spot, and only someone who arrives or leaves
 * moves. `opts.now` is the time in ms and `opts.idleMs` the idle time. `wakeIn` in the result is when time alone changes
 * something next (ms), or null.
 * `aspect` is the pane's width over its height (see aspectOf); the floor is made to match it.
 * Repo rooms come from `repoList` (the manifest), then any repo a coder's task names.
 */
export function layoutCrew(crew, repoList = [], aspect = 0, opts = {}) {
  const now = typeof opts.now === "number" ? opts.now : 0;
  const idleMs = opts.idleMs > 0 ? opts.idleMs : IDLE_MS;
  const mem = opts.mem || newMemory();
  const extraRepos = [...new Set(crew.filter((a) => a.role === "coder" && a.repo).map((a) => a.repo))].filter((r) => !repoList.includes(r)).sort();
  const world = worldFor([...repoList, ...extraRepos], aspect);
  const { desks, rooms, spots } = world;
  const deskBy = new Map(desks.map((d) => [d.key, d]));
  const repoRooms = rooms.filter((r) => r.kind === "repo");

  const byCast = new Map();
  const extras = [];
  for (const a of crew) {
    const k = castKey(a, crew);
    if (k) byCast.set(k, a); else extras.push(a);
  }

  // Everyone as a record, before they are placed.
  const people = CAST.map((c) => ({ ...c, agent: byCast.get(c.id) || null }));
  for (const a of extras) people.push({ id: "x:" + a.address, name: a.name, title: a.role || "agent", role: a.role === "coder" ? "coder" : "extra", agent: a });
  for (const p of people) {
    p.running = !!p.agent;
    p.state = p.agent ? p.agent.status : "off";
    p.kind = p.agent ? p.agent.kind : null;
    p.dim = !p.running && p.id !== "matt" && p.id !== "dog";
    p.desk = null; p.place = null; p.face = "s"; p.spot = null; p.mug = false; p.paddle = 0; p.dir = 1; p.mode = null;
  }
  const by = (id) => people.find((p) => p.id === id);
  const wakes = [];

  // When each turn ended. Someone is busy while working or blocked or changing context; the idle time counts from the
  // render that first saw them not busy, and a done that turns idle does not restart it. Not seen before: counted from now.
  const live = new Set(people.filter((p) => p.agent).map((p) => p.id));
  for (const id of [...mem.act.keys()]) if (!live.has(id)) mem.act.delete(id);
  for (const p of people) {
    if (!p.agent) continue;
    const a = p.agent;
    p.busy = a.status === "working" || a.status === "blocked";
    const active = p.busy || !!a.ctx;
    const prev = mem.act.get(p.id);
    if (active) mem.act.set(p.id, { busy: true, since: now });
    else if (!prev) mem.act.set(p.id, { busy: false, since: a.statusMs !== null && a.statusMs <= now ? a.statusMs : now });
    else if (prev.busy) mem.act.set(p.id, { busy: false, since: now });
    p.idleFor = active ? 0 : now - mem.act.get(p.id).since;
    p.recent = p.idleFor < idleMs;
  }

  // Each running person's mode: what they are doing, which says where they are.
  const stillWait = new Set();
  for (const p of people) {
    if (!p.agent) continue;
    const a = p.agent;
    const ticket = a.repo !== "" && !(a.prDone && !a.pr);
    if (a.ctx === "compact") { p.mode = "rest"; mem.cleared.delete(p.id); continue; }
    if (a.ctx === "clear") {
      if (!mem.cleared.has(p.id)) mem.cleared.set(p.id, now);
      const left = REST_MS - (now - mem.cleared.get(p.id));
      if (left > 0) { p.mode = "rest"; wakes.push(left); } else p.mode = "lounge";
      continue;
    }
    mem.cleared.delete(p.id);
    const sitting = p.busy || p.recent;
    if (!p.busy && p.recent && !(p.role === "coder" && ticket) && !(p.id in SLOT_HOME)) wakes.push(idleMs - p.idleFor);
    if (p.role === "coder") {
      if (ticket) p.mode = p.busy ? "desk" : /^escalation:/.test(a.note) ? "esc" : a.pr ? "wait" : "desk";
      else p.mode = sitting ? "deskfree" : "away";
    } else if (p.id in SLOT_HOME) p.mode = "home";
    else if (p.id === "scofield" || p.id === "amy" || p.id === "yoda" || p.id === "sara") p.mode = sitting ? "home" : "away";
    else p.mode = "away";
    if (p.mode === "wait") stillWait.add(p.id);
  }
  for (const id of [...mem.wait.keys()]) if (!stillWait.has(id)) mem.wait.delete(id);
  for (const id of [...mem.cleared.keys()]) if (!live.has(id)) mem.cleared.delete(id);

  // Home desks for the helpers, then the coders' free slots in each repo room.
  const homes = {};
  if (repoRooms.length) {
    // A home desk is held only while its helper runs, so it never costs a coder a desk otherwise.
    for (const [id, h] of Object.entries(SLOT_HOME)) {
      if (!by(id).running) continue;
      const r = repoRooms[Math.min(h.room, repoRooms.length - 1)];
      homes[id] = repoDesks(r)[h.slot].key;
    }
  }
  const taken = new Set(Object.values(homes));
  const slots = new Map(repoRooms.map((r) => [r.key, repoDesks(r).map((d) => d.key).filter((k) => !taken.has(k))]));

  const sit = (p, d) => { p.desk = d.key; p.place = "desk"; p.x = d.seat.x; p.y = d.seat.y; p.face = d.side === "n" ? "s" : "n"; };
  const coders = people.filter((p) => p.role === "coder" && p.agent);
  const seeks = (c) => c.mode === "desk" || c.mode === "deskfree";
  // Desks stay with whoever held them: a coder with a task keeps its desk in its own room, and a coder who joins takes
  // a free one, so nobody slides. Then a working or blocked coder with none takes a free desk in the first room that has
  // one; if every desk is held, it takes the desk of a coder who is not working or blocked (who goes to the kitchen,
  // ping pong or lounge instead), never the lounge for itself.
  // A coder with no task who only sits there after its turn takes a free desk, and never takes one from anyone.
  const free = (key) => [...slots.values()].find((l) => l.includes(key));
  const take = (p, list, key) => { list.splice(list.indexOf(key), 1); p.desk = key; };
  const ticketed = coders.filter((c) => c.agent.repo);
  for (const p of ticketed) {
    const list = slots.get("repo:" + p.agent.repo), held = mem.desks.get(p.id);
    if (list && held && list.includes(held)) take(p, list, held);
  }
  for (const p of ticketed.filter((c) => !c.desk)) { const list = slots.get("repo:" + p.agent.repo); if (list && list.length) { p.desk = list[0]; list.shift(); } }
  const seekers = coders.filter((c) => !c.desk && seeks(c)).sort((a, b) => Number(b.busy) - Number(a.busy));
  for (const p of seekers) {
    const held = mem.desks.get(p.id);
    const heldList = held ? free(held) : null;
    if (heldList) { take(p, heldList, held); continue; }
    const list = [...slots.values()].find((l) => l.length);
    if (list) { p.desk = list.shift(); continue; }
    if (!p.busy) continue;
    const victim = [...coders].reverse().find((c) => c.desk && !c.busy);
    if (victim) { p.desk = victim.desk; victim.desk = null; }
  }
  mem.desks = new Map(coders.filter((c) => c.desk).map((c) => [c.id, c.desk]));

  // Matt: at his desk only while he is typing, else away in the lounge.
  const matt = by("matt");
  // Seated at his desk while a sign is recent (3 minutes); his hands type only for the first part of it (`mattTyping`). With only
  // `mattTyping` given, he is seated for as long as he types.
  const seated = opts.mattSeated !== undefined ? !!opts.mattSeated : !!opts.mattTyping;
  matt.state = seated ? "matt" : "away";
  matt.typing = seated && !!opts.mattTyping;

  // Who is at ping pong now, for the waiting coder who goes there sooner when someone plays alone.
  const atPong = new Set(people.filter((p) => p.mode === "esc").map((p) => p.id));
  for (const [id, s] of mem.spots) if (s.room === "pong" && live.has(id)) atPong.add(id);

  // Standing places first: desks, the meeting table, Matt.
  const needSpot = [];
  const need = (p, chain) => needSpot.push({ p, chain });
  for (const p of people) {
    if (p.id === "dog") continue;
    if (p.id === "matt") {
      if (seated) { p.x = world.mattDesk.seat.x; p.y = world.mattDesk.seat.y; p.face = "n"; p.place = "matt"; p.desk = "matt"; } else need(p, AWAY);
      continue;
    }
    if (!p.running) { need(p, AWAY); continue; }
    switch (p.mode) {
      case "rest": need(p, ["rest"]); break;
      case "lounge": need(p, AWAY); break;
      case "home":
        if (p.id === "yoda" || p.id === "sara") {
          const m = world.meetSeats[p.id];
          p.place = "meeting"; p.x = m.x; p.y = m.y; p.face = m.face;
        } else sit(p, deskBy.get(homes[p.id] || p.id));
        break;
      case "desk":
      case "deskfree":
        if (p.desk) sit(p, deskBy.get(p.desk)); else need(p, AWAY);
        break;
      case "esc": need(p, ["pong", "kitchen", "lounge"]); break;
      case "wait": {
        let w = mem.wait.get(p.id);
        if (!w) {
          const from = mem.pos.get(p.id) || null;
          const walk = from ? walkMs(legsOf(from, pathTo(world, p.id, from, spots.kitchen[0]))) : 0;
          // Counted from herdr's time for the status change when it gives one (a coder first seen after a long wait).
          const sat = p.agent.statusMs !== null && p.agent.statusMs <= now ? p.agent.statusMs : now;
          w = { arrive: sat + GOAL_HOLD + walk, pong: false };
          mem.wait.set(p.id, w);
        }
        const left = w.arrive + ([...atPong].filter((id) => id !== p.id).length === 1 ? PONG_LONE : PONG_AFTER) - now;
        if (left <= 0) w.pong = true; else if (!w.pong) wakes.push(left);
        need(p, w.pong ? ["pong", "kitchen", "lounge"] : KITCHEN);
        break;
      }
      default: need(p, AWAY);
    }
  }

  // Spots: someone who held a spot in a room last time, for the same reason, keeps it. The rest claim in order:
  // running people first, waiting coders before the rest, so ping pong goes to those who wait.
  const rank = (n) => (n.p.id === "matt" ? -1 : n.p.running ? 0 : 3) + (n.chain[0] === "pong" ? 0 : n.chain[0] === "kitchen" ? 1 : 2);
  const used = new Set();
  const claim = (room, id) => {
    const list = spots[room];
    const usable = room === "pong" ? [0, 1] : list.map((_, i) => i);
    const start = hash(id + room) % usable.length;
    for (let i = 0; i < usable.length; i++) {
      const idx = usable[(start + i) % usable.length];
      if (!used.has(room + ":" + idx)) { used.add(room + ":" + idx); return { ...list[idx], idx }; }
    }
    return null;
  };
  const why = (n) => n.chain.join(">");
  // Everyone placed last time keeps their spot, running or not: an arrival takes a free one along its rooms.
  for (const n of needSpot) {
    const h = mem.spots.get(n.p.id);
    if (h && h.why === why(n) && n.chain.includes(h.room) && !used.has(h.room + ":" + h.idx)) { used.add(h.room + ":" + h.idx); n.got = { ...spots[h.room][h.idx], idx: h.idx }; n.where = h.room; }
  }
  needSpot.map((n, i) => ({ n, i })).sort((a, b) => rank(a.n) - rank(b.n) || a.i - b.i).forEach(({ n }) => {
    const { p, chain } = n;
    let got = n.got || null;
    let where = n.where || "lounge";
    if (!got) for (const room of chain) { got = claim(room, p.id); if (got) { where = room; break; } }
    if (!got) { const s = spots.lounge[hash(p.id) % spots.lounge.length]; got = { x: s.x + 6, y: s.y + 4, idx: -1 }; where = "lounge"; }
    p.place = where; p.x = got.x; p.y = got.y; p.face = "s";
    if (where === "pong") { p.spot = "pong:" + got.idx; p.paddle = got.idx === 0 ? 1 : -1; }
    p.mug = where === "kitchen" || (where === "lounge" && p.role !== "coder");
    n.final = { room: where, idx: got.idx, why: why(n) };
  });
  mem.spots = new Map(needSpot.filter((n) => n.final && n.final.idx >= 0).map((n) => [n.p.id, n.final]));
  mem.pos = new Map(people.filter((p) => p.place).map((p) => [p.id, { x: p.x, y: p.y }]));

  // Waffles: asleep on her bed, or sitting beside Matt while an agent is blocked and needs him.
  const dog = by("dog");
  if (people.some((p) => p.state === "blocked")) { dog.state = "sit"; dog.x = matt.x + 11; dog.y = matt.y + 5; dog.dir = -1; } else { dog.state = "sleep"; dog.x = world.bed.x; dog.y = world.bed.y; }
  dog.place = "dog";

  // Name tags sit below a person, above one who sits at the top row of a pod.
  for (const p of people) {
    const d = p.place === "desk" ? deskBy.get(p.desk) : null;
    p.tag = { x: p.x, y: p.y + 9, up: !!d && d.side === "n" };
  }

  // What each desk's screen shows.
  const screens = {};
  for (const p of people) {
    if (!p.desk || p.id === "matt") continue;
    if (p.place !== "desk") { screens[p.desk] = "dim"; continue; }
    screens[p.desk] = p.state === "working" ? "work" : p.state === "blocked" ? (p.kind === "permission" ? "perm" : p.kind === "question" ? "q" : "esc") : "dim";
  }
  screens.matt = seated ? "work" : "dim";
  for (const p of people) if (p.id !== "matt") p.typing = p.state === "working" && p.place === "desk";

  const rally = people.filter((p) => p.spot === "pong:0" || p.spot === "pong:1").length === 2;
  const next = wakes.filter((w) => w > 0);
  return { ...world, people, dog, screens, rally, wakeIn: next.length ? Math.min(...next) : null, totals: totals(people.filter((p) => AGENT_IDS.includes(p.id) || p.id.startsWith("x:")).map((p) => ({ status: p.state === "off" ? "idle" : p.state }))) };
}

/**
 * Lay name tags out top to bottom. Each item is {id, x, y, w, h, up} in pixels (x, y the top left).
 * A tag that would cover one already placed moves clear of it: down, or up when it sits above its person.
 * Returns each tag's y by id.
 */
export function stackTags(items) {
  const placed = [];
  const out = new Map();
  const order = [...items].sort((a, b) => a.y - b.y || a.x - b.x || String(a.id).localeCompare(String(b.id)));
  for (const t of order) {
    let y = t.y;
    for (let n = 0; n < 8; n++) {
      const hit = placed.find((p) => t.x < p.x + p.w && p.x < t.x + t.w && y < p.y + p.h && p.y < y + t.h);
      if (!hit) break;
      y = t.up ? hit.y - t.h - 1 : hit.y + hit.h + 1;
    }
    placed.push({ x: t.x, y, w: t.w, h: t.h });
    out.set(t.id, y);
  }
  return out;
}

// ---------- starting someone who is not running ----------

/**
 * What a click on a person who is not running can offer. `loh up` starts Scofield and Amy. A coder
 * starts with `loh spawn <coder> <repo> <ticket>`: the offer lists `repos` (the manifest's) and
 * takes a ticket number. loh has no command for anyone else.
 */
export function startPlan(p, repos = [], dir = "") {
  if (!p || p.running) return { kind: "running" };
  if (p.id === "scofield" || p.id === "amy") return { kind: "up", ask: dir ? `Start Scofield and Amy in ${dir}?` : "Start Scofield and Amy with loh up?", hint: "loh up" };
  if (p.role === "coder") return { kind: "spawn", coder: p.id, repos: [...repos], hint: `loh spawn ${p.id} <repo> <ticket>` };
  return { kind: "none", hint: `loh has no command to start ${p.name}` };
}

/** A ticket number: digits only, not zero. */
export function validTicket(s) {
  return /^[0-9]+$/.test(String(s)) && Number(s) > 0;
}

/**
 * The command that runs a start plan, or null when the office cannot run it yet. A coder needs
 * `choice` = {repo, ticket}: the repo one of the plan's, the ticket digits.
 */
export function startCall(plan, cwd, loh, choice) {
  if (!plan) return null;
  if (plan.kind === "up") return { cmd: loh || "loh", args: ["up"], options: { cwd: cwd || undefined, timeout: 60000 } };
  if (plan.kind === "spawn" && choice && plan.repos.includes(choice.repo) && validTicket(choice.ticket)) {
    // spawn fetches, makes a worktree and reads the issue, so it gets longer than the lock calls.
    return { cmd: loh || "loh", args: ["spawn", plan.coder, choice.repo, String(choice.ticket)], options: { cwd: cwd || undefined, timeout: 180000 } };
  }
  return null;
}

/** The folder loh runs in to find the workspace: the coordinator's, any agent's, else the `dir` prop. */
export function anchorCwd(crew, props) {
  const a = crew.find((x) => x.role === "coordinator" && x.cwd) || crew.find((x) => x.cwd);
  if (a) return a.cwd;
  return props && typeof props.dir === "string" ? props.dir : "";
}

/**
 * With no agent running, the folder of another pane in the office's own tab (a terminal in the
 * same workspace). "" when there is none.
 */
export function ownCwd(panes, minePane) {
  const list = panes || [];
  const mine = list.find((p) => p.pane === minePane);
  const same = mine ? list.find((p) => p.tab === mine.tab && p.pane !== minePane && typeof p.cwd === "string" && p.cwd) : null;
  return same ? same.cwd : "";
}

/** The folder loh runs in: the `dir` prop, else a running agent's, else a pane in the office's own tab, else "". */
export function workspaceDir(crew, props, panes, minePane) {
  if (props && typeof props.dir === "string" && props.dir) return props.dir;
  return anchorCwd(crew, {}) || ownCwd(panes, minePane);
}
