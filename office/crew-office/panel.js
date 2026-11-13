// The chat panel beside the office: the selected agent's card, the activity feed, the chat log read
// from the agent's Claude Code session (through `loh transcript`) and a message box that sends
// through `loh tell`. Pure parts live in chat.js. No timers: the log is fetched again when the
// agent's state, step, note or turn changes, which is when herdr redraws the office.

import { div } from "gpui-kit";
import { v_flex, h_flex, InputState, Input, ScrollHandle } from "gpui-base";
import { terminals, exec } from "herdr";
import { activityDiff, cardRows, clock, fetchKey, parseTranscript, pushFeed, sendBlock, speaker, tellCall, tellError, rejectOutcome, tellOutcome, transcriptCall, withPending } from "./chat.js";

const WORDS = { working: "working", blocked: "needs you", done: "done", idle: "idle" };
const FEED_SHOWN = 3;

export class Panel {
  // host: { loh: () => path or undefined, terminal: (agent, cx) => void }
  constructor(host) {
    this.host = host;
    this.address = null; // the selected agent
    this.agent = null; // its latest record from crewOf
    this.turns = []; // parsed transcript
    this.pending = []; // sent by Matt, not in the transcript yet
    this.error = ""; // last send failure
    this.sending = false;
    this.fetching = false;
    this.fetchedKey = null;
    this.wantKey = null;
    this.seen = new Map();
    this.started = false;
    this.feed = [];
    this.inputs = new Map(); // one text state per agent, so a half-typed draft stays
    this.scroll = ScrollHandle.new();
    this.lastCount = -1;
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
    }
    this.agent = a;
    if (!this.inputs.has(a.address)) {
      const st = InputState.new({ placeholder: `Message ${a.name}` });
      st.on("submit", (_e, c) => this.send(c));
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
    const raw = terminals().find((t) => t.address === a.address);
    this.wantKey = fetchKey(a, raw);
    if (this.wantKey !== this.fetchedKey) this.load(cx);
  }

  load(cx) {
    if (this.fetching || !this.agent) return;
    const a = this.agent, key = this.wantKey;
    this.fetching = true;
    const c = transcriptCall(a, this.host.loh());
    exec(c.cmd, c.args, c.options).then((r) => {
      this.fetching = false;
      if (this.address !== a.address) return;
      this.fetchedKey = key;
      if (r.code === 0) {
        this.turns = parseTranscript(r.stdout);
        this.pending = withPending(this.turns, this.pending).pending;
      }
      cx.notify();
    }).catch(() => { this.fetching = false; this.fetchedKey = key; });
  }

  send(cx) {
    const a = this.agent;
    const st = a && this.inputs.get(a.address);
    // While a full-terminal window is open the keyboard belongs to that terminal, never to this box.
    if (!a || !st || this.sending || (this.host.busy && this.host.busy())) return;
    const text = st.value().trim();
    if (!text) return;
    const why = sendBlock(a);
    if (why) { this.error = why; cx.notify(); return; }
    this.sending = true;
    this.error = "";
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
    exec(c.cmd, c.args, c.options).then((r) => {
      this.sending = false;
      const outcome = tellOutcome(r);
      if (outcome === "failed") {
        this.pending = this.pending.filter((p) => p !== entry);
        this.error = tellError(r, a.name);
        st.set_value(text);
      } else if (outcome === "unknown") {
        unknown();
      }
      this.fetchedKey = null;
      cx.notify();
    }).catch((e) => {
      // exec rejects when the program could not be started (loh missing, folder gone): nothing ran,
      // and the text goes back in the box. A rejection that came late may be a timeout with the
      // send still going out: treat that as unconfirmed (rejectOutcome).
      this.sending = false;
      if (rejectOutcome(Date.now() - began) === "failed") {
        this.pending = this.pending.filter((p) => p !== entry);
        this.error = `could not run loh: ${String((e && e.message) || e || "").slice(0, 160)}`.trim();
        st.set_value(text);
      } else {
        unknown();
      }
      this.fetchedKey = null;
      cx.notify();
    });
  }

  button(id, label, onClick, t) {
    return h_flex().id(id).px(8).py(2).rounded(5).border_1().border_color(t.border).text_size(12).text_color(t.foreground)
      .cursor_pointer().hover((e) => e.bg(t.hover)).on_click(onClick).child(label);
  }

