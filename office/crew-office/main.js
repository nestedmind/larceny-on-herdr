// Crew office: one crew's agents at their desks, drawn from `hc` state only.
// Reads terminals() labels (crew, role, task, step, pr, round, note, with_matt)
// and each terminal's status. Keeps no state of its own beyond the pane size and the open chat
// (which agent, in which pane). Clicking an agent docks its live terminal in a split beside the office.
// The drawing is in draw.js and the placement in crew.js. Gaits, typing and the ball animate natively
// (.loop(), .transition()); no repeating timer. A walk is one step per render: a one-shot timer ends each leg.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { terminals, panes, run, exec, notify, props, theme, settings } from "herdr";
import { anchorCwd, chatGone, crewOf, fitScale, layoutCrew, legsOf, lockCall, officePane, pathTo, pickWorkspace, repoNames, reposCall, stackTags, startCall, startPlan, unlockCall, WALK_SPEED } from "./crew.js";
import { BLOCKED, PAL, ball, dogEls, floorLayer, glow, labels, night, personEls, wrapper, Layer } from "./draw.js";

const WORDS = { working: "working", blocked: "needs you", done: "done", idle: "idle" };

export default class CrewOffice extends View {
  init(_props, cx) {
    this.size = { width: 640, height: 480 };
    // The open chat: { pane, address, name, agent } or null. The pane is a split beside this one.
    this.chat = null;
    this.sig = null;
    this.anim = false;
    this.handle = cx.focus_handle();
    // The manifest's repos, as `loh status --repos` last said. Refetched when the crew changes.
    this.repos = [];
    this.reposKey = null;
    // Where each person is drawn: { cur, goal, legs, i, tasks }. See motion().
    this.acx = cx;
    this.walks = new Map();
    this.floor = null;
    // A click on someone who is not running: { person, plan }. Nothing starts until the person confirms.
    this.offer = null;
    this.crewNow = [];
  }

  // Ask loh for the workspace's repos (the mod never reads the manifest itself). It runs in a
  // folder inside the workspace: an agent's, else the `dir` prop. A failure keeps the last list.
  loadRepos(crew, workspace, cx) {
    const dir = anchorCwd(crew, props());
    if (!dir) return;
    const key = `${workspace}|${dir}|${crew.length}`;
    if (key === this.reposKey) return;
    this.reposKey = key;
    const c = reposCall({ cwd: dir }, (props() || {}).loh);
    exec(c.cmd, c.args, c.options).then((r) => {
      if (r.code !== 0) return;
      const next = repoNames(r.stdout);
      if (next.join("\n") !== this.repos.join("\n")) { this.repos = next; cx.notify(); }
    }).catch(() => {});
  }

  // Run loh lock / unlock in the agent's own folder. It exits non-zero when loh or the command
  // is missing or no workspace is found: say so instead of failing silently.
  runLoh(c, a, what) {
    const warn = (why) => notify({ title: `Could not ${what} ${a.name}`, body: String(why || "").slice(0, 200), level: "warning" });
    exec(c.cmd, c.args, c.options).then((r) => { if (r.code !== 0) warn(r.stderr || `loh exited ${r.code}`); }).catch((e) => warn(e && e.message));
  }

  fail(a, e) {
    notify({ title: `Could not open a chat with ${a.name}`, body: String((e && e.message) || e || "").slice(0, 200), level: "warning" });
  }

