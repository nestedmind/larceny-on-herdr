// Crew office: one crew's agents at their desks, drawn from `hc` state only.
// Reads terminals() labels (crew, role, task, step, pr, round, note, with_matt)
// and each terminal's status. Keeps no state of its own beyond the pane size and the open chat
// (which agent, in which pane). Clicking an agent docks its live terminal in a split beside the office.
// The drawing is in draw.js and the placement in crew.js. Gaits, typing and the ball animate natively
// (.loop(), .transition()); no repeating timer. A whole walk is handed to the renderer in one render
// (see motion()); one-shot timers only turn the walker to face the next leg and end the gait.

import { View, div, image } from "gpui-kit";
import { v_flex, h_flex, h_resizable, resizable_panel } from "gpui-base";
import { terminals, panes, run, exec, appHome, notify, props, theme, settings, layout, shared, setShared, openOverlay, closeOverlay, focused, window as appWindow } from "herdr";
import { OFFICE_PING_MS, confettiPieces, pingCall, newToasts, toastStep, toastDismiss, toastPhase, TOAST_SLIDE_MS, seededRand, rallyOf, standLook, MATT_SEAT_HOLD, mattSeatedAt, restAt, screensSeen, snapStay, LIGHTS_KEY, lightsSeenKey, lightsFrom, lightsSignal, lightsValue, chimeSignal, chimeCall, PAD, TYPING_HOLD, aspectOf, doArgs, findNode as findNodeById, entryFor, floorKey, focusArrived, idleMinutesOf, mattTypingAt, newMemory, pickIdleMs, recoveryFor, chatGone, clampPanelW, crewOf, fullTerminalOverlay, termId, modNameOf, modScanCall, resolveModName, holdersAcquire, holdersRelease, panelWidthKey, PANEL_MIN, serialQueue, settingsCall, termHeld, fitScale, fullscreenPlan, restoreSteps, stageBg, layoutCrew, legsOf, prsCall, PRS_EVERY_MS, REPOS_EVERY_MS, lockCall, nextGoal, officePane, pathTo, pickWorkspace, posAt, repoNames, reposCall, crewCall, namesOf, reactDirCall, reactDirOf, stackTags, stageSize, startCall, startPlan, unlockCall, walkChain, WALK_SPEED, workspaceDir } from "./crew.js";
import { BLOCKED, PAL, SLOTS, ball, confettiEls, dogEls, figureBox, floorLayer, floorSvg, floorSvgName, glow, hitBox, labels, mover, nightLayers, personEls, Layer } from "./draw.js";
import { imagePath } from "./photos.js";
import * as fs from "fs/promises";
import { Panel } from "./panel.js";

// How long one render may spend building a big layer's paths before it carries on in the next one.
// herdr stops a render at about 50 ms, so a render that built everything at once was cut off.
const BUILD_MS = 12;
// A walk's end is taken this long after its last leg should have ended, so the clock never ends it early.
const ARRIVE_SLACK = 60;
// How long a walker stands at rest, movers put back, between the end of one walk and the start of the next.
const SETTLE_MS = 50;
// Where the floor pictures go, under herdr's folder, and how many stay there.
const FLOOR_DIR = "crew-office-floors";
const FLOOR_FILES = 12;
// The name tag's own slide, for when the tags restack at rest.
const TAG_SLIDE = { duration: 220, easing: "ease-out" };

// Where a full-screen mode that is still on is written down, so a reload of the office can undo it.
const FS_KEY = "crew-office.fullscreen";
// The name this copy is loaded under. Panes of this mod, and the full-terminal window it opens, are found by it.
// The folder of this source names it until the scan in nameMod() says which mods/ entry leads here: a symlinked
// mod may report its real folder, whose name is not the one it is loaded under.
let MOD = modNameOf(import.meta.url);
// `done` runs once the name is settled, whether or not the scan could say: what looks for this copy's panes waits for it.
function nameMod(done) {
  try {
    const c = modScanCall(import.meta.url, appHome());
    exec(c.cmd, c.args, c.options).then((r) => { if (r && r.code === 0) MOD = resolveModName(MOD, r.stdout); }).catch(() => {}).then(done);
  } catch (_) { done(); /* keep the folder's name */ }
}
// Who holds each agent's with-Matt lock (a docked chat, a full-terminal window). Module state, not persisted:
// every copy of this source (the office and the full-terminal bar) shares it, and a crash or restart starts clean.
let held = {};
// The slim bars that are up, by window id: a bar that never comes up means its window never opened.
const bars = new Set();
// How long a full-terminal window has to show its bar before its hold is let go.
const TERM_GRACE = 4000;
// loh lock and unlock for one agent go through one queue, so the last call sent is the last one run.
const lohQueue = serialQueue();

function lohRun(c, a, what) {
  const warn = (why) => notify({ title: `Could not ${what} ${a.name}`, body: String(why || "").slice(0, 200), level: "warning" });
  return exec(c.cmd, c.args, c.options).then((r) => { if (r.code !== 0) { warn(r.stderr || `loh exited ${r.code}`); return false; } return true; }).catch((e) => { warn(e && e.message); return false; });
}

function holders() {
  return held;
}

// The agent is locked when its first holder arrives, and unlocked when the last one goes.
function hold(a, loh, id) {
  const r = holdersAcquire(holders(), a.address, id);
  held = r.state;
  return r.lock ? lohQueue(a.address, () => lohRun(lockCall(a, loh), a, "lock")) : Promise.resolve();
}

function unhold(a, loh, id) {
  const r = holdersRelease(holders(), a.address, id);
  held = r.state;
  return r.unlock ? lohQueue(a.address, () => lohRun(unlockCall(a, loh), a, "unlock")) : Promise.resolve();
}

// The prototype's toast, in its units (crew-office.html, `.toasts` and `.toast`): the stack's width, the gap, how far under the top of
// the floor it starts (the prototype puts it 58 under the top of its stage, and its floor starts 51 under that, the topbar's 31 and 20, so 7 under the floor's top, on its top wall; the stack is a child of the floor's own box, in px and not scaled with it, so it is 12 from the floor's right edge, whole, and never under the chat panel), and the colours of both themes (--toast-bg, --toast-ink, --toast-muted).
const TOAST_W = 280;
const TOAST_GAP = 6;
const TOAST_TOP = 7;
// How far up a toast is drawn while it is entering or leaving, and the height taken for one until it has been measured (three lines).
const TOAST_RISE = 8;
const TOAST_H = 65;
const TOAST_FONT = "Noto Sans";
const TOAST_LIGHT = { bg: "#ffffff", ink: "#151a24", muted: "#5b6272" };
const TOAST_DARK = { bg: "#222937", ink: "#e3e8f0", muted: "#9ba5b8" };

const WORDS = { working: "working", blocked: "needs you", done: "done", idle: "idle" };

// The floor is a retained nested view of its own. herdr runs a view's render() when that view is
// invalidated, not with every render of the office, so the floor's thousands of path commands are
// described once per plan and not on every render of everything else. The office puts the finished
// floor here ({ layer }), under the id it gave its view, and asks the view to render again when
// the plan changes. (Plain module state: props cross herdr's view bridge as data.)
const FLOORS = new Map();
let floorSeq = 0;

class Floor extends View {
  init(props) { this.id = props && props.id; }
  update(props) { this.id = props && props.id; }
  render() {
    const s = FLOORS.get(this.id);
    if (!s || !s.layer) return div();
    // What this view last drew, so the office knows whether a newly finished floor needs another render.
    s.drawn = s.layer; s.drawnK = s.layer.k;
    this.layer = s.layer;
    return s.layer.fillEl();
  }
}

