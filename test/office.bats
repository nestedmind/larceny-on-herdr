#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

# Run a JS snippet against crew.js. The file is copied to .mjs so older
# node versions treat it as an ES module. The snippet sees `crew`, the module.
crew_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  node --input-type=module -e "import * as crew from '$BATS_TEST_TMPDIR/crew.mjs'; $1"
}

@test "herdr-app check passes on the mod" {
  command -v herdr-app >/dev/null || skip "herdr-app not on PATH"
  run herdr-app check "$(mod_dir)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check passed"* ]]
}

@test "mod.json is valid JSON with a title" {
  command -v node >/dev/null || skip "node not installed"
  run node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(!m.title) process.exit(1)' "$(mod_dir)/mod.json"
  [ "$status" -eq 0 ]
}

@test "mod uses no setTimeout, setInterval or cx.timer" {
  run grep -nE 'setTimeout|setInterval|timer\.' "$(mod_dir)/main.js" "$(mod_dir)/crew.js"
  [ "$status" -ne 0 ]
}

@test "mod animates with frames and loop" {
  grep -q '\.frames(' "$(mod_dir)/main.js"
  grep -q '\.loop(' "$(mod_dir)/main.js"
}

@test "mod reads the labels the README documents" {
  for l in crew role task step pr round note with_matt; do
    grep -q "$l" "$(mod_dir)/crew.js" || { echo "crew.js does not read $l"; return 1; }
    grep -q "\`$l\`" "$REPO_ROOT/office/README.md" || { echo "README does not document $l"; return 1; }
  done
}

@test "a working coder sits in its task's repo room" {
  run crew_js '
const t = [{address:"t1",name:"sucre",state:"live",status:"working",labels:{crew:"w",role:"coder",task:"api#3",step:"editing a.js"}}];
const L = crew.layoutCrew(crew.crewOf(t, "w"));
const s = L.seats[0];
console.log(s.place, L.rooms.filter(r => r.kind === "repo").map(r => r.label).join(","), s.agent.ticket, s.agent.step);'
  [ "$status" -eq 0 ]
  [ "$output" = "desk api 3 editing a.js" ]
}

@test "an idle coder with no task goes to the lounge" {
  run crew_js '
const t = [{address:"t1",name:"whip",state:"live",status:"idle",labels:{crew:"w",role:"coder"}}];
console.log(crew.layoutCrew(crew.crewOf(t, "w")).seats[0].place);'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge" ]
}

@test "standing agents get the leads and meeting rooms" {
  run crew_js '
const mk = (n, role) => ({address:"t"+n,name:role,state:"live",status:"idle",labels:{crew:"w",role}});
const t = [mk(1,"coordinator"), mk(2,"reviewer"), mk(3,"advisor"), mk(4,"teacher")];
console.log(crew.layoutCrew(crew.crewOf(t, "w")).seats.map(s => s.agent.role + ":" + s.place).sort().join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "advisor:meeting coordinator:desk reviewer:desk teacher:meeting" ]
}

@test "a fifth coder in one repo waits in the lounge" {
  run crew_js '
const t = [1,2,3,4,5].map(n => ({address:"t"+n,name:"c"+n,state:"live",status:"working",labels:{crew:"w",role:"coder",task:"web#"+n}}));
const s = crew.layoutCrew(crew.crewOf(t, "w")).seats.map(x => x.place);
console.log(s.filter(p => p === "desk").length, s.filter(p => p === "lounge").length);'
  [ "$status" -eq 0 ]
  [ "$output" = "4 1" ]
}

@test "blocked kind comes from the report, other when absent" {
  run crew_js '
console.log(crew.blockedKind({status:{state:"blocked",kind:"permission"}}), crew.blockedKind({report:{kind:"question"}}), crew.blockedKind({status:"blocked"}));'
  [ "$status" -eq 0 ]
  [ "$output" = "permission question other" ]
}

@test "with_matt=1 sets the flag and other crews are left out" {
  run crew_js '
const t = [
  {address:"t1",name:"a",state:"live",status:"idle",labels:{crew:"w",role:"coder",with_matt:"1"}},
  {address:"t2",name:"b",state:"live",status:"idle",labels:{crew:"other",role:"coder"}}];
const c = crew.crewOf(t, "w");
console.log(c.length, c[0].withMatt);'
  [ "$status" -eq 0 ]
  [ "$output" = "1 true" ]
}

@test "the lock call runs in the agent's own folder with its raw name" {
  run crew_js '
const t = [{address:"t1",name:"sucre-with-a-very-long-name",cwd:"/ws/.worktrees/sucre-api-5",state:"live",status:"idle",labels:{crew:"w",role:"coder"}}];
const a = crew.crewOf(t, "w")[0];
const c = crew.lockCall(a, "");
console.log(c.cmd, c.args.join(" "), c.options.cwd, c.options.timeout, a.name.length <= 16);'
  [ "$status" -eq 0 ]
  [ "$output" = "loh lock sucre-with-a-very-long-name /ws/.worktrees/sucre-api-5 5000 true" ]
}

@test "the lock call uses the loh path from props when given" {
  run crew_js '
const a = crew.crewOf([{address:"t1",name:"a",cwd:"/w",state:"live",status:"idle",labels:{crew:"w"}}], "w")[0];
console.log(crew.lockCall(a, "/opt/loh/bin/loh").cmd);'
  [ "$status" -eq 0 ]
  [ "$output" = "/opt/loh/bin/loh" ]
}

@test "main.js builds the lock call with lockCall and reports a non-zero exit" {
  grep -q 'lockCall(' "$(mod_dir)/main.js"
  grep -q 'r.code !== 0' "$(mod_dir)/main.js"
  grep -q 'notify(' "$(mod_dir)/main.js"
}

@test "repo and ticket from the task label are cut like the other labels" {
  run crew_js '
const t = [{address:"t1",name:"a",state:"live",status:"idle",labels:{crew:"w",role:"coder",task:"a-very-long-repo-name-from-somewhere-else#1234567890"}}];
const a = crew.crewOf(t, "w")[0];
console.log(a.repo.length, a.ticket.length);'
  [ "$status" -eq 0 ]
  [ "$output" = "24 8" ]
}

@test "totals count each state" {
  run crew_js '
const c = ["working","working","blocked","done","idle"].map((s) => ({status:s}));
console.log(JSON.stringify(crew.totals(c)));'
  [ "$status" -eq 0 ]
  [ "$output" = '{"working":2,"blocked":1,"done":1,"idle":1}' ]
}

@test "labels are stripped of control characters and cut to 60 characters" {
  run crew_js '
const t = [{address:"t1",name:"a",state:"live",status:"idle",labels:{crew:"w",role:"coder",step:"x\ny".repeat(40)}}];
const s = crew.crewOf(t, "w")[0].step;
console.log(s.length, /[\u0000-\u001f]/.test(s));'
  [ "$status" -eq 0 ]
  [ "$output" = "60 false" ]
}
