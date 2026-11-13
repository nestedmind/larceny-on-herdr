// Pure placement logic for the crew office. No herdr imports: it takes the
// array that `terminals()` returns (the same shape as `hc ls --json`) and
// returns where everyone sits. All coordinates are in world units; main.js
// scales them to the pane.

export const ROOM_H = 135;
export const DESK_W = 30;
export const DESK_H = 16;
export const REPO_W = 144;
const SIDE_W = 100;
const LOUNGE_Y = 155;
const LOUNGE_H = 95;
const MAX_DESKS = 4;

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

/** The crew: terminals labelled crew=<workspace>, as plain records. */
export function crewOf(terminals, workspace) {
  const out = [];
  for (const t of terminals) {
    const l = t.labels || {};
    if (!workspace || l.crew !== workspace) continue;
    if (t.state && t.state !== "live") continue;
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

export function totals(crew) {
  const n = { working: 0, blocked: 0, done: 0, idle: 0 };
  for (const a of crew) n[STATES.includes(a.status) ? a.status : "idle"] += 1;
  return n;
}

function repoDesks(room) {
  const cx = room.x + REPO_W / 2;
  const mk = (i, dx, y, side) => ({ x: cx + dx - DESK_W / 2, y, side, seat: { x: cx + dx, y: side === "n" ? y - 8 : y + DESK_H + 8 }, tag: { x: cx + dx, y: side === "n" ? y + DESK_H + 3 : y + DESK_H + 18 } });
  return [mk(0, -32, 30, "n"), mk(1, 32, 30, "n"), mk(2, -32, 78, "s"), mk(3, 32, 78, "s")];
}

/**
 * Where everyone goes.
 *  - coder with a task: a desk in that repo's room (up to four; a fifth waits in the lounge)
 *  - coder with no task: the lounge
 *  - coordinator and reviewer: the leads room; advisor and teacher: the meeting room
 *  - anyone else: the lounge
 * Desks are given in name order, so a desk does not move while the crew is the same.
 */
export function layoutCrew(crew) {
  const repos = [...new Set(crew.filter((a) => a.role === "coder" && a.repo).map((a) => a.repo))].sort();
  const rooms = repos.map((r, i) => ({ key: "repo:" + r, kind: "repo", label: r, x: i * REPO_W, y: 0, w: REPO_W, h: ROOM_H }));
  const leftEdge = rooms.length * REPO_W;
  rooms.push({ key: "leads", kind: "leads", label: "Scofield · Amy", x: leftEdge, y: 0, w: SIDE_W, h: ROOM_H });
  rooms.push({ key: "meet", kind: "meet", label: "meeting", x: leftEdge + SIDE_W, y: 0, w: SIDE_W, h: ROOM_H });
  const W = Math.max(leftEdge + 2 * SIDE_W, 380);
  const lounge = [];

  const desks = [];
  const seats = [];
  const used = new Map();
  const leads = rooms.find((r) => r.key === "leads");
  const meet = rooms.find((r) => r.key === "meet");
  const standing = { coordinator: 0, reviewer: 0, advisor: 0, teacher: 0 };

  const leadDesk = (i) => {
    const cx = leads.x + (i === 0 ? 28 : 72);
    return { x: cx - 16, y: 30, side: "s", seat: { x: cx, y: 22 }, tag: { x: cx, y: 49 }, w: 32 };
  };

  for (const a of crew) {
    if (a.role === "coder" && a.repo) {
      const room = rooms.find((r) => r.key === "repo:" + a.repo);
      const slot = used.get(room.key) || 0;
      if (slot < MAX_DESKS) {
        used.set(room.key, slot + 1);
        const d = repoDesks(room)[slot];
        desks.push({ x: d.x, y: d.y, w: DESK_W, h: DESK_H, side: d.side });
        seats.push({ agent: a, x: d.seat.x, y: d.seat.y, face: d.side === "n" ? "s" : "n", tag: d.tag, place: "desk" });
        continue;
      }
    } else if (a.role === "coordinator" || a.role === "reviewer") {
      if (standing[a.role] === 0) {
        standing[a.role] = 1;
        const d = leadDesk(a.role === "coordinator" ? 0 : 1);
        desks.push({ x: d.x, y: d.y, w: d.w, h: DESK_H, side: "s" });
        seats.push({ agent: a, x: d.seat.x, y: d.seat.y, face: "s", tag: d.tag, place: "desk" });
        continue;
      }
    } else if (a.role === "advisor" || a.role === "teacher") {
      if (standing[a.role] === 0) {
        standing[a.role] = 1;
        const west = a.role === "advisor";
        const x = meet.x + (west ? 24 : 76);
        seats.push({ agent: a, x, y: 40, face: west ? "e" : "w", tag: { x, y: 54 }, place: "meeting" });
        continue;
      }
    }
    lounge.push(a);
  }

  const perRow = Math.max(1, Math.floor((W - 20) / 70));
  lounge.forEach((a, i) => {
    const row = Math.floor(i / perRow);
    const col = i % perRow;
    const x = 40 + col * 70;
    const y = LOUNGE_Y + 28 + row * 40;
    seats.push({ agent: a, x, y, face: "s", tag: { x, y: y + 9 }, place: "lounge" });
  });

  const loungeH = Math.max(LOUNGE_H, 28 + Math.ceil(lounge.length / perRow) * 40 + 10);
  rooms.push({ key: "lounge", kind: "lounge", label: "lounge", x: 0, y: LOUNGE_Y, w: W, h: loungeH });
  return { W, H: LOUNGE_Y + loungeH, rooms, desks, seats, totals: totals(crew) };
}