export default class CrewOffice extends View {
  init(_props, cx) {
    // The slim bar of a full-terminal window: nothing else of the office runs there.
    this.termBar = !!(props() || {}).terminalBar;
    if (this.termBar) {
      // After a mod reload this copy has empty module state: record the window as a holder again, so
      // Back unlocks the agent and nothing else's release does. The lock is idempotent.
      const p = props() || {};
      if (p.agent && p.agent.address && p.termId) { bars.add(p.termId); hold(p.agent, p.loh, p.termId); }
      return;
    }
    this.size = { width: 640, height: 480 };
    // The open chat: { pane, address, name, agent } or null. The pane is a split beside this one.
    this.chat = null;
    this.sig = null;
    this.anim = false;
    this.handle = cx.focus_handle();
    this.acx = cx;
    // (The floor's ellipse images are found by this name, so the floor draws again once it is settled.)
    nameMod(() => {
      this.recoverFs();
      try { this.acx.notify(this.floorView); } catch (_) { /* the view was reloaded or closed */ }
    });
    // The manifest's repos, as `loh status --repos` last said. Refetched when the crew changes.
    this.repos = [];
    this.reposKey = null;
    // The crew's names, as `loh crew --json` last said (null until it has: the shipped names).
    this.names = null;
    // The idle time the workspace sets (`idle_minutes` in its manifest, through `loh status --settings`); the idleMinutes prop wins.
    this.idleMinutes = undefined;
    this.reactDir = ""; // where the chat keeps its reactions (`loh react --dir`), "" until loh has said
    // Where each person was last placed, for keeping seats (crew.js layoutCrew), and until when Matt's last key in the message box counts.
    this.mem = newMemory();
    // The toasts showing, and what each agent was last seen with (crew.js toastStep). `pingAt` is when loh was last told the office is open.
    this.toasts = newToasts();
    // The confetti showing ({ id, x, y, at, pieces }), and the merges seen whose desk is not known yet (resolved once the render has the walks).
    this.bursts = [];
    this.burstsDue = [];
    this.burstN = 0;
    // Each toast's measured height, by id.
    this.toastH = new Map();
    this.pingAt = 0;
    this.mattLast = 0;
    this.lastFocus = null;
    // The one timer that renders again when time alone changes something (an idle time ends, a wait ends): { at, task }.
    this.wake = null;
    // Where each person is drawn: { at, goal, from, legs, t0, i, tasks }. See motion().
    this.walks = new Map();
    // Walkers whose rest frame the render in progress draws: marked drawn when that render ends (see holdOrGo).
    this.restSeen = new Set();
    // What each person was last drawn with at rest (crew.js standLook).
    this.looks = new Map();
    // The floor and the night layers: built once for a plan, kept across scales. See render().
    this.floor = null;
    this.floors = new Map();
    this.pics = new Map();
    this.floorId = `floor-${++floorSeq}`;
    FLOORS.set(this.floorId, { layer: null, drawn: null });
    this.floorView = cx.new(Floor, { id: this.floorId });
    // The last floor that was finished, drawn while a new plan builds, and the two most recent finished plans' keys (kept in the cache).
    this.shown = null;
    this.pinned = [];
    this.night = null;
    this.nightLast = null;
    this.moreBuilding = false;
    // Whether the chat panel was showing when the stage was last measured, and when it was last drawn:
    // herdr reports the stage's size a frame late, so a render that opens the panel must know the size is too wide.
    this.sizeWithPanel = false;
    // Whether herdr has reported the stage's real size yet; until it has, the default size would draw a floor at the wrong scale.
    this.measured = false;
    this.drawnWithPanel = false;
    // A click on someone who is not running: { person, plan }. Nothing starts until the person confirms.
    this.offer = null;
    this.crewNow = [];
    // The chat panel beside the office; its Terminal button docks the real terminal (open below).
    // Full-screen mode that is on: { plan, pane } (what it did, so Esc undoes exactly that) or null.
    this.fs = null;
    // Full screen that an earlier copy left on is dealt with once the name is settled (recoverFs): before that, this
    // copy could take another mod's panes for its own.
    // The panel's width: kept per crew in shared state, so a reload keeps it. Clamped on every render, when the office's width is known.
    // It is read once the crew shown is known (render), so it is per crew, not per prop.
    this.panelKey = null;
    // The lights: on at the start, then whatever was saved. Herdr's dark mode only sets the stage colour.
    this.lights = true;
    try { this.lights = lightsFrom(shared(LIGHTS_KEY)); } catch (_) { /* none saved: lights on */ }
    // The stamp of the last `loh office lights` choice applied, per workspace folder (kept with the choice, so a reload does
    // not apply it twice); read when the folder is first known.
    this.lightsSeen = "";
    this.lightsSeenDir = null;
    // The chime (the sound of `loh watch` notices) is kept by loh in .loh/chime, not here: this is what the last ping said or
    // what the button last asked for. chimeSeq counts presses, so a ping already out when one happens does not undo it.
    this.chime = true;
    this.chimeSeq = 0;
    this.chimeDir = null;
    this.panelW = clampPanelW(null, 1e9);
    this.splitW = 0; // the resizable group's own width, once measured
    this.termOpen = false; // a full-terminal window of this copy is open
    this.termWin = null; // the one this copy opened: { id, agent, loh, at, seen }
    this.panel = new Panel({ loh: () => (props() || {}).loh, terminal: (a, cx) => this.open(a, cx), fullTerminal: (a, cx) => this.fullTerminal(a, cx), busy: () => this.termOpen, photos: () => (props() || {}).photos, typed: (cx) => this.typed(cx), width: () => this.panelW, person: () => (this.names && this.names.person) || "", reactDir: () => this.reactDir, emojiScale: () => (props() || {}).emojiScale, modName: () => MOD });
  }

  // Full terminal: the agent's own terminal over the whole herdr window (an overlay window: a slim bar
  // with Back, and the terminal block). It changes no pane, so full-screen mode and its saved plan are
  // untouched, and it works whether or not the office is zoomed. loh locks the agent now and the bar
  // unlocks it when the window goes (see close).
  fullTerminal(a, cx) {
    const loh = (props() || {}).loh;
    const focus = (address) => { try { run("pane.focus", { terminal: address }); } catch (_) { /* focus is a nicety */ } };
    // One window at a time: a second click only brings the keyboard back to it.
    // Only this copy's window counts: another copy's does not hold this one's keyboard.
    const open = Object.entries(holders()).find(([, ids]) => Array.isArray(ids) && ids.some((i) => String(i).startsWith(`term-${MOD}:`)));
    if (open) { focus(open[0]); return; }
    const id = termId(MOD, `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`);
    try { openOverlay(fullTerminalOverlay(a, loh, id, MOD)); } catch (e) { this.fail(a, e); return; }
    hold(a, loh, id);
    this.termWin = { id, agent: a, loh, at: Date.now(), seen: false };
    this.wakeIn(TERM_GRACE + 50);
    this.termOpen = true;
    // A window does not take the keyboard when it opens: give it to the terminal, so Esc and typing go to the agent.
    focus(a.address);
    if (cx) cx.notify();
  }

  // The bar over a full-terminal window.
  renderTermBar() {
    const t = theme();
    const p = props() || {};
    const a = p.agent || {};
    return h_flex().id("term-bar").size_full().px(12).gap(10).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .on_mouse_down("left", (_e, c) => c.stop_propagation())
      .child(div().text_size(12).font_semibold().text_color(t.foreground).child(`Terminal: ${a.name || ""}`))
      .child(div().text_size(11).text_color(t.muted).child("Keys go to the agent; Back returns to the office"))
      .child(div().flex_1())
      .child(h_flex().id("term-back").px(8).py(2).rounded(5).border_1().border_color(t.border).text_size(12).text_color(t.foreground)
        .cursor_pointer().hover((e) => e.bg(t.hover))
        .on_mouse_down("left", (_e, c) => c.stop_propagation())
        .on_click(() => { try { closeOverlay(p.overlay); } catch (_) { /* already closed */ } })
        .child("Back to office"));
  }

  // Ask loh for the workspace's repos (the mod never reads the manifest itself). It runs in a
  // folder inside the workspace: an agent's, else the `dir` prop. A failure keeps the last list. It is asked on a change of
  // workspace, folder or crew size, and every REPOS_EVERY_MS besides, so a repo added to or removed from the manifest shows up.
  // Each ask is three local loh calls (the repo list, the settings and the crew's names): they read files, and no network is used.
  loadRepos(crew, workspace, cx) {
    const dir = this.workspaceDir(crew);
    if (!dir) return;
    const key = `${workspace}|${dir}|${crew.length}`;
    // Asked again when the key changes, and otherwise every REPOS_EVERY_MS (the manifest can change with the key the same).
    const now = Date.now();
    if (key === this.reposKey && this.reposAt && now - this.reposAt < REPOS_EVERY_MS) { this.wakeIn(this.reposAt + REPOS_EVERY_MS - now); return; }
    this.reposKey = key;
    this.reposAt = now;
    this.wakeIn(REPOS_EVERY_MS);
    const c = reposCall({ cwd: dir }, (props() || {}).loh);
    // The continuation runs in cx.spawn with its own cx: the one this method got is dead by then.
    cx.spawn(async (cx) => {
      let r = null;
      try { r = await exec(c.cmd, c.args, c.options); } catch (_) { return; }
      if (r.code !== 0) return;
      const next = repoNames(r.stdout);
      if (next.join("\n") !== this.repos.join("\n")) { this.repos = next; cx.notify(); }
      // The workspace's settings: a failure keeps the last value (loh older than the setting has no such option).
      const s = settingsCall({ cwd: dir }, (props() || {}).loh);
      let sr = null;
      try { sr = await exec(s.cmd, s.args, s.options); } catch (_) { return; }
      if (sr.code !== 0) return;
      const minutes = idleMinutesOf(sr.stdout);
      if (minutes !== this.idleMinutes) { this.idleMinutes = minutes; cx.notify(); }
      // The crew's names (`loh crew --json`): a failure or an older loh keeps the last names, and nothing else here waits on it.
      const n = crewCall({ cwd: dir }, (props() || {}).loh);
      let nr = null;
      try { nr = await exec(n.cmd, n.args, n.options); } catch (_) { return; }
      if (nr.code !== 0) return;
      const names = namesOf(nr.stdout);
      if (names && JSON.stringify(names) !== JSON.stringify(this.names)) { this.names = names; cx.notify(); }
      // Where the chat's reactions are kept (`loh react --dir`): an older loh has no such command and keeps the last folder.
      const d = reactDirCall({ cwd: dir }, (props() || {}).loh);
      let dr = null;
      try { dr = await exec(d.cmd, d.args, d.options); } catch (_) { return; }
      const where = dr.code === 0 ? reactDirOf(dr.stdout) : "";
      if (where && where !== this.reactDir) { this.reactDir = where; cx.notify(); }
    });
  }

