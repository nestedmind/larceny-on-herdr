// Crew office: one crew's agents at their desks, drawn from `hc` state only.
// Reads terminals() labels (crew, role, task, step, pr, round, note, with_matt)
// and each terminal's status. Keeps no state of its own beyond the pane size.
// Animation uses .frames() and .loop(), never timers.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { terminals, panes, run, exec, notify, props, theme, settings } from "herdr";
import { crewOf, layoutCrew, lockCall, pickWorkspace, ROOM_H, DESK_H } from "./crew.js";

const BLOCKED = { permission: ["#e7a43a", "allow?"], question: ["#4f8ff0", "?"], other: ["#d0509f", "!"] };
const WORDS = { working: "working", blocked: "needs you", done: "done", idle: "idle" };

// Person colours, from the Crew Office mock; anyone else gets one by name.
const PEOPLE = {
  scofield: ["#2a211c", "#e8b98f", "#3f5f93"], sucre: ["#16130f", "#b97a50", "#c4533a"],
  mahone: ["#8c6c4c", "#efc9a3", "#6d7d40"], sheba: ["#4a2618", "#8d5a3b", "#8e4fa8"],
  whip: ["#d8b04a", "#f0c8a0", "#2f8f8a"], amy: ["#b8432f", "#f1cfb0", "#39404f"],
  yoda: ["#e4e1d6", "#93b36c", "#8a6e4b"], sara: ["#2b1d14", "#c68a62", "#3f7fbf"],
};
const SHIRTS = ["#c4533a", "#6d7d40", "#8e4fa8", "#2f8f8a", "#d2a03a", "#e46b8f"];

const FLOOR_LIGHT = { wall: "#2b2f3a", repo: "#d8a874", leads: "#d8a874", meet: "#5a7a9a", lounge: "#8a7aa8", corr: "#c99a68", desk: "#f6f1e8", monitor: "#262a35", chip: "#2b2f3a", chipInk: "#f6f3ec" };
const FLOOR_DARK = { wall: "#14161c", repo: "#6b5238", leads: "#6b5238", meet: "#34495f", lounge: "#4f4668", corr: "#5e4a35", desk: "#c9c2b4", monitor: "#262a35", chip: "#0e1015", chipInk: "#eceae4" };

function people(name) {
  const k = String(name).toLowerCase();
  if (PEOPLE[k]) return PEOPLE[k];
  let h = 0;
  for (const ch of k) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return ["#2a211c", "#d9a27a", SHIRTS[h % SHIRTS.length]];
}

export default class CrewOffice extends View {
  init(_props, _cx) {
    this.size = { width: 640, height: 480 };
  }

  // Click: focus the agent (a terminal with no pane gets one first), then lock it with loh.
  open(a) {
    const has = panes().some((p) => p.terminal === a.address);
    run(has ? "agent.focus" : "terminal.keep", { terminal: a.address });
    // Mods can run commands, so set the with-Matt lock. It exits non-zero when loh or
    // the lock command is missing or no workspace is found: say so instead of failing silently.
    const c = lockCall(a, (props() || {}).loh);
    const warn = (why) => notify({ title: `Could not lock ${a.name}`, body: String(why || "").slice(0, 200), level: "warning" });
    exec(c.cmd, c.args, c.options).then((r) => { if (r.code !== 0) warn(r.stderr || `loh exited ${r.code}`); }).catch((e) => warn(e && e.message));
  }

  person(a, x, y, face, k, F) {
    const [hair, skin, shirt] = people(a.name);
    const sz = Math.max(10, 14 * k);
    const state = a.status;
    const color = state === "blocked" ? BLOCKED[a.kind][0] : state === "working" ? "#3fae69" : state === "done" ? "#3fae69" : "#aab2bf";
    const body = div().absolute().left(sz * 0.1).top(sz * 0.3).w(sz * 0.8).h(sz * 0.6).rounded_full().bg(shirt);
    const head = div().absolute().left(sz * 0.2).top(sz * 0.05).w(sz * 0.6).h(sz * 0.6).rounded_full().bg(skin)
      .border(Math.max(1, sz * 0.14)).border_color(face === "n" ? hair : skin);
    const fig = div().relative().w(sz).h(sz).child(body).child(head)
      .when(a.withMatt, (el) => el.child(div().absolute().left(-2).top(-2).w(sz + 4).h(sz + 4).rounded_full().border(2).border_color(color)));
    const hand = div().absolute().left(sz * 0.85).top(-sz * 0.35).w(sz * 0.28).h(sz * 0.28).rounded_full().bg(skin)
      .loop("opacity", { from: 0.35, to: 1, period: 800 });
    const bubble = (text, bg) => div().absolute().left(sz * 0.9).top(-sz * 1.1).px(4).rounded(6).bg(bg).text_size(10).font_semibold().text_color("#ffffff").child(text);
    const typing = div().absolute().left(sz * 0.9).top(-sz * 0.2).text_size(11).text_color(color).child("·").frames(["·  ", "·· ", "···"], 300);
    return div().absolute().left(x * k - sz / 2).top(y * k - sz / 2).w(sz).h(sz)
      .child(fig)
      .when(state === "working", (el) => el.child(typing))
      .when(state === "blocked", (el) => el.child(hand).child(bubble(BLOCKED[a.kind][1], BLOCKED[a.kind][0])))
      .when(state === "done", (el) => el.child(bubble("✓", "#3fae69")));
  }