  render(t, F, cx) {
    const a = this.agent;
    const color = a.status === "blocked" ? "#e7a43a" : a.status === "idle" ? t.muted : "#3fae69";
    const why = sendBlock(a);

    const head = h_flex().flex_none().items_center().gap(8)
      .child(v_flex().flex_1().child(div().text_size(15).font_semibold().text_color(t.foreground).child(a.name))
        .child(div().text_size(11).text_color(t.muted).child(a.role || "agent")))
      .child(div().px(8).h(19).flex().items_center().rounded_full().bg(color).text_size(11).font_semibold().text_color(t.background).child(WORDS[a.status] || a.status))
      .child(this.button("panel-close", "Close", (_e, c) => this.close(c), t));

    const rows = cardRows(a, WORDS).map(([k, v]) => h_flex().gap(8)
      .child(div().w(52).text_size(11).text_color(t.muted).child(k))
      .child(div().flex_1().text_size(12).text_color(t.foreground).child(v)));
    const card = v_flex().flex_none().gap(2).p(8).rounded(6).border_1().border_color(t.border).children(rows);

    const actions = h_flex().flex_none().gap(8).items_center()
      .child(this.button("panel-terminal", "Terminal", (_e, c) => this.host.terminal(a, c), t))
      .child(this.button("panel-full-terminal", "Full terminal", (_e, c) => this.host.fullTerminal(a, c), t))
      .child(div().flex_1().text_size(11).text_color(t.muted).child("Beside the office, or full size"));
    const notice = why
      ? div().flex_none().p(8).rounded(6).bg("#e7a43a33").border_1().border_color("#e7a43a").text_size(12).text_color(t.foreground).child(why)
      : null;

    const tail = this.feed.slice(-FEED_SHOWN);
    const feed = v_flex().flex_none().gap(1).children(tail.length
      ? tail.map((e) => h_flex().gap(6)
        .child(div().w(34).text_size(11).text_color(t.muted).child(e.at))
        .child(div().flex_1().text_size(11.5).text_color(e.level === "blocked" ? "#e7a43a" : t.foreground).child(`${e.name} ${e.text}`)))
      : [div().text_size(11).text_color(t.muted).child("No changes since the office opened.")]);

    const { shown } = withPending(this.turns, this.pending);
    const log = shown.map((m) => v_flex().gap(1).p(6).rounded(6)
      .bg(m.role === "user" ? t.accent + "33" : t.chrome).opacity(m.pending ? 0.6 : 1)
      .child(div().text_size(10).text_color(t.muted).child(`${speaker(m, a.name)}${m.pending ? (m.unsure ? " · not confirmed" : " · sending…") : m.ts ? " · " + clock(new Date(m.ts)) : ""}`))
      .child(div().text_size(12).text_color(t.foreground).whitespace_normal().child(m.text.length > 1200 ? m.text.slice(0, 1200) + "…" : m.text)));
    if (shown.length !== this.lastCount && shown.length > 0) {
      this.lastCount = shown.length;
      this.scroll.scroll_to_item(shown.length - 1);
    }
    // The turns are direct children of the scroll area: scroll_to_item reveals a direct child
    // (gpui-kit.d.ts, ScrollHandle), so a wrapper would leave the newest turn out of reach.
    const chat = v_flex().id("panel-log").flex_1().min_h(0).gap(6).overflow_y_scroll().track_scroll(this.scroll)
      .children(log.length ? log : [div().text_size(11).text_color(t.muted).child(`No messages from ${a.name} yet.`)]);

    const form = h_flex().flex_none().gap(6).items_center()
      .child(div().flex_1().h(28).child(Input.new(this.inputs.get(a.address))))
      .child(this.button("panel-send", this.sending ? "Sending…" : "Send", (_e, c) => this.send(c), t).opacity(why || this.sending ? 0.5 : 1));

    return v_flex().id("panel").size_full().overflow_hidden().gap(8).p(10).bg(t.canvas).border_l(1).border_color(t.border)
      .child(head).child(card).child(actions).when(!!notice, (el) => el.child(notice))
      .child(div().text_size(11).font_semibold().text_color(t.muted).child("Activity")).child(feed)
      .child(div().text_size(11).font_semibold().text_color(t.muted).child(`Chat with ${a.name}`))
      .child(chat)
      .when(!!this.error, (el) => el.child(div().flex_none().text_size(11).text_color("#d0509f").child(this.error)))
      .child(form);
  }
}