  // Waiting coders' pull requests: every PRS_EVERY_MS, `loh status --prs` asks GitHub about each coder with a pr label and
  // clears the label of one that merged or closed, whoever did it. A coder with no pr label costs nothing; a failure is
  // tried again at the next time.
  checkPrs(crew, cx) {
    if (!crew.some((a) => a.pr)) { this.prsAt = 0; return; }
    const now = Date.now();
    if (this.prsAt && now - this.prsAt < PRS_EVERY_MS) { this.wakeIn(this.prsAt + PRS_EVERY_MS - now); return; }
    this.prsAt = now;
    this.wakeIn(PRS_EVERY_MS);
    const dir = this.workspaceDir(crew);
    if (!dir) return;
    const c = prsCall({ cwd: dir }, (props() || {}).loh);
    cx.spawn(async (cx) => {
      try { await exec(c.cmd, c.args, c.options); } catch (_) { /* tried again next time */ }
    });
  }

  // Matt typed in the office's message box: his hands type for TYPING_HOLD from now, and he stays at his desk for
  // MATT_SEAT_HOLD. The render that finds him still there after that sends him away (see wakeIn).
  typed(cx) {
    const was = mattTypingAt(Date.now(), this.mattLast);
    this.mattLast = Date.now();
    // A key while his hands already type changes nothing on screen: render only when they start.
    if (cx && !was) cx.notify();
  }

  // Render again in `ms`, once: the earliest wish wins. Time alone changes things (an idle time ends, a wait for a review
  // ends, Matt stops typing), and herdr renders only when something changes.
  // The random source for the wandering: Math.random, or the numbers the `seed` prop fixes (so a run can be repeated).
  random() {
    const seed = (props() || {}).seed;
    if (typeof seed !== "number" || !Number.isFinite(seed)) return Math.random;
    if (!this.seeded || this.seeded.seed !== seed) this.seeded = { seed, rand: seededRand(seed) };
    return this.seeded.rand;
  }

  wakeIn(ms) {
    const at = Date.now() + ms;
    if (this.wake && this.wake.at <= at) return;
    if (this.wake) { try { this.wake.task.cancel(); } catch (_) { /* already fired */ } }
    const w = { at, task: null };
    w.task = this.acx.timer.after(ms + 5, (c) => {
      if (this.wake === w) this.wake = null;
      try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
    });
    this.wake = w;
  }

  // The addresses of the agents whose terminal Matt has open from the office: the docked chat and a full-terminal window.
  openTerminals() {
    const out = this.chat ? [this.chat.address] : [];
    for (const [address, ids] of Object.entries(holders())) if (Array.isArray(ids) && ids.some((i) => String(i).startsWith(`term-${MOD}:`))) out.push(address);
    return out;
  }

  // Run loh lock / unlock in the agent's own folder. It exits non-zero when loh or the command
  // is missing or no workspace is found: say so instead of failing silently.
  runLoh(c, a, what) {
    return lohRun(c, a, what);
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
      unhold(this.chat.agent, loh, `chat-${this.chat.office}`);
      this.chat = { ...this.chat, address: a.address, name: a.name, agent: a };
    } else {
      const mine = officePane(panes(), props(), MOD);
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
    hold(a, loh, `chat-${this.chat.office}`);
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
    unhold(c.agent, (props() || {}).loh, `chat-${c.office}`);
    if (cx) cx.notify();
  }

  // Full-screen mode: zoom the office pane (hiding the chat split), hide herdr's chrome that is
  // showing, and take the window full screen unless it is. The plan records what was done, so Esc
  // (or the same button) undoes exactly that: a bar that was hidden before stays hidden.
  enterFullscreen(view, cx) {
    if (this.fs) return;
    const all = panes();
    // A plan is already saved: never write over it, it is the only record of what was hidden.
    let saved = null;
    try { saved = shared(FS_KEY); } catch (_) { /* none */ }
    const entry = entryFor(saved, all.map((p) => p.pane), view.mine, all.filter((p) => p.mod === MOD).map((p) => p.pane));
    if (entry === "adopt") { this.fs = saved; this.handle.focus(); if (cx) cx.notify(); return; }
    if (entry === "blocked") { notify({ title: "Full screen is already on", body: "An office is in full screen. Click this office to take it back, or close the other office pane.", level: "warning" }); return; }
    if (entry === "restore") { notify({ title: "Putting the bars back", body: "An earlier full screen was left on. Press Full screen again once they are back.", level: "info" }); this.recover(saved); return; }
    const me = all.find((p) => p.pane === view.mine);
    const plan = fullscreenPlan(layout(), {
      fullscreen: !!(appWindow() || {}).fullscreen,
      zoomed: view.zoomed,
      siblings: !!me && all.some((p) => p.tab === me.tab && p.pane !== me.pane),
    });
    this.fs = { plan, pane: view.mine };
    try { setShared(FS_KEY, this.fs); } catch (_) { /* the reload recovery is best effort */ }
    const step = (fn) => { try { fn(); } catch (_) { /* carry on: the rest should still apply */ } };
    if (plan.zoom && view.mine) step(() => run("pane.zoom", { pane: view.mine }));
    for (const id of plan.hide) step(() => run("layout.hide", { id }));
    if (plan.window) step(() => window.toggle_fullscreen());
    this.handle.focus();
    if (cx) cx.notify();
  }

  // Undo a plan, last step first. Each step first checks that it still has something to undo, so
  // one the person already took back by hand (F11, Ctrl+Shift+B) is left alone: a node is shown
  // only if it is still hidden, the window leaves full screen only if the plan turned it on.
  undo(plan, pane) {
    const step = (fn) => { try { fn(); } catch (_) { /* carry on */ } };
    for (const s of restoreSteps(plan)) {
      if (s.window) step(() => { if ((appWindow() || {}).fullscreen) window.toggle_fullscreen(); });
      else if (s.show) step(() => { const n = findNodeById(layout(), s.show); if (n && n.hidden) run("layout.show", { id: s.show }); });
      else if (s.zoom && pane) step(() => { if ((panes().find((p) => p.pane === pane) || {}).zoomed) run("pane.zoom", { pane }); });
    }
  }

  // The same undo, through `herdr-app do` with exec: on app quit only exec goes out, other commands
  // may be dropped. Resolves true only when every step that was needed succeeded. The window's full
  // screen has no command, so it is a best-effort toggle that does not count.
  async undoByExec(plan, pane) {
    let ok = true;
    for (const s of restoreSteps(plan)) {
      try {
        if (s.window) { if ((appWindow() || {}).fullscreen) window.toggle_fullscreen(); continue; }
        if (s.show) { const n = findNodeById(layout(), s.show); if (!(n && n.hidden)) continue; }
        if (s.zoom) { if (!((panes().find((p) => p.pane === pane) || {}).zoomed)) continue; }
        const args = doArgs(s, pane);
        if (!args) continue;
        const r = await exec("herdr-app", args, { timeout: 5000 });
        if (r.code !== 0) ok = false;
      } catch (_) { ok = false; }
    }
    return ok;
  }

  // Full screen that an earlier copy left on. Its own pane (a reload): carry on with it. A pane that
  // is gone (a crash, a restart): put the chrome back. Another live pane's: never touch it.
  recoverFs() {
    try {
      const left = shared(FS_KEY);
      const now = panes();
      const offices = now.filter((p) => p.mod === MOD).map((p) => p.pane);
      const what = recoveryFor(left, now.map((p) => p.pane), officePane(now, props(), MOD), offices);
      if (what === "adopt") this.fs = left;
      else if (what === "undo") this.recover(left);
    } catch (_) { /* nothing to recover */ }
  }

  // Put back what a plan left undone, and forget the plan only once that worked: otherwise it stays
  // saved and the next start tries again.
  recover(saved) {
    this.undoByExec(saved.plan, saved.pane).then((ok) => { if (ok) setShared(FS_KEY, null); }).catch(() => {});
  }

  leaveFullscreen(cx) {
    const f = this.fs;
    if (!f) return;
    this.fs = null;
    this.undo(f.plan, f.pane);
    try { setShared(FS_KEY, null); } catch (_) { /* nothing to clear */ }
    this.handle.focus();
    if (cx) cx.notify();
  }

