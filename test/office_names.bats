#!/usr/bin/env bats
# The office draws the names the crew config gives (ticket #50): `loh crew --json` says who sits where.

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  cp "$(mod_dir)/chat.js" "$BATS_TEST_TMPDIR/chat.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; import * as chat from '$BATS_TEST_TMPDIR/chat.mjs'; $1"
}

HELPERS='
const T = (name, status, labels = {}) => ({address: "t-" + name, name, state: "live", status, cwd: "/ws/" + name, labels: {crew: "w", ...labels}});
const NAMES = {coordinator: "Mia", reviewer: "Rex", advisor: "Ada", teacher: "Tom", coders: ["Ana", "Bo", "Cy"], person: "Dana"};
const lay = (ts, names) => crew.layoutCrew(crew.crewOf(ts, "w"), ["api"], 0, {mem: crew.newMemory(), now: 0, names});
'

@test "namesOf reads loh crew --json and rejects anything else" {
  run crew_js "$HELPERS"'
console.log(JSON.stringify(crew.namesOf(JSON.stringify(NAMES))));
console.log(crew.namesOf("nope"), crew.namesOf("[]"), crew.namesOf("{}"));
console.log(crew.crewCall({cwd: "/ws"}, "/bin/loh").args.join(" "));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '{"coordinator":"Mia","reviewer":"Rex","advisor":"Ada","teacher":"Tom","coders":["Ana","Bo","Cy"],"person":"Dana"}' ]
  [ "${lines[1]}" = "null null null" ]
  [ "${lines[2]}" = "crew --json" ]
}

@test "with no names the cast is as it was" {
  run crew_js "$HELPERS"'
const L = lay([]);
console.log(L.people.map((p) => p.id + "=" + p.name).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "scofield=Scofield sucre=Sucre mahone=Mahone sheba=Sheba whip=Whip amy=Amy maya=Maya opemipo=Opemipo yoda=Yoda sara=Sara matt=Owner dog=Waffles" ]
}

@test "custom names sit in the right seats and Maya and Opemipo stay" {
  run crew_js "$HELPERS"'
const L = lay([], NAMES);
console.log(L.people.map((p) => p.id + "=" + p.name + ":" + p.title).join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "scofield=Mia:coordinator ana=Ana:coder bo=Bo:coder cy=Cy:coder amy=Rex:reviewer maya=Maya:designer opemipo=Opemipo:researcher yoda=Ada:advisor sara=Tom:teacher matt=Dana:owner dog=Waffles:office dog" ]
}

@test "a terminal named for a custom person takes that person's seat" {
  run crew_js "$HELPERS"'
const L = lay([T("mia", "working", {role: "coordinator"}), T("rex", "idle", {role: "reviewer"}), T("ana", "working", {role: "coder", task: "api#3"})], NAMES);
const by = (id) => L.people.find((p) => p.id === id);
console.log(by("scofield").running, by("amy").running, by("ana").running, by("scofield").place, by("ana").desk, L.people.filter((p) => p.id.startsWith("x:")).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true desk repo:api:1 0" ]
}

@test "a role stand-in still works under a custom name" {
  run crew_js "$HELPERS"'
const L = lay([T("boss", "working", {role: "coordinator"})], NAMES);
const p = L.people.find((q) => q.id === "scofield");
console.log(p.running, p.name);'
  [ "$status" -eq 0 ]
  [ "$output" = "true Mia" ]
}

@test "a 3-coder and a 5-coder roster give that many coder seats" {
  run crew_js "$HELPERS"'
const five = {...NAMES, coders: ["A1", "B2", "C3", "D4", "E5"]};
const n = (names) => lay([], names).people.filter((p) => p.role === "coder").map((p) => p.id).join(",");
console.log(n(NAMES)); console.log(n(five));
const L = lay(["A1", "B2", "C3", "D4", "E5"].map((c) => T(c.toLowerCase(), "working", {role: "coder", task: "api#1"})), five);
console.log(L.people.filter((p) => p.role === "coder").map((p) => p.running + ":" + p.place).join(" "));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ana,bo,cy" ]
  [ "${lines[1]}" = "a1,b2,c3,d4,e5" ]
  [ "${lines[2]}" = "true:desk true:desk true:desk true:desk true:lounge" ]
}

@test "the owner is drawn under person: and is Owner with none" {
  run crew_js "$HELPERS"'
const w = crew.worldFor(["api"], 0, NAMES);
console.log(w.rooms.find((r) => r.kind === "matt").label, "|", w.rooms.find((r) => r.kind === "leads").label);
const d = crew.worldFor(["api"]);
console.log(d.rooms.find((r) => r.kind === "matt").label, "|", d.rooms.find((r) => r.kind === "leads").label);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Dana | Mia · Rex" ]
  [ "${lines[1]}" = "Owner | Scofield · Amy" ]
}

@test "the chat speaker label and the lock row use the owner's name" {
  run crew_js "$HELPERS"'
const m = {role: "user", text: "hi"};
console.log(chat.speaker(m, "Mia", "Dana"), chat.speaker(m, "Mia"), chat.speaker(m, "Mia", ""));
console.log(JSON.stringify(chat.cardRows({role: "coder", status: "idle", withMatt: true}, {idle: "idle"}, "Dana").pop()));
console.log(JSON.stringify(chat.cardRows({role: "coder", status: "idle", withMatt: true}, {idle: "idle"}).pop()));
console.log(chat.copyAll([m], "Mia", "Dana"));'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Dana Owner Owner" ]
  [ "${lines[1]}" = '["Lock","with Dana"]' ]
  [ "${lines[2]}" = '["Lock","with the owner"]' ]
  [ "${lines[3]}" = "Dana" ]
}

@test "the start offer names the configured coordinator and reviewer" {
  run crew_js "$HELPERS"'
const L = lay([], NAMES);
const p = L.people.find((q) => q.id === "scofield");
console.log(crew.startPlan(p, [], "/ws", NAMES).ask);
console.log(crew.startPlan(p, [], "/ws").ask);
const a = L.people.find((q) => q.id === "ana");
console.log(crew.startPlan(a, ["api"]).hint);'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Start Mia and Rex in /ws?" ]
  [ "${lines[1]}" = "Start Scofield and Amy in /ws?" ]
  [ "${lines[2]}" = "loh spawn ana <repo> <ticket>" ]
}

@test "a renamed person gets their own look, not the default's" {
  run crew_js "$HELPERS"'
console.log(JSON.stringify(crew.look("mia")) !== JSON.stringify(crew.look("scofield")), JSON.stringify(crew.look("Scofield")) === JSON.stringify(crew.look("scofield")));'
  [ "$status" -eq 0 ]
  [ "$output" = "true true" ]
}

@test "a coder named like a fixed seat gets an id of its own" {
  run crew_js "$HELPERS"'
const L = lay([T("sara", "working", {role: "coder", task: "api#1"})], {...NAMES, coders: ["Sara", "Bo"]});
const ids = L.people.map((p) => p.id);
console.log(new Set(ids).size === ids.length, L.people.filter((p) => p.name === "Sara").map((p) => p.id + ":" + p.role + ":" + p.running).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "true c:sara:coder:true" ]
}
