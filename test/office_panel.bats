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
const el = () => new Proxy({}, { get: () => () => el() });
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
export const TextareaState = { new: () => { const s = { text: "", sets: [], set_value(v) { s.text = v; s.sets.push(v); }, replace(v) { s.text += v; }, value: () => s.text, on(e, h) { (s.handlers ||= {})[e] = h; return true; }, focus() {}, set_soft_wrap() {}, set_auto_grow(a, b) { s.grow = [a, b]; } }; return s; } };
export const ScrollHandle = { new: () => ({ scroll_to_item(i) { (globalThis.SCROLLS ||= []).push(i); } }) };
JS
  cat > "$d/node_modules/herdr/index.js" <<'JS'
export const terminals = () => [];
export const home = () => process.env.PHOME || "/nohome";
export const appHome = () => (process.env.PHOME || "/nohome") + "/.config/herdr-app";
export const exec = (c, a, o) => new Promise((resolve, reject) => {
  // `loh photos thumbs` answers at once (set globalThis.THUMBS to what it prints), so a test need not settle it by hand.
  if (a[0] === "photos") { (globalThis.THUMB_CALLS ||= []).push(a.join(" ")); resolve({ code: 0, stdout: globalThis.THUMBS || "thumbs: 0 made, 0 up to date (magick)\n" }); return; }
  (globalThis.CALLS ||= []).push({ c, a, resolve, reject });
});
JS
  echo '{"type":"module"}' > "$d/package.json"
  for f in panel chat crew draw photos; do sed -E 's#from "\./([a-z]+)\.js"#from "./\1.mjs"#' "$(mod_dir)/$f.js" > "$d/$f.mjs"; done
  cat > "$d/run.mjs" <<EOF
import { Panel } from "./panel.mjs";
const deadUses = [];
const dead = (what) => { deadUses.push(what); throw new Error("cx is no longer valid: it was captured during an earlier call and used later (" + what + ")"); };
const tasks = [], taskErrors = [];
const mkcx = () => {
  const cx = { alive: true,
    notify() { if (!cx.alive) dead("notify"); },
    stop_propagation() { (globalThis.STOPS ||= []).push(1); },
    write_to_clipboard(t) { (globalThis.CLIP ||= []).push(t); },
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
  [ "$output" = "[39,39,40]" ]
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