  // herdr calls this when the office is closed or reloaded, and on app quit (where only exec is
  // sure to go out). The chrome is put back with exec; the saved plan is cleared only when that
  // worked, so a quit that dropped it is finished by the next office to start.
  async close(_cx) {
    if (this.termBar) {
      // The full-terminal window is going (Back, the terminal ending, a layout switch): release the lock its opening set.
      const p = props() || {};
      if (p.termId) bars.delete(p.termId);
      if (p.agent && p.agent.address && p.termId) { try { await unhold(p.agent, p.loh, p.termId); } catch (_) { /* nothing to undo */ } }
      return;
    }
    FLOORS.delete(this.floorId);
    const f = this.fs;
    if (!f) return;
    this.fs = null;
    if (await this.undoByExec(f.plan, f.pane)) { try { setShared(FS_KEY, null); } catch (_) { /* nothing to clear */ } }
  }

  // The floor is the same for as long as the plan is, but drawn as paths it was painted again on every animated frame
  // (about a third of a frame's time). Its SVG goes once into a folder of its own in herdr's folder, named by the plan and
  // the picture's size; image() then loads it and the renderer keeps it. herdr rasterises an image at its own size, so the
  // picture is written at a whole number of pixels a world unit, 2 to 6 and about one and a half times the scale (a bigger one costs memory by the square), and a new size means a new file;
  // until that one is there the last one for the plan stays. Returns the path image() takes when there is a file, else
  // null (the floor view draws). Each copy of the mod (MOD) has a folder of its own, so a copy under test never deletes the picture another is using; at most FLOOR_FILES pictures stay in it.
  floorPicture(key, layer, L, k) {
    const per = Math.min(6, Math.max(2, Math.ceil(1.5 * k)));
    const id = `${key}|${per}`;
    let p = this.pics.get(id);
    if (!p) {
      const dir = `${appHome()}/${FLOOR_DIR}/${MOD}`;
      const name = floorSvgName(key, per);
      p = { key, rel: imagePath(appHome(), `${dir}/${name}`), name, ready: false };
      this.pics.set(id, p);
      // Built and written in a task of its own, not in this render: building the text of a big floor takes a while.
      this.acx.timer.after(1, (c) => {
        fs.mkdir(dir, { recursive: true })
          .then(() => fs.writeFile(`${dir}/${name}`, floorSvg(layer, L.W, L.H, per)))
          .then(() => { p.ready = true; try { c.notify(); } catch (_) { /* the view was reloaded or closed */ } })
          .then(() => fs.readdir(dir))
          .then((names) => {
            const mine = new Set([...this.pics.values()].map((q) => q.name));
            const stale = names.filter((f) => /^crew-office-floor-[0-9a-f]{8}\.svg$/.test(f) && !mine.has(f));
            const over = names.filter((f) => /^crew-office-floor-[0-9a-f]{8}\.svg$/.test(f)).length - FLOOR_FILES;
            return Promise.all(stale.slice(0, Math.max(0, over)).map((f) => fs.unlink(`${dir}/${f}`).catch(() => {})));
          })
          .catch(() => { /* no file: the floor view keeps drawing it */ });
      });
    }
    if (p.ready) return p.rel;
    const same = [...this.pics.values()].filter((q) => q.key === key && q.ready).pop();
    return same ? same.rel : null;
  }

  // Where each person is drawn this render. A person whose place changed walks there door to door:
  // crew.js gives the legs, and this render hands the whole walk to the renderer at once as a chain of
  // movers (draw.js's mover), each leg a native transition that starts when the one before ends. The
  // render describes the same chain for as long as the walk lasts, so a render for any other reason
  // leaves the walk alone and nothing depends on a timer arriving on time. One-shot timers do two
  // small things: turn the walker to face the next leg, and end the gait when the walk is over.
  // `snap` (a new scale or floor) puts everyone in place. Someone whose place changed in that same render (an
  // agent whose chat closed as it ended) is put where they stood instead, carried onto the new floor with their
  // room (snapStay), drawn at rest, and walks to the new place from the next render, as anyone else does.
  // Each person is { at, goal, from, legs, t0, i, tasks }: `at` is where they stand when not walking;
  // while walking they go from `from` along `legs`, which began at `t0` (ms), and `i` is the leg they face.
  motion(L, snap) {
    const out = new Map();
    const here = new Set();
    const now = Date.now();
    for (const p of L.people) {
      here.add(p.id);
      const goal = { x: p.x, y: p.y };
      let w = this.walks.get(p.id);
      if (!w) { w = { at: goal, goal, from: goal, legs: [], t0: 0, i: 0, tasks: [], gen: 0 }; this.walks.set(p.id, w); }
      if (snap) {
        const stay = snapStay(w, goal, now, this.motionL, L);
        this.stopWalk(w); w.gen++; w.pending = null; w.settling = false; w.resting = false; w.arming = null; w.legs = []; w.i = 0;
        if (stay) {
          // Drawn at rest where they stand; the walk is handed over only once this frame was drawn to its end (#88).
          w.at = stay; w.from = stay; w.goal = stay;
          w.resting = true; w.restDrawn = false; this.restSeen.add(w);
          w.tasks.push(this.acx.timer.after(SETTLE_MS, (c) => { try { c.notify(); } catch (_) { /* the view was reloaded or closed */ } }));
        } else { w.at = goal; w.goal = goal; w.from = goal; }
      }
      else if (w.settling) this.settle(w);
      else this.holdOrGo(w, p, L, goal, now);
      if (w.arming) {
        // The arm frame: the walk's transition policies on movers still at zero, drawn before any offset changes.
        const a = w.arming;
        const c = walkChain(a.from, a.legs, SLOTS);
        c.links = c.links.map((l) => ({ ...l, dx: 0, dy: 0 }));
        out.set(p.id, { rest: false, walking: true, from: a.from, chain: { ...c, gen: w.gen }, x: a.from.x, y: a.from.y, face: a.legs[0].face });
        continue;
      }
      const walking = w.legs.length > 0;
      const pos = walking ? posAt(w.from, w.legs, now - w.t0) : w.at;
      const face = walking ? w.legs[Math.min(w.i, w.legs.length - 1)].face : p.face;
      out.set(p.id, { rest: restAt(w.at, goal, walking), walking, from: walking ? w.from : w.at, chain: { ...walkChain(walking ? w.from : w.at, walking ? w.legs : [], SLOTS), gen: w.gen }, x: pos.x, y: pos.y, face });
    }
    for (const id of [...this.walks.keys()]) if (!here.has(id)) { this.stopWalk(this.walks.get(id)); this.walks.delete(id); }
    this.motionL = L; // the floor the walk records are on, for the next snap
    return out;
  }

  stopWalk(w) {
    for (const t of w.tasks) { try { t.cancel(); } catch (_) { /* already done */ } }
    w.tasks = [];
  }

  // The render after a walk ends draws the person at rest, with every mover put back to zero, and asks for one
  // more render a moment on: a walk is never handed over in the render that ends the one before it. The movers
  // of the walk that ended still hold its offsets, and a new walk's offsets with their delays would be drawn
  // from there, a whole walk away, each leg sliding the wrong way in a leg's time.
  settle(w) {
    w.settling = false;
    // The rest frame counts as drawn only once a render that drew it has run to its end (render() marks it): see holdOrGo.
    w.resting = true; w.restDrawn = false;
    this.restSeen.add(w);
    w.tasks.push(this.acx.timer.after(SETTLE_MS, (c) => {
      try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
    }));
  }

  // A new place for someone is acted on only once it has held for a moment, and never while they walk
  // (crew.js nextGoal). A state that flips back within seconds moves nobody. A walk already handed to the
  // renderer is never redirected, so nobody is routed from a point in mid-air and no running mover is
  // retargeted. When the walk ends, the next render sees the new place and walks there from where they stand.
  // The next walk is handed over only after a render that drew the rest frame ran to its end. A render that herdr cuts off at its
  // deadline has run motion() but drawn nothing, and a walk handed over after it would be drawn from the old offsets.
  holdOrGo(w, p, L, goal, now) {
    if (w.arming) {
      // A walk's policies (durations, delays) and its offsets are never changed in one render: a mover whose
      // policy changes with its value is drawn at the new value for a frame. The walk is armed first, with
      // its policies at zero offsets, and starts in the render after that one was drawn to its end.
      this.restSeen.add(w);
      if (!w.restDrawn) {
        if (!w.wake) {
          w.wake = this.acx.timer.after(SETTLE_MS + 5, (c) => {
            w.wake = null;
            try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
          });
        }
        return;
      }
      const a = w.arming;
      w.arming = null;
      this.beginWalk(w, a.from, a.legs);
      return;
    }
    if (w.resting) {
      this.restSeen.add(w);
      if (!w.restDrawn) {
        if (!w.wake) {
          w.wake = this.acx.timer.after(SETTLE_MS + 5, (c) => {
            w.wake = null;
            try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
          });
        }
        return;
      }
      w.resting = false;
    }
    const d = nextGoal(w.pending, w.goal, goal, now, w.legs.length > 0);
    w.pending = d.pending;
    if (d.wakeIn !== null && !w.wake) {
      w.wake = this.acx.timer.after(d.wakeIn + 5, (c) => {
        w.wake = null;
        try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
      });
    }
    if (d.go) this.planWalk(w, p, L, goal);
  }

