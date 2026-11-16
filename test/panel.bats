#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

# The chat panel's pure logic (office/crew-office/chat.js), checked with node.

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

# Run a JS snippet against chat.js. The file is copied to .mjs so older node
# versions treat it as an ES module. The snippet sees `chat`, the module.
chat_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/chat.js" "$BATS_TEST_TMPDIR/chat.mjs"
  node --input-type=module -e "import * as chat from '$BATS_TEST_TMPDIR/chat.mjs'; $1"
}

@test "panel: transcript and tell run loh in the agent's folder with the raw name" {
  run chat_js '
const a = { rawName: "scofield", cwd: "/ws/x" };
console.log(JSON.stringify(chat.transcriptCall(a, "/bin/loh", 30)));
console.log(JSON.stringify(chat.tellCall(a, undefined, "--force; rm -rf x")));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '{"cmd":"/bin/loh","args":["transcript","scofield","--last","30"],"options":{"cwd":"/ws/x","timeout":8000}}' ]
  [ "${lines[1]}" = '{"cmd":"loh","args":["tell","scofield","--force; rm -rf x"],"options":{"cwd":"/ws/x","timeout":75000}}' ]
}

@test "panel: parseTranscript reads what loh transcript prints for the fixture session" {
  command -v node >/dev/null || skip "node not installed"
  proj="$BATS_TEST_TMPDIR/projects/-ws"
  mkdir -p "$proj" "$BATS_TEST_TMPDIR/hcbin"
  cp "$REPO_ROOT/test/fixtures/transcripts/coordinator.jsonl" "$proj/s.jsonl"
  printf '#!/usr/bin/env bash\necho "{\\"state\\":\\"live\\",\\"cwd\\":\\"/ws\\",\\"argv\\":[\\"claude\\"]}"\n' >"$BATS_TEST_TMPDIR/hcbin/hc"
  chmod +x "$BATS_TEST_TMPDIR/hcbin/hc"
  PATH="$BATS_TEST_TMPDIR/hcbin:$PATH" LOH_CLAUDE_PROJECTS="$BATS_TEST_TMPDIR/projects" \
    "$REPO_ROOT/bin/loh" transcript scofield >"$BATS_TEST_TMPDIR/t.json"
  run chat_js '
import fs from "node:fs";
const t = chat.parseTranscript(fs.readFileSync("'"$BATS_TEST_TMPDIR"'/t.json", "utf8"));
console.log(t.map((m) => m.role[0] + ":" + m.text.split("\n")[0]).join("|"));
console.log(chat.parseTranscript("not json").length, chat.parseTranscript("{}").length, chat.parseTranscript(JSON.stringify([{role:"tool",text:"x"},{role:"user",text:""},{role:"user",text:"ok"}])).length);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "u:Hello coordinator, what is open?|a:Two tickets are open: api#2 and web#1.|u:Please merge api#2|a:web PR #5 squash-merged.|a:Merged." ]
  [ "${lines[1]}" = "0 0 1" ]
}

@test "panel: a sent message shows as pending until the transcript has it" {
  run chat_js '
const turns = [{ role: "user", text: "hi", ts: "" }, { role: "assistant", text: "hello", ts: "" }];
let r = chat.withPending(turns, [{ text: "merge it" }]);
console.log(r.shown.map((m) => m.text + (m.pending ? "*" : "")).join("|"), r.pending.length);
r = chat.withPending([...turns, { role: "user", text: "merge it", ts: "" }], [{ text: "merge it " }]);
console.log(r.shown.length, r.pending.length);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "hi|hello|merge it* 1" ]
  [ "${lines[1]}" = "3 0" ]
}

@test "panel: Send is off while the agent is blocked, and the reason names the dialog" {
  run chat_js '
const base = { name: "Amy", status: "blocked", kind: "permission" };
console.log(chat.sendBlock(base));
console.log(chat.sendBlock({ ...base, kind: "question" }));
console.log(JSON.stringify(chat.sendBlock({ ...base, status: "working" })), JSON.stringify(chat.sendBlock({ ...base, status: "idle" })));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Amy is waiting on a permission dialog. Answer it in the terminal; a typed message would answer it for you." ]
  [[ "${lines[1]}" == "Amy is waiting on a question."* ]]
  [ "${lines[2]}" = '"" ""' ]
}

