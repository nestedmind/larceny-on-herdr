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

@test "mod uses no repeating timer, setTimeout or setInterval" {
  run grep -nE 'setTimeout|setInterval|timer\.every|requestAnimationFrame' "$(mod_dir)/main.js" "$(mod_dir)/crew.js" "$(mod_dir)/draw.js"
  [ "$status" -ne 0 ]
}

@test "mod animates with loop and transition in draw.js" {
  grep -q '\.loop(' "$(mod_dir)/draw.js"
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
const s = L.people.find((p) => p.id === "sucre");
console.log(s.place, L.rooms.filter(r => r.kind === "repo").map(r => r.label).join(","), s.agent.ticket, s.agent.step);'
  [ "$status" -eq 0 ]
  [ "$output" = "desk api 3 editing a.js" ]
}

@test "an idle coder with no task goes to the lounge" {
  run crew_js '
const t = [{address:"t1",name:"whip",state:"live",status:"idle",labels:{crew:"w",role:"coder"}}];
console.log(crew.layoutCrew(crew.crewOf(t, "w")).people.find((p) => p.id === "whip").place);'
  [ "$status" -eq 0 ]
  [ "$output" = "lounge" ]
}

@test "standing agents get the leads and meeting rooms" {
  run crew_js '
const mk = (n, role) => ({address:"t"+n,name:role,state:"live",status:"idle",labels:{crew:"w",role}});
const t = [mk(1,"coordinator"), mk(2,"reviewer"), mk(3,"advisor"), mk(4,"teacher")];
console.log(crew.layoutCrew(crew.crewOf(t, "w")).people.filter((p) => p.agent).map(s => s.agent.role + ":" + s.place).sort().join(" "));'
  [ "$status" -eq 0 ]
  [ "$output" = "advisor:meeting coordinator:desk reviewer:desk teacher:meeting" ]
}