  // Click: open the chat beside the office. The agent's own terminal is shown in a split of this
  // tab (terminal.show), so the person types straight into it, and loh locks the agent.
  // Clicking another agent swaps the terminal in the same split and moves the lock.
  open(a, cx) {
    const loh = (props() || {}).loh;
    if (this.chat && this.chat.address === a.address) return;
    if (this.chat) {
      try { run("terminal.show", { terminal: a.address, pane: this.chat.pane }); } catch (e) { this.fail(a, e); return; }
      this.runLoh(unlockCall(this.chat.agent, loh), this.chat.agent, "unlock");
      this.chat = { ...this.chat, address: a.address, name: a.name, agent: a };
    } else {
      const mine = officePane(panes(), props());
      if (!mine) { this.fail(a, new Error("the office pane was not found")); return; }
      const before = new Set(panes().map((p) => p.pane));
      const tab = (panes().find((p) => p.pane === mine) || {}).tab;
      let pane = null;
      try {
        run("pane.split", { direction: "right", pane: mine });
        const added = panes().find((p) => !before.has(p.pane) && (!tab || p.tab === tab));
        pane = added ? added.pane : null;
        if (!pane) throw new Error("the split did not open");
        run("terminal.show", { terminal: a.address, pane });
      } catch (e) {
        // Show the split's own terminal back before closing it, and close only if that worked:
        // pane.close "ends its terminal", and which one that means while another is shown is not documented.
        if (pane) { try { run("terminal.show", { pane }); run("pane.close", { pane }); } catch (_) { /* leave the split */ } }
        this.fail(a, e);
        return;
      }
      this.chat = { pane, office: mine, address: a.address, name: a.name, agent: a };
    }
    this.runLoh(lockCall(a, loh), a, "lock");
    try { run("pane.focus", { pane: this.chat.pane }); } catch (_) { /* focus is a nicety */ }
    cx.notify();
  }

  // Close the chat: put the split's own terminal back first (so closing the pane never ends the
  // agent), close the split only if that worked, release the lock. Not named `close`: herdr calls a
  // View's close(cx) on unload, and this must run only when the person asks.
  closeChat(cx) {
    const c = this.chat;
    if (!c) return;
    this.chat = null;
    try {
      run("terminal.show", { pane: c.pane });
      run("pane.close", { pane: c.pane });
    } catch (e) {
      // The pane may be gone already; if it is not, leave it rather than risk ending the agent.
      if (panes().some((p) => p.pane === c.pane)) notify({ title: "Could not close the chat split", body: String((e && e.message) || e || "").slice(0, 200), level: "warning" });
    }
    this.runLoh(unlockCall(c.agent, (props() || {}).loh), c.agent, "unlock");
    if (cx) cx.notify();
  }

  // Full screen: pane.zoom on the office pane hides the chat split; Esc zooms back out.
  zoom(mine) {
    run("pane.zoom", { pane: mine });
    this.handle.focus();
  }

  // Where each person is drawn this render. A person whose place changed walks there door to door:
  // crew.js gives the legs, and each render draws the person at the end of the current leg with a
  // linear slide of the leg's length (a native transition). A one-shot timer ends each leg and
  // redraws, so the next leg starts and the gait stops when the last one ends. A render that changes
  // nothing for a person leaves its walk alone. `snap` (a new scale or floor) puts everyone in place.
  motion(L, snap) {
    const out = new Map();
    const here = new Set();
    for (const p of L.people) {
      here.add(p.id);
      const goal = { x: p.x, y: p.y };
      let w = this.walks.get(p.id);
      if (!w) { w = { cur: goal, goal, legs: [], i: 0, tasks: [] }; this.walks.set(p.id, w); }
      if (snap) { this.stopWalk(w); w.cur = goal; w.goal = goal; w.legs = []; w.i = 0; }
      else if (w.goal.x !== goal.x || w.goal.y !== goal.y) this.planWalk(w, p, L, goal);
      const leg = w.legs[w.i];
      out.set(p.id, leg ? { x: leg.x, y: leg.y, face: leg.face, ms: leg.ms, walking: true } : { x: goal.x, y: goal.y, face: p.face, ms: 1, walking: false });
    }
    for (const id of [...this.walks.keys()]) if (!here.has(id)) { this.stopWalk(this.walks.get(id)); this.walks.delete(id); }
    return out;
  }

  stopWalk(w) {
    for (const t of w.tasks) { try { t.cancel(); } catch (_) { /* already done */ } }
    w.tasks = [];
  }