@test "panel: tellError shows loh's own line without its prefix" {
  run chat_js '
console.log(chat.tellError({ code: 9, stderr: "loh: amy is blocked on a dialog; answer it in its terminal\n" }, "Amy"));
console.log(chat.tellError({ code: 3, stderr: "" }, "Amy"));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "amy is blocked on a dialog; answer it in its terminal" ]
  [ "${lines[1]}" = "could not send to Amy (loh exited 3)" ]
}

@test "panel: the activity feed records state changes and escalations, not the first look" {
  run chat_js '
const mk = (status, note = "", kind = null) => [{ address: "t1", name: "Amy", status, note, kind }];
let d = chat.activityDiff(new Map(), mk("working"), true);
console.log(d.events.length);
d = chat.activityDiff(d.seen, mk("working"), false);
console.log(d.events.length);
d = chat.activityDiff(d.seen, mk("blocked", "", "permission"), false);
console.log(d.events.map((e) => e.name + " " + e.text + " " + e.level).join("|"));
d = chat.activityDiff(d.seen, mk("done", "escalation:round 5 open"), false);
console.log(d.events.map((e) => e.text + " " + e.level).join("|"));
d = chat.activityDiff(d.seen, mk("done", "escalation:round 5 open"), false);
console.log(d.events.length);
let f = [];
for (let i = 0; i < 130; i++) f = chat.pushFeed(f, [{ name: "A", text: String(i), level: "info" }], "09:00");
console.log(f.length, f[0].text, f[99].text);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = "0" ]
  [ "${lines[2]}" = "Amy needs you (permission) blocked" ]
  [ "${lines[3]}" = "finished a turn done|escalates: round 5 open blocked" ]
  [ "${lines[4]}" = "0" ]
  [ "${lines[5]}" = "100 30 129" ]
}

@test "panel: the card shows the facts it has" {
  run chat_js '
const w = { working: "working", blocked: "needs you", done: "done", idle: "idle" };
console.log(JSON.stringify(chat.cardRows({ role: "coder", status: "blocked", kind: "question", repo: "api", ticket: "3", pr: "7", round: "2", step: "", note: "", withMatt: true }, w)));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["Role","coder"],["State","needs you (question)"],["Ticket","api#3"],["PR","7 · round 2"],["Lock","with Matt"]]' ]
}

@test "panel: main.js loads the panel and nothing in the mod sends with --force" {
  grep -q 'from "./panel.js"' "$(mod_dir)/main.js"
  run grep -n -- '--force' "$(mod_dir)/panel.js" "$(mod_dir)/chat.js"
  [ "$status" -ne 0 ]
}

@test "panel: the mod files use no repeating timer; the panel has one one-shot for the Copied label" {
  run grep -nE 'setTimeout|setInterval|timer\.every' "$(mod_dir)/panel.js" "$(mod_dir)/chat.js"
  [ "$status" -ne 0 ]
}

@test "panel: tell outlasts hc send's 60 s draft wait" {
  run chat_js 'console.log(chat.tellCall({ rawName: "a", cwd: "/x" }, "loh", "t").options.timeout > 60000)'
  [ "$output" = "true" ]
}

@test "panel: a cut-off send is unknown, a refusal from loh is failed" {
  run chat_js '
console.log(chat.tellOutcome({ code: 0, stderr: "" }));
console.log(chat.tellOutcome({ code: 9, stderr: "loh: amy is blocked\n" }));
console.log(chat.tellOutcome({ code: 1, stderr: "loh: cannot look up amy" }));
console.log(chat.tellOutcome({ code: 124, stderr: "" }), chat.tellOutcome({ code: 137, stderr: "" }), chat.tellOutcome({ code: null }), chat.tellOutcome(undefined));
console.log(chat.tellOutcome({ code: 10, stderr: "" }));
console.log(chat.tellOutcome({ code: 12, stderr: "loh: hc send amy failed (exit 3): x; the message may still have gone out" }));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "sent" ]
  [ "${lines[1]}" = "failed" ]
  [ "${lines[2]}" = "failed" ]
  [ "${lines[3]}" = "unknown unknown unknown unknown" ]
  [ "${lines[4]}" = "unknown" ]
}