  planWalk(w, p, L, goal) {
    const start = w.at;
    this.stopWalk(w);
    w.goal = goal;
    const legs = legsOf(start, pathTo(L, p.id, start, goal), p.id === "dog" ? WALK_SPEED * 1.5 : WALK_SPEED);
    if (!legs.length) { w.at = goal; w.legs = []; w.i = 0; return; }
    w.arming = { from: start, legs }; w.restDrawn = false;
    this.restSeen.add(w);
    w.tasks.push(this.acx.timer.after(SETTLE_MS, (c) => {
      try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
    }));
  }

  beginWalk(w, from, legs) {
    const goal = w.goal;
    w.from = from; w.legs = legs; w.t0 = Date.now(); w.i = 0;
    let at = 0;
    legs.forEach((leg, i) => {
      at += leg.ms;
      // At each corner, turn to face the next leg; after the last, stop the gait.
      const last = i === legs.length - 1;
      w.tasks.push(this.acx.timer.after(last ? at + ARRIVE_SLACK : at, (c) => {
        if (w.legs !== legs) return;
        if (last) { w.at = goal; w.legs = []; w.i = 0; w.settling = true; w.gen++; } else w.i = i + 1;
        try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
      }));
    });
  }

  // A click on someone who is not running: say what would start them, and ask first.
  offerStart(p, cx) {
    const plan = startPlan(p, this.repos, this.workspaceDir(this.crewNow), this.names);
    this.offer = { person: p, plan, repo: plan.kind === "spawn" ? (plan.repos[0] || "") : "", ticket: "" };
    this.handle.focus();
    cx.notify();
  }

  // The folder loh runs in to find the workspace: the `dir` prop, else the coordinator's folder or
  // any running agent's, else a pane in the office's own tab. Empty when none has one.
  workspaceDir(crew) {
    return workspaceDir(crew, props(), panes(), officePane(panes(), props(), MOD));
  }

  // Tell loh an office is open, now and every OFFICE_PING_MS (a render is asked for then, as for the repo list): while it
  // hears, `loh watch` sends no desktop notice, because the toast says it. It runs in an agent's folder, which is how loh finds the workspace.
  pingLoh(crew, now, cx) {
    if (this.pingAt && now - this.pingAt < OFFICE_PING_MS) { this.wakeIn(this.pingAt + OFFICE_PING_MS - now); return; }
    const dir = this.workspaceDir(crew);
    // With no folder to find the workspace from there is nothing to run in; the next render for any reason looks again.
    if (!dir) return;
    this.pingAt = now;
    this.chimeDir = dir;
    const seq = this.chimeSeq;
    this.wakeIn(OFFICE_PING_MS);
    if (this.lightsSeenDir !== dir) {
      this.lightsSeenDir = dir;
      this.lightsSeen = "";
      try { this.lightsSeen = String(shared(lightsSeenKey(dir)) || ""); } catch (_) { /* none saved */ }
    }
    // The ping says what the office shows, and its answer carries the choice of `loh office lights on|off`; one not seen
    // yet is applied as the button would. The continuation runs in cx.spawn with its own cx: the render's is dead by then.
    const c = pingCall({ cwd: dir }, (props() || {}).loh, this.lights);
    cx.spawn(async (cx) => {
      let r = null;
      try { r = await exec(c.cmd, c.args, c.options); } catch (_) { return; } // loh is missing: the desktop notices stay on
      const chime = r && r.code === 0 ? chimeSignal(r.stdout) : null;
      if (chime !== null && chime !== this.chime && seq === this.chimeSeq) { this.chime = chime; cx.notify(); }
      const sig = r && r.code === 0 ? lightsSignal(r.stdout, this.lightsSeen) : null;
      if (!sig) return;
      this.lightsSeen = sig.stamp;
      try { setShared(lightsSeenKey(dir), sig.stamp); } catch (_) { /* only remembered */ }
      this.setLights(sig.on, cx);
    });
  }

  // A toast was clicked: it goes, and that agent's chat opens as a click on the person opens it.
  clickToast(x, cx) {
    toastDismiss(this.toasts, x.id);
    const a = (this.crewNow || []).find((q) => q.address === x.who);
    if (a) this.pick({ agent: a, id: a.rawName }, cx);
    else cx.notify();
  }

  // The toasts, top right of the stage, newest first, as the prototype's `.toast` (crew-office.html): 280 wide, a 4px edge in the kind's
  // colour, 8px radius, padding 7px 10px, 12.5px text on a 1.35 line, a bold head, a 11.5px muted hint, 6px between, the prototype's
  // --toast-bg / --toast-ink / --toast-muted for the office lights (on: the light card, off: the dark one, whatever herdr's theme). Each is placed by its own top (the heights are measured, so a new toast
  // pushes the others down with a slide and not a jump), and slides and fades in and out (TOAST_SLIDE_MS): a mounted toast is first
  // drawn faded and 8px up, and the render one tick on draws it in place. The shadow is the nearest the renderer has (shadow_lg: it
  // takes no offset or blur of its own).
  toastEls(t, now, floorW) {
    const tok = this.lights ? TOAST_LIGHT : TOAST_DARK;
    const colour = { q: PAL.q, perm: PAL.perm, esc: PAL.esc, done: PAL.work, info: PAL.idle };
    const slide = { duration: TOAST_SLIDE_MS, easing: "ease-out" };
    const shown = [...this.toasts.list, ...this.toasts.leaving];
    for (const id of [...this.toastH.keys()]) if (!shown.some((x) => x.id === id)) this.toastH.delete(id);
    // min(280px, 100% - 24px) of the floor, as the prototype's `.toasts` (its stage is the floor).
    const w = Math.max(0, Math.min(TOAST_W, floorW - 24));
    let y = 0;
    const cards = shown.map((x) => {
      const here = y;
      y += (this.toastH.get(x.id) || TOAST_H) + TOAST_GAP;
      const live = toastPhase(x, now) === "show";
      return v_flex().id(x.id).absolute().left(0).top(here + (live ? 0 : -TOAST_RISE)).w(w).opacity(live ? 1 : 0)
        .transition("top", slide).transition("opacity", slide)
        .px(10).py(7).gap(1).rounded(8).bg(tok.bg).border_l(4).border_color(colour[x.kind] || PAL.idle).shadow_lg().font_family(TOAST_FONT)
        .cursor_pointer().on_click((_e, cx) => this.clickToast(x, cx))
        .on_size_change((m, c) => {
          if (Math.abs((this.toastH.get(x.id) || 0) - m.height) < 0.5) return;
          this.toastH.set(x.id, m.height);
          c.notify();
        })
        .child(div().text_size(12.5).line_height("16.875px").font_bold().text_color(tok.ink).child(x.head))
        .child(div().text_size(12.5).line_height("16.875px").text_color(tok.ink).child(x.body))
        .child(div().text_size(11.5).line_height("15.525px").text_color(tok.muted).child(x.hint));
    });
    return div().id("toasts").absolute().top(TOAST_TOP).right(12).w(w).children(cards);
  }

  confirmStart(cx) {
    const o = this.offer;
    if (!o) return;
    const dir = this.workspaceDir(this.crewNow);
    const call = startCall(o.plan, dir, (props() || {}).loh, { repo: o.repo, ticket: o.ticket });
    if (!call) return; // a coder still needs a repo and a ticket: keep the form open
    this.offer = null;
    if (!dir) notify({ title: "Could not start", body: "No folder to find the workspace from. Set the dir prop to a folder in the workspace.", level: "warning" });
    else {
      const started = this.runLoh(call, { name: o.plan.kind === "spawn" || o.plan.kind === "start" ? o.person.name : "the crew" }, "start");
      // A persona started from the office shows its chat once loh has started it, as a click on a
      // running agent does. No terminal split: that opens only from the panel's Terminal button.
      if (o.plan.kind === "start") started.then((ok) => { if (ok) this.openStarted(o.person.id); });
    }
    cx.notify();
  }

  // Select a persona that has just been started, once herdr lists its terminal, so its chat shows.
  // (The click's cx is dead by then, so the chat opens from a timer's own.)
  openStarted(id) {
    let a = null;
    try { a = crewOf(terminals(), pickWorkspace(terminals(), (props() || {}).crew)).find((x) => String(x.rawName || x.name || "").toLowerCase() === id); } catch (_) { /* no listing */ }
    if (a && this.acx) this.acx.timer.after(0, (c) => { try { this.panel.select(a, c); c.notify(); } catch (_) { /* the view was reloaded or closed */ } });
  }

  // Keys while a coder's form is open: digits make the ticket, Enter starts, Esc cancels.
  offerKey(e, cx) {
    // Only while the office itself has the keyboard: typing in the chat panel's input must never reach the form.
    if (!this.handle.is_focused()) return false;
    const o = this.offer;
    if (!o || o.plan.kind !== "spawn") return false;
    if (e.key === "escape") { this.offer = null; cx.notify(); return true; }
    if (e.key === "enter") { this.confirmStart(cx); return true; }
    if (e.key === "backspace") { o.ticket = o.ticket.slice(0, -1); cx.notify(); return true; }
    if (/^[0-9]$/.test(e.key) && o.ticket.length < 7) { o.ticket += e.key; cx.notify(); return true; }
    return false;
  }

