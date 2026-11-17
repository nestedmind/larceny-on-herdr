// Pure logic for emoji reactions in the chat panel (ticket #77). No herdr or gpui imports, so node can test it.
// Two stores per agent, each with one writer, in the folder `loh react --dir` prints:
//   <agent>.owner.json  the owner's reactions on the agent's messages (the panel writes it):
//                       [{ id, emoji, excerpt, told, gone }]
//                       told: the agent was told with a message. gone: taken back after it was told, so the
//                       agent is still to hear of that, and the entry goes once it has.
//   <agent>.agent.json  the agent's reactions on the owner's messages (`loh react` writes it): [{ id, emoji }]
// A message's id is the session line's uuid, which `loh transcript` gives every turn.

/** The six, in the order chips are drawn whoever reacted. */
export const REACTIONS = ["👍", "✅", "❌", "👀", "❤️", "😂"];
export const EXCERPT_MAX = 40;

/** The emoji as one of the six (the heart with or without its variation selector), or null. */
export function normalise(e) {
  const s = e === "❤" ? "❤️" : e;
  return REACTIONS.includes(s) ? s : null;
}

/** The message's first line, cut to 40 characters with an ellipsis. Markdown stays as written. */
export function excerptOf(text) {
  const line = String(text || "").trim().split("\n")[0].trim();
  const chars = [...line];
  return chars.length > EXCERPT_MAX ? chars.slice(0, EXCERPT_MAX).join("") + "…" : line;
}

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** The text without its leading reaction lines: `(<owner> reacted 👍 to your message "…")` and `(<owner> took back …)`. */
export function stripReactionLines(text, owner) {
  const re = new RegExp(`^\\(${esc(owner)} (reacted|took back) .+\\)$`);
  const lines = String(text).split("\n");
  let i = 0;
  while (i < lines.length && re.test(lines[i])) i++;
  return i === 0 ? text : lines.slice(i).join("\n").trim();
}

/** What the agent is told, one line each, oldest first: the reactions not yet told, and the ones taken back after they were. */
export function reactionLines(entries, owner) {
  const out = [];
  for (const e of entries) {
    if (e.gone) out.push(`(${owner} took back ${e.emoji} on your message "${e.excerpt}")`);
    else if (!e.told) out.push(`(${owner} reacted ${e.emoji} to your message "${e.excerpt}")`);
  }
  return out;
}

/** The text `loh tell` gets: the reaction lines, then a newline and what the owner typed. */
export function withReactionLines(entries, owner, text) {
  const lines = reactionLines(entries, owner);
  return lines.length ? `${lines.join("\n")}\n${text}` : text;
}

const same = (a, b) => a.id === b.id && a.emoji === b.emoji;

/**
 * The owner clicks `emoji` on message `id` (its text gives the excerpt): the new list. A reaction that is on goes
 * off: dropped when the agent never heard of it, kept as `gone` when it did. One that is off goes on; one taken
 * back and put on again before the agent heard of the removal is simply on again.
 */
export function toggleOwner(entries, id, emoji, text) {
  const at = entries.findIndex((e) => same(e, { id, emoji }));
  if (at < 0) return [...entries, { id, emoji, excerpt: excerptOf(text), told: false, gone: false }];
  if (entries[at].gone) return entries.map((x, i) => (i === at ? { ...x, gone: false } : x));
  if (entries[at].told) return entries.map((x, i) => (i === at ? { ...x, gone: true } : x));
  return entries.filter((_, i) => i !== at);
}

/**
 * After a message carrying the lines for `sent` went out: those reactions are told, and the ones taken back are
 * dropped. An entry whose state has changed since (put on again while the message went out) is left alone.
 */
export function markTold(entries, sent) {
  const was = (e) => sent.some((s) => same(s, e) && !!s.gone === !!e.gone);
  return entries.filter((e) => !(was(e) && e.gone)).map((e) => (was(e) ? { ...e, told: true } : e));
}

/** The id of the owner's newest turn in the log (not the launch prompt, not one still pending): where 👀 goes. */
export function seenId(turns) {
  for (let i = turns.length - 1; i >= 0; i--) {
    const m = turns[i];
    if (m.role === "user" && !m.launch && !m.pending && m.id) return m.id;
  }
  return "";
}

/**
 * The chips under one message, in the order of the six: [{ emoji, by: "owner" | "agent", seen }].
 * `owner` is the owner's reactions (on the agent's own messages), `agent` the agent's (on the owner's), and `eyes`
 * the id that carries 👀 without anyone having typed it (seenId).
 */
export function chipsFor(m, { owner = [], agent = [], eyes = "" } = {}) {
  if (!m.id || m.pending || m.launch) return [];
  const out = [];
  for (const emoji of REACTIONS) {
    if (m.role === "assistant" && owner.some((e) => e.id === m.id && e.emoji === emoji && !e.gone)) out.push({ emoji, by: "owner", seen: false });
    else if (m.role === "user" && (agent.some((e) => e.id === m.id && e.emoji === emoji) || (emoji === "👀" && eyes === m.id))) {
      out.push({ emoji, by: "agent", seen: emoji === "👀" });
    }
  }
  return out;
}

/** Whether the owner has `emoji` on message `id`. */
export function ownerHas(entries, id, emoji) {
  return entries.some((e) => e.id === id && e.emoji === emoji && !e.gone);
}

/** The file of one store of one agent. */
export function storePath(dir, agent, who) {
  return `${dir}/${agent}.${who}.json`;
}

/** A store read back: only well-formed entries, and [] for a file that is not a list. */
export function parseStore(text, who) {
  let list;
  try { list = JSON.parse(text); } catch { return []; }
  if (!Array.isArray(list)) return [];
  const out = [];
  for (const e of list) {
    if (!e || typeof e.id !== "string" || !e.id || !REACTIONS.includes(e.emoji)) continue;
    if (who === "agent") out.push({ id: e.id, emoji: e.emoji });
    else out.push({ id: e.id, emoji: e.emoji, excerpt: typeof e.excerpt === "string" ? e.excerpt : "", told: !!e.told, gone: !!e.gone });
  }
  return out;
}

/** Read one store; a failure is an empty list (a store not written yet is the usual case). */
export async function readStore(fs, dir, agent, who) {
  try { return parseStore(String(await fs.readFile(storePath(dir, agent, who), "utf8")), who); } catch (_) { return []; }
}

/** Write the owner's store whole, through a temporary file, so a read never sees half of it. */
export async function writeOwner(fs, dir, agent, entries) {
  const path = storePath(dir, agent, "owner");
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(`${path}.tmp`, JSON.stringify(entries) + "\n");
  await fs.rename(`${path}.tmp`, path);
}
