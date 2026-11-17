#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

# react writes the agent's reaction to the owner's newest message into the workspace's reaction folder.
# The fake hc answers `hc get` with the agent's name, cwd and argv; the session is a fixture.
setup() {
  make_plugin_tree
  cp "$REPO_ROOT"/lib/loh/transcript.sh "$REPO_ROOT"/lib/loh/react.sh "$PLUGIN_TREE/lib/loh/"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat >"$BIN/hc" <<'SH'
#!/usr/bin/env bash
[[ "$1" == get ]] && cat "$HC_DIR/get.json"
SH
  chmod +x "$BIN/hc"
  export HC_DIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" HC_TERMINAL_ID=t7
  export LOH_CLAUDE_PROJECTS="$BATS_TEST_TMPDIR/projects"
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS/.loh" "$WS/api"
  : >"$WS/.loh/workspace.md"
  PROJ="$LOH_CLAUDE_PROJECTS/$(printf '%s' "$WS/api" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$PROJ"
  printf '{"name":"scofield","state":"live","cwd":"%s","argv":["claude","--agent","larceny:coordinator"],"status":{"state":"idle"}}\n' "$WS/api" >"$HC_DIR/get.json"
  cp "$REPO_ROOT/test/fixtures/transcripts/reacting.jsonl" "$PROJ/c1.jsonl"
  cd "$WS/api"
}

@test "react --dir prints the workspace's reaction folder" {
  run "$LOH" react --dir
  [ "$status" -eq 0 ]
  [ "$output" = "$WS/.loh/reactions" ]
}

@test "react puts the emoji on the owner's newest message" {
  run "$LOH" react 👍
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$WS/.loh/reactions/scofield.agent.json")" = '[{"id":"u-m2","emoji":"👍"}]' ]
}

@test "react twice with the same emoji is a no-op, and a second emoji joins it" {
  "$LOH" react 👍
  run "$LOH" react 👍
  [ "$status" -eq 0 ]
  "$LOH" react 👀
  [ "$(jq -c . "$WS/.loh/reactions/scofield.agent.json")" = '[{"id":"u-m2","emoji":"👍"},{"id":"u-m2","emoji":"👀"}]' ]
}

@test "react takes the heart with or without its variation selector, and stores it with" {
  run "$LOH" react ❤
  [ "$status" -eq 0 ]
  [ "$(jq -j '.[0].emoji' "$WS/.loh/reactions/scofield.agent.json" | od -An -tx1 | tr -d ' \n')" = "e29da4efb88f" ]
}

@test "react refuses an emoji outside the six and writes nothing" {
  run --separate-stderr "$LOH" react 🎉
  [ "$status" -eq 2 ]
  [ "$stderr" = "loh: react takes one of 👍 ✅ ❌ 👀 ❤️ 😂, got: 🎉" ]
  [ ! -e "$WS/.loh/reactions/scofield.agent.json" ]
}

@test "react says so when the session has no message of the owner's to react to" {
  printf '{"uuid":"x","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]},"timestamp":"2026-11-13T02:00:00.000Z"}\n' >"$PROJ/c1.jsonl"
  run --separate-stderr "$LOH" react 👍
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no message from"* ]]
}

@test "react skips the launch prompt: it is not the owner's message" {
  head -n 2 "$REPO_ROOT/test/fixtures/transcripts/reacting.jsonl" >"$PROJ/c1.jsonl"
  run --separate-stderr "$LOH" react 👍
  [ "$status" -eq 1 ]
}

@test "react outside a herdr terminal says so" {
  unset HC_TERMINAL_ID
  run --separate-stderr "$LOH" react 👍
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"HC_TERMINAL_ID"* ]]
}

@test "react --set-owner writes the owner's store of an agent, replacing the file, in a folder not made yet" {
  rmdir "$WS/.loh/reactions" 2>/dev/null || true
  run "$LOH" react --set-owner yoda '[{"id":"a","emoji":"👍","excerpt":"x","told":false,"gone":false}]'
  [ "$status" -eq 0 ]
  run "$LOH" react --set-owner yoda '[]'
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/.loh/reactions/yoda.owner.json")" = '[]' ]
  [ "$(ls "$WS/.loh/reactions")" = "yoda.owner.json" ]
}

@test "react --set-owner refuses a store that is not a list and a name that is not an agent's" {
  run "$LOH" react --set-owner yoda '{"a":1}'
  [ "$status" -ne 0 ]
  run "$LOH" react --set-owner ../yoda '[]'
  [ "$status" -ne 0 ]
  run "$LOH" react --set-owner yoda
  [ "$status" -eq 2 ]
  [ ! -e "$WS/.loh/reactions/yoda.owner.json" ]
}