  planWalk(w, p, L, goal) {
    this.stopWalk(w);
    const legs = legsOf(w.cur, pathTo(L, p.id, w.cur, goal), p.id === "dog" ? WALK_SPEED * 1.5 : WALK_SPEED);
    w.goal = goal; w.legs = legs; w.i = 0;
    if (!legs.length) { w.cur = goal; return; }
    let at = 0;
    legs.forEach((leg, i) => {
      at += leg.ms;
      w.tasks.push(this.acx.timer.after(at, (c) => {
        if (w.legs !== legs) return;
        w.cur = leg; w.i = i + 1;
        if (w.i >= legs.length) { w.legs = []; w.i = 0; w.cur = goal; }
        try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
      }));
    });
  }

  // A click on someone who is not running: say what would start them, and ask first.
  offerStart(p, cx) {
    this.offer = { person: p, plan: startPlan(p) };
    cx.notify();
  }

  confirmStart(cx) {
    const o = this.offer;
    this.offer = null;
    if (o && o.plan.kind === "up") {
      const dir = anchorCwd(this.crewNow, props());
      if (!dir) notify({ title: "Could not start the crew", body: "No agent is running to find the workspace from. Set the dir prop to a folder in the workspace.", level: "warning" });
      else this.runLoh(startCall(o.plan, dir, (props() || {}).loh), { name: "the crew" }, "start");
    }
    cx.notify();
  }

  offerRow(t) {
    const o = this.offer;
    if (!o) return null;
    const button = (id, label, bg, fg, onClick) => h_flex().id(id).px(8).py(2).rounded(5).bg(bg).text_size(12).text_color(fg).cursor_pointer().hover((e) => e.opacity(0.85)).on_click(onClick).child(label);
    const asks = o.plan.kind === "up";
    const text = asks ? o.plan.ask : o.plan.kind === "spawn" ? `${o.person.name} is not running. Start with: ${o.plan.hint}` : `${o.plan.hint}.`;
    return h_flex().id("offer").px(12).py(6).gap(10).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .child(div().flex_1().text_size(12).text_color(t.foreground).child(text))
      .when(asks, (el) => el.child(button("offer-yes", "Start", t.solid, t.solid_foreground, (_e, cx) => this.confirmStart(cx))))
      .child(button("offer-no", asks ? "Cancel" : "Dismiss", t.raised, t.foreground, (_e, cx) => { this.offer = null; cx.notify(); }));
  }

  // A person with no terminal, and Matt and Waffles: one line, a dot and the name. Someone who can be
  // started is a button.
  chip(p, left, top, motion) {
    const startable = !p.running && p.id !== "matt" && p.id !== "dog";
    const dot = p.id === "dog" ? PAL.dog : p.id === "matt" ? PAL.accent : PAL.idle;
    const el = h_flex().id(`tag-${p.id}`).absolute().left(left).top(top).h(17).px(6).gap(4).items_center().rounded_full().bg(PAL.chip)
      .when(this.anim, (e) => e.transition("left", motion).transition("top", motion))
      .child(div().w(7).h(7).rounded_full().bg(dot))
      .child(div().text_size(10.5).font_semibold().text_color(PAL.chipInk).whitespace_nowrap().child(p.name))
      .when(startable, (e) => e.child(div().text_size(10).text_color(PAL.chipInk).opacity(0.7).whitespace_nowrap().child("· no pane")));
    return startable ? el.cursor_pointer().hover((e) => e.opacity(0.85)).on_click((_e, cx) => this.offerStart(p, cx)) : el;
  }

