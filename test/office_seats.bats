#!/usr/bin/env bats
# Where each person sits or stands by what their session is doing (ticket #26): the rows of Matt's table,
# the idle time, and the rule that someone keeps their spot while they are in a room.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

# JS helper text. `play` runs one memory through a list of renders, [ms, terminals, options], and gives the last layout.
# Times are in seconds here (s) so a test reads like the table.
HELPERS='
const T = (name, status, labels = {}, extra = {}) => ({address: "t-" + name, name, state: "live", status, cwd: "/ws/" + name, labels: {crew: "w", ...labels}, ...extra});
// Someone who is simply away (idle too long, cleared, Matt away) is in the lounge, or the kitchen when stand-ins fill the lounge: both read "lounge" here.
const P = (L, id) => { const p = L.people.find((q) => q.id === id); const away = p.mode === "away" || p.mode === "lounge" || p.mode === "deskfree" || p.mode === "desk" || p.state === "away"; return away && p.place === "kitchen" ? { ...p, place: "lounge" } : p; };
const at = (L, id) => { const p = P(L, id); return [p.place, p.desk || "-"].join(":"); };
const play = (steps, repos = ["api", "web"], aspect = 0) => {
  const mem = crew.newMemory(); const out = [];
  for (const [s, ts, o] of steps) out.push(crew.layoutCrew(crew.crewOf(ts, "w"), repos, aspect, {mem, now: s * 1000, ...o}));
  return out;
};
const last = (a) => a[a.length - 1];
'

@test "idle time is 3 minutes by default" {
  run crew_js "$HELPERS"'console.log(crew.IDLE_MS, crew.idleMsOf(undefined), crew.idleMsOf(5), crew.idleMsOf("2"), crew.idleMsOf(0), crew.idleMsOf("x"), crew.idleMsOf(-1));'
  [ "$status" -eq 0 ]
  [ "$output" = "180000 180000 300000 120000 180000 180000 180000" ]
}

@test "the idle setting is read from loh status --settings" {
  run crew_js "$HELPERS"'console.log(crew.idleMinutesOf("{\"idle_minutes\":7}"), crew.idleMinutesOf("{}"), crew.idleMinutesOf("nope"), crew.settingsCall({cwd: "/ws"}, "/bin/loh").args.join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "7 undefined undefined status --settings" ]
}