  offerRow(t) {
    const o = this.offer;
    if (!o) return null;
    const button = (id, label, bg, fg, onClick) => h_flex().id(id).px(8).py(2).rounded(5).bg(bg).text_size(12).text_color(fg).cursor_pointer().hover((e) => e.opacity(0.85)).on_click(onClick).child(label);
    const cancel = button("offer-no", o.plan.kind === "up" || o.plan.kind === "start" || o.plan.kind === "spawn" ? "Cancel" : "Dismiss", t.raised, t.foreground, (_e, cx) => { this.offer = null; cx.notify(); });
    if (o.plan.kind === "spawn") {
      // Start <coder> on a repo from the manifest and a ticket number; nothing runs until Start.
      const ready = !!startCall(o.plan, "x", "loh", { repo: o.repo, ticket: o.ticket });
      const repos = o.plan.repos.map((r) => h_flex().id(`offer-repo-${r}`).px(8).py(2).rounded(5).text_size(12)
        .bg(o.repo === r ? t.solid : t.raised).text_color(o.repo === r ? t.solid_foreground : t.foreground).cursor_pointer()
        .on_click((_e, cx) => { o.repo = r; this.handle.focus(); cx.notify(); }).child(r));
      return h_flex().id("offer").px(12).py(6).gap(8).items_center().bg(t.chrome).border_b(1).border_color(t.border)
        .child(div().text_size(12).text_color(t.foreground).child(`Start ${o.person.name} (loh spawn) on`))
        .children(repos.length ? repos : [div().text_size(12).text_color(t.muted).child("no repos in the manifest")])
        .child(div().text_size(12).text_color(t.foreground).child("ticket #"))
        .child(h_flex().id("offer-ticket").px(8).py(2).rounded(5).border_1().border_color(t.border).min_w(60).text_size(12).text_color(t.foreground)
          .child(o.ticket === "" ? "number" : o.ticket).when(o.ticket === "", (el) => el.text_color(t.muted)))
        .child(div().flex_1())
        .child(button("offer-yes", "Start", ready ? t.solid : t.raised, ready ? t.solid_foreground : t.muted, (_e, cx) => this.confirmStart(cx)))
        .child(cancel);
    }
    const asks = o.plan.kind === "up" || o.plan.kind === "start";
    return h_flex().id("offer").px(12).py(6).gap(10).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .child(div().flex_1().text_size(12).text_color(t.foreground).child(asks ? o.plan.ask : `${o.plan.hint}.`))
      .when(asks, (el) => el.child(button("offer-yes", "Start", t.solid, t.solid_foreground, (_e, cx) => this.confirmStart(cx))))
      .child(cancel);
  }

  // What a click on a person does, from the figure or from the name tag: someone running opens their
  // chat panel (and moves the open chat to them), someone not running who can be started gets the offer.
  pick(p, cx) {
    this.typed(null); // a click is Matt at work, as in the prototype
    if (p.agent) { this.panel.select(p.agent, cx); if (this.chat) this.open(p.agent, cx); }
    else if (!p.running && p.id !== "matt" && p.id !== "dog") this.offerStart(p, cx);
  }

  // A person with no terminal, and Matt and Waffles: one line, a dot and the name. Someone who can be
  // started is a button. (left, top) is where its corner is, in px from the person.
  chip(p, left, top, slide) {
    const startable = !p.running && p.id !== "matt" && p.id !== "dog";
    const dot = p.id === "dog" ? PAL.dog : p.id === "matt" ? PAL.accent : PAL.idle;
    const el = h_flex().id(`tag-${p.id}`).absolute().left(left).top(top).h(17).px(6).gap(4).items_center().rounded_full().bg(PAL.chip)
      .when(!!slide, (e) => e.transition("left", slide).transition("top", slide))
      .child(div().w(7).h(7).rounded_full().bg(dot))
      .child(div().text_size(10.5).font_semibold().text_color(PAL.chipInk).whitespace_nowrap().child(p.name));
    return startable ? el.cursor_pointer().hover((e) => e.opacity(0.85)).on_click((_e, cx) => this.pick(p, cx)) : el;
  }

  // An agent's name tag, `w` wide, its corner (left, top) px from the person.
  tag(p, left, top, w, F, t, slide) {
    const a = p.agent;
    const color = a.status === "blocked" ? BLOCKED[a.kind][0] : a.status === "working" ? "#3fae69" : a.status === "done" ? "#3fae69" : t.muted;
    const ticket = a.repo ? `${a.repo}${a.ticket ? "#" + a.ticket : ""}` : "";
    const where = [ticket, a.pr ? `PR ${a.pr}` : "", a.round ? `r${a.round}` : ""].filter(Boolean).join(" · ");
    const step = a.step || a.note || WORDS[a.status];
    return v_flex().id(`tag-${a.address}`).absolute().left(left).top(top).w(w)
      .when(!!slide, (el) => el.transition("left", slide).transition("top", slide))
      .items_center().gap(1).px(4).py(2).rounded(5).bg(F.chip + "e6").cursor_pointer()
      .hover((e) => e.bg(F.chip))
      .on_click((_e, cx) => this.pick(p, cx))
      .child(div().text_size(11).font_semibold().text_color(F.chipInk).truncate().child(a.name))
      .when(where !== "", (el) => el.child(div().text_size(9.5).text_color(F.chipInk).truncate().child(where)))
      .child(div().text_size(9.5).text_color(color).truncate().child(step))
      .when(a.withMatt, (el) => el.child(div().px(4).rounded(4).bg(t.accent).text_size(9).font_semibold().text_color(t.accent_foreground).child(`with ${(this.names && this.names.person) || "owner"}`)));
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
      .child(button("lights", this.lights ? "Lights off" : "Lights on", (_e, cx) => this.setLights(!this.lights, cx)))
      .child(button("chime", this.chime ? "🔊 Chime on" : "🔇 Chime off", (_e, cx) => this.setChime(!this.chime, cx)))
      .child(button("fullscreen", this.fs ? "Exit full screen (Esc)" : "Full screen", (_e, cx) => (this.fs ? this.leaveFullscreen(cx) : this.enterFullscreen(view, cx))))
      .when(!!this.chat && !view.zoomed, (el) => el.child(button("close-chat", "Close chat", (_e, cx) => this.closeChat(cx))));
  }


  setLights(on, cx) {
    this.lights = !!on;
    try { setShared(LIGHTS_KEY, lightsValue(this.lights)); } catch (_) { /* the choice is only remembered, not needed */ }
    if (cx) cx.notify();
  }

  // The Chime button and C: run `loh chime on|off`, which keeps the setting; the next ping confirms what loh holds.
  setChime(on, cx) {
    this.chime = !!on;
    this.chimeSeq++;
    const c = chimeCall(this.chime, { cwd: this.chimeDir }, (props() || {}).loh);
    try { exec(c.cmd, c.args, c.options).catch(() => {}); } catch (_) { /* loh is missing: the next ping shows what it holds */ }
    if (cx) cx.notify();
  }

  // Ask for another render one tick on, once.
  keepBuilding() {
    if (this.moreBuilding) return;
    this.moreBuilding = true;
    this.acx.timer.after(1, (c) => {
      this.moreBuilding = false;
      try { c.notify(); } catch (_) { /* the view was reloaded or closed */ }
    });
  }

