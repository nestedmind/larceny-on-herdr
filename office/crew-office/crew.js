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
      round: clean(l.round, 4),
      note: clean(l.note, 60),
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
 * Scale that fits the floor into the stage, the area main.js measures for it (the bar and the offer row are outside it; 8px of padding all round).
 * It may drop below 1, so a narrow pane (the chat takes half the tab) shrinks the floor instead of
 * cutting it. `fits` is false only when even the smallest scale overflows: main.js then stops centring.
 */
export function fitScale(size, floor) {
  const raw = Math.min((size.width - 16) / floor.W, (size.height - 16) / floor.H);
  const k = Math.min(8, Math.max(MIN_SCALE, raw));
  return { k, fits: floor.W * k <= size.width - 16 + 0.5 };
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

const mkRoom = (key, kind, label, x, y, w, h, door) => ({ key, kind, label, x, y, w, h, door });

const mkDesk = (key, room, cx, y, side, w = 28) => ({
  key, room, cx, x: cx - w / 2, y, w, h: DESK_H, side,
  seat: { x: cx, y: side === "n" ? y - 6 : y + DESK_H + 6 },
});

export function repoDesks(room) {
  const px = room.x + REPO_W / 2;
  return [mkDesk(`${room.key}:1`, room.key, px - 15, 42, "n"), mkDesk(`${room.key}:2`, room.key, px + 15, 42, "n"),
    mkDesk(`${room.key}:3`, room.key, px - 15, 58, "s"), mkDesk(`${room.key}:4`, room.key, px + 15, 58, "s")];
}

/**
 * The floor plan, from the prototype: a row of repo rooms (one per repo, four desks each), then the
 * leads room and the meeting room; a corridor; then Matt's room, kitchen, lounge, ping pong and the
 * rest room. The top row grows with the repo count. The bottom row is 480 wide, so extra width goes
 * to the lounge and moves ping pong and the rest room over.
 */
export function worldFor(repoNames = []) {
  const repos = [...new Set(repoNames)];
  const n = repos.length;
  const topW = n * REPO_W + 2 * SIDE_W;
  const W = Math.max(topW, BASE_W);
  const e = W - BASE_W;
  const rooms = repos.map((r, i) => mkRoom("repo:" + r, "repo", r, i * REPO_W, 0, REPO_W, ROOM_H, i * REPO_W + REPO_W / 2));
  const leftEdge = n * REPO_W;
  rooms.push(mkRoom("leads", "leads", "Scofield · Amy", leftEdge, 0, SIDE_W, ROOM_H, leftEdge + 45));
  rooms.push(mkRoom("meet", "meet", "meeting", leftEdge + SIDE_W, 0, SIDE_W, ROOM_H, leftEdge + SIDE_W + 45));
  rooms.push(mkRoom("matt", "matt", "Matt", 0, ROW_Y, 96, ROW_H, 50));
  rooms.push(mkRoom("kitchen", "kitchen", "kitchen", 96, ROW_Y, 100, ROW_H, 146));
  rooms.push(mkRoom("lounge", "lounge", "lounge", 196, ROW_Y, 104 + e, ROW_H, 284));
  rooms.push(mkRoom("pong", "pong", "ping pong", 300 + e, ROW_Y, 96, ROW_H, 348 + e));
  rooms.push(mkRoom("rest", "rest", "rest room", 396 + e, ROW_Y, 84, ROW_H, 438 + e));
  const room = (k) => rooms.find((r) => r.kind === k);

  const desks = [];
  for (const r of rooms.filter((x) => x.kind === "repo")) desks.push(...repoDesks(r));
  const leads = room("leads");
  desks.push(mkDesk("scofield", "leads", leads.x + 22, 30, "s", 32), mkDesk("amy", "leads", leads.x + 68, 30, "s", 32));
  const mattDesk = mkDesk("matt", "matt", 36, 194, "s", 46);

  const meet = room("meet");
  const spots = {
    kitchen: [{ x: 126, y: 216 }, { x: 166, y: 216 }, { x: 126, y: 246 }, { x: 166, y: 246 }, { x: 146, y: 206 }, { x: 146, y: 256 }],
    lounge: [{ x: 214, y: 184 }, { x: 232, y: 184 }, { x: 250, y: 184 }, { x: 210, y: 228 }, { x: 272, y: 228 }, { x: 226, y: 258 }, { x: 254, y: 258 }, { x: 284, y: 200 }],
    pong: [{ x: 318 + e, y: 224 }, { x: 378 + e, y: 224 }, { x: 332 + e, y: 264 }, { x: 364 + e, y: 264 }],
    rest: [{ x: 418 + e, y: 200 }, { x: 458 + e, y: 200 }, { x: 418 + e, y: 252 }, { x: 458 + e, y: 252 }],
  };
  return {
    W, H: WORLD_H, rooms, desks, mattDesk, spots,
    bed: { x: room("lounge").x + 88, y: 270 },
    meetSeats: { yoda: { x: meet.x + 20, y: 50, face: "e" }, sara: { x: meet.x + 70, y: 50, face: "w" } },
    pods: rooms.filter((r) => r.kind === "repo").map((r) => ({ repo: r.label, px: r.x + REPO_W / 2 })),
  };
}

/** The room a point is in, or null in the corridor. */
export function roomAt(world, x, y) {
  if (y >= ROOM_H && y <= ROW_Y) return null;
  return world.rooms.find((r) => x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) || null;
}

/** The point just inside a room's door. */
export function doorInner(room) {
  return { x: room.door, y: room.y === 0 ? ROOM_H - 10 : ROW_Y + 10 };
}

/** The corridor lane a walker uses: a little different for each person, so two do not overlap. */
export function laneFor(id) {
  return LANE_Y + ((hash(String(id)) % 5) - 2) * 3;
}

/** Door-to-door waypoints from one point to another (the destination is the last one). */
export function pathTo(world, id, from, to) {
  const lane = laneFor(id);
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

// ---------- who stands where ----------

const SLOT_HOME = { opemipo: { room: 0, slot: 3 }, maya: { room: 1, slot: 2 } };

/**
 * Everyone, placed from real state. All twelve are always there.
 *  - a coder with a task and a free desk: working or blocked at the desk; done in the kitchen;
 *    idle at ping pong. The desk stays its own while it is away, so the others do not move.
 *  - a coder without a desk, and anyone not running: the lounge (then the kitchen and the rest room when full)
 *  - Scofield and Amy at their own desks while running; Yoda and Sara at the meeting table
 *  - Maya and Opemipo at a home desk in the repo rooms while running
 *  - Matt at his desk; Waffles on her bed, or beside Matt while an agent is blocked
 * Repo rooms come from `repoList` (the manifest), then any repo a coder's task names. Desks are given
 * in name order, so a desk does not move while the crew is the same.
 */
export function layoutCrew(crew, repoList = []) {
  const extraRepos = [...new Set(crew.filter((a) => a.role === "coder" && a.repo).map((a) => a.repo))].filter((r) => !repoList.includes(r)).sort();
  const world = worldFor([...repoList, ...extraRepos]);
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
    p.desk = null; p.place = null; p.face = "s"; p.spot = null; p.mug = false; p.paddle = 0; p.dir = 1;
  }
  const by = (id) => people.find((p) => p.id === id);

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
  const busy = (c) => c.state === "working" || c.state === "blocked";
  const own = (p) => { const list = slots.get("repo:" + p.agent.repo); if (list && list.length) p.desk = list.shift(); };
  // Everyone with a task takes a desk in their own room, in name order, so desks stay put while the
  // crew is the same. Then a working or blocked coder with none takes a free desk in the first room
  // that has one; if every desk is held, it takes the desk of an idle or done coder (who goes to the
  // kitchen, ping pong or lounge instead). A busy coder is never in the lounge while a desk could be theirs.
  for (const p of coders.filter((c) => c.agent.repo)) own(p);
  for (const p of coders.filter((c) => !c.desk && busy(c))) {
    const list = [...slots.values()].find((l) => l.length);
    if (list) { p.desk = list.shift(); continue; }
    const victim = [...coders].reverse().find((c) => c.desk && !busy(c));
    if (victim) { p.desk = victim.desk; victim.desk = null; }
  }

  // Standing places first: desks, the meeting table, Matt.
  const needSpot = [];
  for (const p of people) {
    if (p.id === "matt") { p.x = world.mattDesk.seat.x; p.y = world.mattDesk.seat.y; p.face = "n"; p.place = "matt"; p.desk = "matt"; continue; }
    if (p.id === "dog") continue;
    if (!p.running) { needSpot.push({ p, chain: ["lounge", "kitchen", "rest"] }); continue; }
    // Scofield and Amy are at their desks while working or blocked; idle or done they go to the lounge or kitchen.
    if ((p.id === "scofield" || p.id === "amy") && (p.state === "working" || p.state === "blocked")) { sit(p, deskBy.get(p.id)); continue; }
    if (p.id === "yoda" || p.id === "sara") {
      const m = world.meetSeats[p.id];
      p.place = "meeting"; p.x = m.x; p.y = m.y; p.face = m.face;
      continue;
    }
    if (homes[p.id]) { sit(p, deskBy.get(homes[p.id])); continue; }
    if (p.role === "coder") {
      if (p.desk && (p.state === "working" || p.state === "blocked")) { sit(p, deskBy.get(p.desk)); continue; }
      if (p.state === "done") { needSpot.push({ p, chain: ["kitchen", "rest", "lounge"] }); continue; }
      if (p.state === "idle" && p.agent.repo) { needSpot.push({ p, chain: ["pong", "kitchen", "lounge", "rest"] }); continue; }
    }
    needSpot.push({ p, chain: p.state === "done" ? ["kitchen", "rest", "lounge"] : ["lounge", "kitchen", "rest"] });
  }

  // Spots: running people first, waiting coders before the rest, so ping pong goes to those who wait.
  const rank = (n) => (n.p.running ? 0 : 3) + (n.chain[0] === "pong" ? 0 : n.chain[0] === "kitchen" ? 1 : 2);
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
  needSpot.map((n, i) => ({ n, i })).sort((a, b) => rank(a.n) - rank(b.n) || a.i - b.i).forEach(({ n }) => {
    const { p, chain } = n;
    let got = null;
    let where = "lounge";
    for (const room of chain) { got = claim(room, p.id); if (got) { where = room; break; } }
    if (!got) { const s = spots.lounge[hash(p.id) % spots.lounge.length]; got = { x: s.x + 6, y: s.y + 4, idx: -1 }; }
    p.place = where; p.x = got.x; p.y = got.y; p.face = "s";
    if (where === "pong") { p.spot = "pong:" + got.idx; p.paddle = got.idx === 0 ? 1 : -1; }
    p.mug = where === "kitchen" || (where === "lounge" && p.role !== "coder");
  });

  // Waffles: asleep on her bed, or sitting beside Matt while an agent is blocked and needs him.
  const dog = by("dog");
  const matt = by("matt");
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
  screens.matt = "work";

  const rally = people.filter((p) => p.spot === "pong:0" || p.spot === "pong:1").length === 2;
  return { ...world, people, dog, screens, rally, totals: totals(people.filter((p) => AGENT_IDS.includes(p.id) || p.id.startsWith("x:")).map((p) => ({ status: p.state === "off" ? "idle" : p.state }))) };
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
 * With no agent running, the folder of a pane in the office's own tab, else of any pane
 * (a terminal in the same workspace). "" when none has one.
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
