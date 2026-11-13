// Crew office: one crew's agents at their desks, drawn from `hc` state only.
// Reads terminals() labels (crew, role, task, step, pr, round, note, with_matt)
// and each terminal's status. Keeps no state of its own beyond the pane size and the open chat
// (which agent, in which pane). Clicking an agent docks its live terminal in a split beside the office.
// Animation uses .frames() and .loop(), never timers.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { terminals, panes, run, exec, notify, props, theme, settings } from "herdr";
import { chatGone, crewOf, fitScale, layoutCrew, lockCall, officePane, pickWorkspace, repoNames, reposCall, unlockCall, ROOM_H, DESK_H } from "./crew.js";

const BLOCKED = { permission: ["#e7a43a", "allow?"], question: ["#4f8ff0", "?"], other: ["#d0509f", "!"] };
const WORDS = { working: "working", blocked: "needs you", done: "done", idle: "idle" };

// Person colours, from the Crew Office mock; anyone else gets one by name.
const PEOPLE = {
  scofield: ["#2a211c", "#e8b98f", "#3f5f93"], sucre: ["#16130f", "#b97a50", "#c4533a"],
  mahone: ["#8c6c4c", "#efc9a3", "#6d7d40"], sheba: ["#4a2618", "#8d5a3b", "#8e4fa8"],
  whip: ["#d8b04a", "#f0c8a0", "#2f8f8a"], amy: ["#b8432f", "#f1cfb0", "#39404f"],
  yoda: ["#e4e1d6", "#93b36c", "#8a6e4b"], sara: ["#2b1d14", "#c68a62", "#3f7fbf"],
};
const WALK = { duration: 900, easing: "ease-in-out" };
const SHIRTS =["#c4533a", "#6d7d40", "#8e4fa8", "#2f8f8a", "#d2a03a", "#e46b8f"];

const FLOOR_LIGHT = { wall: "#2b2f3a", repo: "#d8a874", leads: "#d8a874", meet: "#5a7a9a", lounge: "#8a7aa8", kitchen: "#e8dfc9", corr: "#c99a68", desk: "#f6f1e8", monitor: "#262a35", chip: "#2b2f3a", chipInk: "#f6f3ec",
  screen: "#1f2a36", screenInk: "#8fd3a5", counter: "#b9b2a3", fridge: "#dfe6ea", table: "#8aa27a", sofa: "#6a5a8c", rug: "#d98b4a", bed: "#c0504a", bedIn: "#f0e0c8", dog: "#d9a066" };
const FLOOR_DARK = { wall: "#14161c", repo: "#6b5238", leads: "#6b5238", meet: "#34495f", lounge: "#4f4668", kitchen: "#6a6252", corr: "#5e4a35", desk: "#c9c2b4", monitor: "#262a35", chip: "#0e1015", chipInk: "#eceae4",
  screen: "#10161d", screenInk: "#6fb98a", counter: "#7a7568", fridge: "#9aa3a8", table: "#5c7050", sofa: "#463c60", rug: "#8f5a30", bed: "#8a3a36", bedIn: "#b8a890", dog: "#a87a4c" };

