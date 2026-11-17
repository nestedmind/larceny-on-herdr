#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

mod_dir() { printf '%s\n' "$REPO_ROOT/office/crew-office"; }

# Run a JS snippet against reactions.js (copied to .mjs). The snippet sees `r`, the module.
react_js() {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/reactions.js" "$BATS_TEST_TMPDIR/reactions.mjs"
  node --input-type=module -e "import * as r from '$BATS_TEST_TMPDIR/reactions.mjs'; $1"
}

@test "the six are 👍 ✅ ❌ 👀 ❤️ 😂 in that order, and the bare heart counts as the heart" {
  run react_js 'console.log(r.REACTIONS.join(" "), r.normalise("❤") === "❤️", r.normalise("🎉"))'
  [ "$status" -eq 0 ]
  [ "$output" = "👍 ✅ ❌ 👀 ❤️ 😂 true null" ]
}

@test "the excerpt is the first line, cut to 40 characters with an ellipsis" {
  run react_js 'console.log(JSON.stringify([r.excerptOf("short\nsecond"), r.excerptOf("#61 is merged (squash, 8b3e700). Sucre'"'"'s PR is next"), r.excerptOf("x".repeat(40)), r.excerptOf("x".repeat(41))]))'
  [ "$status" -eq 0 ]
  [ "$output" = '["short","#61 is merged (squash, 8b3e700). Sucre'\''s…","xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…"]' ]
}

@test "reaction lines: one per reaction not yet told, oldest first, then one for each taken back after it was told" {
  run react_js '
const e = [
  { id: "a", emoji: "👍", excerpt: "first", told: false, gone: false },
  { id: "b", emoji: "✅", excerpt: "second", told: true, gone: false },
  { id: "c", emoji: "❌", excerpt: "third", told: true, gone: true },
  { id: "d", emoji: "😂", excerpt: "fourth", told: false, gone: false }];
console.log(r.withReactionLines(e, "Matt", "Thanks"))'
  [ "$status" -eq 0 ]
  [ "$output" = $'(Matt reacted 👍 to your message "first")\n(Matt took back ❌ on your message "third")\n(Matt reacted 😂 to your message "fourth")\nThanks' ]
}

@test "no lines and no change to the text when nothing is untold" {
  run react_js 'console.log(r.withReactionLines([{ id: "b", emoji: "✅", excerpt: "x", told: true, gone: false }], "Matt", "Thanks"))'
  [ "$output" = "Thanks" ]
}

@test "the lines are stripped from the front of a turn, and only the front" {
  run react_js '
const t = `(Matt reacted 👍 to your message "a (b)")\n(Matt took back 👍 on your message "a")\nHello\n(Matt reacted 👍 to your message "later")`;
console.log(JSON.stringify([r.stripReactionLines(t, "Matt"), r.stripReactionLines(t, "Pat"), r.stripReactionLines("plain", "Matt")]))'
  [ "$output" = '["Hello\n(Matt reacted 👍 to your message \"later\")","(Matt reacted 👍 to your message \"a (b)\")\n(Matt took back 👍 on your message \"a\")\nHello\n(Matt reacted 👍 to your message \"later\")","plain"]' ]
}

@test "a name with a regex character is matched as written" {
  run react_js 'console.log(r.stripReactionLines("(A.B reacted 👍 to your message \"x\")\nhi", "A.B"), "|", r.stripReactionLines("(AxB reacted 👍 to your message \"x\")\nhi", "A.B").length)'
  [ "$output" = $'hi | 39' ]
}

@test "clicking an emoji adds it; clicking it again before the agent was told drops it" {
  run react_js '
const a = r.toggleOwner([], "m1", "👍", "Done: #61");
const b = r.toggleOwner(a, "m1", "👍", "Done: #61");
console.log(JSON.stringify([a, b]))'
  [ "$output" = '[[{"id":"m1","emoji":"👍","excerpt":"Done: #61","told":false,"gone":false}],[]]' ]
}

@test "taking back a reaction the agent was told of keeps it as gone, and putting it on again clears that" {
  run react_js '
const told = [{ id: "m1", emoji: "👍", excerpt: "x", told: true, gone: false }];
const a = r.toggleOwner(told, "m1", "👍", "x");
const b = r.toggleOwner(a, "m1", "👍", "x");
console.log(JSON.stringify([a[0].gone, b[0].gone, b[0].told]))'
  [ "$output" = '[true,false,true]' ]
}

@test "after a message went out, its reactions are told and the taken-back ones go" {
  run react_js '
const e = [
  { id: "a", emoji: "👍", excerpt: "x", told: false, gone: false },
  { id: "b", emoji: "✅", excerpt: "x", told: true, gone: true },
  { id: "c", emoji: "❌", excerpt: "x", told: false, gone: false }];
const sent = [e[0], e[1]];
console.log(JSON.stringify(r.markTold(e, sent).map((x) => [x.id, x.told])))'
  [ "$output" = '[["a",true],["c",false]]' ]
}

@test "a reaction put on while the message was going out is not marked told by it" {
  run react_js '
const sent = [{ id: "a", emoji: "👍", excerpt: "x", told: true, gone: true }];
const now = [{ id: "a", emoji: "👍", excerpt: "x", told: true, gone: false }];
console.log(JSON.stringify(r.markTold(now, sent)))'
  [ "$output" = '[{"id":"a","emoji":"👍","excerpt":"x","told":true,"gone":false}]' ]
}

@test "👀 goes on the owner's newest turn that is in the log: not the launch prompt, not a pending one" {
  run react_js '
const turns = [
  { role: "user", id: "l", launch: true }, { role: "assistant", id: "a1" },
  { role: "user", id: "u1" }, { role: "assistant", id: "a2" }, { role: "user", id: "u2" },
  { role: "user", id: "", pending: true }];
console.log(r.seenId(turns), "|", r.seenId([{ role: "user", id: "l", launch: true }]), "|")'
  [ "$output" = "u2 |  |" ]
}

@test "chips under an agent's message are the owner's, in the order of the six" {
  run react_js '
const owner = [{ id: "m", emoji: "😂" }, { id: "m", emoji: "👍" }, { id: "x", emoji: "✅" }, { id: "m", emoji: "❌", gone: true }];
console.log(JSON.stringify(r.chipsFor({ role: "assistant", id: "m" }, { owner })))'
  [ "$output" = '[{"emoji":"👍","by":"owner","seen":false},{"emoji":"😂","by":"owner","seen":false}]' ]
}

@test "chips under the owner's message are the agent's, with 👀 once on the newest and never twice" {
  run react_js '
const agent = [{ id: "u2", emoji: "👀" }, { id: "u2", emoji: "👍" }];
const m = { role: "user", id: "u2" };
console.log(JSON.stringify([r.chipsFor(m, { agent, eyes: "u2" }), r.chipsFor(m, { eyes: "u2" }), r.chipsFor({ role: "user", id: "u1" }, { agent, eyes: "u2" }).length]))'
  [ "$output" = '[[{"emoji":"👍","by":"agent","seen":false},{"emoji":"👀","by":"agent","seen":true}],[{"emoji":"👀","by":"agent","seen":true}],0]' ]
}

@test "a pending message, the launch prompt and a turn with no id carry no chips" {
  run react_js '
const eyes = "p";
console.log(JSON.stringify([r.chipsFor({ role: "user", id: "p", pending: true }, { eyes }), r.chipsFor({ role: "user", id: "p", launch: true }, { eyes }), r.chipsFor({ role: "user", id: "" }, { eyes: "" })]))'
  [ "$output" = '[[],[],[]]' ]
}

@test "a store is read back with its bad entries dropped, and a broken file is empty" {
  run react_js '
const t = JSON.stringify([{ id: "a", emoji: "👍" }, { id: "", emoji: "👍" }, { id: "b", emoji: "🎉" }, null, { id: "c", emoji: "✅", excerpt: "x", told: true }]);
console.log(JSON.stringify([r.parseStore(t, "agent"), r.parseStore(t, "owner"), r.parseStore("{", "owner"), r.parseStore("{}", "owner")]))'
  [ "$output" = '[[{"id":"a","emoji":"👍"},{"id":"c","emoji":"✅"}],[{"id":"a","emoji":"👍","excerpt":"","told":false,"gone":false},{"id":"c","emoji":"✅","excerpt":"x","told":true,"gone":false}],[],[]]' ]
}

@test "the owner's store is written to a file and read back, and a missing folder is made" {
  run react_js '
import("node:fs/promises").then(async (fs) => {
  const dir = process.env.BATS_TEST_TMPDIR + "/store/deep";
  const e = [{ id: "a", emoji: "👍", excerpt: "x", told: false, gone: false }];
  await r.writeOwner(fs, dir, "scofield", e);
  console.log(JSON.stringify([await r.readStore(fs, dir, "scofield", "owner"), await r.readStore(fs, dir, "nobody", "owner"), (await fs.readdir(dir))]));
});'
  [ "$output" = '[[{"id":"a","emoji":"👍","excerpt":"x","told":false,"gone":false}],[],["scofield.owner.json"]]' ]
}

@test "the office asks loh for the reactions folder in the workspace's folder, and takes a line that is a path" {
  command -v node >/dev/null || skip "node not installed"
  cp "$(mod_dir)/crew.js" "$BATS_TEST_TMPDIR/crew.mjs"
  run node --input-type=module -e "import * as c from '$BATS_TEST_TMPDIR/crew.mjs'; console.log(JSON.stringify([c.reactDirCall({ cwd: '/ws/x' }, '/bin/loh'), c.reactDirOf('/ws/.loh/reactions\n'), c.reactDirOf(''), c.reactDirOf('loh: nope')]))"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"cmd":"/bin/loh","args":["react","--dir"],"options":{"cwd":"/ws/x","timeout":5000}},"/ws/.loh/reactions","",""]' ]
}
