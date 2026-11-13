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

@test "panel: the mod files use no timer" {
  run grep -nE 'setTimeout|setInterval|timer\.' "$(mod_dir)/panel.js" "$(mod_dir)/chat.js"
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
console.log(chat.tellOutcome({ code: 1, stderr: "loh: hc send amy failed" }));
console.log(chat.tellOutcome({ code: 124, stderr: "" }), chat.tellOutcome({ code: 137, stderr: "" }), chat.tellOutcome({ code: null }), chat.tellOutcome(undefined));
console.log(chat.tellOutcome({ code: 10, stderr: "" }));'
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
  grep -A1 'track_scroll(this.scroll)' "$(mod_dir)/panel.js" | grep -q '^      \.children(log'
}

@test "panel: clicking a person selects the panel even when a terminal is docked" {
  grep -q 'this.panel.select(p.agent, cx); if (this.chat) this.open(p.agent, cx);' "$(mod_dir)/main.js"
}

@test "panel: a loh that cannot start says so and restores the text" {
  grep -q "could not run loh" "$(mod_dir)/panel.js"
  run grep -A14 "}).catch((e) => {" "$(mod_dir)/panel.js"
  [[ "$output" == *'rejectOutcome(Date.now() - began) === "failed"'* ]]
  [[ "$output" == *'st.set_value(text)'* ]]
  [[ "$output" == *'unknown();'* ]]
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
