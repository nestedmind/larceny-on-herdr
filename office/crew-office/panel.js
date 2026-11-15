// The chat panel beside the office: the selected agent's card, the activity feed, the chat log read
// from the agent's Claude Code session (through `loh transcript`) and a message box that sends
// through `loh tell`. Pure parts live in chat.js. No timers: the log is fetched again when the
// agent's state, step, note or turn changes, which is when herdr redraws the office.

import { div } from "gpui-kit";
import { v_flex, h_flex, TextareaState, Textarea, TextView, ScrollHandle } from "gpui-base";
import { terminals, exec } from "herdr";
import { activityDiff, blockedCount, cardRows, clock, copyAll, displayName, copyText, enterAction, feedRows, fetchKey, groupLog, markdownOf, parseTranscript, pushFeed, SEND_HINT, sendBlock, speaker, tellCall, tellError, rejectOutcome, tellOutcome, transcriptCall, viaMark, withPending } from "./chat.js";

const WORDS = { working: "working", blocked: "needs you", done: "done", idle: "idle" };
const COPIED_MS = 1500;

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
    this.lastCount = -1;
    this.lastFeed = -1;
    this.tab = "chat"; // "chat" or "activity"
    this.hover = null; // the log row under the pointer: its Copy shows
    this.copied = null; // the row whose Copy was just clicked
    this.blocked = 0; // agents that need Matt now: the Crew activity tab's badge
  }

  get open() { return !!this.address; }

  select(a, cx) {
    if (this.address !== a.address) {
      this.address = a.address;
      this.turns = [];
      this.pending = [];
      this.error = "";
      this.fetchedKey = null;
      this.lastCount = -1;
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
      st.on("change", (_e, c) => { if (this.host.typed) this.host.typed(c); });
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

  render(t, F, cx) {
    const raw = this.agent;
    const a = { ...raw, name: displayName(raw.name) };
    const color = a.status === "blocked" ? t.blocked : a.status === "working" ? t.working : a.status === "done" ? t.done : t.idle;
    const why = sendBlock(a);

    // Name, then role and state once; Terminal and Full terminal on their own row.
    const head = h_flex().flex_none().items_center().gap(8)
      .child(v_flex().flex_1().min_w(0).child(div().text_size(15).font_semibold().text_color(t.foreground).child(a.name))
        .child(h_flex().gap(5).items_center().text_size(12).text_color(t.muted)
          .child(div().w(8).h(8).rounded_full().bg(color))
          .child(div().child(`${a.role || "agent"} · ${WORDS[a.status] || a.status}`))))
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

    const tabs = h_flex().flex_none().items_center().gap(4).border_b(1).border_color(t.border)
      .child(this.tabButton("tab-chat", "Chat", "chat", 0, t))
      .child(this.tabButton("tab-activity", "Crew activity", "activity", this.blocked, t))
      .child(div().flex_1())
      .when(this.tab === "chat", (el) => el.child(this.button("panel-copy-all", this.copied === "all" ? "Copied" : "Copy all", (_e, c) => this.copy("all", copyAll(withPending(this.turns, this.pending).shown, a.name), c), t)));

    return v_flex().id("panel").size_full().overflow_hidden().gap(8).p(12).bg(t.canvas).border_l(1).border_color(t.border)
      .child(head).child(actions).when(!!factRows, (el) => el.child(factRows)).when(!!notice, (el) => el.child(notice))
      .child(tabs)
      .child(this.tab === "chat" ? this.chatLog(t, a) : this.activity(t))
      .when(!!this.error, (el) => el.child(div().flex_none().text_size(12).text_color(t.blocked).child(this.notSent ? `Not sent: ${this.error} Your message is back in the box.` : this.error)))
      .child(this.form(t, raw, why));
  }

  tabButton(id, label, name, badge, t) {
    const on = this.tab === name;
    return h_flex().id(id).px(8).py(4).gap(6).items_center().text_size(12).font_semibold().cursor_pointer()
      .text_color(on ? t.foreground : t.muted).border_b(2).border_color(on ? t.accent : "#00000000")
      .on_click((_e, c) => { this.tab = name; this.lastCount = -1; this.lastFeed = -1; c.notify(); })
      .child(label)
      .when(badge > 0, (el) => el.child(div().px(5).h(16).flex().items_center().rounded_full().bg(t.blocked).text_size(11).text_color(t.canvas).child(String(badge))));
  }

  // The log, Discord-style: a photo column (the placeholder is a round swatch until #35), the name and time,
  // and every line of text aligned with the name. Matt's turns sit in a shaded band across the panel.
  chatLog(t, a) {
    const { shown } = withPending(this.turns, this.pending);
    const rows = groupLog(shown, a.name).map(({ m, head, key: id }) => {
      const who = speaker(m, a.name);
      const mine = m.role === "user" && !m.launch;
      const stamp = m.pending ? (m.unsure ? "Not confirmed" : "Sending…") : m.ts ? clock(new Date(m.ts)) : "";
      const body = m.launch
        ? div().text_size(12).text_color(t.muted).whitespace_normal().child(`Launch prompt · ${markdownOf(m)}`)
        : TextView.markdown(`msg-${id}`, markdownOf(m)).selectable(true).text_size(13).text_color(t.foreground);
      const key = `m-${id}`;
      const hovered = this.hover === key || this.copied === key;
      const text = v_flex().flex_1().min_w(0).gap(2)
        .when(head, (el) => el.child(h_flex().gap(6).items_baseline()
          .child(div().text_size(13).font_semibold().text_color(t.foreground).child(`${who}${viaMark(m)}`))
          .child(div().text_size(12).text_color(m.unsure ? t.blocked : t.muted).child(stamp))))
        .child(body);
      const row = h_flex().id(key).relative().w_full().gap(8).px(12).py(head ? 6 : 1).items_start()
        .when(mine, (el) => el.bg(t.raised)).opacity(m.pending && !m.unsure ? 0.6 : 1)
        .on_hover((h, c) => { if (h) this.hover = key; else if (this.hover === key) this.hover = null; c.notify(); })
        .child(div().flex_none().w(32).h(head ? 32 : 0).rounded_full().bg(head ? (mine ? t.accent : t.chrome) : "#00000000"))
        .child(text)
        .when(hovered && !m.launch, (el) => el.child(div().absolute().top(2).right(12)
          .child(this.button(`copy-${id}`, this.copied === key ? "Copied" : "Copy", (_e, c) => this.copy(key, copyText(m), c), t))));
      return row;
    });
    if (shown.length !== this.lastCount && shown.length > 0) {
      this.lastCount = shown.length;
      this.scroll.scroll_to_item(shown.length - 1);
    }
    // The rows are direct children of the scroll area: scroll_to_item reveals a direct child
    // (gpui-kit.d.ts, ScrollHandle), so a wrapper would leave the newest one out of reach.
    const empty = this.fetchedKey === null && !shown.length ? "Loading the conversation…" : `No messages with ${a.name} yet. Anything you send goes to their terminal.`;
    return v_flex().id("panel-log").flex_1().min_h(0).gap(0).overflow_y_scroll().track_scroll(this.scroll)
      .children(rows.length ? rows : [div().px(12).text_size(12).text_color(t.muted).child(empty)]);
  }

  // Every change since the office opened, oldest first, scrolled to the newest.
  activity(t) {
    const rows = feedRows(this.feed);
    if (rows.length !== this.lastFeed) {
      this.lastFeed = rows.length;
      this.feedScroll.scroll_to_item(rows.length - 1);
    }
    return v_flex().id("panel-activity").flex_1().min_h(0).gap(4).overflow_y_scroll().track_scroll(this.feedScroll)
      .children(rows.map((e) => h_flex().gap(8)
        .child(div().w(36).flex_none().text_size(12).text_color(t.muted).child(e.at))
        .child(div().flex_1().min_w(0).text_size(12).text_color(e.level === "blocked" ? t.blocked : t.foreground).whitespace_normal().child(e.text))));
  }

  // The message box: wraps and grows 1 to 6 rows, a border that reads at 3:1 (muted), the hint under it.
  form(t, a, why) {
    const box = div().flex_1().min_w(0).border_1().border_color(t.muted).rounded(6).bg(t.surface)
      .on_key_down((e, c) => this.key(e, c))
      .child(Textarea.new(this.inputs.get(a.address)));
    return v_flex().flex_none().gap(4)
      .child(h_flex().gap(6).items_end()
        .child(box)
        .child(this.button("panel-send", this.sending ? "Sending…" : "Send", (_e, c) => this.send(c), t).opacity(why || this.sending ? 0.5 : 1)))
      .when(!why, (el) => el.child(div().text_size(11).text_color(t.muted).child(SEND_HINT)));
  }
}
