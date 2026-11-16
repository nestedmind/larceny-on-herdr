// Pure logic for the chat panel. No herdr or gpui imports, so node can test it:
// the commands the panel runs, the parsing of what they print, the pending-message
// bookkeeping and the activity feed's diff of agent states. panel.js draws it.

const FEED_MAX = 100;
// `hc send` waits up to its draft_wait (60 s by default) for a half-typed draft in the target's
// terminal. The call must outlast that, or a send that is still going to happen looks like a failure.
export const TELL_TIMEOUT = 75000;

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
  return { cmd: loh || "loh", args: ["tell", agent.rawName, text], options: { cwd: agent.cwd || undefined, timeout: TELL_TIMEOUT } };
}

/** The turns in `loh transcript` output: [{ role, text, ts }]. Anything else gives []. */
export function parseTranscript(text) {
  let list;
  try { list = JSON.parse(text); } catch { return []; }
  if (!Array.isArray(list)) return [];
  const out = [];
  for (const m of list) {
    if (!m || (m.role !== "user" && m.role !== "assistant" && m.role !== "agent") || typeof m.text !== "string" || m.text === "") continue;
    // role "agent" is another agent's message into this session; `from` is its sender.
    // `loh transcript` reads the whole session and flags its first user turn when that is the launch prompt
    // (wrapped in <pasted_content>). The window shown here may start later, so only that flag counts: a paste of Matt's is his.
    const launch = m.role === "user" && m.launch === true;
    out.push({ role: m.role, text: m.text, ts: typeof m.ts === "string" ? m.ts : "", from: typeof m.from === "string" ? clip(m.from, 24) : "", pending: false, unsure: false, launch, via: m.via === "discord" ? "discord" : "" });
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
  return { shown: [...turns, ...rest.map((p) => ({ role: "user", text: p.text, ts: "", from: "", pending: true, unsure: !!p.unsure }))], pending: rest };
}

/**
 * What a rejected exec means. herdr.d.ts says exec rejects when the program cannot start, and says
 * nothing about a timeout, which might reject too. A rejection within REJECT_QUICK_MS is a start
 * failure (nothing ran: "failed"); a later one may be a timeout with the send still going out
 * ("unknown").
 */
export const REJECT_QUICK_MS = 5000;
export function rejectOutcome(elapsedMs) {
  return typeof elapsedMs === "number" && elapsedMs >= 0 && elapsedMs < REJECT_QUICK_MS ? "failed" : "unknown";
}

/**
 * What happened to a `loh tell` call that returned: "sent", "failed" (loh said no, and said why: nothing
 * was sent) or "unknown" (killed or cut off with no word from loh, or exit 12: `hc send` failed after it
 * may have typed, so the message may still go out).
 */
export function tellOutcome(result) {
  if (!result || typeof result.code !== "number") return "unknown";
  if (result.code === 0) return "sent";
  const said = String(result.stderr || "").trim() !== "";
  return [1, 2, 9, 10, 11].includes(result.code) && said ? "failed" : "unknown";
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

/** What the owner is called where a person reads it: `person:` from the crew config, else a neutral word. */
export function ownerName(person) {
  return person ? String(person) : "Owner";
}

/** Who a log turn is from: the owner for typed turns, the sender's name for another agent's message. */
export function speaker(m, agentName, person = "") {
  if (m.launch) return "launch prompt";
  if (m.role === "user") return ownerName(person);
  if (m.role === "agent") return m.from || "another agent";
  return agentName;
}

/** The small mark after the speaker of a turn that came in through a channel. */
export function viaMark(m) {
  return m.via === "discord" ? " · via Discord" : "";
}

/** Whose floor figure is the avatar of a turn, as a lower-case name. The owner's typed turns carry the owner's name. */
export function avatarName(m, agent, person = "") {
  if (m.role === "user") return ownerName(person).toLowerCase();
  if (m.role === "agent") return String(m.from || "").toLowerCase();
  return String((agent && (agent.rawName || agent.name)) || "").toLowerCase();
}

/** The text a turn shows: a launch prompt is one clipped line without its wrapper tags. */
export function shownText(m) {
  if (m.launch) return clip(m.text.replace(/<\/?pasted_content\b[^>]*>/g, " ").replace(/\s+/g, " "), 140);
  return m.text;
}

/** The markdown a turn hands to the text view: the text as written, trimmed. Launch prompts stay one plain line. */
export function markdownOf(m) {
  return shownText(m).trim();
}

/** An agent's name for the screen: the first letter capitalised ("scofield" is "Scofield"). */
export function displayName(name) {
  const s = String(name || "");
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export const SEND_HINT = "Enter sends · Ctrl+Enter adds a line";
export const GROUP_MS = 7 * 60 * 1000;

/** What a key in the message box does: "send" (Enter), "newline" (Ctrl+Enter) or null (leave it to the box). */
export function enterAction(e) {
  if (!e || e.key !== "enter") return null;
  const m = e.modifiers || {};
  if (m.shift || m.alt || m.platform) return null;
  return m.control ? "newline" : "send";
}

/**
 * The log as rows { m, head }: head is true when the turn starts a group (photo and name shown). A turn
 * continues the group before it when the speaker is the same, neither is a launch prompt or pending,
 * both came in the same way (typed or via Discord), and both have a time at most GROUP_MS apart.
 */
export function groupLog(turns, agentName, person = "") {
  const out = [];
  const seen = new Map();
  let prev = null;
  for (const m of turns) {
    const who = speaker(m, agentName, person);
    const at = m.ts ? Date.parse(m.ts) : NaN;
    const joins = prev && !m.launch && !prev.m.launch && !m.pending && !prev.m.pending && prev.who === who
      && (prev.m.via || "") === (m.via || "")
      && Number.isFinite(at) && Number.isFinite(prev.at) && at - prev.at >= 0 && at - prev.at <= GROUP_MS;
    out.push({ m, head: !joins, key: turnKey(m, seen) });
    prev = { m, who, at };
  }
  return out;
}

/**
 * The space round row `i` of a grouped log, from Maya's spec (changes-p1.md, Round 2): a new speaker starts 16 px
 * under the last turn and a grouped turn 4 px under it. Matt's turns sit in a band that reaches 8 px above and 8 px
 * below his group, so a band's edge is 8 px from its neighbour and 8 px from its own content. `mt` is outside the
 * band, `pt` and `pb` inside the row (and so inside the band, where there is one).
 */
export function rowSpace(log, i) {
  const mineAt = (r) => !!r && r.m.role === "user" && !r.m.launch;
  const row = log[i], prev = log[i - 1], next = log[i + 1];
  const mine = mineAt(row);
  const pb = mine && !(next && !next.head && mineAt(next)) ? 8 : 0;
  if (!row.head) return { mt: 0, pt: 4, pb };
  if (mine) return { mt: i === 0 || mineAt(prev) ? 0 : 8, pt: 8, pb };
  return { mt: 0, pt: i === 0 ? 8 : mineAt(prev) ? 8 : 16, pb };
}

/**
 * A key for a turn that stays with the turn when the 40-turn window slides: its role, time and text, plus a
 * count for an identical earlier turn in the same log (`seen` carries the counts). Not the position.
 */
export function turnKey(m, seen) {
  const base = `${m.pending ? "p" : m.role}|${m.from || ""}|${m.ts || ""}|${m.text.length}|${hashOf(m.text)}`;
  const n = (seen.get(base) || 0) + 1;
  seen.set(base, n);
  return `${base}|${n}`;
}

function hashOf(text) {
  let h = 5381;
  for (let i = 0; i < text.length; i++) h = ((h << 5) + h + text.charCodeAt(i)) | 0;
  return (h >>> 0).toString(36);
}

/** What Copy puts on the clipboard for one turn: its whole text. */
export function copyText(m) {
  return m.text;
}

/** What Copy all puts on the clipboard: each turn as "Name · HH:MM", a newline and its text, a blank line between turns. */
export function copyAll(turns, agentName, person = "") {
  return turns.map((m) => {
    const t = m.ts && Number.isFinite(Date.parse(m.ts)) ? ` · ${clock(new Date(m.ts))}` : "";
    return `${speaker(m, agentName, person)}${t}\n${m.text}`;
  }).join("\n\n");
}

/** The Crew activity list: the "Office opened" row, then every change in order. */
export function feedRows(feed) {
  return [{ at: "", text: "Office opened. Changes before this are not shown.", level: "info" },
    ...feed.map((e) => ({ at: e.at, text: `${displayName(e.name)} ${e.text}`, level: e.level }))];
}

/** The tab badge: how many agents need Matt now (blocked). Not an unread count. */
export function blockedCount(crew) {
  return crew.filter((a) => a.status === "blocked").length;
}

/** Card rows for an agent: [label, value], only the ones known. */
export function cardRows(agent, words, person = "") {
  const rows = [["Role", agent.role || "agent"], ["State", words[agent.status] || agent.status]];
  if (agent.status === "blocked") rows[1][1] = `${words.blocked}${agent.kind && agent.kind !== "other" ? ` (${agent.kind})` : ""}`;
  if (agent.repo) rows.push(["Ticket", `${agent.repo}${agent.ticket ? "#" + agent.ticket : ""}`]);
  if (agent.pr) rows.push(["PR", `${agent.pr}${agent.round ? ` · round ${agent.round}` : ""}`]);
  if (agent.step) rows.push(["Step", agent.step]);
  if (agent.note) rows.push(["Note", agent.note]);
  if (agent.withMatt) rows.push(["Lock", `with ${person || "the owner"}`]);
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
