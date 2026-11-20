#!/usr/bin/env bats
# panel.js under node, with gpui-kit, gpui-base and herdr replaced by stubs. The cx stub is stricter
# than herdr: a cx from an event handler is dead once the handler returns (as in herdr), and a cx from
# cx.spawn is also dead once its task ends (herdr hands the task an AsyncContext that may be held). Using
# a dead cx throws, so a panel that keeps a handler's cx and uses it after an await fails here.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

# Runs $1 as module code with `panel`, `agent`, `input`, `calls`, `click`, `settle` and `taskErrors` in scope.
panel_js() {
  command -v node >/dev/null || skip "node not installed"
  local d="$BATS_TEST_TMPDIR/panel"
  mkdir -p "$d/node_modules/gpui-kit" "$d/node_modules/gpui-base" "$d/node_modules/herdr"
  cat > "$d/node_modules/gpui-kit/index.js" <<'JS'
const el = () => new Proxy({}, { get: (_, k) => (...a) => { if (k === "on_mouse_down") (globalThis.HANDLERS ||= []).push(a); return el(); } });
export const div = el;
export const svg = () => el();
export const image = (p) => { (globalThis.IMAGES ||= []).push(p); return el(); };
const pb = () => new Proxy({}, { get: () => () => pb() });
export const PathBuilder = { fill: pb, stroke: pb };
globalThis.window ||= { paint_path: el };
JS
  cat > "$d/node_modules/gpui-base/index.js" <<'JS'
import { div } from "gpui-kit";
export const v_flex = div, h_flex = div, Textarea = { new: () => div() }, TextView = { markdown: () => div() };
export const TextareaState = { new: () => { const s = { text: "", sets: [], set_value(v) { s.text = v; s.sets.push(v); delete s.sel; }, set_selected_range(r) { s.sel = r; }, selected_range: () => s.sel || { start: s.text.length, end: s.text.length }, replace(v) { const r = s.selected_range(); s.text = s.text.slice(0, r.start) + v + s.text.slice(r.end); s.sel = { start: r.start + v.length, end: r.start + v.length }; }, value: () => s.text, on(e, h) { (s.handlers ||= {})[e] = h; return true; }, focus() {}, set_soft_wrap() {}, set_auto_grow(a, b) { s.grow = [a, b]; } }; return s; } };
export const ScrollHandle = { new: () => ({ scroll_to_item(i) { (globalThis.SCROLLS ||= []).push(i); } }) };
JS
  cat > "$d/node_modules/herdr/index.js" <<'JS'
export const terminals = () => [];
export const home = () => process.env.PHOME || "/nohome";
export const appHome = () => (process.env.PHOME || "/nohome") + "/.config/herdr-app";
import { execFile } from "node:child_process";
export const exec = (c, a, o) => new Promise((resolve, reject) => {
  // `loh photos thumbs` answers at once (set globalThis.THUMBS to what it prints), so a test need not settle it by hand.
  if (a[0] === "photos") { (globalThis.THUMB_CALLS ||= []).push(a.join(" ")); resolve({ code: 0, stdout: globalThis.THUMBS || "thumbs: 0 made, 0 up to date (magick)\n" }); return; }
  // `loh react --set-owner` runs for real: the office saves the owner's reactions through it.
  if (a[0] === "react") { (globalThis.REACT_CALLS ||= []).push({ a, cwd: o && o.cwd }); execFile(process.env.LOH_BIN, a, { cwd: o && o.cwd }, (e, stdout, stderr) => (e && typeof e.code !== "number" ? reject(e) : resolve({ code: e ? e.code : 0, stdout, stderr }))); return; }
  (globalThis.CALLS ||= []).push({ c, a, resolve, reject });
});
JS
  # herdr's fs/promises, as its docs and declarations give it: no rename, and writes only under herdr-app's folder.
  cat > "$d/herdrfs.mjs" <<'JS'
import * as real from "node:fs/promises";
const app = (process.env.PHOME || "/nohome") + "/.config/herdr-app";
const home = (p) => { if (!(p === app || p.startsWith(app + "/"))) throw new Error("fs: write outside " + app + ": " + p); };
export const readFile = real.readFile, readdir = real.readdir, exists = (p) => real.access(p).then(() => true, () => false);
export const writeFile = (p, c) => { home(p); return real.writeFile(p, c); };
export const mkdir = (p, o) => { home(p); return real.mkdir(p, o); };
export const unlink = (p) => { home(p); return real.unlink(p); };
export const rmdir = (p) => { home(p); return real.rmdir(p); };
JS
  echo '{"type":"module"}' > "$d/package.json"
  for f in panel chat crew draw photos reactions; do sed -E 's#from "\./([a-z]+)\.js"#from "./\1.mjs"#; s#from "fs/promises"#from "./herdrfs.mjs"#' "$(mod_dir)/$f.js" > "$d/$f.mjs"; done
  export LOH_BIN="${LOH_BIN:-$REPO_ROOT/bin/loh}"
  cat > "$d/run.mjs" <<EOF
import { Panel } from "./panel.mjs";
const deadUses = [];
const dead = (what) => { deadUses.push(what); throw new Error("cx is no longer valid: it was captured during an earlier call and used later (" + what + ")"); };
const tasks = [], taskErrors = [];
const mkcx = () => {
  const cx = { alive: true,
    notify() { if (!cx.alive) dead("notify"); globalThis.NOTIFIES = (globalThis.NOTIFIES || 0) + 1; },
    timer: { after(ms, fn) { (globalThis.TIMERS ||= []).push({ ms, fn }); return { cancel() {} }; } },
    stop_propagation() { (globalThis.STOPS ||= []).push(1); },
    write_to_clipboard(t) { (globalThis.CLIP ||= []).push(t); },
    read_from_clipboard() { const c = globalThis.CLIP || []; return c.length ? c[c.length - 1] : undefined; },
    spawn(fn) {
      if (!cx.alive) dead("spawn");
      const c = mkcx();
      tasks.push(new Promise((ok) => ok(fn(c))).catch((e) => { taskErrors.push(String(e.message)); }).then(() => { c.alive = false; }));
    } };
  return cx;
};
// An event handler's call: its cx is valid while the handler runs and dead after.
const click = (fn) => { const cx = mkcx(); try { fn(cx); } finally { cx.alive = false; } };
const settle = async () => { for (let i = 0; i < 5; i++) { await new Promise((r) => setImmediate(r)); await Promise.all(tasks); } };
const panel = new Panel({ loh: () => "loh" });
const agent = { address: "t1", name: "Scofield", rawName: "scofield", status: "idle", cwd: "/ws" };
click((cx) => panel.select(agent, cx));
const input = panel.inputs.get("t1");
const calls = () => globalThis.CALLS;
$1
EOF
  (cd "$d" && node run.mjs)
}