  tag(a, s, k, F, t) {
    const color = a.status === "blocked" ? BLOCKED[a.kind][0] : a.status === "working" ? "#3fae69" : a.status === "done" ? "#3fae69" : t.muted;
    const ticket = a.repo ? `${a.repo}${a.ticket ? "#" + a.ticket : ""}` : "";
    const where = [ticket, a.pr ? `PR ${a.pr}` : "", a.round ? `r${a.round}` : ""].filter(Boolean).join(" · ");
    const step = a.step || a.note || WORDS[a.status];
    const w = 100;
    return v_flex().id(`tag-${a.address}`).absolute().left(s.tag.x * k - w / 2).top(s.tag.y * k).w(w)
      .items_center().gap(1).px(4).py(2).rounded(5).bg(F.chip + "e6").cursor_pointer()
      .hover((e) => e.bg(F.chip))
      .on_click(() => this.open(a))
      .child(div().text_size(11).font_semibold().text_color(F.chipInk).truncate().child(a.name))
      .when(where !== "", (el) => el.child(div().text_size(9.5).text_color(F.chipInk).truncate().child(where)))
      .child(div().text_size(9.5).text_color(color).truncate().child(step))
      .when(a.withMatt, (el) => el.child(div().px(4).rounded(4).bg(t.accent).text_size(9).font_semibold().text_color(t.accent_foreground).child("with Matt")));
  }

  bar(t, n) {
    const cell = (key, label) => h_flex().gap(4).items_center()
      .child(div().w(8).h(8).rounded_full().bg(t[key] ?? t.unknown))
      .child(div().text_size(12).text_color(t.foreground).child(`${n[key]} ${label}`));
    return h_flex().id("totals").px(12).py(6).gap(16).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .child(div().text_size(12).font_semibold().text_color(t.foreground).child("Crew office"))
      .child(cell("working", "working")).child(cell("blocked", "blocked"))
      .child(cell("done", "done")).child(cell("idle", "idle"));
  }

  render(_cx) {
    const t = theme();
    const F = settings().dark ? FLOOR_DARK : FLOOR_LIGHT;
    const list = terminals();
    const crew = crewOf(list, pickWorkspace(list, (props() || {}).crew));
    const L = layoutCrew(crew);
    const k = Math.min(4, Math.max(1, (this.size.width - 16) / L.W));
    const u = (n) => n * k;

    const rooms = L.rooms.map((r) => div().absolute().left(u(r.x) + 1).top(u(r.y) + 1).w(u(r.w) - 2).h(u(r.h) - 2).rounded(4)
      .bg(F[r.kind] ?? F.repo).child(div().absolute().left(6).top(2).text_size(10).font_semibold().text_color("#ffffffcc").child(r.label)));
    const desks = L.desks.map((d) => div().absolute().left(u(d.x)).top(u(d.y)).w(u(d.w)).h(u(DESK_H)).rounded(2).bg(F.desk)
      .child(div().absolute().left(u(d.w / 2 - 6)).top(u(d.side === "n" ? 9 : 2)).w(u(12)).h(u(4)).rounded(1).bg(F.monitor)));
    const table = L.rooms.filter((r) => r.kind === "meet").map((r) => div().absolute().left(u(r.x + 36)).top(u(26)).w(u(28)).h(u(34)).rounded(6).bg(F.desk).opacity(0.7));
    const figures = L.seats.map((s) => this.person(s.agent, s.x, s.y, s.face, k, F));
    const tags = L.seats.map((s) => this.tag(s.agent, s, k, F, t));
    const empty = crew.length === 0
      ? [div().absolute().left(12).top(u(ROOM_H) / 2).text_size(13).text_color(F.chipInk).child("No crew terminals found. Start one with loh up.")]
      : [];

    const floor = div().relative().w(u(L.W)).h(u(L.H)).rounded(6).bg(F.wall)
      .child(div().absolute().left(0).top(u(ROOM_H)).w(u(L.W)).h(u(20)).bg(F.corr))
      .children(rooms).children(desks).children(table).children(figures).children(tags).children(empty);

    return v_flex().id("root").size_full().bg(t.canvas)
      .on_size_change((size, cx) => { this.size = size; cx.notify(); })
      .child(this.bar(t, L.totals))
      .child(div().p(8).child(floor));
  }
}
