// The chat panel beside the office: the selected agent's card, the activity feed, the chat log read
// from the agent's Claude Code session (through `loh transcript`) and a message box that sends
// through `loh tell`. Pure parts live in chat.js. No timers: the log is fetched again when the
// agent's state, step, note or turn changes, which is when herdr redraws the office.

import { div, image } from "gpui-kit";
import * as fs from "fs/promises";
import { v_flex, h_flex, TextareaState, Textarea, TextView, ScrollHandle } from "gpui-base";
import { terminals, exec, home, appHome } from "herdr";
import { bustEl, iconEl } from "./draw.js";
import { imagePath, photoDirs, placement, scanPhotos, squareOf } from "./photos.js";
import { activityDiff, avatarName, blockedCount, cardRows, clock, copyAll, displayName, copyText, enterAction, feedRows, fetchKey, groupLog, markdownOf, parseTranscript, rowSpace, pushFeed, SEND_HINT, sendBlock, speaker, tellCall, tellError, rejectOutcome, tellOutcome, transcriptCall, viaMark, withPending } from "./chat.js";

const WORDS = { working: "working", blocked: "needs you", done: "done", idle: "idle" };
const STATE_WORDS = { working: "Working", blocked: "Needs you", done: "Done", idle: "Idle" };
const COPIED_MS = 1500;
// How often the photo folder is read again, so a photo added while the office is open appears within this.
export const PHOTOS_EVERY_MS = 60000;
// herdr's own UI font has a regular face only, so bold and italics (and semibold names) drew as plain text. Noto
// Sans has them, and is the sans Maya's frames are drawn in. Where it is missing the default font is used, as before.
const FONT = "Noto Sans";
// Whether `now` is `was` with exactly one newline put in somewhere.
export function oneNewline(was, now) {
  if (now.length !== was.length + 1) return false;
  let i = 0;
  while (i < was.length && was[i] === now[i]) i++;
  return now[i] === "\n" && now.slice(i + 1) === was.slice(i);
}
const cap = (w) => (w ? w[0].toUpperCase() + w.slice(1) : w);

export class Panel {
  // host: { loh: () => path or undefined, terminal: (agent, cx) => void, typed: (cx) => void (a key in the message box) }
  constructor(host) {
    this.host = host;
    this.address = null; // the selected agent
    this.agent = null; // its latest record from crewOf
    this.turns = []; // parsed transcript
    this.pending = []; // sent by Matt, not in the transcript yet
    this.error = ""; // last send failure
    this.notSent = false; // the failure was a refusal: nothing went out, and the text is back in the box
    this.sending = false;
    this.fetching = false;
    this.fetchedKey = null;
    this.wantKey = null;
    this.seen = new Map();
    this.started = false;
    this.feed = [];
    this.inputs = new Map(); // one text state per agent, so a half-typed draft stays
    this.scroll = ScrollHandle.new();
    this.feedScroll = ScrollHandle.new();
    this.logEnd = null; // the newest log row last scrolled to: its key, so a full 40-turn window still follows
    this.feedEnd = null; // the same for the activity feed
    this.tab = "chat"; // "chat" or "activity"
    this.hover = null; // the log row under the pointer: its Copy shows
    this.copied = null; // the row whose Copy was just clicked
    this.last = new Map(); // each box's text after its last change
    this.preNl = null; // the text before the newline the last Enter put in
    this.focused = false; // the message box has the keyboard
    this.blocked = 0; // agents that need Matt now: the Crew activity tab's badge
    this.photos = new Map(); // lower-case name -> { path, w, h, crop } of each photo found (photos.js)
    this.photosAt = 0; // when the photo folder was last asked for
    this.photosBusy = false;
  }

  // The panel's width in px, for the 24 px avatar below 320.
  get width() { return this.host.width ? this.host.width() : 360; }

  get open() { return !!this.address; }