  tag(a, s, k, F, t) {
    const color = a.status === "blocked" ? BLOCKED[a.kind][0] : a.status === "working" ? "#3fae69" : a.status === "done" ? "#3fae69" : t.muted;
    const ticket = a.repo ? `${a.repo}${a.ticket ? "#" + a.ticket : ""}` : "";
    const where = [ticket, a.pr ? `PR ${a.pr}` : "", a.round ? `r${a.round}` : ""].filter(Boolean).join(" · ");
    const step = a.step || a.note || WORDS[a.status];
    const w = Math.min(100, Math.max(64, 100 * k));
    return v_flex().id(`tag-${a.address}`).absolute().left(s.tag.x * k - w / 2).top(s.tag.y * k).w(w)
      .when(this.anim, (el) => el.transition("left", s.motion).transition("top", s.motion))
      .items_center().gap(1).px(4).py(2).rounded(5).bg(F.chip + "e6").cursor_pointer()
      .hover((e) => e.bg(F.chip))
      .on_click((_e, cx) => this.open(a, cx))
      .child(div().text_size(11).font_semibold().text_color(F.chipInk).truncate().child(a.name))
      .when(where !== "", (el) => el.child(div().text_size(9.5).text_color(F.chipInk).truncate().child(where)))
      .child(div().text_size(9.5).text_color(color).truncate().child(step))
      .when(a.withMatt, (el) => el.child(div().px(4).rounded(4).bg(t.accent).text_size(9).font_semibold().text_color(t.accent_foreground).child("with Matt")));
  }

  bar(t, n, view) {
    // Summary pills, as in the prototype: one per state, in the theme's own state colours.
    const cell = (key, label) => h_flex().px(8).h(19).items_center().rounded_full().bg(t[key] ?? t.unknown)
      .opacity(n[key] === 0 ? 0.55 : 1)
      .child(div().text_size(11).font_semibold().text_color(t.background).child(`${n[key]} ${label}`));
    const button = (id, label, onClick) => h_flex().id(id).px(8).py(2).rounded(5).border_1().border_color(t.border)
      .text_size(12).text_color(t.foreground).cursor_pointer().hover((e) => e.bg(t.hover)).on_click(onClick).child(label);
    return h_flex().id("totals").px(12).py(6).gap(16).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .child(div().text_size(12).font_semibold().text_color(t.foreground).child("Crew office"))
      .child(cell("working", "working")).child(cell("blocked", "blocked"))
      .child(cell("done", "done")).child(cell("idle", "idle"))
      .child(div().flex_1())
      .when(!!this.chat && !view.zoomed, (el) => el.child(div().text_size(12).text_color(t.muted).child(`Chat: ${this.chat.name}`)))
      .when(!!this.chat && view.mine !== null, (el) => el.child(button("fullscreen", view.zoomed ? "Show chat (Esc)" : "Full screen", () => this.zoom(view.mine))))
      .when(!!this.chat && !view.zoomed, (el) => el.child(button("close-chat", "Close chat", (_e, cx) => this.closeChat(cx))));
  }


