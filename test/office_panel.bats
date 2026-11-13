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
JS
  cat > "$d/node_modules/gpui-base/index.js" <<'JS'
import { div } from "gpui-kit";
export const v_flex = div, h_flex = div, Input = { new: () => div() };
export const InputState = { new: () => { const s = { text: "", sets: [], set_value(v) { s.text = v; s.sets.push(v); }, value: () => s.text, on() {}, focus() {} }; return s; } };
export const ScrollHandle = { new: () => ({ scroll_to_item() {} }) };
JS
  cat > "$d/node_modules/herdr/index.js" <<'JS'
export const terminals = () => [];
export const exec = (c, a, o) => new Promise((resolve, reject) => { (globalThis.CALLS ||= []).push({ c, a, resolve, reject }); });
JS
  echo '{"type":"module"}' > "$d/package.json"
  for f in panel chat; do sed -E 's#from "\./([a-z]+)\.js"#from "./\1.mjs"#' "$(mod_dir)/$f.js" > "$d/$f.mjs"; done
  cat > "$d/run.mjs" <<EOF
import { Panel } from "./panel.mjs";
const deadUses = [];
const dead = (what) => { deadUses.push(what); throw new Error("cx is no longer valid: it was captured during an earlier call and used later (" + what + ")"); };
const tasks = [], taskErrors = [];
const mkcx = () => {
  const cx = { alive: true,
    notify() { if (!cx.alive) dead("notify"); },
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