  select(a, cx) {
    if (this.address !== a.address) {
      this.address = a.address;
      this.turns = [];
      this.pending = [];
      this.error = "";
      this.fetchedKey = null;
      this.logEnd = null;
      this.hover = null;
      this.copied = null;
    }
    this.agent = a;
    if (!this.inputs.has(a.address)) {
      const st = TextareaState.new({ placeholder: `Message ${displayName(a.name)}`, rows: 1 });
      // Wraps and grows from 1 row to 6, then scrolls inside itself.
      st.set_soft_wrap(true);
      st.set_auto_grow(1, 6);
      // Every key in the box counts as Matt typing in herdr: the office seats him at his desk.
      st.on("change", (_e, c) => {
        // Remember the text before a lone newline went in, so Enter's newline can be taken back out.
        const v = st.value(), was = this.last.get(a.address) ?? "";
        // Any other change forgets it: only the very last edit being that newline counts.
        this.preNl = oneNewline(was, v) ? was : null;
        this.last.set(a.address, v);
        if (this.host.typed) this.host.typed(c);
      });
      // Enter inside the textarea never reaches a wrapper's on_key_down: the textarea takes it as its own
      // action, inserts the newline and then emits "submit" with the modifiers (kit: InputEvent). So a plain
      // Enter is a send here, and Ctrl/Shift+Enter keeps the newline. send() trims the text, so the newline
      // Enter just put in is not sent; if it lands after the box was cleared, it is cleared again.
      st.on("submit", (e, c) => this.submitted(e, st, c));
      // The box's border follows the keyboard: accent at 2 px with focus, muted at rest.
      st.on("focus", (_e, c) => { this.focused = true; c.notify(); });
      st.on("blur", (_e, c) => { this.focused = false; c.notify(); });
      this.inputs.set(a.address, st);
    }
    this.inputs.get(a.address).focus();
    cx.notify();
  }

  close(cx) {
    this.address = null;
    this.agent = null;
    cx.notify();
  }

  // Called on every render with the crew: record state changes for the feed, keep the selected
  // agent's record fresh (close the panel if it left) and refetch the log when something changed.
  sync(crew, cx) {
    const d = activityDiff(this.seen, crew, !this.started);
    this.seen = d.seen;
    this.started = true;
    this.loadPhotos(cx);
    if (d.events.length) this.feed = pushFeed(this.feed, d.events, clock(new Date()));
    if (!this.address) return;
    const a = crew.find((c) => c.address === this.address);
    if (!a) { this.address = null; this.agent = null; return; }
    this.agent = a;
    this.blocked = blockedCount(crew);
    const raw = terminals().find((t) => t.address === a.address);
    this.wantKey = fetchKey(a, raw);
    if (this.wantKey !== this.fetchedKey) this.load(cx);
  }

  // Read the photo folder, at most every PHOTOS_EVERY_MS, on a render (the office already wakes every minute for its repo list); a failure keeps what was found. A photo with no file, or one that
  // cannot be read, is simply absent, and its person keeps the floor figure.
  loadPhotos(cx) {
    const now = Date.now();
    if (this.photosBusy) return;
    if (this.photosAt && now - this.photosAt < PHOTOS_EVERY_MS) return;
    this.photosAt = now;
    this.photosBusy = true;
    cx.spawn(async (cx) => {
      let found = null;
      try { found = await scanPhotos(fs, photoDirs(home(), appHome(), this.host.photos && this.host.photos())); } catch (_) { /* keep the last */ }
      this.photosBusy = false;
      if (!found) return;
      const sig = (m) => JSON.stringify([...m].sort());
      if (sig(found) !== sig(this.photos)) { this.photos = found; cx.notify(); }
    });
  }

  load(cx) {
    if (this.fetching || !this.agent) return;
    const a = this.agent, key = this.wantKey;
    this.fetching = true;
    const c = transcriptCall(a, this.host.loh());
    // The continuation runs in cx.spawn with its own cx: the cx this method was called with is dead by then.
    cx.spawn(async (cx) => {
      let r = null;
      try { r = await exec(c.cmd, c.args, c.options); } catch (_) { /* keep the old log */ }
      this.fetching = false;
      if (!r) { this.fetchedKey = key; return; }
      if (this.address !== a.address) return;
      this.fetchedKey = key;
      if (r.code === 0) {
        this.turns = parseTranscript(r.stdout);
        this.pending = withPending(this.turns, this.pending).pending;
      }
      cx.notify();
    });
  }