  render(cx) {
    const t = theme();
    const dark = !!settings().dark;
    const list = terminals();
    const workspace = pickWorkspace(list, (props() || {}).crew);
    const crew = crewOf(list, workspace);
    this.crewNow = crew;
    this.loadRepos(crew, workspace, cx);
    const L = layoutCrew(crew, this.repos);
    const allPanes = panes();
    // The person closed the chat's split by hand: release the lock the click set.
    if (chatGone(allPanes, this.chat)) {
      const c = this.chat;
      this.chat = null;
      this.runLoh(unlockCall(c.agent, (props() || {}).loh), c.agent, "unlock");
    }
    // While a chat is open, keep using the office pane found when it opened: the click moves focus
    // to the chat, and officePane looks for the focused one.
    const mine = (this.chat && this.chat.office) || officePane(allPanes, props());
    const view = { mine, zoomed: !!(allPanes.find((p) => p.pane === mine) || {}).zoomed };
    // Fit the floor to the pane in both directions. The scale may drop below 1 (the chat takes
    // part of the tab); the floor is centred only while it fits, so it never spills off the left.
    const { k, fits } = fitScale(this.size, L);
    // Walk only when someone's place changed. A new scale (resize, the chat opening) or floor
    // width (the repo list arriving) moves every position at once, so draw those frames without
    // the transition and everything jumps with the rooms and desks.
    const sig = `${k}|${L.W}`;
    this.anim = sig === this.sig;
    this.sig = sig;
    const u = (n) => n * k;
    const mo = this.motion(L, !this.anim);

    // The floor does not change with the crew, only with the plan and the scale.
    const floorKey = `${k}|${L.W}|${L.pods.map((p) => p.repo).join(",")}`;
    if (!this.floor || this.floor.key !== floorKey) this.floor = { key: floorKey, layer: floorLayer(L, k) };

    // Screens: a lit strip on each desk, and Matt's two monitors.
    const lit = [];
    const screens = [];
    for (const d of L.desks) {
      const s = L.screens[d.key];
      if (s) { screens.push([d, s]); if (s !== "dim") lit.push([d, s]); }
    }
    for (const dx of [-9, 9]) {
      const d = { cx: L.mattDesk.cx + dx, y: L.mattDesk.y, h: L.mattDesk.h, side: "s" };
      screens.push([d, "work"]); lit.push([d, "work"]);
    }
    const glows = screens.flatMap(([d, s]) => glow(d, s, k));
    // The desk of someone Matt is talking to gets an accent strip.
    const plaque = new Layer(k, 0, 0, L.W, L.H);
    for (const p of L.people) {
      const d = p.agent && p.agent.withMatt && p.desk ? L.desks.find((q) => q.key === p.desk) : null;
      if (d) plaque.rr(d.x + 2, d.side === "n" ? d.y + 1 : d.y + d.h - 3, d.w - 4, 2, 1, PAL.accent);
    }

    // People, back to front. A wrapper carries each across the floor; the drawing inside is draw.js's.
    const figures = [...L.people].sort((a, b) => mo.get(a.id).y - mo.get(b.id).y).map((p) => {
      const m = mo.get(p.id);
      const motion = this.anim ? { duration: m.ms, easing: "linear" } : null;
      const kids = p.id === "dog" ? dogEls(p, k, m.walking) : personEls(p, k, m.walking ? m.face : p.face, m.walking, L);
      return wrapper(p.id, m.x, m.y, k, motion).children(kids);
    });

    // Name tags, stacked so none covers another.
    const F = { chip: PAL.chip, chipInk: PAL.chipInk };
    const sized = L.people.map((p) => {
      const a = p.agent;
      const where = a ? [a.repo, a.pr, a.round].some(Boolean) : false;
      const w = a ? Math.min(100, Math.max(64, 100 * k)) : (p.name.length + (p.running || p.id === "matt" || p.id === "dog" ? 0 : 9)) * 6.4 + 26;
      const h = a ? 4 + 13 + 11 + (where ? 11 : 0) + (a.withMatt ? 13 : 0) : 17;
      const m = mo.get(p.id);
      const left = Math.min(Math.max(2, u(m.x) - w / 2), Math.max(2, u(L.W) - w - 2));
      const up = p.tag.up && !m.walking;
      return { id: p.id, p, a, w, h, m, up, x: left, y: up ? u(m.y - 10) - h : u(m.y + 9) };
    });
    const tops = stackTags(sized);
    const tags = sized.map((s) => {
      const top = Math.max(2, tops.get(s.id));
      const motion = { duration: s.m.ms, easing: "linear" };
      if (s.a) return this.tag(s.a, { tag: { x: (s.x + s.w / 2) / k, y: top / k }, motion }, k, F, t);
      return this.chip(s.p, s.x, top, motion);
    });
    const nightEls = dark ? night(L, k, lit).concat(lit.flatMap(([d, s]) => glow(d, s, k))) : [];

    const floor = div().relative().w(u(L.W)).h(u(L.H)).rounded(6).bg(PAL.wall)
      .child(this.floor.layer.el()).children(labels(L, k, crew.length)).children(glows).child(plaque.el())
      .children(ball(L, k, L.rally)).children(figures).children(nightEls).children(tags);

    return v_flex().id("root").size_full().bg(t.canvas).track_focus(this.handle)
      .on_size_change((size, cx) => { this.size = size; cx.notify(); })
      .on_key_down((e, cx) => {
        if (e.key === "escape" && view.zoomed && view.mine) { run("pane.zoom", { pane: view.mine }); cx.stop_propagation(); }
      })
      .child(this.bar(t, L.totals, view))
      .when(!!this.offer, (el) => el.child(this.offerRow(t)))
      .child(h_flex().p(8).when(fits, (el) => el.justify_center()).child(floor));
  }
}