  render(cx) {
    if (this.termBar) return this.renderTermBar();
    const t = theme();
    const dark = !!settings().dark;
    const list = terminals();
    const workspace = pickWorkspace(list, (props() || {}).crew);
    const crew = crewOf(list, workspace);
    this.crewNow = crew;
    const wkey = panelWidthKey(workspace);
    if (wkey !== this.panelKey) {
      this.panelKey = wkey;
      let saved = null;
      try { saved = shared(wkey); } catch (_) { /* none */ }
      this.panelW = clampPanelW(saved, 1e9);
    }
    // A window whose bar never came up (it failed to open) or has gone keeps no hold.
    const w = this.termWin;
    if (w) {
      if (bars.has(w.id)) w.seen = true;
      else if (w.seen || Date.now() - w.at > TERM_GRACE) { this.termWin = null; unhold(w.agent, w.loh, w.id); }
    }
    this.termOpen = termHeld(holders(), undefined, MOD);
    this.loadRepos(crew, workspace, cx);
    this.checkPrs(crew, cx);
    this.panel.sync(crew, cx);
    const allPanes = panes();
    // The person closed the chat's split by hand: release the lock the click set.
    if (chatGone(allPanes, this.chat)) {
      const c = this.chat;
      this.chat = null;
      unhold(c.agent, (props() || {}).loh, `chat-${c.office}`);
    }
    // While a chat is open, keep using the office pane found when it opened: the click moves focus
    // to the chat, and officePane looks for the focused one.
    const mine = (this.chat && this.chat.office) || officePane(allPanes, props(), MOD);
    const view = { mine, zoomed: !!(allPanes.find((p) => p.pane === mine) || {}).zoomed };
    // Fit the floor to the stage in both directions. The scale may drop below 1 (the chat takes
    // part of the tab); the floor is centred only while it fits, so it never spills off the left.
    // The stage is measured beside the panel column, so the panel's width is already out of it, but
    // herdr reports it a layout late: the render that opens or closes the panel corrects for that.
    const showPanel = this.panel.open && !this.chat;
    const size = stageSize(this.size, this.sizeWithPanel, showPanel, this.panelW);
    this.drawnWithPanel = showPanel;
    const now = Date.now();
    // The toasts: what the crew's change calls for, and when the oldest goes. (Not while the crew is still unlisted, so the
    // first listing is only recorded, never announced.)
    if (crew.length) {
      const ts = toastStep(this.toasts, crew, now);
      this.burstsDue.push(...ts.bursts);
      const due = [ts.nextMs, ts.animMs].filter((x) => x !== null);
      if (due.length) this.wakeIn(Math.min(...due));
    }
    this.pingLoh(crew, now, cx);
    let focus = null;
    try { focus = focused(); } catch (_) { /* no focus information: only the message box counts */ }
    // Focus arriving on a terminal he opened from the office counts as Matt at work for TYPING_HOLD, like a key in the message
    // box; focus that stays there does not renew it (herdr shows no keys typed in a terminal).
    const here = focus && focus.terminal ? focus.terminal : null;
    if (focusArrived(here, this.lastFocus, this.openTerminals())) this.mattLast = now;
    this.lastFocus = here;
    const L = layoutCrew(crew, this.repos, aspectOf(size), {
      mem: this.mem, now, names: this.names, rand: this.random(),
      idleMs: pickIdleMs((props() || {}).idleMinutes, this.idleMinutes),
      mattSeated: mattSeatedAt(now, this.mattLast),
      mattTyping: mattTypingAt(now, this.mattLast),
    });
    this.layoutNow = L;
    // Time alone ends some things: ask for a render then. Matt's typing hold and his seat hold are two of them.
    const mattEnds = [TYPING_HOLD, MATT_SEAT_HOLD].map((h) => this.mattLast + h - now).filter((ms) => this.mattLast > 0 && ms > 0);
    const waits = [L.wakeIn, ...(mattEnds.length ? [Math.min(...mattEnds)] : [])].filter((x) => x !== null);
    if (waits.length) this.wakeIn(Math.min(...waits));
    const { k, fits } = fitScale(size, L);
    const stageColour = stageBg(dark);
    const F = { chip: PAL.chip, chipInk: PAL.chipInk };
    // Cold start: until the stage's real size is known nothing is sized from the floor, and then not until the first floor plan
    // is complete, so the floor, the people and the tags appear together.
    const waiting = () => div().text_size(12).text_color(t.muted).child("Setting up the office…");
    if (!this.measured) return this.frame(t, L, view, stageColour, true, waiting(), showPanel, F, cx);
    // Walk only when someone's place changed. A new scale (resize, the chat opening) or floor
    // width (the repo list arriving) moves every position at once, so draw those frames without
    // the transition and everything jumps with the rooms and desks.
    const sig = `${k}|${L.W}|${L.H}`;
    this.anim = sig === this.sig;
    this.sig = sig;
    const u = (n) => n * k;
    const mo = this.motion(L, !this.anim);
    // Confetti at the merger's desk: where they stand now (their walk to the rest room starts after this render). Gone for good
    // once its longest piece is: each piece is drawn until its own life ends, and a render is asked for at the next end. (herdr gives
    // no reduced-motion setting to the mods, so it is not honoured: a known gap, noted in the PR.)
    for (const d of this.burstsDue.splice(0)) {
      const who = L.people.find((p) => p.agent && p.agent.address === d.who);
      const m = who ? mo.get(who.id) : null;
      if (m) this.bursts.push({ id: `confetti-${++this.burstN}`, x: m.x, y: m.y - 6, at: now, pieces: confettiPieces(this.random()) });
    }
    this.bursts = this.bursts.filter((b) => b.pieces.some((p) => now - b.at < p.life));
    const alive = this.bursts.map((b) => ({ b, pieces: b.pieces.filter((p) => now - b.at < p.life) }));
    const ends = alive.flatMap(({ b, pieces }) => pieces.map((p) => b.at + p.life - now));
    if (ends.length) this.wakeIn(Math.min(...ends));

    // The floor does not change with the crew, only with the plan; a new scale only resizes it. Its
    // paths are built a little at a time, so no render runs past herdr's deadline building them.
    // A new plan takes a few renders (the drawing list, which shapes share a path, then the paths).
    // Until it is finished the last finished floor stays on screen, stretched to the new box (its
    // paths are percentages). The two most recent finished plans (the panel open and closed) are
    // never pushed out of the cache by a drag through other shapes.
    const key = floorKey(L);
    if (!this.floor || this.floor.key !== key) {
      this.floor = this.floors.get(key) || { key, layer: null };
      this.floors.delete(key);
      this.floors.set(key, this.floor);
      while (this.floors.size > 4) {
        const old = [...this.floors.keys()].find((x) => x !== key && !this.pinned.includes(x));
        if (old === undefined) break;
        this.floors.delete(old);
      }
    }
    // (A first render after a reload also has the whole crew to draw, so with no floor yet the drawing list waits for the second.)
    if (!this.floor.layer && (this.shown || this.floor.waited)) this.floor.layer = floorLayer(L, k, () => MOD);
    this.floor.waited = true;
    let building = true;
    if (this.floor.layer) {
      const layer = this.floor.layer.at(k);
      if (!layer.done) layer.build(BUILD_MS);
      building = !layer.done;
      if (layer.done) { this.shown = this.floor; this.pinned = [key, ...this.pinned.filter((x) => x !== key)].slice(0, 2); }
    }
    if (!this.shown) { this.keepBuilding(); return this.frame(t, L, view, stageColour, true, waiting(), showPanel, F, cx); }
    // The floor view draws the last finished floor (stretched over a new plan's box until that is finished, as its
    // paths are percentages). A plan that finished since it last drew is handed over, and the view is asked, one tick on,
    // to render once more. The view's first render, when it is first mounted, draws what is handed over by then.
    const handed = FLOORS.get(this.floorId);
    // (A rounded div's radius is in pixels, so a new scale asks the view to render again.)
    handed.layer = this.shown.layer.at(k);
    if (handed.drawn && (handed.drawn !== handed.layer || handed.drawnK !== k) && !this.floorAsked) {
      this.floorAsked = true;
      this.acx.timer.after(1, (c) => {
        this.floorAsked = false;
        try { c.notify(this.floorView); } catch (_) { /* the view was reloaded or closed */ }
      });
    }

    // Screens: a lit strip on each desk, and Matt's two monitors.
    const lit = [];
    const screens = [];
    const rest = {};
    for (const [id, m] of mo) rest[id] = m.rest;
    const seen = screensSeen(L, rest);
    this.screensNow = seen;
    for (const d of L.desks) {
      const s = seen[d.key];
      if (s) { screens.push([d, s]); if (s !== "dim") lit.push([d, s]); }
    }
    for (const dx of [-9, 9]) {
      const d = { cx: L.mattDesk.cx + dx, y: L.mattDesk.y, h: L.mattDesk.h, side: "s" };
      screens.push([d, seen.matt]); if (seen.matt !== "dim") lit.push([d, seen.matt]);
    }
    const glows = screens.flatMap(([d, s]) => glow(d, s, k));
    // The desk of someone Matt is talking to gets an accent strip.
    const plaque = new Layer(k, 0, 0, L.W, L.H);
    for (const p of L.people) {
      const d = p.agent && p.agent.withMatt && p.desk ? L.desks.find((q) => q.key === p.desk) : null;
      if (d) plaque.rr(d.x + 2, d.side === "n" ? d.y + 1 : d.y + d.h - 3, d.w - 4, 2, 1, PAL.accent);
    }

    // People, back to front. A chain of movers carries each across the floor (see motion()); the
    // drawing inside is draw.js's, and a click on the figure does what a click on its tag does.
    // What the kitchen and the table put on someone follows where they stand (standLook), so the room they are leaving
    // does not change before they set off.
    const looks = new Map(L.people.map((p) => [p.id, standLook(this.looks.get(p.id), p, mo.get(p.id).rest)]));
    this.looks = looks;
    const rally = rallyOf(L.people.map((p) => ({ look: looks.get(p.id), walking: mo.get(p.id).walking })));
    // People, back to front: sorted by y each render.
    const order = [...L.people].sort((a, b) => mo.get(a.id).y - mo.get(b.id).y);
    // `officeLog` in the tab's props: one line per render with the figure order and each person's place and spot.
    if ((props() || {}).officeLog) {
      try { console.error("office render " + JSON.stringify({ order: order.map((p) => p.id), at: order.map((p) => [p.id, p.place, p.spot === undefined ? null : p.spot, Math.round(mo.get(p.id).x), Math.round(mo.get(p.id).y), mo.get(p.id).walking ? 1 : 0]) })); } catch (_) { /* logging only */ }
    }
    const figures = order.map((p) => {
      const m = mo.get(p.id);
      const look = looks.get(p.id);
      const kids = p.id === "dog" ? dogEls(p, k, m.walking, m.face) : personEls({ ...p, mug: look.mug, paddle: look.paddle }, k, m.face, m.walking, L, m.rest);
      const clickable = !!p.agent || (!p.running && p.id !== "matt" && p.id !== "dog");
      return mover("m-" + p.id, m.from, m.chain, k, m.walking, figureBox(p.id, k, kids));
    });
    // The click targets are their own layer, above the night layers (drawn on top of everything else but the labels and tags).
    const hits = L.people.filter((p) => !!p.agent || (!p.running && p.id !== "matt" && p.id !== "dog")).map((p) => {
      const m = mo.get(p.id);
      return mover("hm-" + p.id, m.from, m.chain, k, m.walking, hitBox(p.id, k, (_e, c) => this.pick(p, c)));
    });

    // Name tags. Someone at rest has a tag where it clears the others (stacked, and kept on the floor);
    // someone walking has theirs just below them, carried by the same chain as the figure, so it stays
    // with them and never trails or jumps.
    const sized = L.people.map((p) => {
      const a = p.agent;
      const where = a ? [a.repo, a.pr, a.round].some(Boolean) : false;
      const w = a ? Math.min(100, Math.max(64, 100 * k)) : (p.name.length + (p.running || p.id === "matt" || p.id === "dog" ? 0 : 9)) * 6.4 + 26;
      const h = a ? 4 + 13 + 11 + (where ? 11 : 0) + (a.withMatt ? 13 : 0) : 17;
      const m = mo.get(p.id);
      const left = Math.min(Math.max(2, u(m.x) - w / 2), Math.max(2, u(L.W) - w - 2));
      const up = p.tag.up && !m.walking;
      return { id: p.id, p, w, h, m, up, x: left, y: up ? u(m.y - 10) - h : u(m.y + 9) };
    });
    const tops = stackTags(sized.filter((s) => !s.m.walking));
    const tags = sized.map((s) => {
      // Where the tag's corner is from the person, in px.
      const off = s.m.walking ? { x: -s.w / 2, y: u(9) } : { x: s.x - u(s.m.x), y: Math.max(u(2), tops.get(s.id)) - u(s.m.y) };
      const slide = this.anim ? TAG_SLIDE : { duration: 1 };
      const body = s.p.agent ? this.tag(s.p, off.x, off.y, s.w, F, t, slide) : this.chip(s.p, off.x, off.y, slide);
      return mover("tm-" + s.id, s.m.from, s.m.chain, k, s.m.walking, body);
    });
    // The night layers are built once for a set of lit screens, a little at a time like the floor. A
    // change in the lit screens (an agent changing state) keeps the last finished night on screen until the new one is built.
    let nightEls = [];
    if (!this.lights) {
      const nkey = `${key}|${lit.map(([d, s]) => `${d.cx},${d.y},${s}`).join(";")}`;
      if (!this.night || this.night.key !== nkey) this.night = { key: nkey, layers: nightLayers(L, lit) };
      let budget = BUILD_MS;
      for (const layer of this.night.layers) {
        const t0 = Date.now();
        layer.at(k).build(Math.max(0, budget));
        budget -= Date.now() - t0;
      }
      const ready = this.night.layers.every((layer) => layer.done);
      if (ready) this.nightLast = this.night.layers;
      else building = true;
      const use = ready ? this.night.layers : this.nightLast || this.night.layers;
      nightEls = use.map((layer) => layer.at(k).el(ready || use === this.nightLast ? undefined : 0)).concat(lit.flatMap(([d, s]) => glow(d, s, k)));
    }
    // A layer still being built carries on in the next render, one tick on.
    if (building) this.keepBuilding();

    // One box for the whole floor: the floor view, the people, the click targets and the tags are all placed in it at k.
    // The view sits in a box of that same size (not in one that takes its size from its content or the stage).
    // The finished floor as a picture, once its file is there; until then (or if the file cannot be written) the floor view draws it.
    const pic = this.floorPicture(this.shown.key, this.shown.layer, L, k);
    const floorBox = div().id("floor-box").absolute().left(0).top(0).w(u(L.W)).h(u(L.H))
      .child(pic ? image(pic).absolute().left(0).top(0).w(u(L.W)).h(u(L.H)) : this.floorView);
    const floor = div().id("floor").relative().flex_none().w(u(L.W)).h(u(L.H)).rounded(6).bg(PAL.wall)
      .child(floorBox).children(glows).child(plaque.el())
      .children(ball(L, k, rally)).children(figures).children(alive.flatMap(({ b, pieces }) => confettiEls(b, pieces, k))).children(nightEls).children(hits)
      // Room labels, repo chips and the wall screen's text stay bright at night, so they come after it.
      .children(labels(L, k, crew.length)).children(tags)
      // The toasts are in the floor's box, as the prototype's are in its stage: after everything, so they are on top.
      .when(this.toasts.list.length + this.toasts.leaving.length > 0, (el) => el.child(this.toastEls(t, Date.now(), u(L.W))));

    const out = this.frame(t, L, view, stageColour, fits, floor, showPanel, F, cx);
    for (const w of this.restSeen) w.restDrawn = true;
    this.restSeen.clear();
    return out;
  }