  send(cx) {
    const a = this.agent;
    const st = a && this.inputs.get(a.address);
    // While a full-terminal window is open the keyboard belongs to that terminal, never to this box.
    if (!a || !st || this.sending || (this.host.busy && this.host.busy())) return;
    const text = st.value().trim();
    if (!text) return;
    const why = sendBlock(a);
    if (why) { this.error = why; this.notSent = false; cx.notify(); return; }
    this.sending = true;
    this.error = "";
    this.notSent = false;
    const entry = { text };
    this.pending.push(entry);
    st.set_value("");
    const c = tellCall(a, this.host.loh(), text);
    // Only a "failed" call (loh refused, nothing was sent) puts the text back. A call that was cut
    // off may still deliver: keep the message in the log as unconfirmed and say so, so a second Send
    // does not send it twice.
    const unknown = () => {
      entry.unsure = true;
      this.error = `Not sure ${a.name} got it: the send did not report back and may still go out. Check the log before sending again.`;
    };
    const began = Date.now();
    cx.spawn(async (cx) => {
      // Only a rejection of exec itself says loh could not run. Everything after it is our own
      // handling, outside the try: a failure there must never read as "loh could not run".
      let r = null, rejected = null;
      try { r = await exec(c.cmd, c.args, c.options); } catch (e) { rejected = e || new Error("exec failed"); }
      this.sending = false;
      if (rejected) {
        // exec rejects when the program could not be started (loh missing, folder gone): nothing ran,
        // and the text goes back in the box. A rejection that came late may be a timeout with the
        // send still going out: treat that as unconfirmed (rejectOutcome).
        if (rejectOutcome(Date.now() - began) === "failed") {
          this.pending = this.pending.filter((p) => p !== entry);
          this.notSent = true;
          this.error = `could not run loh: ${String(rejected.message || rejected || "").slice(0, 160)}`.trim();
          st.set_value(text);
        } else {
          unknown();
        }
      } else {
        const outcome = tellOutcome(r);
        if (outcome === "failed") {
          this.pending = this.pending.filter((p) => p !== entry);
          this.notSent = true;
          this.error = tellError(r, a.name);
          st.set_value(text);
        } else if (outcome === "unknown") {
          unknown();
        }
      }
      this.fetchedKey = null;
      cx.notify();
    });
  }

  // The textarea's submit event: plain Enter sends, Ctrl+Enter (secondary) and Shift+Enter keep their newline.
  // A plain Enter always takes back the one newline the textarea put in, whether or not the message goes out.
  submitted(e, st, cx) {
    const keep = !!(e && (e.secondary || e.shift));
    if (keep) { cx.notify(); return; }
    const v = st.value();
    if (this.preNl !== null && oneNewline(this.preNl, v)) st.set_value(this.preNl);
    else if (v.endsWith("\n")) st.set_value(v.slice(0, -1));
    this.preNl = null;
    const a = this.agent;
    const why = this.sending ? "the last message is still going out" : this.host.busy && this.host.busy() ? "a full terminal window has the keyboard" : !st.value().trim() ? "the box is empty" : a && sendBlock(a) ? "the agent is waiting on a dialog" : "";
    if (!why) this.send(cx);
    else if (!st.value().trim()) cx.notify();
    else { this.error = `Enter did not send: ${why}.`; this.notSent = false; cx.notify(); }
    if (cx.timer) {
      cx.timer.after(40, (c) => {
        if (st.value() === "\n") st.set_value("");
        try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
      });
    }
  }

  // A key in the message box, caught on the wrapper around it. Enter sends; Ctrl+Enter adds a line at the caret.
  key(e, cx) {
    const act = enterAction(e);
    const st = this.agent && this.inputs.get(this.agent.address);
    if (!act || !st) return;
    cx.stop_propagation();
    if (act === "send") this.send(cx);
    else st.replace("\n");
  }

  // Copy puts text on the clipboard and shows "Copied" on that row for COPIED_MS.
  copy(key, text, cx) {
    cx.write_to_clipboard(text);
    this.copied = key;
    cx.notify();
    if (cx.timer) {
      cx.timer.after(COPIED_MS, (c) => {
        if (this.copied === key) this.copied = null;
        try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
      });
    }
  }

  button(id, label, onClick, t) {
    return h_flex().id(id).px(8).py(2).rounded(5).border_1().border_color(t.border).text_size(12).text_color(t.foreground)
      .cursor_pointer().hover((e) => e.bg(t.hover)).on_click(onClick).child(label);
  }