@test "a fifth coder in one repo waits in the lounge" {
  run crew_js '
const t = [1,2,3,4,5].map(n => ({address:"t"+n,name:"c"+n,state:"live",status:"working",labels:{crew:"w",role:"coder",task:"web#"+n}}));
const s = crew.layoutCrew(crew.crewOf(t, "w")).people.filter((p) => p.agent).map(x => x.place);
console.log(s.filter(p => p === "desk").length, s.filter(p => p === "lounge").length);'
  [ "$status" -eq 0 ]
  [ "$output" = "2 3" ]
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

@test "a watch terminal and a non-Claude terminal are never drawn" {
  run crew_js '
const mk = (n, agent, role) => ({address:"t"+n,name:n,agent,state:"live",status:"idle",labels:{crew:"w",role}});
const t = [mk("scofield","claude-code","coordinator"), mk("loh-watch","loh","watch"), mk("w2",undefined,"watch"), mk("shell","zsh",undefined), mk("sucre","claude-code","coder")];
console.log(crew.crewOf(t, "w").map(a => a.name).join(","));'
  [ "$status" -eq 0 ]
  [ "$output" = "scofield,sucre" ]
}

@test "the manifest's repos get rooms with four empty desks and no coders" {
  run crew_js '
const L = crew.layoutCrew([], ["api", "web"]);
const r = L.rooms.filter(x => x.kind === "repo");
console.log(r.map(x => x.label).join(","), L.desks.length, L.people.filter((p) => p.agent).length);'
  [ "$status" -eq 0 ]
  [ "$output" = "api,web 10 0" ]
}

@test "a coder whose repo is not in the manifest still gets a room, after the manifest's" {
  run crew_js '
const t = [{address:"t1",name:"a",state:"live",status:"working",labels:{crew:"w",role:"coder",task:"zed#1"}}];
const L = crew.layoutCrew(crew.crewOf(t, "w"), ["web", "api"]);
console.log(L.rooms.filter(x => x.kind === "repo").map(x => x.label).join(","), L.people.find((p) => p.agent).place);'
  [ "$status" -eq 0 ]
  [ "$output" = "web,api,zed desk" ]
}

@test "the floor is exactly as wide as its rooms" {
  run crew_js '
const L = crew.layoutCrew([], ["api", "web"]);
const edge = Math.max(...L.rooms.map(r => r.x + r.w));
console.log(L.W === edge, crew.layoutCrew([], []).W);'
  [ "$status" -eq 0 ]
  [ "$output" = "true 480" ]
}

@test "repo list parsing keeps names only and drops junk" {
  run crew_js '
console.log(crew.repoNames(JSON.stringify([{name:"api"},{name:"web"},{name:""},{x:1}])).join(","), crew.repoNames("nope").length);'
  [ "$status" -eq 0 ]
  [ "$output" = "api,web 0" ]
}

@test "main.js asks loh status --repos instead of reading the manifest" {
  grep -q 'reposCall(' "$(mod_dir)/main.js"
  ! grep -q 'workspace.md' "$(mod_dir)/main.js" "$(mod_dir)/crew.js"
}

@test "the bottom row is Matt's room, kitchen, lounge, ping pong and rest room, edge to edge" {
  run crew_js '
const L = crew.layoutCrew([], ["api", "web"]);
const row = L.rooms.filter(r => r.y === 160).sort((a, b) => a.x - b.x);
const joined = row.every((r, i) => i === 0 ? r.x === 0 : r.x === row[i - 1].x + row[i - 1].w);
console.log(row.map(r => r.kind).join(","), joined, row[row.length - 1].x + row[row.length - 1].w === L.W);'
  [ "$status" -eq 0 ]
  [ "$output" = "matt,kitchen,lounge,pong,rest true true" ]
}

@test "a coder with a task who is done walks to the kitchen, and back to the desk when working" {
  run crew_js '
const mk = (st) => crew.layoutCrew(crew.crewOf([{address:"t1",name:"sucre",state:"live",status:st,labels:{crew:"w",role:"coder",task:"api#3"}}], "w"), ["api"]);
const d = mk("done"), w = mk("working");
const k = d.rooms.find(r => r.kind === "kitchen"), s = d.people.find(p => p.id === "sucre");
console.log(s.place, s.x >= k.x && s.x <= k.x + k.w && s.y >= k.y && s.y <= k.y + k.h, w.people.find(p => p.id === "sucre").place);'
  [ "$status" -eq 0 ]
  [ "$output" = "kitchen true desk" ]
}

@test "a done coder in the kitchen keeps its desk reserved, so the others do not move" {
  run crew_js '
const mk = (n, st) => ({address:"t"+n,name:"c"+n,state:"live",status:st,labels:{crew:"w",role:"coder",task:"api#"+n}});
const at = (L, n) => { const s = L.people.find(x => x.agent && x.agent.name === "c" + n); return s.x + "," + s.y; };
const before = crew.layoutCrew(crew.crewOf([mk(1,"working"), mk(2,"working"), mk(3,"working")], "w"), ["api"]);
const after = crew.layoutCrew(crew.crewOf([mk(1,"done"), mk(2,"working"), mk(3,"working")], "w"), ["api"]);
console.log(at(before,2) === at(after,2), at(before,3) === at(after,3), after.people.find(s => s.agent && s.agent.name === "c1").place);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true kitchen" ]
}

@test "done coders overflow from the kitchen to the rest room when the kitchen is full" {
  run crew_js '
const t = [1,2,3,4,5,6,7].map(n => ({address:"t"+n,name:"c"+n,state:"live",status:"done",labels:{crew:"w",role:"coder",task:(n < 4 ? "api#" : "web#")+n}}));
const p = crew.layoutCrew(crew.crewOf(t, "w"), ["api","web"]).people.filter(x => x.agent).map(s => s.place);
console.log(p.filter(x => x === "kitchen").length, p.filter(x => x === "rest").length, p.filter(x => x === "desk").length);'
  [ "$status" -eq 0 ]
  [ "$output" = "6 1 0" ]
}

@test "main.js animates only when the place changes, not when the scale or floor width does" {
  grep -q 'this.sig' "$(mod_dir)/main.js"
}

@test "the dog has a bed in the lounge and a seated desk worker has a face direction" {
  run crew_js '
const L = crew.layoutCrew([], ["api"]);
const l = L.rooms.find(r => r.kind === "lounge");
console.log(L.dog.x >= l.x && L.dog.x <= l.x + l.w && L.dog.y >= l.y && L.dog.y <= l.y + l.h, L.dog.name);'
  [ "$status" -eq 0 ]
  [ "$output" = "true Waffles" ]
}

@test "main.js slides people between places with a native transition, not a timer" {
  grep -q 'transition("left"' "$(mod_dir)/draw.js"
  grep -q 'transition("top"' "$(mod_dir)/draw.js"
}

@test "the unlock call mirrors the lock call: raw name, agent's folder, props loh" {
  run crew_js '
const a = crew.crewOf([{address:"t1",name:"scofield",cwd:"/ws/lead",state:"live",status:"idle",labels:{crew:"w"}}], "w")[0];
const c = crew.unlockCall(a, "/opt/loh");
console.log(c.cmd, c.args.join(" "), c.options.cwd, c.options.timeout);'
  [ "$status" -eq 0 ]
  [ "$output" = "/opt/loh unlock scofield /ws/lead 5000" ]
}

@test "the scale drops below 1 when the floor is wider than the pane" {
  run crew_js '
const L = crew.layoutCrew([], ["api", "web"]);
const wide = crew.fitScale({ width: 1000, height: 800 }, L);
const narrow = crew.fitScale({ width: 216, height: 800 }, L);
console.log(wide.fits, narrow.k < 1, narrow.fits, Math.round(narrow.k * L.W) <= 200);'
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true" ]
}

@test "a floor that cannot fit even at the smallest scale is reported as not fitting" {
  run crew_js '
const L = crew.layoutCrew([], ["api", "web"]);
const s = crew.fitScale({ width: 20, height: 20 }, L);
console.log(s.fits, s.k > 0);'
  [ "$status" -eq 0 ]
  [ "$output" = "false true" ]
}

@test "the chat is gone when its pane is no longer in the pane list" {
  run crew_js '
const chat = { pane: "p9", name: "scofield" };
console.log(crew.chatGone([{pane:"p1"},{pane:"p9"}], chat), crew.chatGone([{pane:"p1"}], chat), crew.chatGone([], null));'
  [ "$status" -eq 0 ]
  [ "$output" = "false true false" ]
}

@test "the office pane is the one named by props, else the focused crew-office pane" {
  run crew_js '
const ps = [{pane:"p1",mod:"crew-office",focused:false},{pane:"p2",mod:"crew-office",focused:true},{pane:"p3",terminal:"t1"}];
console.log(crew.officePane(ps, {pane:"p1"}), crew.officePane(ps, {}), crew.officePane([{pane:"p3",terminal:"t1"}], {}));'
  [ "$status" -eq 0 ]
  [ "$output" = "p1 p2 null" ]
}

@test "main.js docks the agent's terminal in a split, unlocks on close, and never calls agent.focus" {
  grep -q 'pane.split' "$(mod_dir)/main.js"
  grep -q 'terminal.show' "$(mod_dir)/main.js"
  grep -q 'unlockCall(' "$(mod_dir)/main.js"
  grep -q 'pane.zoom' "$(mod_dir)/main.js"
  grep -q 'closeChat(' "$(mod_dir)/main.js"
  ! grep -qE '^  close\(' "$(mod_dir)/main.js"
  ! grep -q 'agent.focus' "$(mod_dir)/main.js"
  ! grep -q 'terminal.keep' "$(mod_dir)/main.js"
}