@test "panel: another agent's message is labelled with its sender, not Matt" {
  run chat_js '
const t = chat.parseTranscript(JSON.stringify([
  { role: "user", text: "hi", ts: "" },
  { role: "agent", text: "PR merged", from: "whip", ts: "" },
  { role: "agent", text: "no sender", ts: "" },
  { role: "assistant", text: "ok", ts: "" }]));
console.log(t.map((m) => chat.speaker(m, "Scofield")).join("|"));
const r = chat.withPending(t, [{ text: "later", unsure: true }]);
console.log(r.shown[4].pending, r.shown[4].unsure, chat.speaker(r.shown[4], "Scofield"));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Matt|whip|another agent|Scofield" ]
  [ "${lines[1]}" = "true true Matt" ]
}

@test "panel: the log's turns are direct children of the scroll area" {
  # scroll_to_item reveals a direct child, so no wrapper may sit between the scroll div and the turns
  run grep -n 'overflow_y_scroll().track_scroll' "$(mod_dir)/panel.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *'v_flex().id("panel-log")'* ]]
  run grep -c 'track_scroll(this.scroll)$' "$(mod_dir)/panel.js"
  [ "$output" = "1" ]
  grep -A1 'track_scroll(this.scroll)' "$(mod_dir)/panel.js" | grep -q '^      \.children(rows'
}

@test "panel: clicking a person selects the panel even when a terminal is docked" {
  grep -q 'this.panel.select(p.agent, cx); if (this.chat) this.open(p.agent, cx);' "$(mod_dir)/main.js"
}

@test "panel: a quick rejection is a start failure, a late one may be a timeout" {
  run chat_js '
console.log(chat.rejectOutcome(0), chat.rejectOutcome(40), chat.rejectOutcome(4999));
console.log(chat.rejectOutcome(5000), chat.rejectOutcome(75000), chat.rejectOutcome(undefined), chat.rejectOutcome(-1));
console.log(chat.REJECT_QUICK_MS < chat.TELL_TIMEOUT);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "failed failed failed" ]
  [ "${lines[1]}" = "unknown unknown unknown unknown" ]
  [ "${lines[2]}" = "true" ]
}

@test "panel: only the turn loh flagged is the launch prompt, so a pasted turn of Matt's at the start of the window stays his" {
  run chat_js '
const wrapped = "<pasted_content id=\"fbdb\">\nYou are running in a herdr terminal.\n\nLoad these skills first.\n</pasted_content id=\"fbdb\">";
const flagged = chat.parseTranscript(JSON.stringify([
  { role: "user", text: wrapped, launch: true }, { role: "assistant", text: "ok" }, { role: "user", text: "Hey" }]));
console.log(flagged.map((m) => !!m.launch).join(","));
console.log(chat.speaker(flagged[0], "Scofield"), "|", chat.speaker(flagged[2], "Scofield"));
console.log(chat.shownText(flagged[0]));
console.log(chat.shownText(flagged[2]));
// The window starts after the launch prompt, with a long paste of Matt'"'"'s: no flag, so it is his.
const late = chat.parseTranscript(JSON.stringify([
  { role: "user", text: "<pasted_content id=\"x\">my notes</pasted_content id=\"x\">" }, { role: "assistant", text: "ok" }]));
console.log(late[0].launch, chat.speaker(late[0], "Scofield"), chat.shownText(late[0]));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "true,false,false" ]
  [ "${lines[1]}" = "launch prompt | Matt" ]
  [ "${lines[2]}" = "You are running in a herdr terminal. Load these skills first." ]
  [ "${lines[3]}" = "Hey" ]
  [ "${lines[4]}" = 'false Matt <pasted_content id="x">my notes</pasted_content id="x">' ]
}