  // Copy on hover, as an icon (design decision 10): a 24 px square in `popover` with a `border` edge and a 14 px
  // glyph in `muted`; a tick for 1.5 s after a click. The glyphs are drawn paths (draw.js iconEl).
  copyChip(id, done, onClick, t) {
    return h_flex().id(id).w(24).h(24).items_center().justify_center().rounded(5).border_1().border_color(t.border).bg(t.popover)
      .cursor_pointer().tooltip(done ? "Copied" : "Copy").hover((e) => e.bg(t.hover)).on_click(onClick)
      .child(iconEl(done ? "copied" : "copy", 14, t.muted));
  }

  render(t, F, cx) {
    const raw = this.agent;
    const a = { ...raw, name: displayName(raw.name) };
    const color = a.status === "blocked" ? t.blocked : a.status === "working" ? t.working : a.status === "done" ? t.done : t.idle;
    const why = sendBlock(a);

    // Name, then role and state once; Terminal and Full terminal on their own row.
    const state = `${STATE_WORDS[a.status] || cap(a.status)}${a.status === "blocked" && a.kind && a.kind !== "other" ? ` · ${a.kind}` : ""}`;
    const head = h_flex().flex_none().items_center().gap(10)
      .child(this.avatar(avatarName({ role: "assistant" }, raw), 36, t))
      .child(v_flex().flex_1().min_w(0).child(div().text_size(15).line_height("20px").font_semibold().text_color(t.foreground).child(a.name))
        .child(h_flex().gap(5).items_center().text_size(12).line_height("16px").text_color(t.muted)
          .child(div().child(`${cap(a.role || "agent")} ·`))
          .child(div().w(8).h(8).rounded_full().bg(color))
          .child(div().child(state))))
      .child(this.button("panel-close", "Close", (_e, c) => this.close(c), t));

    const actions = h_flex().flex_none().gap(8)
      .child(this.button("panel-terminal", "Terminal", (_e, c) => this.host.terminal(raw, c), t).flex_1().justify_center())
      .child(this.button("panel-full-terminal", "Full terminal", (_e, c) => this.host.fullTerminal(raw, c), t).flex_1().justify_center());

    // Facts the header does not carry: ticket, PR, step, note, lock.
    const facts = cardRows(a, WORDS).filter(([k]) => k !== "Role" && k !== "State" && !(k === "Step" && (a.step === "idle" || a.step === a.status)));
    const factRows = facts.length ? v_flex().flex_none().gap(2).children(facts.map(([k, v]) => h_flex().gap(8)
      .child(div().w(52).text_size(12).text_color(t.muted).child(k))
      .child(div().flex_1().min_w(0).text_size(12).text_color(t.foreground).child(v)))) : null;

    const notice = why
      ? h_flex().flex_none().gap(8).items_center().p(8).rounded(6).bg(t.raised).border_l(3).border_color(t.blocked)
        .child(div().flex_1().min_w(0).text_size(12).text_color(t.foreground).child(why))
        .child(this.button("panel-notice-terminal", "Open terminal", (_e, c) => this.host.terminal(raw, c), t))
      : null;

    const tabs = h_flex().flex_none().items_center().gap(4).px(12).border_b(1).border_color(t.border)
      .child(this.tabButton("tab-chat", "Chat", "chat", 0, t))
      .child(this.tabButton("tab-activity", "Crew activity", "activity", this.blocked, t))
      .child(div().flex_1())
      .when(this.tab === "chat", (el) => el.child(div().id("panel-copy-all").text_size(12).line_height("16px").text_color(t.muted).cursor_pointer()
        .hover((e) => e.text_color(t.foreground))
        .on_click((_e, c) => this.copy("all", copyAll(withPending(this.turns, this.pending).shown, a.name), c))
        .child(this.copied === "all" ? "Copied" : "Copy all")));

    // Header, tabs and log run edge to edge (the log's rows carry their own 12 px, so Matt's band reaches both
    // edges); a full-width divider sits between the log and the composer, which has 8 px above and 12 below.
    const top = v_flex().flex_none().gap(8).px(12).pt(12).pb(8)
      .child(head).child(actions).when(!!factRows, (el) => el.child(factRows)).when(!!notice, (el) => el.child(notice));
    const composer = v_flex().flex_none().gap(8).px(12).pt(8).pb(12).border_t(1).border_color(t.border)
      .when(!!this.error, (el) => el.child(div().text_size(12).text_color(t.blocked).child(this.notSent ? `Not sent: ${this.error} Your message is back in the box.` : this.error)))
      .child(this.form(t, raw, why));
    return v_flex().id("panel").size_full().overflow_hidden().gap(0).font_family(FONT).bg(t.canvas).border_l(1).border_color(t.border)
      .child(top)
      .child(tabs)
      .child(this.tab === "chat" ? this.chatLog(t, a) : this.activity(t))
      .child(composer);
  }

