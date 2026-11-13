#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

# transcript reads the Claude Code session file of an agent. The fake hc
# answers `hc get` with the agent's cwd and argv; the session files are the
# fixtures in test/fixtures/transcripts, copied into a fake ~/.claude/projects.
setup() {
  make_plugin_tree
  cp "$REPO_ROOT"/lib/loh/transcript.sh "$PLUGIN_TREE/lib/loh/transcript.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat >"$BIN/hc" <<'SH'
#!/usr/bin/env bash
[[ "$1" == get ]] && cat "$HC_DIR/get.json"
SH
  chmod +x "$BIN/hc"
  export HC_DIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH"
  export LOH_CLAUDE_PROJECTS="$BATS_TEST_TMPDIR/projects"
  # a cwd with a dot and a slash: both become "-" in the projects folder name
  CWD="/home/me/ws.x/sandbox"
  PROJ="$LOH_CLAUDE_PROJECTS/-home-me-ws-x-sandbox"
  mkdir -p "$PROJ"
  printf '{"state":"live","cwd":"%s","argv":["claude","--agent","larceny:coordinator","--permission-mode","auto"],"status":{"state":"idle"}}\n' "$CWD" >"$HC_DIR/get.json"
}

fixture() { cp "$REPO_ROOT/test/fixtures/transcripts/$1.jsonl" "$PROJ/$2.jsonl"; }

@test "transcript keeps user turns and assistant text, in order, and nothing else" {
  fixture coordinator c1
  run --separate-stderr "$LOH" transcript scofield
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[] | .role + ": " + .text] | join("|")' <<<"$output")" = \
    $'user: Hello coordinator, what is open?|assistant: Two tickets are open: api#2 and web#1.|user: Please merge api#2|assistant: Merged.\n\nDone.' ]
}

@test "transcript carries the timestamp of each turn" {
  fixture coordinator c1
  run "$LOH" transcript scofield
  [ "$(jq -r '.[0].ts' <<<"$output")" = "2026-11-13T02:33:12.000Z" ]
}

@test "transcript --last N keeps the newest N turns" {
  fixture coordinator c1
  run "$LOH" transcript scofield --last 2
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].text] | join("|")' <<<"$output")" = $'Please merge api#2|Merged.\n\nDone.' ]
}

@test "transcript picks the session of the agent's own --agent among several in one folder" {
  fixture coordinator c1
  fixture reviewer r1
  touch -d '2026-11-13 04:00' "$PROJ/r1.jsonl"
  touch -d '2026-11-13 03:00' "$PROJ/c1.jsonl"
  run "$LOH" transcript scofield
  [ "$(jq -r '.[0].text' <<<"$output")" = "Hello coordinator, what is open?" ]
}

@test "transcript takes the newest of two sessions for the same agent" {
  fixture coordinator c1
  fixture reviewer c2
  sed -i 's/larceny:reviewer/larceny:coordinator/' "$PROJ/c2.jsonl"
  touch -d '2026-11-13 03:00' "$PROJ/c1.jsonl"
  touch -d '2026-11-13 04:00' "$PROJ/c2.jsonl"
  run "$LOH" transcript scofield
  [ "$(jq -r '.[0].text' <<<"$output")" = "review PR 3" ]
}

@test "transcript falls back to the newest session when argv names no agent" {
  fixture coordinator c1
  fixture reviewer r1
  touch -d '2026-11-13 04:00' "$PROJ/r1.jsonl"
  touch -d '2026-11-13 03:00' "$PROJ/c1.jsonl"
  printf '{"state":"live","cwd":"%s","argv":["claude"]}\n' "$CWD" >"$HC_DIR/get.json"
  run "$LOH" transcript scofield
  [ "$(jq -r '.[0].text' <<<"$output")" = "review PR 3" ]
}

@test "transcript prints [] when the agent has no session file yet" {
  run "$LOH" transcript scofield
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "transcript rejects a name that is not a plain name, and a bad --last" {
  run --separate-stderr "$LOH" transcript "../x"
  [ "$status" -eq 2 ]
  run --separate-stderr "$LOH" transcript scofield --last zero
  [ "$status" -eq 2 ]
  run --separate-stderr "$LOH" transcript
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh transcript"* ]]
}

@test "transcript cuts a very long turn" {
  fixture reviewer r1
  jq -c --arg t "$(head -c 9000 /dev/zero | tr '\0' x)" 'if .type=="assistant" then .message.content[0].text=$t else . end' "$PROJ/r1.jsonl" >"$PROJ/r1.tmp"
  mv "$PROJ/r1.tmp" "$PROJ/r1.jsonl"
  run "$LOH" transcript scofield
  [ "$(jq -r '.[1].text | length' <<<"$output")" -le 4001 ]
}