@test "panel: a turn that came via Discord keeps the field and gets a via Discord mark" {
  run chat_js '
const t = chat.parseTranscript(JSON.stringify([{role:"user",text:"hi",ts:"",via:"discord"},{role:"user",text:"yo",ts:""},{role:"user",text:"x",via:"<b>"}]));
console.log(t.map((m) => JSON.stringify(chat.viaMark(m))).join("|"));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '" · via Discord"|""|""' ]
}

@test "panel: a message over 1200 characters is shown whole" {
  run chat_js '
const long = "word ".repeat(600).trim();
const m = { role: "assistant", text: long, ts: "" };
console.log(long.length, chat.shownText(m).length, chat.shownText(m) === long);'
  [ "$status" -eq 0 ]
  [ "$output" = "2999 2999 true" ]
}

@test "panel: Enter sends, Ctrl+Enter adds a line, other chords do nothing" {
  run chat_js '
const k = (key, mods = {}) => chat.enterAction({ key, modifiers: { shift: false, control: false, alt: false, platform: false, function: false, ...mods } });
console.log(k("enter"), k("enter", { control: true }), k("enter", { shift: true }), k("enter", { alt: true }), k("a"), k("a", { control: true }));'
  [ "$status" -eq 0 ]
  [ "$output" = "send newline null null null null" ]
}

@test "panel: turns of one speaker within 7 minutes are grouped, others start a new group" {
  run chat_js '
const t = (min) => new Date(Date.UTC(2026, 10, 15, 10, min)).toISOString();
const turns = [
  { role: "assistant", text: "a", ts: t(0) }, { role: "assistant", text: "b", ts: t(6) },
  { role: "assistant", text: "c", ts: t(14) },
  { role: "user", text: "d", ts: t(15) }, { role: "user", text: "e", ts: t(16) },
  { role: "assistant", text: "f", ts: t(17) },
  { role: "agent", from: "amy", text: "g", ts: t(18) }, { role: "agent", from: "yoda", text: "h", ts: t(19) },
  { role: "user", text: "i", ts: "", pending: true }];
console.log(chat.groupLog(turns, "Scofield").map((r) => (r.head ? "H" : "-")).join(""));'
  [ "$status" -eq 0 ]
  [ "$output" = "H-HH-HHHH" ]
}

@test "panel: a Discord turn after a typed one starts a group, two Discord turns in a row stay grouped" {
  run chat_js '
const t = (min) => new Date(Date.UTC(2026, 10, 16, 6, min)).toISOString();
const turns = [
  { role: "user", text: "typed", ts: t(0), via: "" }, { role: "user", text: "d1", ts: t(1), via: "discord" },
  { role: "user", text: "d2", ts: t(2), via: "discord" }, { role: "user", text: "typed2", ts: t(3), via: "" }];
console.log(chat.groupLog(turns, "Scofield").map((r) => (r.head ? "H" : "-")).join(""));'
  [ "$status" -eq 0 ]
  [ "$output" = "HH-H" ]
}

@test "panel: Copy puts the whole message on the clipboard, Copy all the turns shown with speaker and time" {
  run chat_js '
const turns = [{ role: "user", text: "Hi **there**", ts: "2026-11-15T10:05:00" }, { role: "assistant", text: "a\n\n- b", ts: "" }, { role: "user", text: "later", ts: "", pending: true }];
console.log(JSON.stringify(chat.copyText(turns[1])));
console.log(JSON.stringify(chat.copyAll(turns, "Scofield")));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '"a\n\n- b"' ]
  [ "${lines[1]}" = '"Matt · 10:05\nHi **there**\n\nScofield\na\n\n- b\n\nMatt\nlater"' ]
}