@test "Scofield and Amy stay at their desks after a turn ends, and leave only after the idle time" {
  run crew_js "$HELPERS"'
const w = [T("scofield", "working", {role: "coordinator"}), T("amy", "working", {role: "reviewer"})];
const d = [T("scofield", "done", {role: "coordinator"}), T("amy", "idle", {role: "reviewer"})];
const a = play([[0, w], [10, d], [10 + 179, d], [10 + 180, d]]);
console.log(a.map((L) => at(L, "scofield") + "/" + at(L, "amy")).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk:scofield/desk:amy desk:scofield/desk:amy desk:scofield/desk:amy lounge:-/lounge:-" ]
}

@test "after the idle time a person goes to the lounge, with a mug, whether their last turn is done or idle" {
  run crew_js "$HELPERS"'
const w = [T("scofield", "working", {role: "coordinator"}), T("amy", "working", {role: "reviewer"})];
const d = [T("scofield", "done", {role: "coordinator"}), T("amy", "idle", {role: "reviewer"})];
const L = last(play([[0, w], [10, d], [200, d]]));
console.log(P(L, "scofield").mug, P(L, "amy").mug, P(L, "scofield").desk, L.screens.scofield);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true null undefined" ]
}

@test "the idle time counts from when the turn ended, and done turning idle does not restart it" {
  run crew_js "$HELPERS"'
const w = [T("scofield", "working", {role: "coordinator"})];
const a = play([[0, w], [100, [T("scofield", "done", {role: "coordinator"})]], [150, [T("scofield", "idle", {role: "coordinator"})]], [279, [T("scofield", "idle", {role: "coordinator"})]], [280, [T("scofield", "idle", {role: "coordinator"})]]]);
console.log(a.map((L) => P(L, "scofield").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk desk desk desk lounge" ]
}

@test "a person first seen idle, with herdr's time for the change (status_ms), counts the idle time from then" {
  run crew_js "$HELPERS"'
const mk = (ms) => [T("amy", "idle", {role: "reviewer"}, {status_ms: ms})];
const a = play([[1000, mk(1000 * 1000 - 200000)]]);
const b = play([[1000, mk(1000 * 1000 - 100000)]]);
const c = play([[1000, mk(undefined)]]);
console.log(P(a[0], "amy").place, P(b[0], "amy").place, P(c[0], "amy").place, crew.crewOf(mk(5), "w")[0].statusMs);'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge desk desk 5" ]
}

@test "a blocked person stays at the desk however long it lasts" {
  run crew_js "$HELPERS"'
const b = [T("scofield", "blocked", {role: "coordinator"}, {report: {kind: "question"}})];
const L = last(play([[0, b], [3600, b]]));
console.log(at(L, "scofield"), P(L, "scofield").state, P(L, "scofield").kind);'
  [ "$status" -eq 0 ]
  [ "$output" = "desk:scofield blocked question" ]
}

@test "work starting again sends someone who left back to the desk" {
  run crew_js "$HELPERS"'
const i = [T("amy", "idle", {role: "reviewer"})], w = [T("amy", "working", {role: "reviewer"})];
const a = play([[0, i], [200, i], [210, w]]);
console.log(a.map((L) => P(L, "amy").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk lounge desk" ]
}

@test "the idle time is a setting: a shorter one sends people away sooner" {
  run crew_js "$HELPERS"'
const i = [T("amy", "idle", {role: "reviewer"})];
const a = play([[0, i, {idleMs: 60000}], [59, i, {idleMs: 60000}], [60, i, {idleMs: 60000}]]);
console.log(a.map((L) => P(L, "amy").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk desk lounge" ]
}

@test "Yoda and Sara sit at the meeting table until idle for the idle time, then go to the lounge" {
  run crew_js "$HELPERS"'
const ts = [T("yoda", "done", {role: "advisor"}), T("sara", "idle", {role: "teacher"})];
const a = play([[0, ts], [179, ts], [180, ts]]);
console.log(a.map((L) => P(L, "yoda").place + "/" + P(L, "sara").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "meeting/meeting meeting/meeting lounge/lounge" ]
}

@test "a coder with a ticket and no PR stays at its desk when its turn ends, for as long as it lasts" {
  run crew_js "$HELPERS"'
const w = [T("sucre", "working", {role: "coder", task: "api#4"})], d = [T("sucre", "done", {role: "coder", task: "api#4"})];
const a = play([[0, w], [5, d], [5000, d]]);
console.log(a.map((L) => at(L, "sucre")).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk:repo:api:1 desk:repo:api:1 desk:repo:api:1" ]
}

@test "a coder with no ticket sits at a free desk after its turn, and goes to the lounge after the idle time" {
  run crew_js "$HELPERS"'
const w = [T("zed", "working", {role: "coder"})], d = [T("zed", "done", {role: "coder"})];
const a = play([[0, w], [5, d], [184, d], [185, d]]);
console.log(a.map((L) => P(L, L.people.find((p) => p.agent).id).place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk desk desk lounge" ]
}

@test "a coder waiting on a review of its PR is in the kitchen with a mug" {
  run crew_js "$HELPERS"'
const w = [T("sucre", "working", {role: "coder", task: "api#4"})];
const d = [T("sucre", "done", {role: "coder", task: "api#4", pr: "9", round: "1"})];
const a = play([[0, w], [5, d]]);
const p = P(last(a), "sucre");
console.log(at(a[0], "sucre"), p.place, p.mug, p.desk, p.paddle);'
  [ "$status" -eq 0 ]
  [ "$output" = "desk:repo:api:1 kitchen true repo:api:1 0" ]
}

@test "a waiting coder takes up ping pong about 15 s after it sits down, and keeps its desk" {
  run crew_js "$HELPERS"'
const d = [T("sucre", "idle", {role: "coder", task: "api#4", pr: "9", round: "1"})];
const a = play([[0, d], [14, d], [25, d], [40, d]]);
console.log(a.map((L) => P(L, "sucre").place).join(" "), P(last(a), "sucre").paddle !== 0, P(last(a), "sucre").mug);'
  [ "$status" -eq 0 ]
  [ "$output" = "kitchen kitchen pong pong true false" ]
}

@test "a coder who waits goes to ping pong after 2 s when someone is alone at the table" {
  run crew_js "$HELPERS"'
const esc = T("whip", "idle", {role: "coder", task: "web#2", pr: "5", note: "escalation:stuck"});
const w = T("sucre", "idle", {role: "coder", task: "api#4", pr: "9", round: "1"});
const a = play([[0, [esc, w]], [3, [esc, w]], [20, [esc, w]]]);
console.log(a.map((L) => P(L, "whip").place + "/" + P(L, "sucre").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "pong/kitchen pong/kitchen pong/pong" ]
}

@test "two coders waiting on reviews play ping pong with each other, and a rally starts" {
  run crew_js "$HELPERS"'
const ts = [T("sucre", "done", {role: "coder", task: "api#4", pr: "9", round: "1"}), T("mahone", "done", {role: "coder", task: "api#5", pr: "10", round: "1"})];
const L = last(play([[0, ts], [40, ts], [50, ts]]));
console.log(P(L, "sucre").place, P(L, "mahone").place, L.rally);'
  [ "$status" -eq 0 ]
  [ "$output" = "pong pong true" ]
}

@test "a coder escalated to Matt (its note starts with escalation:) is at ping pong at once" {
  run crew_js "$HELPERS"'
const ts = [T("sucre", "idle", {role: "coder", task: "api#4", pr: "9", note: "escalation:stuck"})];
const L = last(play([[0, ts]]));
console.log(P(L, "sucre").place, P(L, "sucre").paddle !== 0, P(L, "sucre").desk);'
  [ "$status" -eq 0 ]
  [ "$output" = "pong true repo:api:1" ]
}

@test "after an escalation is answered (the prompt removes the note), the coder is at its desk, then waiting in the kitchen, not at ping pong at once" {
  run crew_js "$HELPERS"'
const c = (st, l) => [T("sucre", st, {role: "coder", task: "api#4", ...l})];
const esc = c("done", {pr: "9", round: "2", note: "escalation:stuck"});
const answered = c("working", {pr: "9", round: "2"});
const pushed = c("done", {pr: "9", round: "3"});
const a = play([[0, esc], [10, answered], [100, pushed], [102, pushed], [130, pushed]]);
console.log(a.map((L) => P(L, "sucre").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "pong desk kitchen kitchen pong" ]
}

@test "a coder with a ticket and no PR who escalated and was answered stays at its desk after its next turn" {
  run crew_js "$HELPERS"'
const c = (st, l) => [T("sucre", st, {role: "coder", task: "api#4", ...l})];
const a = play([[0, c("done", {note: "escalation:need a decision"})], [10, c("working", {})], [100, c("done", {})], [400, c("done", {})]]);
console.log(a.map((L) => P(L, "sucre").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "pong desk desk desk" ]
}

@test "a coder who works again after its review comes back goes to its desk" {
  run crew_js "$HELPERS"'
const d = [T("sucre", "idle", {role: "coder", task: "api#4", pr: "9", round: "1"})], w = [T("sucre", "working", {role: "coder", task: "api#4", pr: "9", round: "2"})];
const a = play([[0, d], [60, d], [70, w]]);
console.log(a.map((L) => P(L, "sucre").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "kitchen pong desk" ]
}

@test "someone compacting is in the rest room, and goes back to the desk when it is done" {
  run crew_js "$HELPERS"'
const w = [T("sucre", "working", {role: "coder", task: "api#4"})], c = [T("sucre", "working", {role: "coder", task: "api#4", ctx: "compact"})];
const a = play([[0, w], [10, c], [100, c], [110, w]]);
console.log(a.map((L) => P(L, "sucre").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk rest rest desk" ]
}

@test "Scofield compacting goes to the rest room and comes back to his desk, even after a long compaction" {
  run crew_js "$HELPERS"'
const w = [T("scofield", "working", {role: "coordinator"})], c = [T("scofield", "working", {role: "coordinator", ctx: "compact"})];
const a = play([[0, w], [10, c], [500, c], [501, w]]);
console.log(a.map((L) => at(L, "scofield")).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk:scofield rest:- rest:- desk:scofield" ]
}

@test "after a clear someone rests a few seconds, then goes to the lounge whatever their ticket" {
  run crew_js "$HELPERS"'
const w = [T("sucre", "idle", {role: "coder", task: "api#4", pr: "9", round: "1"})], c = [T("sucre", "idle", {role: "coder", task: "api#4", pr: "9", round: "1", ctx: "clear"})];
const a = play([[0, w], [10, c], [13, c], [15, c], [200, c]]);
console.log(a.map((L) => P(L, "sucre").place).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "kitchen rest rest lounge lounge" ]
}

@test "the rest room is not an overflow room: a crowd of done people never stands in it" {
  run crew_js "$HELPERS"'
const ts = Array.from({length: 12}, (_, i) => T("z" + i, "idle", {role: "coder"}));
const L = last(play([[0, ts], [300, ts]]));
const rest = L.people.filter((p) => p.place === "rest").length;
console.log(rest, L.people.filter((p) => p.agent && p.place !== "desk").length);'
  [ "$status" -eq 0 ]
  [ "$output" = "0 12" ]
}

@test "a person with no session is in the lounge, as before" {
  run crew_js "$HELPERS"'
const L = last(play([[0, []]]));
console.log(P(L, "scofield").place, P(L, "amy").place, P(L, "scofield").running, P(L, "scofield").dim);'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge lounge false true" ]
}

@test "Matt is at his desk while he is typing and in the lounge, away, when he is not" {
  run crew_js "$HELPERS"'
const a = play([[0, [], {mattTyping: true}], [10, [], {mattTyping: false}], [20, [], {mattTyping: true}]]);
const f = (L) => { const m = P(L, "matt"); return [m.place, m.state, m.desk, m.mug].join(":"); };
console.log(a.map(f).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "matt:matt:matt:false lounge:away::true matt:matt:matt:false" ]
}

@test "a spot in a room is kept while the person is in it: someone leaving or joining moves only themselves" {
  run crew_js "$HELPERS"'
const mk = (n) => T(n, "idle", {role: "coder"});
const ids = ["k1", "k2"];
const all = ids.map(mk);
const pos = (L, list) => list.map((id) => P(L, "x:t-" + id).x + "," + P(L, "x:t-" + id).y).join(" ");
// Two idle coders with no ticket: all in the lounge or the kitchen after the idle time. Then one leaves, one joins.
const base = (list) => pos(play([[0, all], [200, all]])[1], list);
const withLeft = (gone) => play([[0, all], [200, all], [201, all.filter((a) => a.name !== gone)]]);
const out = [];
for (const gone of ids) { const rest = ids.filter((i) => i !== gone); out.push(base(rest) === pos(last(withLeft(gone)), rest)); }
const joined = play([[0, all], [200, all], [201, [mk("k0"), ...all]]]);
out.push(base(ids) === pos(last(joined), ids));
console.log(out.every(Boolean), out.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true 3" ]
}

@test "a waiting coder who gets a spot in the kitchen keeps it when another waiting coder leaves or arrives" {
  run crew_js "$HELPERS"'
const mk = (n, i) => T(n, "done", {role: "coder", task: "api#" + i, pr: "1", round: "1"});
const names = ["a1", "b2", "c3"];
const all = names.map(mk);
const pos = (L, list) => list.map((id) => P(L, "x:t-" + id).x + "," + P(L, "x:t-" + id).y).join(" ");
const base = (list) => pos(play([[0, all], [5, all]])[1], list);
const out = [];
for (const gone of names) { const rest = names.filter((n) => n !== gone); out.push(base(rest) === pos(last(play([[0, all], [5, all], [6, all.filter((a) => a.name !== gone)]])), rest)); }
console.log(out.every(Boolean), out.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true 3" ]
}

@test "everyone keeps their spot, people with no session included, when one person arrives, leaves or changes room" {
  run crew_js "$HELPERS"'
const pos = (L) => Object.fromEntries(L.people.filter((p) => p.id !== "dog").map((p) => [p.id, p.place + "@" + p.x + "," + p.y]));
const moved = (a, b, who) => Object.keys(a).filter((k) => k !== who && a[k] !== b[k]);
const out = [];
// Scofield goes idle past the idle time: nobody else moves (the lounge holds the stand-ins).
{ const t = [T("scofield", "done", {role: "coordinator"}), T("sucre", "working", {role: "coder", task: "api#1"})];
  const L = play([[0, t], [1, t], [200, t]]); out.push(moved(pos(L[1]), pos(L[2]), "scofield").length); }
// A coder joins, a coder leaves.
{ const base = [T("whip", "working", {role: "coder", task: "web#1"}), T("sucre", "working", {role: "coder", task: "api#2"})];
  const joined = [...base, T("mahone", "working", {role: "coder", task: "api#3"})];
  const a = play([[0, base], [1, joined]]); out.push(moved(pos(a[0]), pos(a[1]), "mahone").length);
  const b = play([[0, joined], [1, base]]); out.push(moved(pos(b[0]), pos(b[1]), "mahone").length); }
// A waiting coder in the kitchen goes back to work.
{ const mk = (st) => [1, 2].map((i) => T("z" + i, i === 2 ? st : "done", {role: "coder", task: "api#" + i, pr: String(i)}));
  const L = play([[0, mk("done")], [5, mk("done")], [6, mk("working")]]); out.push(moved(pos(L[1]), pos(L[2]), "x:t-z2").length); }
console.log(out.join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "0 0 0 0" ]
}

@test "desks are kept: a coder who joins a repo does not move the coders already at its desks" {
  run crew_js "$HELPERS"'
const mk = (n, repo) => T(n, "working", {role: "coder", task: repo + "#" + n.length});
const before = [mk("sucre", "api"), mk("whip", "api")];
const after = [mk("aaron", "api"), mk("sucre", "api"), mk("whip", "api")];
const a = play([[0, before], [1, after]]);
console.log(at(a[0], "sucre"), at(a[0], "whip"), at(a[1], "sucre"), at(a[1], "whip"), at(a[1], "x:t-aaron"));'
  [ "$status" -eq 0 ]
  [ "$output" = "desk:repo:api:1 desk:repo:api:2 desk:repo:api:1 desk:repo:api:2 desk:repo:api:3" ]
}

@test "the mod prop sets the idle time before the workspace setting does, and a bad prop falls back to the setting" {
  run crew_js "$HELPERS"'console.log(crew.pickIdleMs(5, 10), crew.pickIdleMs("2", 10), crew.pickIdleMs(undefined, 10), crew.pickIdleMs(0, 10), crew.pickIdleMs("x", undefined), crew.pickIdleMs(undefined, undefined));'
  [ "$status" -eq 0 ]
  [ "$output" = "300000 120000 600000 600000 180000 180000" ]
}

@test "Matt is typing until 20 s after his last sign, and focus counts only when it arrives on a terminal opened from the office" {
  run crew_js "$HELPERS"'
const t = crew.TYPING_HOLD;
console.log(t, crew.mattTypingAt(1000, 1000 + t), crew.mattTypingAt(1000 + t, 1000 + t), crew.mattTypingAt(1000, 0),
  crew.focusArrived("t5", null, ["t5"]), crew.focusArrived("t5", "t5", ["t5"]), crew.focusArrived("t6", "t5", ["t5"]), crew.focusArrived(null, "t5", ["t5"]));'
  [ "$status" -eq 0 ]
  [ "$output" = "20000 true false false true false false false" ]
}

@test "layout reports how long until the next change that time alone causes" {
  run crew_js "$HELPERS"'
const i = [T("amy", "idle", {role: "reviewer"})];
const a = play([[0, i], [100, i], [181, i]]);
console.log(a[0].wakeIn, a[1].wakeIn, a[2].wakeIn);'
  [ "$status" -eq 0 ]
  [ "$output" = "180000 80000 null" ]
}