function people(name) {
  const k = String(name).toLowerCase();
  if (PEOPLE[k]) return PEOPLE[k];
  let h = 0;
  for (const ch of k) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return ["#2a211c", "#d9a27a", SHIRTS[h % SHIRTS.length]];
}

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
  }

  // Ask loh for the workspace's repos (the mod never reads the manifest itself). It runs in an
  // agent's folder, which is inside the workspace. A failure keeps the last list.
  loadRepos(crew, workspace, cx) {
    const from = crew.find((a) => a.role === "coordinator" && a.cwd) || crew.find((a) => a.cwd);
    if (!from) return;
    const key = `${workspace}|${from.cwd}|${crew.length}`;
    if (key === this.reposKey) return;
    this.reposKey = key;
    const c = reposCall(from, (props() || {}).loh);
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

  // One person, seen from above: shoulders, hair and a face that turns to `face` (n, s, e, w).
  // A working person at a desk has both hands on the keyboard, on the side the desk is on.
  // The wrapper has a stable id and slides (transition left/top) when the agent's place changes,
  // so a state change shows as a walk to the new room. No timer: the slide runs natively.
  person(a, x, y, face, place, k, F) {
    const [hair, skin, shirt] = people(a.name);
    const sz = Math.max(12, 16 * k);
    const state = a.status;
    const color = state === "blocked" ? BLOCKED[a.kind][0] : state === "working" ? "#3fae69" : state === "done" ? "#3fae69" : "#aab2bf";
    const side = face === "e" ? 1 : face === "w" ? -1 : 0;
    const dot = (cx, cy, d, bg) => div().absolute().left(sz * (cx - d / 2)).top(sz * (cy - d / 2)).w(sz * d).h(sz * d).rounded_full().bg(bg);
    const bodyW = side ? 0.5 : 0.78;
    const body = div().absolute().left(sz * (0.5 - bodyW / 2)).top(sz * (side ? 0.3 : 0.4)).w(sz * bodyW).h(sz * (side ? 0.62 : 0.5)).rounded_full().bg(shirt);
    // Hair is the whole head; the face is a smaller disc shifted toward where the person looks.
    const hx = 0.5 + side * 0.07;
    const head = dot(0.5, 0.3, 0.62, hair);
    const faceDisc = face === "n" ? null : dot(hx, face === "s" ? 0.36 : 0.32, 0.5, skin);
    const eye = (dx) => dot(0.5 + dx, 0.38, 0.09, "#1b1b1f");
    const eyes = face === "s" ? [eye(-0.1), eye(0.1)] : side ? [dot(0.5 + side * 0.17, 0.32, 0.09, "#1b1b1f")] : [];
    const fig = div().relative().w(sz).h(sz).child(body).child(head).when(!!faceDisc, (el) => el.child(faceDisc)).children(eyes)
      .when(a.withMatt, (el) => el.child(div().absolute().left(-2).top(-2).w(sz + 4).h(sz + 4).rounded_full().border(2).border_color(color)));
    // Hands: on the keyboard (in front of the body, toward the desk) while working at a desk.
    const reach = face === "s" ? 0.98 : face === "n" ? -0.1 : 0.5;
    const keys = state === "working" && place === "desk"
      ? [dot(0.36, reach, 0.2, skin).loop("opacity", { from: 0.7, to: 1, period: 260 }), dot(0.64, reach, 0.2, skin).loop("opacity", { from: 1, to: 0.7, period: 260 })]
      : [];
    const hand = div().absolute().left(sz * 0.85).top(-sz * 0.35).w(sz * 0.28).h(sz * 0.28).rounded_full().bg(skin)
      .loop("opacity", { from: 0.35, to: 1, period: 800 });
    const bubble = (text, bg) => div().absolute().left(sz * 0.9).top(-sz * 1.1).px(4).rounded(6).bg(bg).text_size(10).font_semibold().text_color("#ffffff").child(text);
    const typing = div().absolute().left(sz * 0.9).top(-sz * 0.2).text_size(11).text_color(color).child("·").frames(["·  ", "·· ", "···"], 300);
    return div().id(`person-${a.address}`).absolute().left(x * k - sz / 2).top(y * k - sz / 2).w(sz).h(sz)
      .when(this.anim, (el) => el.transition("left", WALK).transition("top", WALK))
      .child(fig).children(keys)
      .when(state === "working", (el) => el.child(typing))
      .when(state === "blocked", (el) => el.child(hand).child(bubble(BLOCKED[a.kind][1], BLOCKED[a.kind][0])))
      .when(state === "done", (el) => el.child(bubble("✓", "#3fae69")));
  }

  tag(a, s, k, F, t) {
    const color = a.status === "blocked" ? BLOCKED[a.kind][0] : a.status === "working" ? "#3fae69" : a.status === "done" ? "#3fae69" : t.muted;
    const ticket = a.repo ? `${a.repo}${a.ticket ? "#" + a.ticket : ""}` : "";
    const where = [ticket, a.pr ? `PR ${a.pr}` : "", a.round ? `r${a.round}` : ""].filter(Boolean).join(" · ");
    const step = a.step || a.note || WORDS[a.status];
    const w = Math.min(100, Math.max(64, 100 * k));
    return v_flex().id(`tag-${a.address}`).absolute().left(s.tag.x * k - w / 2).top(s.tag.y * k).w(w)
      .when(this.anim, (el) => el.transition("left", WALK).transition("top", WALK))
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
    const F = settings().dark ? FLOOR_DARK : FLOOR_LIGHT;
    const list = terminals();
    const workspace = pickWorkspace(list, (props() || {}).crew);
    const crew = crewOf(list, workspace);
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
    // Slide only when someone's place changed. A new scale (resize, the chat opening) or floor
    // width (the repo list arriving) moves every position at once, so draw those frames without
    // the transition and everything jumps with the rooms and desks.
    const sig = `${k}|${L.W}`;
    this.anim = sig === this.sig;
    this.sig = sig;
    const u = (n) => n * k;

    const rooms = L.rooms.map((r) => div().absolute().left(u(r.x) + 1).top(u(r.y) + 1).w(u(r.w) - 2).h(u(r.h) - 2).rounded(4)
      .bg(F[r.kind] ?? F.repo).child(div().absolute().left(6).top(2).text_size(10).font_semibold().text_color("#ffffffcc").child(r.label)));
    const desks = L.desks.map((d) => div().absolute().left(u(d.x)).top(u(d.y)).w(u(d.w)).h(u(DESK_H)).rounded(2).bg(F.desk)
      .child(div().absolute().left(u(d.w / 2 - 6)).top(u(d.side === "n" ? 9 : 2)).w(u(12)).h(u(4)).rounded(1).bg(F.monitor)));
    const box = (x, y, w, h, bg, r = 2) => div().absolute().left(u(x)).top(u(y)).w(u(w)).h(u(h)).rounded(r).bg(bg);
    const meet = L.rooms.find((r) => r.kind === "meet");
    const lounge = L.rooms.find((r) => r.kind === "lounge");
    const kitchen = L.rooms.find((r) => r.kind === "kitchen");
    const decor = [];
    if (meet) {
      // Meeting table with its screen on the back wall; the screen says how many agents are live.
      decor.push(box(meet.x + 28, 40, 40, 36, F.desk, 6).opacity(0.7));
      decor.push(box(meet.x + 26, 6, 44, 12, F.screen, 2).child(div().absolute().left(4).top(1).text_size(Math.max(7, 6 * k)).text_color(F.screenInk).child(`${crew.length} on the crew`)));
    }
    if (kitchen) {
      decor.push(box(kitchen.x + 4, kitchen.y + 8, 40, 11, F.counter), box(kitchen.x + 56, kitchen.y + 8, 40, 11, F.counter));
      decor.push(box(kitchen.x + 80, kitchen.y + kitchen.h - 26, 16, 22, F.fridge, 2));
      decor.push(box(kitchen.x + 36, kitchen.y + 38, 28, 28, F.table, 14));
    }
    if (lounge) {
      decor.push(box(lounge.x + 8, lounge.y + 14, 56, 12, F.sofa, 4));
      decor.push(box(lounge.x + 18, lounge.y + 38, 56, 34, F.rug, 16));
      // Waffles, asleep on her bed, with a slow "zz".
      const dg = L.dog;
      decor.push(box(dg.x - 12, dg.y - 8, 24, 16, F.bed, 8), box(dg.x - 8, dg.y - 5, 16, 10, F.bedIn, 5));
      decor.push(box(dg.x - 7, dg.y - 4, 14, 8, F.dog, 4));
      decor.push(div().absolute().left(u(dg.x + 5)).top(u(dg.y - 14)).text_size(Math.max(8, 7 * k)).text_color(F.chipInk).child("zz").loop("opacity", { from: 0.2, to: 1, period: 1600 }));
    }
    const table = decor;
    const figures = L.seats.map((s) => this.person(s.agent, s.x, s.y, s.face, s.place, k, F));
    const tags = L.seats.map((s) => this.tag(s.agent, s, k, F, t));
    const empty = crew.length === 0
      ? [div().absolute().left(12).top(u(ROOM_H) / 2).text_size(13).text_color(F.chipInk).child("No crew terminals found. Start one with loh up.")]
      : [];

    const floor = div().relative().w(u(L.W)).h(u(L.H)).rounded(6).bg(F.wall)
      .child(div().absolute().left(0).top(u(ROOM_H)).w(u(L.W)).h(u(20)).bg(F.corr))
      .children(rooms).children(desks).children(table).children(figures).children(tags).children(empty);

    return v_flex().id("root").size_full().bg(t.canvas).track_focus(this.handle)
      .on_size_change((size, cx) => { this.size = size; cx.notify(); })
      .on_key_down((e, cx) => {
        if (e.key === "escape" && view.zoomed && view.mine) { run("pane.zoom", { pane: view.mine }); cx.stop_propagation(); }
      })
      .child(this.bar(t, L.totals, view))
      .child(h_flex().p(8).when(fits, (el) => el.justify_center()).child(floor));
  }
}
