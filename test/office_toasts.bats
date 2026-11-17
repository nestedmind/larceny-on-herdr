#!/usr/bin/env bats
# The office's toasts (ticket #93): which events raise one, their text, kind and order, how many show and for how long.
# The model is in crew.js (toastStep); main.js draws it (office_main.bats).

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $HELPERS $1"
}

HELPERS='
const T = (name, status, labels = {}) => ({address: "t-" + name, name, state: "live", status, cwd: "/ws/" + name, labels: {crew: "w", role: "coder", ...labels}});
const working = (name, labels) => T(name, {state: "working"}, labels);
const blocked = (name, kind, msg) => T(name, {state: "blocked", kind, msg});
const agents = (...ts) => crew.crewOf(ts, "w");
const show = (l) => l.map((x) => [x.kind, x.head, x.body, x.who].join("|")).join(";");
'

@test "the first look at the crew raises nothing, even for an agent that is already blocked or has escalated" {
  run crew_js '
const m = crew.newToasts();
const r = crew.toastStep(m, agents(blocked("sucre", "permission", "Bash: ls"), working("sheba", {note: "escalation:stuck"})), 0);
console.log(r.list.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "an agent that becomes blocked on a permission raises a perm toast with its name, the kind and the whole message" {
  run crew_js '
const m = crew.newToasts();
crew.toastStep(m, agents(working("sucre")), 0);
const r = crew.toastStep(m, agents(blocked("sucre", "permission", "Bash: rm -rf build")), 10);
console.log(show(r.list));'
  [ "$status" -eq 0 ]
  [ "$output" = "perm|Sucre needs you|permission: Bash: rm -rf build|t-sucre" ]
}

@test "a question is a q toast, and a block of another kind is a q toast with just the message" {
  run crew_js '
const m = crew.newToasts();
crew.toastStep(m, agents(working("amy"), working("sucre")), 0);
const r = crew.toastStep(m, agents(blocked("amy", "question", "Which branch?"), blocked("sucre", "other", "waiting")), 10);
console.log(show(r.list));'
  [ "$status" -eq 0 ]
  [ "$output" = "q|Sucre needs you|waiting|t-sucre;q|Amy needs you|question: Which branch?|t-amy" ]
}

@test "the same block seen again raises no second toast, a new block after it ended raises one" {
  run crew_js '
const m = crew.newToasts();
crew.toastStep(m, agents(working("sucre")), 0);
crew.toastStep(m, agents(blocked("sucre", "question", "A?")), 10);
const again = crew.toastStep(m, agents(blocked("sucre", "question", "A?")), 20);
crew.toastStep(m, agents(working("sucre")), 30);
const next = crew.toastStep(m, agents(blocked("sucre", "question", "B?")), 40);
console.log(again.list.length, next.list.length, next.list[0].body);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 2 question: B?" ]
}

@test "an escalation note raises an esc toast with the whole note, not cut at the card's 60 characters" {
  run crew_js '
const note = "escalation:" + "x".repeat(100);
const m = crew.newToasts();
crew.toastStep(m, agents(working("sucre")), 0);
const r = crew.toastStep(m, agents(working("sucre", {note})), 10);
console.log(r.list[0].kind, r.list[0].head, r.list[0].body.length, r.list[0].body === "x".repeat(100));'
  [ "$status" -eq 0 ]
  [ "$output" = "esc Sucre escalates 100 true" ]
}

@test "an undelivered note raises an info toast; a note that is neither raises none; the same note twice raises one" {
  run crew_js '
const m = crew.newToasts();
crew.toastStep(m, agents(working("sucre")), 0);
const a = crew.toastStep(m, agents(working("sucre", {note: "reading the ticket"})), 10);
const b = crew.toastStep(m, agents(working("sucre", {note: "undelivered:amy: she has finished"})), 20);
const c = crew.toastStep(m, agents(working("sucre", {note: "undelivered:amy: she has finished"})), 30);
console.log(a.list.length, show(b.list), c.list.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "0 info|Sucre's message was not delivered|amy: she has finished|t-sucre 1" ]
}

@test "a second, different escalation from the same agent raises a second toast" {
  run crew_js '
const m = crew.newToasts();
crew.toastStep(m, agents(working("sucre", {note: "escalation:one"})), 0);
crew.toastStep(m, agents(working("sucre", {note: "escalation:two"})), 10);
const r = crew.toastStep(m, agents(working("sucre", {note: "escalation:three"})), 20);
console.log(r.list.map((x) => x.body).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "three,two" ]
}

@test "at most 3 toasts show, the newest first, and a fourth pushes out the oldest" {
  run crew_js '
const m = crew.newToasts();
const names = ["amy", "bo", "cy", "di"];
crew.toastStep(m, agents(...names.map((n) => working(n))), 0);
const r = crew.toastStep(m, agents(...names.map((n) => blocked(n, "permission", "go " + n))), 10);
console.log(r.list.map((x) => x.who).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "t-di,t-cy,t-bo" ]
}

@test "a toast goes 7 s after it came, and the step says when the next one goes" {
  run crew_js '
const m = crew.newToasts();
crew.toastStep(m, agents(working("amy"), working("bo")), 0);
const a = crew.toastStep(m, agents(blocked("amy", "question", "A?"), working("bo")), 1000);
const b = crew.toastStep(m, agents(blocked("amy", "question", "A?"), blocked("bo", "question", "B?")), 3000);
const c = crew.toastStep(m, agents(blocked("amy", "question", "A?"), blocked("bo", "question", "B?")), 8000);
const d = crew.toastStep(m, agents(blocked("amy", "question", "A?"), blocked("bo", "question", "B?")), 10000);
const e = crew.toastStep(m, agents(blocked("amy", "question", "A?"), blocked("bo", "question", "B?")), 10001);
console.log(a.nextMs, b.list.length, b.nextMs, c.list.length, c.nextMs, d.list.length, d.nextMs, e.list.length, e.nextMs);'
  [ "$status" -eq 0 ]
  [ "$output" = "7000 2 5000 1 2000 0 null 0 null" ]
}

@test "dismissing a toast removes just that one" {
  run crew_js '
const m = crew.newToasts();
crew.toastStep(m, agents(working("amy"), working("bo")), 0);
const r = crew.toastStep(m, agents(blocked("amy", "question", "A?"), blocked("bo", "question", "B?")), 10);
crew.toastDismiss(m, r.list[0].id);
console.log(m.list.map((x) => x.who).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "t-amy" ]
}

@test "a merge toast (ticket #70) is a done toast: the model takes one from outside, with the same limits" {
  run crew_js '
const m = crew.newToasts();
crew.toastStep(m, agents(working("amy")), 0);
crew.toastPush(m, {kind: "done", head: "api PR #4 merged", body: "sucre closed #12", who: "t-sucre"}, 100);
const r = crew.toastStep(m, agents(working("amy")), 200);
console.log(show(r.list));'
  [ "$status" -eq 0 ]
  [ "$output" = "done|api PR #4 merged|sucre closed #12|t-sucre" ]
}

@test "an agent that goes away is forgotten, so coming back blocked raises a toast again" {
  run crew_js '
const m = crew.newToasts();
crew.toastStep(m, agents(working("amy")), 0);
crew.toastStep(m, agents(blocked("amy", "question", "A?")), 10);
crew.toastStep(m, agents(), 20);
const r = crew.toastStep(m, agents(blocked("amy", "question", "A?")), 30);
console.log(r.list.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}