  // The avatar: the person's photo in a circle with a thin border, cropped to a square (the default crop, or the
  // photo's .crop sidecar); with no photo, their floor figure as a head-and-shoulders bust (draw.js's bustEl).
  // `bg` is the colour behind the avatar. GPUI's overflow_hidden clips to the rectangle, not to rounded corners, so the
  // circle is cut by a mask: a ring twice the avatar's size whose hole is the circle, in the background colour, laid
  // over the picture (its outer circle, radius `size`, reaches past the square's corners).
  avatar(name, size, t, bg = t.canvas) {
    const p = name ? this.photos.get(String(name).toLowerCase()) : null;
    if (!p) return bustEl(name || "?", size, t.border);
    const at = placement(size, p.w, p.h, squareOf(p.w, p.h, p.crop));
    return div().flex_none().relative().w(size).h(size).overflow_hidden().bg(t.raised)
      .child(image(imagePath(appHome(), p.path)).absolute().left(at.left).top(at.top).w(at.width).h(at.height))
      .child(div().absolute().left(-size / 2).top(-size / 2).w(size * 2).h(size * 2).rounded(size).border(size / 2).border_color(bg))
      .child(div().absolute().left(0).top(0).w(size).h(size).rounded_full().border_1().border_color(t.border));
  }

  tabButton(id, label, name, badge, t) {
    const on = this.tab === name;
    return h_flex().id(id).px(8).py(4).gap(6).items_center().text_size(12).font_semibold().cursor_pointer()
      .text_color(on ? t.foreground : t.muted).border_b(2).border_color(on ? t.foreground : "#00000000")
      .on_click((_e, c) => { this.tab = name; this.logEnd = null; this.feedEnd = null; c.notify(); })
      .child(label)
      .when(badge > 0, (el) => el.child(div().px(5).h(16).flex().items_center().rounded_full().bg(t.blocked).text_size(11).text_color(t.canvas).child(String(badge))));
  }

  // The log, Discord-style: a photo column (the placeholder is a round swatch until #35), the name and time,
  // and every line of text aligned with the name. Matt's turns sit in a shaded band across the panel.
  chatLog(t, a) {
    const { shown } = withPending(this.turns, this.pending);
    const log = groupLog(shown, a.name);
    const rows = log.map(({ m, head, key: id }, i) => {
      const who = speaker(m, a.name);
      const mine = m.role === "user" && !m.launch;
      const stamp = m.pending ? (m.unsure ? "Not confirmed" : "Sending…") : m.ts ? clock(new Date(m.ts)) : "";
      const body = m.launch
        ? div().text_size(12).text_color(t.muted).whitespace_normal().child(`Launch prompt · ${markdownOf(m)}`)
        : TextView.markdown(`msg-${id}`, markdownOf(m)).selectable(true).font_family(FONT).text_size(14).line_height("20px").text_color(t.foreground);
      const key = `m-${id}`;
      const hovered = this.hover === key || this.copied === key;
      // Maya's spacing (changes-p1.md, Round 2): a new speaker starts 16 px under the last turn, a grouped turn 4 px;
      // 4 px between the name row and the body; 10 px between photo and text (8 at 24 px). Matt's band is 8 px
      // taller above and below his group, so its edge sits 8 px from the neighbour and 8 px from his own content.
      const pic = this.width < 320 ? 24 : 32;
      const sp = rowSpace(log, i);
      const text = v_flex().flex_1().min_w(0).gap(4)
        .when(head, (el) => el.child(h_flex().gap(6).items_baseline()
          .child(div().text_size(12).line_height("16px").font_semibold().text_color(t.foreground).child(who))
          .child(div().text_size(12).line_height("16px").text_color(m.unsure ? t.blocked : t.muted).child(`${stamp}${viaMark(m)}`))))
        .child(body);
      const row = h_flex().id(key).relative().w_full().gap(pic === 24 ? 8 : 10).px(12)
        .mt(sp.mt).pt(sp.pt).pb(sp.pb).items_start()
        .when(mine, (el) => el.bg(t.raised)).opacity(m.pending && !m.unsure ? 0.6 : 1)
        .on_hover((h, c) => { const was = this.hover; if (h) this.hover = key; else if (this.hover === key) this.hover = null; if (this.hover !== was) c.notify(); })
        .child(head ? this.avatar(m.launch ? "" : avatarName(m, a), pic, t, mine ? t.raised : t.canvas) : div().flex_none().w(pic))
        .child(text)
        .when(hovered && !m.launch, (el) => el.child(div().absolute().top(2).right(12)
          .child(this.copyChip(`copy-${id}`, this.copied === key, (_e, c) => this.copy(key, copyText(m), c), t))));
      return row;
    });
    // Follow the newest turn. The window holds at most 40 turns, so once it is full a new turn leaves the count
    // unchanged: the newest row's key is what says something arrived (or that Matt just sent one). The kit
    // cannot read the scroll offset, so this always jumps.
    const end = log.length ? log[log.length - 1].key : null;
    if (end !== this.logEnd && end !== null) {
      this.logEnd = end;
      this.scroll.scroll_to_item(log.length - 1);
    }
    // The rows are direct children of the scroll area: scroll_to_item reveals a direct child
    // (gpui-kit.d.ts, ScrollHandle), so a wrapper would leave the newest one out of reach.
    const empty = this.fetchedKey === null && !shown.length ? "Loading the conversation…" : `No messages with ${a.name} yet. Anything you send goes to their terminal.`;
    return v_flex().id("panel-log").flex_1().min_h(0).gap(0).pb(8).overflow_y_scroll().track_scroll(this.scroll)
      .children(rows.length ? rows : [div().px(12).text_size(12).text_color(t.muted).child(empty)]);
  }