@test "send: a message that went out stays sent, with no error and an empty box, though its click cx is long dead" {
  run panel_js '
input.text = "Hey Scofield";
click((cx) => panel.send(cx));
calls()[0].resolve({ code: 0, stdout: "", stderr: "" });
await settle();
console.log(JSON.stringify([panel.error, input.text, panel.pending.length, panel.sending, taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["","",1,false,[],[]]' ]
}

@test "send: a failure in our own handling after loh returned 0 never puts the text back or says loh could not run" {
  run panel_js '
input.text = "Hey Scofield";
click((cx) => panel.send(cx));
calls()[0].resolve({ code: 0, stdout: "", stderr: "" });
Object.defineProperty(panel, "fetchedKey", { set() { throw new Error("handling blew up"); }, get() { return null; } });
await settle();
console.log(JSON.stringify([panel.error, input.text, input.sets, taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["","",[""],["handling blew up"],[]]' ]
}

@test "send: loh not starting (quick rejection) restores the text and says so" {
  run panel_js '
input.text = "Hey Scofield";
click((cx) => panel.send(cx));
calls()[0].reject(new Error("spawn loh ENOENT"));
await settle();
console.log(JSON.stringify([panel.error, input.text, panel.pending.length, taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["could not run loh: spawn loh ENOENT","Hey Scofield",0,[],[]]' ]
}

@test "send: loh refusing with a reason restores the text and shows loh's line" {
  run panel_js '
input.text = "Hey Scofield";
click((cx) => panel.send(cx));
calls()[0].resolve({ code: 9, stdout: "", stderr: "loh: scofield is blocked on a dialog\n" });
await settle();
console.log(JSON.stringify([panel.error, input.text, panel.pending.length, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["scofield is blocked on a dialog","Hey Scofield",0,[]]' ]
}

@test "transcript fetch: the log is read and shown though the render cx is long dead" {
  run panel_js '
panel.wantKey = "k1";
click((cx) => panel.load(cx));
calls()[0].resolve({ code: 0, stdout: JSON.stringify([{ role: "assistant", text: "hi", ts: "" }]), stderr: "" });
await settle();
console.log(JSON.stringify([panel.turns.length, panel.fetchedKey, panel.fetching, taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[1,"k1",false,[],[]]' ]
}

@test "send: a rejection that comes after 6 s may be a timeout: the text stays out of the box and the message shows as unconfirmed" {
  run panel_js '
let now = 1000000; Date.now = () => now;
input.text = "Hey Scofield";
click((cx) => panel.send(cx));
now += 6000;
calls()[0].reject(new Error("timed out"));
await settle();
console.log(JSON.stringify([input.text, input.sets, panel.pending.length, panel.pending[0] && panel.pending[0].unsure, panel.error.startsWith("Not sure Scofield got it"), taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["",[""],1,true,true,[],[]]' ]
}

@test "send: a call cut off with no word from loh (no exit code) is unconfirmed, not restored" {
  run panel_js '
input.text = "Hey Scofield";
click((cx) => panel.send(cx));
calls()[0].resolve({ code: null, stdout: "", stderr: "" });
await settle();
console.log(JSON.stringify([input.text, input.sets, panel.pending.length, panel.pending[0] && panel.pending[0].unsure, panel.error.startsWith("Not sure Scofield got it"), taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["",[""],1,true,true,[],[]]' ]
}

@test "send: a refusal code with no stderr is unconfirmed, and so is hc send failing (exit 12)" {
  run panel_js '
input.text = "a";
click((cx) => panel.send(cx));
calls()[0].resolve({ code: 9, stdout: "", stderr: "" });
await settle();
const first = [input.text, panel.pending[0].unsure];
panel.pending = []; panel.error = ""; input.text = "b";
click((cx) => panel.send(cx));
calls()[1].resolve({ code: 12, stdout: "", stderr: "loh: hc send scofield failed (exit 3): x; the message may still have gone out\n" });
await settle();
console.log(JSON.stringify([first, input.text, panel.pending[0].unsure, panel.error.startsWith("Not sure")]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["",true],"",true,true]' ]
}

@test "message box: Enter sends the text and stops the key, Ctrl+Enter keeps a newline in what is sent" {
  run panel_js '
const key = (k, control) => click((cx) => panel.key({ key: k, modifiers: { shift: false, control: !!control, alt: false, platform: false, function: false } }, cx));
input.text = "line one";
key("enter", true);
console.log(JSON.stringify(input.text), calls() === undefined, (globalThis.STOPS || []).length);
input.text += "line two";
key("enter", false);
console.log(JSON.stringify(calls()[0].a), (globalThis.STOPS || []).length);
calls()[0].resolve({ code: 0, stdout: "", stderr: "" });
await settle();
console.log(JSON.stringify([input.text, taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '"line one\n" true 1' ]
  [ "${lines[1]}" = '["tell","scofield","line one\nline two"] 2' ]
  [ "${lines[2]}" = '["",[],[]]' ]
}

@test "message box: Shift+Enter and other keys are left to the box" {
  run panel_js '
click((cx) => panel.key({ key: "enter", modifiers: { shift: true, control: false, alt: false, platform: false, function: false } }, cx));
click((cx) => panel.key({ key: "a", modifiers: { shift: false, control: false, alt: false, platform: false, function: false } }, cx));
console.log(calls() === undefined, (globalThis.STOPS || []).length, JSON.stringify(input.text));'
  [ "$status" -eq 0 ]
  [ "$output" = 'true 0 ""' ]
}

@test "message box: Enter inside the textarea arrives as a submit event: plain Enter sends, Ctrl and Shift keep the newline" {
  run panel_js '
const sub = (e) => click((cx) => { cx.timer = { after() {} }; input.handlers.submit(e, cx); });
input.text = "one\n";
sub({ secondary: true });
sub({ shift: true });
console.log(calls() === undefined, JSON.stringify(input.text));
input.text = "hello\n";
sub({ secondary: false });
console.log(calls().length, JSON.stringify(calls()[0].a.slice(-1)), JSON.stringify(input.text));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'true "one\n"' ]
  [ "${lines[1]}" = '1 ["hello"] ""' ]
}

@test "message box: a plain Enter that cannot send still takes its newline back out and says why" {
  run panel_js '
const sub = (e) => click((cx) => { cx.timer = { after() {} }; input.handlers.submit(e, cx); });
input.text = "draft\n";
panel.sending = true;
sub({});
console.log(calls() === undefined, JSON.stringify(input.text), panel.error);
panel.sending = false; panel.error = "";
input.text = "";
sub({});
console.log(JSON.stringify(input.text), panel.sending);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'true "draft" Enter did not send: the last message is still going out.' ]
  [ "${lines[1]}" = '"" false' ]
}

@test "layout: no line height in the panel is a bare number, which the kit reads as a multiplier" {
  run grep -nE 'line_height\([0-9.]+\)' "$(mod_dir)/panel.js"
  [ "$status" -eq 1 ]
}

@test "message box: a stale newline memory is never restored over newer text" {
  run panel_js '
const change = (v) => { input.text = v; input.handlers.change({}, { notify() {} }); };
change("ab"); change("ab\n"); // Ctrl+Enter put a newline in
change("xyz");                  // then the box was cleared and retyped
change("xy\nz");               // a plain Enter with the caret before the z: the newline goes in, then submit
click((cx) => { cx.timer = { after() {} }; input.handlers.submit({}, cx); });
console.log(panel.preNl, JSON.stringify(calls() && calls()[0].a.slice(-1)));'
  [ "$status" -eq 0 ]
  [ "$output" = 'null ["xyz"]' ]
}

@test "scroll: the log follows the newest turn even when the 40-turn window is full, and Matt's own send" {
  run panel_js '
const th = { foreground: "#fff", muted: "#999", border: "#333", canvas: "#000", chrome: "#111", raised: "#222", surface: "#111", accent: "#06f", hover: "#222", blocked: "#f90", working: "#0f0", done: "#09f", idle: "#888" };
const turn = (i) => ({ role: i % 2 ? "assistant" : "user", text: "t" + i, ts: new Date(Date.UTC(2026, 10, 15, 10, i)).toISOString() });
const draw = () => click((cx) => panel.render(th, {}, cx));
panel.turns = Array.from({ length: 40 }, (_, i) => turn(i));
draw(); draw();
panel.turns = Array.from({ length: 40 }, (_, i) => turn(i + 1)); // one arrived, one left: still 40
draw();
panel.pending = [{ text: "mine" }];
draw();
console.log(JSON.stringify(globalThis.SCROLLS));'
  [ "$status" -eq 0 ]
  [ "$output" = "[40,40,41]" ]
}

@test "scroll: a sent message is drawn at once, before loh has delivered it" {
  run panel_js '
input.text = "Hey Scofield";
globalThis.NOTIFIES = 0;
click((cx) => panel.send(cx));
const before = globalThis.NOTIFIES;
calls()[0].resolve({ code: 0, stdout: "", stderr: "" });
await settle();
console.log(before > 0, panel.pending.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true 1" ]
}

@test "scroll: a reaction added to or taken off one of the newest turns scrolls the log to the end again; one on an older turn does not" {
  run panel_js '
const th = { foreground: "#fff", muted: "#999", border: "#333", canvas: "#000", chrome: "#111", raised: "#222", surface: "#111", accent: "#06f", hover: "#222", blocked: "#f90", working: "#0f0", done: "#09f", idle: "#888" };
const draw = () => click((cx) => panel.render(th, {}, cx));
panel.turns = [{ role: "assistant", id: "a0", text: "old", ts: "2026-11-15T10:00:00Z" }, { role: "user", id: "u0", text: "x", ts: "2026-11-15T10:00:30Z" }, { role: "assistant", id: "a2", text: "y", ts: "2026-11-15T10:00:40Z" }, { role: "user", id: "u1", text: "Hi", ts: "2026-11-15T10:01:00Z" }, { role: "assistant", id: "a1", text: "newest", ts: "2026-11-15T10:02:00Z" }];
draw(); draw();
const n0 = globalThis.SCROLLS.length;
panel.owner = [{ id: "a1", emoji: "👍" }];
draw(); draw();
const n1 = globalThis.SCROLLS.length;
panel.owner = [{ id: "a1", emoji: "👍" }, { id: "a0", emoji: "❤️" }];
draw();
const n2 = globalThis.SCROLLS.length;
panel.owner = [{ id: "a0", emoji: "❤️" }];
draw();
const n3 = globalThis.SCROLLS.length;
panel.pending = [{ text: "mine" }];
draw();
panel.owner = [{ id: "a0", emoji: "❤️" }, { id: "a1", emoji: "😂" }];
draw();
console.log(n0, n1, n2, n3, globalThis.SCROLLS.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 2 2 3 5" ]
}

@test "scroll: a new newest row is revealed again a moment later, once it has been laid out; a stale request does nothing" {
  run panel_js '
const th = { foreground: "#fff", muted: "#999", border: "#333", canvas: "#000", chrome: "#111", raised: "#222", surface: "#111", accent: "#06f", hover: "#222", blocked: "#f90", working: "#0f0", done: "#09f", idle: "#888" };
const draw = () => click((cx) => panel.render(th, {}, cx));
const run = () => { const ts = globalThis.TIMERS || []; globalThis.TIMERS = []; ts.forEach((t) => { const c = { notify() {} }; t.fn(c); }); };
panel.turns = [{ role: "user", id: "u1", text: "Hi", ts: "2026-11-15T10:01:00Z" }, { role: "assistant", id: "a1", text: "yo", ts: "2026-11-15T10:02:00Z" }];
draw(); run();
globalThis.SCROLLS = [];
panel.pending = [{ text: "mine" }];
draw();
const now = globalThis.SCROLLS.slice();
run();
const after = globalThis.SCROLLS.slice();
// A request that is overtaken by a newer row does nothing.
panel.pending = [{ text: "mine" }, { text: "two" }];
draw();
panel.pending = [{ text: "mine" }, { text: "two" }, { text: "three" }];
const stale = (globalThis.TIMERS || []).slice(); globalThis.TIMERS = [];
draw();
globalThis.SCROLLS = [];
stale.forEach((t) => t.fn({ notify() {} }));
console.log(JSON.stringify([now, after, globalThis.SCROLLS]));'
  [ "$status" -eq 0 ]
  [ "$output" = "[[3],[3,3],[]]" ]
}

@test "scroll: the activity feed follows its newest row when it is full" {
  run panel_js '
const th = { foreground: "#fff", muted: "#999", border: "#333", canvas: "#000", chrome: "#111", raised: "#222", surface: "#111", accent: "#06f", hover: "#222", blocked: "#f90", working: "#0f0", done: "#09f", idle: "#888" };
panel.tab = "activity";
const draw = () => click((cx) => panel.render(th, {}, cx));
panel.feed = Array.from({ length: 100 }, (_, i) => ({ at: "10:" + i, name: "amy", text: "e" + i, level: "info" }));
draw(); draw();
panel.feed = Array.from({ length: 100 }, (_, i) => ({ at: "10:" + (i + 1), name: "amy", text: "e" + (i + 1), level: "info" }));
draw();
console.log(JSON.stringify(globalThis.SCROLLS));'
  [ "$status" -eq 0 ]
  [ "$output" = "[100,100]" ]
}

@test "layout: a full-width border divider sits above the composer, which pads 8 above and 12 below" {
  run grep -c 'pt(8).pb(12).border_t(1).border_color(t.border)' "$(mod_dir)/panel.js"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "font: the panel and its message text views use a family that has bold and italic faces" {
  run grep -c 'font_family(FONT)' "$(mod_dir)/panel.js"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "layout: via Discord follows the time in the time's own style, and the selected tab is underlined in foreground" {
  run grep -c 'child(`${stamp}${viaMark(m)}`)' "$(mod_dir)/panel.js"
  [ "$output" = "1" ]
  run grep -c 'viaMark(m)}`))' "$(mod_dir)/panel.js"
  [ "$output" = "1" ]
  run grep -c 'border_color(on ? t.foreground' "$(mod_dir)/panel.js"
  [ "$output" = "1" ]
}

@test "message box: it wraps and grows from one row to six" {
  run panel_js 'console.log(JSON.stringify(input.grow));'
  [ "$status" -eq 0 ]
  [ "$output" = "[1,6]" ]
}

@test "copy: Copy puts that message on the clipboard, Copy all the turns shown; Copied clears after 1.5 s" {
  run panel_js '
panel.turns = [{ role: "user", text: "Hi", ts: "" }, { role: "assistant", text: "**Hello**\n\n- a", ts: "" }];
let fired = null;
click((cx) => { cx.timer = { after: (ms, fn) => { fired = [ms, fn]; } }; panel.copy("m1", panel.turns[1].text, cx); });
console.log(JSON.stringify(globalThis.CLIP), panel.copied, fired[0]);
fired[1]({ notify() {} });
console.log(panel.copied);
click((cx) => panel.copy("all", "x", cx));
click((cx) => panel.render({ foreground: "#fff", muted: "#999", border: "#333", canvas: "#000", chrome: "#111", raised: "#222", surface: "#111", accent: "#06f", hover: "#222", blocked: "#f90", working: "#0f0", done: "#09f", idle: "#888" }, {}, cx));
console.log(JSON.stringify(globalThis.CLIP[1]));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '["**Hello**\n\n- a"] m1 1500' ]
  [ "${lines[1]}" = "null" ]
  [ "${lines[2]}" = '"x"' ]
}

# Right-click menus (ticket #170). The panel's handlers are driven the way herdr drives them: a row or the box
# names itself on its own right press (pressRight), then the panel root's right press (rootRight) opens the menu at
# its local position, which is where the pointer is in the panel.
THEME='{ foreground: "#fff", muted: "#999", border: "#333", canvas: "#000", chrome: "#111", raised: "#222", surface: "#111", accent: "#06f", hover: "#222", popover: "#181818", blocked: "#f90", working: "#0f0", done: "#09f", idle: "#888" }'

@test "right-click menu: a message's Copy message puts that message's text on the clipboard and shows Copied, and the menu goes" {
  run panel_js '
panel.turns = [{ role: "user", text: "Hi", ts: "" }, { role: "assistant", text: "**Hello**\n\n- a", ts: "" }];
click((cx) => { panel.pressRight({ kind: "message", key: "m1", text: panel.turns[1].text }); panel.rootRight({ button: "right", local_position: { x: 40, y: 90 } }, cx); });
console.log(JSON.stringify([panel.menu.kind, panel.menu.x, panel.menu.y, panel.menu.items]));
click((cx) => panel.pickMenu("copy", cx));
console.log(JSON.stringify([globalThis.CLIP, panel.copied, panel.menu]));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '["message",40,90,[{"id":"copy","label":"Copy message","enabled":true}]]' ]
  [ "${lines[1]}" = '[["**Hello**\n\n- a"],"m1",null]' ]
}

@test "right-click menu: the chat box offers Cut, Copy and Paste; Cut takes the selection out and onto the clipboard" {
  run panel_js '
input.text = "hello world"; input.sel = { start: 0, end: 5 };
globalThis.CLIP = ["from elsewhere"];
click((cx) => { panel.pressRight({ kind: "box" }); panel.rootRight({ button: "right", local_position: { x: 40, y: 400 } }, cx); });
console.log(JSON.stringify(panel.menu.items));
click((cx) => panel.pickMenu("cut", cx));
console.log(JSON.stringify([input.text, globalThis.CLIP.at(-1), panel.menu]));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '[{"id":"cut","label":"Cut","enabled":true},{"id":"copy","label":"Copy","enabled":true},{"id":"paste","label":"Paste","enabled":true}]' ]
  [ "${lines[1]}" = '[" world","hello",null]' ]
}

@test "right-click menu: a selection that is lost between opening the menu and choosing (the click moved the keyboard) is put back first" {
  run panel_js '
input.text = "hello world"; input.sel = { start: 0, end: 5 };
click((cx) => { panel.pressRight({ kind: "box" }); panel.rootRight({ button: "right", local_position: { x: 5, y: 400 } }, cx); });
input.sel = { start: 11, end: 11 };
click((cx) => panel.pickMenu("cut", cx));
console.log(JSON.stringify([input.text, globalThis.CLIP]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[" world",["hello"]]' ]
}

@test "right-click menu: typing while the menu is open closes it, and a stale choice cuts nothing" {
  run panel_js '
input.text = "hello world"; input.sel = { start: 6, end: 11 };
const open = () => click((cx) => { panel.pressRight({ kind: "box" }); panel.rootRight({ button: "right", local_position: { x: 5, y: 400 } }, cx); });
open();
input.handlers.change({}, { notify() {} });
console.log(panel.menu);
open();
input.text = "XXXX hello world";
click((cx) => panel.pickMenu("cut", cx));
console.log(JSON.stringify([input.text, globalThis.CLIP || null]));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "null" ]
  [ "${lines[1]}" = '["XXXX hello world",null]' ]
}

@test "right-click menu: choosing another agent closes an open menu" {
  run panel_js '
click((cx) => { panel.pressRight({ kind: "message", key: "m0", text: "x" }); panel.rootRight({ button: "right", local_position: { x: 1, y: 1 } }, cx); });
click((cx) => panel.select({ ...agent, address: "t2", name: "Amy" }, cx));
console.log(panel.menu, panel.rightFor);'
  [ "$status" -eq 0 ]
  [ "$output" = "null null" ]
}

@test "right-click menu: render wires a right press on a row, on the box and on the panel root" {
  run panel_js '
panel.turns = [{ role: "assistant", text: "Hello", ts: "" }];
globalThis.HANDLERS = [];
click((cx) => panel.render('"$THEME"', {}, cx));
const hs = globalThis.HANDLERS.filter((a) => a[0] === "right").map((a) => a[1]);
const kinds = hs.map((h) => {
  panel.menu = null; panel.rightFor = { kind: "pre" };
  click((cx) => h({ local_position: { x: 1, y: 1 } }, cx));
  return panel.menu ? "root:" + panel.menu.kind : panel.rightFor.kind;
});
console.log(JSON.stringify(kinds.sort()));'
  [ "$status" -eq 0 ]
  [ "$output" = '["box","message","root:pre"]' ]
}

@test "right-click menu: chat box Copy copies the selection and leaves the text alone" {
  run panel_js '
input.text = "hello world"; input.sel = { start: 6, end: 11 };
click((cx) => { panel.pressRight({ kind: "box" }); panel.rootRight({ button: "right", local_position: { x: 5, y: 400 } }, cx); });
click((cx) => panel.pickMenu("copy", cx));
console.log(JSON.stringify([input.text, globalThis.CLIP, panel.menu]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["hello world",["world"],null]' ]
}

@test "right-click menu: with no selection Cut and Copy are disabled and do nothing" {
  run panel_js '
input.text = "hello"; input.sel = { start: 2, end: 2 };
click((cx) => { panel.pressRight({ kind: "box" }); panel.rootRight({ button: "right", local_position: { x: 5, y: 400 } }, cx); });
console.log(JSON.stringify(panel.menu.items.map((i) => [i.id, i.enabled])));
click((cx) => panel.pickMenu("cut", cx));
click((cx) => panel.pickMenu("copy", cx));
console.log(JSON.stringify([input.text, globalThis.CLIP || null, panel.menu === null]));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '[["cut",false],["copy",false],["paste",false]]' ]
  [ "${lines[1]}" = '["hello",null,false]' ]
}

@test "right-click menu: Paste puts the clipboard at the cursor, or over the selection, and is disabled when the clipboard is empty" {
  run panel_js '
input.text = "hello world"; input.sel = { start: 5, end: 5 };
globalThis.CLIP = ["XY"];
click((cx) => { panel.pressRight({ kind: "box" }); panel.rootRight({ button: "right", local_position: { x: 5, y: 400 } }, cx); });
click((cx) => panel.pickMenu("paste", cx));
console.log(JSON.stringify([input.text, panel.menu]));
input.sel = { start: 0, end: 5 };
click((cx) => { panel.pressRight({ kind: "box" }); panel.rootRight({ button: "right", local_position: { x: 5, y: 400 } }, cx); });
click((cx) => panel.pickMenu("paste", cx));
console.log(input.text);
globalThis.CLIP = [];
click((cx) => { panel.pressRight({ kind: "box" }); panel.rootRight({ button: "right", local_position: { x: 5, y: 400 } }, cx); });
console.log(JSON.stringify(panel.menu.items.map((i) => [i.id, i.enabled])));
click((cx) => panel.pickMenu("paste", cx));
console.log(input.text);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '["helloXY world",null]' ]
  [ "${lines[1]}" = "XYXY world" ]
  [ "${lines[2]}" = '[["cut",false],["copy",false],["paste",false]]' ]
  [ "${lines[3]}" = "XYXY world" ]
}

@test "right-click menu: it closes on Escape and on a press outside it, and a right press on nothing opens none" {
  run panel_js '
const open = () => click((cx) => { panel.pressRight({ kind: "message", key: "m0", text: "x" }); panel.rootRight({ button: "right", local_position: { x: 1, y: 1 } }, cx); });
open(); click((cx) => panel.menuKey({ key: "a", modifiers: {} }, cx)); console.log(panel.menu !== null);
click((cx) => panel.menuKey({ key: "escape", modifiers: {} }, cx)); console.log(panel.menu === null);
open(); click((cx) => panel.closeMenu(cx)); console.log(panel.menu === null);
open(); click((cx) => panel.rootRight({ button: "right", local_position: { x: 9, y: 9 } }, cx)); console.log(panel.menu === null);
click((cx) => panel.rootRight({ button: "right", local_position: { x: 9, y: 9 } }, cx)); console.log(panel.menu === null);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "true" ]
  [ "${lines[1]}" = "true" ]
  [ "${lines[2]}" = "true" ]
  [ "${lines[3]}" = "true" ]
  [ "${lines[4]}" = "true" ]
}

@test "right-click menu: the panel draws with either menu open, and closing the chat closes the menu" {
  run panel_js '
panel.turns = [{ role: "assistant", text: "Hello", ts: "" }];
for (const target of [{ kind: "message", key: "m0", text: "Hello" }, { kind: "box" }]) {
  click((cx) => { panel.pressRight(target); panel.rootRight({ button: "right", local_position: { x: 400, y: 200 } }, cx); });
  click((cx) => panel.render('"$THEME"', {}, cx));
}
console.log(panel.menu.x <= panel.width);
click((cx) => panel.close(cx));
console.log(panel.menu);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "true" ]
  [ "${lines[1]}" = "null" ]
}

@test "render: a log with Matt's, the agent's, another agent's and a launch turn draws without error" {
  run panel_js '
panel.turns = [{ role: "user", text: "L", launch: true, ts: "" }, { role: "user", text: "Hi", ts: "2026-11-15T10:00:00Z" }, { role: "assistant", text: "**Hello**", ts: "2026-11-15T10:01:00Z" }, { role: "agent", from: "amy", text: "ok", ts: "2026-11-15T10:02:00Z" }];
const th = { foreground: "#fff", muted: "#999", border: "#333", canvas: "#000", chrome: "#111", raised: "#222", surface: "#111", accent: "#06f", hover: "#222", blocked: "#f90", working: "#0f0", done: "#09f", idle: "#888" };
click((cx) => { panel.render(th, {}, cx); panel.tab = "activity"; panel.render(th, {}, cx); });
console.log("drawn");'
  [ "$status" -eq 0 ]
  [ "$output" = "drawn" ]
}

# Photos (#35): the avatar is the person's photo when the folder has one, else the floor figure.
photo_home() {
  local h="$BATS_TEST_TMPDIR/phome"
  mkdir -p "$h/.config/herdr-app/photos"
  printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\1\x2c\0\0\2\x58\x08\x02\0\0\0' > "$h/.config/herdr-app/photos/yoda.png"
  printf 'not a picture' > "$h/.config/herdr-app/photos/sara.png"
  printf '%s' "$h"
}

@test "photos: a person with a photo gets it as an image from the herdr-app folder; one with none, or an unreadable one, gets the floor figure" {
  local h; h="$(photo_home)"
  PHOME="$h" run panel_js '
const t = { raised: "a", border: "b" };
click((cx) => panel.loadPhotos(cx));
await settle();
const before = (globalThis.IMAGES || []).length;
panel.avatar("Yoda", 36, t); const afterYoda = globalThis.IMAGES.length;
panel.avatar("sara", 36, t); panel.avatar("matt", 36, t); panel.avatar("", 36, t);
console.log(JSON.stringify([[...panel.photos.keys()], before, afterYoda, globalThis.IMAGES.length, globalThis.IMAGES[0], taskErrors]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["yoda"],0,1,1,"photos/yoda.png",[]]' ]
}

@test "photos: a photo added while the office is open shows on the next read, and nothing is read again before then" {
  local h; h="$(photo_home)"
  PHOME="$h" run panel_js '
const fs = await import("node:fs/promises");
click((cx) => panel.loadPhotos(cx)); await settle();
await fs.writeFile(process.env.PHOME + "/.config/herdr-app/photos/amy.png", await fs.readFile(process.env.PHOME + "/.config/herdr-app/photos/yoda.png"));
click((cx) => panel.loadPhotos(cx)); await settle();
const early = [...panel.photos.keys()].sort();
panel.photosAt -= 61000;
click((cx) => panel.loadPhotos(cx)); await settle();
console.log(JSON.stringify([early, [...panel.photos.keys()].sort(), taskErrors]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["yoda"],["amy","yoda"],[]]' ]
}

@test "photos: a photo's crop shows in how the image is placed; with no folder at all the panel still draws" {
  local h; h="$(photo_home)"
  PHOME="$h" run panel_js '
click((cx) => panel.loadPhotos(cx)); await settle();
console.log(JSON.stringify(panel.photos.get("yoda")));'
  [ "$status" -eq 0 ]
  [ "$output" = '{"path":"'"$h"'/.config/herdr-app/photos/yoda.png","w":300,"h":600,"crop":null}' ]
  PHOME="$BATS_TEST_TMPDIR/empty" run panel_js '
click((cx) => panel.loadPhotos(cx)); await settle();
panel.avatar("yoda", 36, { raised: "a", border: "b" });
console.log(JSON.stringify([panel.photos.size, taskErrors]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[0,[]]' ]
}

@test "photos: loh photos thumbs is asked for the folder once the pictures are drawn, and a made thumb replaces the picture" {
  local h; h="$(photo_home)"
  PHOME="$h" run panel_js '
const fs = await import("node:fs/promises");
const dir = process.env.PHOME + "/.config/herdr-app/photos";
click((cx) => panel.loadPhotos(cx)); await settle();
const first = panel.photos.get("yoda").path.slice(dir.length);
await fs.mkdir(dir + "/.thumbs");
await fs.writeFile(dir + "/.thumbs/yoda.default.png", Buffer.from("89504e470d0a1a0a0000000d49484452000000800000008008020000", "hex"));
globalThis.THUMBS = "made yoda\nthumbs: 1 made, 0 up to date (magick)\n";
panel.photosAt -= 61000;
click((cx) => panel.loadPhotos(cx)); await settle();
const p = panel.photos.get("yoda");
console.log(JSON.stringify([first, globalThis.THUMB_CALLS.length, globalThis.THUMB_CALLS[0] === "photos thumbs " + dir, p.path.slice(dir.length), p.w, p.h, p.crop, taskErrors]));'
  [ "$status" -eq 0 ]
  [ "$output" = '["/yoda.png",2,true,"/.thumbs/yoda.default.png",128,128,null,[]]' ]
}

# Reactions (#77): the owner's clicks, the lines the next message carries, and the stores read back.
react_dir() { mkdir -p "$BATS_TEST_TMPDIR/ws/.loh/reactions"; : >"$BATS_TEST_TMPDIR/ws/.loh/workspace.md"; printf '%s' "$BATS_TEST_TMPDIR/ws/.loh/reactions"; }

@test "reactions: a transcript turn's id is kept and its leading reaction lines are not shown" {
  run panel_js '
panel.host.person = () => "Matt";
panel.wantKey = "k";
click((cx) => panel.load(cx));
calls()[0].resolve({ code: 0, stdout: JSON.stringify([{ role: "assistant", id: "a1", text: "Done", ts: "" }, { role: "user", id: "u1", text: "(Matt reacted 👍 to your message \"Done\")\nThanks", ts: "" }]), stderr: "" });
await settle();
console.log(JSON.stringify(panel.turns.map((m) => [m.id, m.text])));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["a1","Done"],["u1","Thanks"]]' ]
}

@test "reactions: a click shows at once, starts no turn and is saved; a second click takes it back" {
  local d; d="$(react_dir)"
  RDIR="$d" run panel_js '
const fs = await import("node:fs/promises");
panel.host.reactDir = () => process.env.RDIR;
const m = { role: "assistant", id: "a1", text: "#61 is merged", ts: "", pending: false };
click((cx) => panel.react(m, "👍", cx)); await settle();
const on = JSON.parse(await fs.readFile(process.env.RDIR + "/scofield.owner.json", "utf8"));
click((cx) => panel.react(m, "👍", cx)); await settle();
const off = JSON.parse(await fs.readFile(process.env.RDIR + "/scofield.owner.json", "utf8"));
console.log(JSON.stringify([on, off, globalThis.CALLS || [], taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[[{"id":"a1","emoji":"👍","excerpt":"#61 is merged","told":false,"gone":false}],[],[],[],[]]' ]
}

@test "reactions: a click is saved under herdr's fs rules, in a folder not made yet, and a new panel reads it back (the office reopened)" {
  local d; d="$BATS_TEST_TMPDIR/ws2/.loh/reactions"
  mkdir -p "$BATS_TEST_TMPDIR/ws2/.loh"; : >"$BATS_TEST_TMPDIR/ws2/.loh/workspace.md"
  RDIR="$d" run panel_js '
panel.host.reactDir = () => process.env.RDIR;
click((cx) => panel.react({ role: "assistant", id: "a1", text: "#61 is merged", ts: "" }, "👍", cx)); await settle();
const again = new Panel({ loh: () => "loh", reactDir: () => process.env.RDIR });
click((cx) => again.select(agent, cx));
await again.loadReactions(agent);
console.log(JSON.stringify([again.owner, globalThis.REACT_CALLS.map((c) => [c.a.slice(0, 3), c.cwd]), taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[[{"id":"a1","emoji":"👍","excerpt":"#61 is merged","told":false,"gone":false}],[[["react","--set-owner","scofield"],"'"$BATS_TEST_TMPDIR"'/ws2"]],[],[]]' ]
}

@test "reactions: a click made before the folder is known is saved once it is, merged with what the file holds" {
  local d; d="$(react_dir)"
  printf '[{"id":"old","emoji":"✅","excerpt":"older","told":true,"gone":false}]\n' >"$d/scofield.owner.json"
  RDIR="$d" run panel_js '
let dir = "";
panel.host.reactDir = () => dir;
click((cx) => panel.react({ role: "assistant", id: "a1", text: "hi", ts: "" }, "👍", cx)); await settle();
const before = [globalThis.REACT_CALLS || [], panel.owner.length];
dir = process.env.RDIR;
panel.wantKey = "k";
click((cx) => panel.load(cx));
calls()[0].resolve({ code: 0, stdout: "[]", stderr: "" });
await settle();
const fs = await import("node:fs/promises");
const saved = JSON.parse(await fs.readFile(dir + "/scofield.owner.json", "utf8"));
console.log(JSON.stringify([before, saved.map((e) => e.id + e.emoji), panel.owner.map((e) => e.id + e.emoji), taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[[[],1],["old✅","a1👍"],["old✅","a1👍"],[],[]]' ]
}

@test "reactions: a save that fails is logged and shows no error in the panel, and the chip stays" {
  local d; d="$(react_dir)"
  printf '#!/bin/sh\necho "disk full" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/failing-loh"; chmod +x "$BATS_TEST_TMPDIR/failing-loh"
  LOH_BIN="$BATS_TEST_TMPDIR/failing-loh" RDIR="$d" run panel_js '
const logged = []; console.error = (...a) => logged.push(a.join(" "));
panel.host.reactDir = () => process.env.RDIR;
click((cx) => panel.react({ role: "assistant", id: "a1", text: "hi", ts: "" }, "👍", cx)); await settle();
console.log(JSON.stringify([logged, panel.error, panel.owner.length, taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["office reactions: saving scofield'"'"'s owner reactions failed: disk full"],"",1,[],[]]' ]
}

@test "reactions: the next message carries a line for each reaction, shows only what was typed, and marks them told once sent" {
  local d; d="$(react_dir)"
  RDIR="$d" run panel_js '
const fs = await import("node:fs/promises");
panel.host.reactDir = () => process.env.RDIR;
panel.host.person = () => "Matt";
click((cx) => panel.react({ role: "assistant", id: "a1", text: "#61 is merged\nmore", ts: "" }, "👍", cx)); await settle();
input.text = "Thanks";
click((cx) => panel.send(cx));
const tell = calls()[0].a;
calls()[0].resolve({ code: 0, stdout: "", stderr: "" });
await settle();
const saved = JSON.parse(await fs.readFile(process.env.RDIR + "/scofield.owner.json", "utf8"));
console.log(JSON.stringify([tell, panel.pending.map((p) => p.text), saved.map((e) => e.told), taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["tell","scofield","(Matt reacted 👍 to your message \"#61 is merged\")\nThanks"],["Thanks"],[true],[],[]]' ]
}

@test "reactions: a message that was refused leaves its reactions untold" {
  local d; d="$(react_dir)"
  RDIR="$d" run panel_js '
panel.host.reactDir = () => process.env.RDIR;
panel.host.person = () => "Matt";
click((cx) => panel.react({ role: "assistant", id: "a1", text: "hi", ts: "" }, "✅", cx)); await settle();
input.text = "Thanks";
click((cx) => panel.send(cx));
calls()[0].resolve({ code: 9, stdout: "", stderr: "loh: scofield is blocked on a dialog\n" });
await settle();
console.log(JSON.stringify([panel.owner.map((e) => e.told), taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[[false],[],[]]' ]
}

@test "reactions: the sent message, back in the transcript with its lines, is the pending one and is not shown twice" {
  local d; d="$(react_dir)"
  RDIR="$d" run panel_js '
panel.host.reactDir = () => process.env.RDIR;
panel.host.person = () => "Matt";
click((cx) => panel.react({ role: "assistant", id: "a1", text: "hi", ts: "" }, "👍", cx)); await settle();
input.text = "Thanks";
click((cx) => panel.send(cx));
const sent = calls()[0].a[2];
calls()[0].resolve({ code: 0, stdout: "", stderr: "" });
await settle();
panel.wantKey = "k2";
click((cx) => panel.load(cx));
calls()[1].resolve({ code: 0, stdout: JSON.stringify([{ role: "user", id: "u1", text: sent, ts: "2026-11-15T10:00:00Z" }]), stderr: "" });
await settle();
console.log(JSON.stringify([panel.pending.length, panel.turns.map((m) => m.text)]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[0,["Thanks"]]' ]
}

@test "reactions: both stores are read with the log, so a reload keeps them" {
  local d; d="$(react_dir)"
  printf '[{"id":"a1","emoji":"❤️","excerpt":"hi","told":true,"gone":false}]\n' >"$d/scofield.owner.json"
  printf '[{"id":"u1","emoji":"👍"}]\n' >"$d/scofield.agent.json"
  RDIR="$d" run panel_js '
panel.host.reactDir = () => process.env.RDIR;
panel.wantKey = "k";
click((cx) => panel.load(cx));
calls()[0].resolve({ code: 0, stdout: "[]", stderr: "" });
await settle();
console.log(JSON.stringify([panel.owner, panel.agentR, taskErrors, deadUses]));'
  [ "$output" = '[[{"id":"a1","emoji":"❤️","excerpt":"hi","told":true,"gone":false}],[{"id":"u1","emoji":"👍"}],[],[]]' ]
}

@test "reactions: a log with chips on both sides, the bar and the owner's pending message draws without error" {
  local d; d="$(react_dir)"
  RDIR="$d" run panel_js '
panel.host.reactDir = () => process.env.RDIR;
panel.turns = [{ role: "user", text: "L", launch: true, ts: "" }, { role: "assistant", id: "a1", text: "**Hello**", ts: "2026-11-15T10:01:00Z" }, { role: "user", id: "u1", text: "Hi", ts: "2026-11-15T10:02:00Z" }, { role: "agent", from: "amy", id: "g1", text: "ok", ts: "2026-11-15T10:03:00Z" }];
panel.owner = [{ id: "a1", emoji: "👍", excerpt: "x", told: false, gone: false }];
panel.agentR = [{ id: "u1", emoji: "✅" }];
panel.pending = [{ text: "Sending" }];
const { groupLog } = await import("./chat.mjs");
panel.hover = "m-" + groupLog(panel.turns, "Scofield", "")[1].key;
let bars = 0; globalThis.BARS = () => bars++;
const th = { foreground: "#fff", muted: "#999", border: "#333", canvas: "#000", chrome: "#111", raised: "#222", surface: "#111", accent: "#06f", hover: "#222", blocked: "#f90", working: "#0f0", done: "#09f", idle: "#888", popover: "#101010" };
click((cx) => panel.render(th, {}, cx));
console.log("drawn");'
  [ "$output" = "drawn" ]
}

# The six as images (#77): drawn from emoji/ in a mod's folder under herdr-app's (import.meta.url is empty in herdr, so the
# folders are searched), and a glyph when an image cannot be used.
emoji_home() {
  local h="$BATS_TEST_TMPDIR/ehome" m="$BATS_TEST_TMPDIR/ehome/.config/herdr-app/mods"
  mkdir -p "$m/aaa-old" "$m/crew-office-test"
  cp -r "$REPO_ROOT/office/crew-office/emoji" "$m/crew-office-test/emoji"
  printf '%s' "$h"
}

@test "emoji images: each of the six is an image once checked, and a glyph before that" {
  PHOME="$(emoji_home)" run panel_js '
const six = ["👍", "✅", "❌", "👀", "❤️", "😂"];
const before = six.map((e) => panel.glyphKind(e));
click((cx) => panel.loadEmoji(cx)); await settle();
console.log(JSON.stringify([before, six.map((e) => panel.glyphKind(e)), panel.emojiSrc("👍"), taskErrors, deadUses]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["text","text","text","text","text","text"],["image","image","image","image","image","image"],"mods/crew-office-test/emoji/1f44d-20.png",[],[]]' ]
}

@test "emoji images: a missing, cut-short or wrong-size image is a glyph, and the rest stay images" {
  PHOME="$(emoji_home)" run panel_js '
const fs = await import("node:fs/promises");
const d = process.env.PHOME + "/.config/herdr-app/mods/crew-office-test/emoji/";
await fs.rm(d + "2705-20.png");
await fs.truncate(d + "274c-20.png", 10);
await fs.copyFile(d + "1f440-32.png", d + "1f440-20.png");
click((cx) => panel.loadEmoji(cx)); await settle();
console.log(JSON.stringify(["👍", "✅", "❌", "👀", "❤️", "😂"].map((e) => panel.glyphKind(e))));'
  [ "$output" = '["image","text","text","text","image","image"]' ]
}

@test "emoji images: an image missing from one copy of the mod is taken from another, and the office's own copy comes first" {
  local h; h="$(emoji_home)"
  local m="$h/.config/herdr-app/mods"
  mkdir "$m/zzz-mine"
  cp -r "$REPO_ROOT/office/crew-office/emoji" "$m/zzz-mine/emoji"
  rm "$m/crew-office-test/emoji/2705-20.png" "$m/zzz-mine/emoji/1f44d-20.png"
  PHOME="$h" run panel_js '
panel.host.modName = () => "zzz-mine";
click((cx) => panel.loadEmoji(cx)); await settle();
console.log(JSON.stringify([panel.emojiSrc("👍"), panel.emojiSrc("✅"), panel.emojiSrc("❌")]));'
  [ "$output" = '["mods/crew-office-test/emoji/1f44d-20.png","mods/zzz-mine/emoji/2705-20.png","mods/zzz-mine/emoji/274c-20.png"]' ]
}

@test "emoji images: the emojiScale the office gives picks the size" {
  PHOME="$(emoji_home)" run panel_js '
panel.host.emojiScale = () => 2;
click((cx) => panel.loadEmoji(cx)); await settle();
console.log(JSON.stringify([panel.glyphKind("👍"), panel.emojiSrc("👍"), panel.emojiSrc("🎉")]));'
  [ "$output" = '["image","mods/crew-office-test/emoji/1f44d-32.png",null]' ]
}

@test "emoji images: with no mods folder at all every chip is a glyph, never empty" {
  PHOME="$BATS_TEST_TMPDIR/nohome" run panel_js '
click((cx) => panel.loadEmoji(cx)); await settle();
console.log(JSON.stringify([["👍", "❤️"].map((e) => panel.glyphKind(e)), taskErrors]));'
  [ "$output" = '[["text","text"],[]]' ]
}

@test "emoji images: the images are read once, not again on a later render or hover" {
  local h; h="$(emoji_home)"
  PHOME="$h" run panel_js '
const fs = await import("node:fs/promises");
click((cx) => panel.loadEmoji(cx)); await settle();
await fs.rm(process.env.PHOME + "/.config/herdr-app/mods", { recursive: true });
click((cx) => panel.loadEmoji(cx)); await settle();
console.log(panel.glyphKind("👍"));'
  [ "$output" = "image" ]
}

@test "scroll: the log ends in a spacer row, which is what the log reveals, so the gap above the message box shows" {
  run grep -c 'id("panel-log").*\.pb(8)' "$(mod_dir)/panel.js"
  [ "$output" = "0" ]
  run grep -c 'id("panel-log-end")' "$(mod_dir)/panel.js"
  [ "$output" = "1" ]
}