  // The bar, the stage and the panel. The stage is where the floor is scaled to: the area left under
  // the bar and the offer row, measured there, so nothing is subtracted by guess. Anything that still
  // spills (for one frame, while a size is on its way) is cut at the stage, so it is never drawn under
  // the panel. It reports its size even while it only shows the waiting line.
  frame(t, L, view, stageColour, fits, child, showPanel, F, cx) {
    const stage = h_flex().id("stage").size_full().min_w(0).p(PAD).bg(stageColour).overflow_hidden().when(fits, (el) => el.justify_center().items_center())
      .on_size_change((measured, c) => {
        this.sizeWithPanel = this.drawnWithPanel;
        const first = !this.measured;
        this.measured = true;
        if (first || measured.width !== this.size.width || measured.height !== this.size.height) { this.size = measured; c.notify(); }
      })
      .child(child);

    return v_flex().id("root").size_full().bg(stageColour).track_focus(this.handle)
      .on_key_down((e, cx) => {
        if (this.termOpen) return;
        if (this.offerKey(e, cx)) { cx.stop_propagation(); return; }
        if ((e.key === "l" || e.key === "L") && !e.modifiers?.control && !e.modifiers?.alt && !e.modifiers?.platform && this.handle.is_focused()) { this.setLights(!this.lights, cx); cx.stop_propagation(); return; }
        if ((e.key === "c" || e.key === "C") && !e.modifiers?.control && !e.modifiers?.alt && !e.modifiers?.platform && this.handle.is_focused()) { this.setChime(!this.chime, cx); cx.stop_propagation(); return; }
        if (e.key === "escape" && this.fs) { this.leaveFullscreen(cx); cx.stop_propagation(); }
        else if (e.key === "escape" && view.zoomed && view.mine) { run("pane.zoom", { pane: view.mine }); cx.stop_propagation(); }
        else if (e.key === "escape" && this.chat) { this.closeChat(cx); cx.stop_propagation(); }
        else if (e.key === "escape" && this.panel.open) { this.panel.close(cx); cx.stop_propagation(); }
      })
      .child(this.bar(t, L.totals, view))
      .when(!!this.offer, (el) => el.child(this.offerRow(t)))
      .child(showPanel ? this.split(stage, t, F, cx, view.mine) : h_flex().flex_1().min_h(0).child(div().flex_1().min_w(0).h_full().child(stage)));
  }

  // The stage and the panel, with a draggable divider between them. herdr's own resizable group keeps the
  // width while it is dragged; when a drag ends the width is clamped (the panel's minimum up to half the
  // office) and saved, and the floor refits through the stage's size report like any other resize.
  split(stage, t, F, cx, pane) {
    // The limit comes from the group's own width, which a drag does not change, never from the stage plus the old panel.
    const max = clampPanelW(1e9, this.splitW || this.size.width + this.panelW);
    const box = (group) => div().id("split-box").flex_1().min_w(0).min_h(0).h_full()
      .on_size_change((m, c) => { if (m.width !== this.splitW) { this.splitW = m.width; c.notify(); } })
      .child(group);
    return box(h_resizable(`office-split-${pane || ""}`).size_full()
      .on_resize((sizes) => {
        const w = clampPanelW(sizes[sizes.length - 1], sizes.reduce((n, x) => n + x, 0));
        if (w === this.panelW) return;
        this.panelW = w;
        try { setShared(this.panelKey, w); } catch (_) { /* the width is only remembered, not needed */ }
      })
      .child(resizable_panel().size_range(120).child(stage))
      .child(resizable_panel().size(Math.min(this.panelW, max)).size_range(PANEL_MIN, max).child(this.panel.render(t, F, cx))));
  }
}
