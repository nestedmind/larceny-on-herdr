// Pure logic for the chat panel. No herdr or gpui imports, so node can test it:
// the commands the panel runs, the parsing of what they print, the pending-message
// bookkeeping and the activity feed's diff of agent states. panel.js draws it.

const FEED_MAX = 100;

/** Strip control characters and cut to n characters. */
function clip(value, n) {
  const s = String(value ?? "").replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, " ").trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

/** `loh transcript <name> --last N`, run in the agent's own folder (loh finds the workspace from there). */
export function transcriptCall(agent, loh, last = 40) {
  return { cmd: loh || "loh", args: ["transcript", agent.rawName, "--last", String(last)], options: { cwd: agent.cwd || undefined, timeout: 8000 } };
}

/** `loh tell <name> <text>`: the text is one argument, so nothing in it is read as an option or a shell word. */
export function tellCall(agent, loh, text) {
  return { cmd: loh || "loh", args: ["tell", agent.rawName, text], options: { cwd: agent.cwd || undefined, timeout: 15000 } };
}

/** The turns in `loh transcript` output: [{ role, text, ts }]. Anything else gives []. */
export function parseTranscript(text) {
  let list;
  try { list = JSON.parse(text); } catch { return []; }
  if (!Array.isArray(list)) return [];
  const out = [];
  for (const m of list) {
    if (!m || (m.role !== "user" && m.role !== "assistant") || typeof m.text !== "string" || m.text === "") continue;
    out.push({ role: m.role, text: m.text, ts: typeof m.ts === "string" ? m.ts : "", pending: false });
  }
  return out;
}

/**
 * The log to show: the transcript, then Matt's messages that were sent but are not in the
 * transcript yet (the session file lags the send). A pending message is "in" once a user turn
 * of the transcript has the same text.
 */
export function withPending(turns, pending) {
  const seen = turns.filter((m) => m.role === "user").map((m) => m.text.trim());
  const rest = pending.filter((p) => !seen.includes(p.text.trim()));
  return { shown: [...turns, ...rest.map((p) => ({ role: "user", text: p.text, ts: "", pending: true }))], pending: rest };
}

/** What to tell Matt when `loh tell` failed: loh's own line, without its "loh: " prefix. */
export function tellError(result, name) {
  const first = String((result && result.stderr) || "").split("\n").map((l) => l.trim()).find(Boolean) || "";
  const msg = first.replace(/^loh:\s*/, "");
  if (msg) return clip(msg, 200);
  return `could not send to ${name} (loh exited ${result && result.code})`;
}

/** Why Send is off for this agent, or "" when it can send. Blocked agents wait on a dialog the message would answer. */
export function sendBlock(agent) {
  if (!agent) return "";
  if (agent.status !== "blocked") return "";
  const what = agent.kind === "permission" ? "a permission dialog" : agent.kind === "question" ? "a question" : "a dialog";
  return `${agent.name} is waiting on ${what}. Answer it in the terminal; a typed message would answer it for you.`;
}

/** Card rows for an agent: [label, value], only the ones known. */
export function cardRows(agent, words) {
  const rows = [["Role", agent.role || "agent"], ["State", words[agent.status] || agent.status]];
  if (agent.status === "blocked") rows[1][1] = `${words.blocked}${agent.kind && agent.kind !== "other" ? ` (${agent.kind})` : ""}`;
  if (agent.repo) rows.push(["Ticket", `${agent.repo}${agent.ticket ? "#" + agent.ticket : ""}`]);
  if (agent.pr) rows.push(["PR", `${agent.pr}${agent.round ? ` · round ${agent.round}` : ""}`]);
  if (agent.step) rows.push(["Step", agent.step]);
  if (agent.note) rows.push(["Note", agent.note]);
  if (agent.withMatt) rows.push(["Lock", "with Matt"]);
  return rows;
}

const SAYS = {
  working: () => "started working",
  done: () => "finished a turn",
  idle: () => "is idle",
  blocked: (kind) => `needs you (${kind || "other"})`,
};

/**
 * Compare the crew with what the last call saw and report changes. `seen` maps address to
 * { status, note }; the first call only records a baseline. Returns { seen, events }, events as
 * { name, text, level } in the order of the crew; level is "blocked", "done" or "info".
 * The source is the same status and note labels `loh watch` follows.
 */
export function activityDiff(seen, crew, first) {
  const next = new Map();
  const events = [];
  for (const a of crew) {
    const before = seen.get(a.address);
    next.set(a.address, { status: a.status, note: a.note });
    if (first || !before) continue;
    if (before.status !== a.status && SAYS[a.status]) {
      events.push({ name: a.name, text: SAYS[a.status](a.kind), level: a.status === "blocked" ? "blocked" : a.status === "done" ? "done" : "info" });
    }
    if (a.note !== before.note && /^escalation:/.test(a.note)) {
      events.push({ name: a.name, text: `escalates: ${a.note.replace(/^escalation:/, "")}`, level: "blocked" });
    }
  }
  return { seen: next, events };
}

/** Append events to a feed, keeping the newest FEED_MAX. `at` is the time label. */
export function pushFeed(feed, events, at) {
  const out = feed.concat(events.map((e) => ({ ...e, at })));
  return out.length > FEED_MAX ? out.slice(out.length - FEED_MAX) : out;
}

/** HH:MM for a Date. */
export function clock(d) {
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** The key that says a refetch of the transcript is due: it changes when the agent's turn or state does. */
export function fetchKey(agent, raw) {
  return [agent.address, agent.status, agent.step, agent.note, raw && raw.turn != null ? raw.turn : ""].join("|");
}