  // Every change since the office opened, oldest first, scrolled to the newest.
  activity(t) {
    const rows = feedRows(this.feed);
    // Keyed on the newest row, not the count: the feed keeps its last 100 changes, so a full one stays 100 long.
    const end = `${rows.length}|${rows[rows.length - 1].at}|${rows[rows.length - 1].text}`;
    if (end !== this.feedEnd) {
      this.feedEnd = end;
      this.feedScroll.scroll_to_item(rows.length - 1);
    }
    return v_flex().id("panel-activity").flex_1().min_h(0).gap(4).px(12).py(8).overflow_y_scroll().track_scroll(this.feedScroll)
      .children(rows.map((e) => h_flex().gap(8)
        .child(div().w(36).flex_none().text_size(12).text_color(t.muted).child(e.at))
        .child(div().flex_1().min_w(0).text_size(12).text_color(e.level === "blocked" ? t.blocked : t.foreground).whitespace_normal().child(e.text))));
  }

  // The message box, as designed: 13 px on an 18 px line, 8 px inside the border (4 above and below), grows from
  // 1 row (28 px) to 6 (118 px). Border: muted at rest, accent at 2 px with focus; the padding gives 1 px back so
  // the box does not change size. Send is a solid button the height of the one-row box, at the box's bottom.
  form(t, a, why) {
    const on = this.focused;
    const box = div().flex_1().min_w(0).min_h(30).rounded(6).bg(t.surface).text_size(14).line_height("20px").text_color(t.foreground)
      .when(on, (el) => el.border_2().border_color(t.accent).px(7).py(3))
      .when(!on, (el) => el.border_1().border_color(t.muted).px(8).py(4))
      .on_key_down((e, c) => this.key(e, c))
      .child(Textarea.new(this.inputs.get(a.address)).text_size(14).line_height("20px").p(0).border_0());
    const send = h_flex().id("panel-send").flex_none().h(30).px(14).items_center().justify_center().rounded(6).bg(t.solid)
      .text_size(13).font_bold().text_color(t.solid_foreground).opacity(why || this.sending ? 0.5 : 1)
      .cursor_pointer().on_click((_e, c) => this.send(c)).child(this.sending ? "Sending…" : "Send");
    return v_flex().flex_none().gap(4)
      .child(h_flex().gap(6).items_end().child(box).child(send))
      .when(!why, (el) => el.child(div().text_size(11).text_color(t.muted).child(SEND_HINT)));
  }
}