@test "panel: markdown goes to the text view as written, with nothing dropped or added" {
  run chat_js '
const md = "**bold** `code`\n\n```js\nlet a = 1;\n```\n\n- one\n- two\n\n| a | b |\n|---|---|\n\n<div>raw</div> ~~x~~";
console.log(chat.markdownOf({ role: "assistant", text: md }) === md);
console.log(JSON.stringify(chat.markdownOf({ role: "user", text: "  hi  ", launch: false })));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "true" ]
  [ "${lines[1]}" = '"hi"' ]
}

@test "panel: the activity list opens with the office-opened row and keeps every change in order" {
  run chat_js '
console.log(JSON.stringify(chat.feedRows([])));
console.log(JSON.stringify(chat.feedRows([{ at: "10:01", name: "Amy", text: "is idle", level: "info" }, { at: "10:02", name: "Sucre", text: "needs you (permission)", level: "blocked" }])));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '[{"at":"","text":"Office opened. Changes before this are not shown.","level":"info"}]' ]
  [ "${lines[1]}" = '[{"at":"","text":"Office opened. Changes before this are not shown.","level":"info"},{"at":"10:01","text":"Amy is idle","level":"info"},{"at":"10:02","text":"Sucre needs you (permission)","level":"blocked"}]' ]
}

@test "panel: the tab badge counts blocked agents and is empty when none are" {
  run chat_js '
console.log(chat.blockedCount([{ status: "blocked" }, { status: "idle" }, { status: "blocked" }]), chat.blockedCount([{ status: "done" }]));'
  [ "$status" -eq 0 ]
  [ "$output" = "2 0" ]
}

@test "panel: the hint and the block messages say how to send" {
  run chat_js 'console.log(chat.SEND_HINT);'
  [ "$output" = "Enter sends · Ctrl+Enter adds a line" ]
}

@test "panel: a turn keeps its key when the window slides, and identical turns get different keys" {
  run chat_js '
const mk = (t, min) => ({ role: "assistant", text: t, ts: "2026-11-15T10:0" + min + ":00Z" });
const full = [mk("a", 0), mk("b", 1), mk("b", 1), mk("c", 2)];
const slid = full.slice(1);
const k1 = chat.groupLog(full, "S").map((r) => r.key), k2 = chat.groupLog(slid, "S").map((r) => r.key);
console.log(k2.every((k, i) => k === k1[i + 1]), new Set(k1).size === 4);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true" ]
}

@test "panel: the space between turns is Maya's: 16 new speaker, 4 grouped, bands 8 above and below" {
  run chat_js '
const T = (role, min, extra = {}) => ({ role, text: "x" + min, ts: new Date(Date.UTC(2026, 10, 15, 10, min)).toISOString(), ...extra });
const log = chat.groupLog([T("assistant", 0), T("assistant", 1), T("user", 2), T("user", 3), T("assistant", 4), T("user", 30)], "Scofield");
const sp = log.map((_, i) => chat.rowSpace(log, i));
// What sits between the content of row i-1 and row i: the row above ends pb inside its band, then mt outside, then pt inside.
const gaps = sp.slice(1).map((r, k) => sp[k].pb + r.mt + r.pt);
console.log(JSON.stringify(log.map((r) => r.head)), JSON.stringify(gaps));
console.log(JSON.stringify(sp.map((r) => [r.mt, r.pt, r.pb])));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '[true,false,true,false,true,true] [4,16,4,16,16]' ]
  [ "${lines[1]}" = '[[0,8,0],[0,4,0],[8,8,0],[0,4,8],[0,8,0],[8,8,8]]' ]
}

@test "panel: a turn's avatar is the floor figure of whoever wrote it" {
  run chat_js '
const a = { rawName: "scofield", name: "Scofield" };
console.log(chat.avatarName({ role: "user" }, a), chat.avatarName({ role: "assistant" }, a), chat.avatarName({ role: "agent", from: "Amy" }, a), JSON.stringify(chat.avatarName({ role: "agent" }, a)));'
  [ "$status" -eq 0 ]
  [ "$output" = 'matt scofield amy ""' ]
}
