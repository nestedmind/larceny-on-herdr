#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper
load loh_helper

# release archives a coder's Claude Code session folder into
# <workspace>/.loh/transcripts/ and then ends the terminal. The fake hc answers
# `hc get` per name; the session folders are real files under a temp
# LOH_CLAUDE_PROJECTS.
setup() {
  make_workspace
  use_fake_hc_only
  use_hc_script
  LOH="$REPO_ROOT/bin/loh"
  export LOH_CLAUDE_PROJECTS="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$LOH_CLAUDE_PROJECTS"
  unset HC_TERMINAL_ID
  # a worktree folder name as Claude Code writes it: every non-alphanumeric becomes "-"
  SUCRE_CWD="$WS/.worktrees/sucre-api-12"
  SUCRE_SRC="$LOH_CLAUDE_PROJECTS/$(printf '%s' "$SUCRE_CWD" | sed 's/[^A-Za-z0-9]/-/g')"
  coder_get sucre "$SUCRE_CWD" idle api#12
  hc_reply get.amy '{"state":"live","cwd":"/x","labels":{"crew":"demo","role":"reviewer"},"status":{"state":"idle"}}'
  hc_reply get.elsewhere '{"state":"live","cwd":"/x","labels":{"crew":"other","role":"coder","task":"api#1"},"status":{"state":"idle"}}'
}

# coder_get <name> <cwd> <status> <task>
coder_get() {
  hc_reply "get.$1" "$(jq -nc --arg c "$2" --arg s "$3" --arg t "$4" \
    '{state:"live",cwd:$c,labels:{crew:"demo",role:"coder",task:$t},status:{state:$s}}')"
}

make_session() {
  mkdir -p "$SUCRE_SRC/sub"
  printf '{"type":"user"}\n' >"$SUCRE_SRC/s1.jsonl"
  printf 'more\n' >"$SUCRE_SRC/sub/notes.txt"
}

@test "release copies the session folder whole, removes the source, then ends the terminal" {
  make_session
  run "$LOH" release sucre
  [ "$status" -eq 0 ]
  dest="$WS/.loh/transcripts/sucre-api-12"
  [ "$(cat "$dest/s1.jsonl")" = '{"type":"user"}' ]
  [ "$(cat "$dest/sub/notes.txt")" = "more" ]
  [ ! -e "$SUCRE_SRC" ]
  [[ "$output" == *"$dest"* ]]
  [ "$(grep -n -x -F $'kill\tsucre' "$FAKE_HC_LOG" | cut -d: -f1)" -lt "$(grep -n -x -F $'rm\tsucre' "$FAKE_HC_LOG" | cut -d: -f1)" ]
}

@test "release refuses a coder that is still working, and with --force archives and ends it" {
  make_session
  coder_get sucre "$SUCRE_CWD" working api#12
  run --separate-stderr "$LOH" release sucre
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"working"* ]]
  [ -d "$SUCRE_SRC" ]
  ! grep -q $'^kill\t' "$FAKE_HC_LOG"
  run "$LOH" release sucre --force
  [ "$status" -eq 0 ]
  [ -f "$WS/.loh/transcripts/sucre-api-12/s1.jsonl" ]
  [ ! -e "$SUCRE_SRC" ]
  grep -qxF $'kill\tsucre' "$FAKE_HC_LOG"
  grep -qxF $'rm\tsucre' "$FAKE_HC_LOG"
}

@test "release refuses a blocked coder without --force" {
  make_session
  coder_get sucre "$SUCRE_CWD" blocked api#12
  run "$LOH" release sucre
  [ "$status" -ne 0 ]
  [ -d "$SUCRE_SRC" ]
}

@test "release adds -2 and -3 when the archive name is taken" {
  mkdir -p "$WS/.loh/transcripts/sucre-api-12"
  make_session
  run "$LOH" release sucre
  [ "$status" -eq 0 ]
  [ -f "$WS/.loh/transcripts/sucre-api-12-2/s1.jsonl" ]
  make_session
  run "$LOH" release sucre
  [ "$status" -eq 0 ]
  [ -f "$WS/.loh/transcripts/sucre-api-12-3/s1.jsonl" ]
  [ -z "$(ls -A "$WS/.loh/transcripts/sucre-api-12")" ]
}

@test "release leaves the source and the terminal alone when the copy fails" {
  make_session
  : >"$WS/.loh/transcripts" # a file where the folder should be
  run --separate-stderr "$LOH" release sucre
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"source is left"* ]]
  [ -f "$SUCRE_SRC/s1.jsonl" ]
  ! grep -q $'^kill\t' "$FAKE_HC_LOG"
}

@test "release leaves the source when the copy does not verify" {
  make_session
  mkdir -p "$BATS_TEST_TMPDIR/badbin"
  # a cp that makes the destination and copies nothing
  printf '#!/usr/bin/env bash\nmkdir -p "${@: -1}"\n' >"$BATS_TEST_TMPDIR/badbin/cp"
  chmod +x "$BATS_TEST_TMPDIR/badbin/cp"
  PATH="$BATS_TEST_TMPDIR/badbin:$PATH" run --separate-stderr "$LOH" release sucre
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"source is left"* ]]
  [ -f "$SUCRE_SRC/s1.jsonl" ]
  [ ! -e "$WS/.loh/transcripts/sucre-api-12" ]
  ! grep -q $'^kill\t' "$FAKE_HC_LOG"
}

@test "release refuses a name that is not a coder of this crew" {
  run --separate-stderr "$LOH" release amy
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not a coder"* ]]
  run --separate-stderr "$LOH" release elsewhere
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not a coder"* ]]
  run "$LOH" release nobody
  [ "$status" -ne 0 ]
  ! grep -q $'^kill\t' "$FAKE_HC_LOG"
}

@test "release rejects a bad name and an unknown option with usage" {
  run --separate-stderr "$LOH" release "../x"
  [ "$status" -eq 2 ]
  run --separate-stderr "$LOH" release sucre --nuke
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh release"* ]]
  run --separate-stderr "$LOH" release
  [ "$status" -eq 2 ]
}

@test "release copies but never removes a folder whose coder runs outside the workspace's worktrees" {
  other="$BATS_TEST_TMPDIR/elsewhere"
  src="$LOH_CLAUDE_PROJECTS/$(printf '%s' "$other" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$src"
  echo hi >"$src/s1.jsonl"
  coder_get sucre "$other" idle api#12
  run "$LOH" release sucre
  [ "$status" -eq 0 ]
  [ -f "$WS/.loh/transcripts/sucre-api-12/s1.jsonl" ]
  [ -f "$src/s1.jsonl" ]
}

@test "release never removes a folder for a cwd with .. in it" {
  sneaky="$WS/.worktrees/../api"
  src="$LOH_CLAUDE_PROJECTS/$(printf '%s' "$sneaky" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$src"
  echo hi >"$src/s1.jsonl"
  coder_get sucre "$sneaky" idle api#12
  run "$LOH" release sucre
  [ -f "$src/s1.jsonl" ]
}

@test "release with no session folder still ends the coder" {
  run "$LOH" release sucre
  [ "$status" -eq 0 ]
  [ ! -e "$WS/.loh/transcripts" ] || [ -z "$(ls -A "$WS/.loh/transcripts")" ]
  grep -qxF $'kill\tsucre' "$FAKE_HC_LOG"
  grep -qxF $'rm\tsucre' "$FAKE_HC_LOG"
}

@test "release leaves other session folders alone" {
  make_session
  mkdir -p "$LOH_CLAUDE_PROJECTS/-home-me-coordinator"
  echo keep >"$LOH_CLAUDE_PROJECTS/-home-me-coordinator/c.jsonl"
  run "$LOH" release sucre
  [ -f "$LOH_CLAUDE_PROJECTS/-home-me-coordinator/c.jsonl" ]
}

@test "release then transcript --archived reads the archived chat" {
  mkdir -p "$SUCRE_SRC"
  cp "$REPO_ROOT/test/fixtures/transcripts/coordinator.jsonl" "$SUCRE_SRC/c1.jsonl"
  run "$LOH" release sucre
  [ "$status" -eq 0 ]
  run "$LOH" transcript --archived sucre-api-12
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].text' <<<"$output")" = "Hello coordinator, what is open?" ]
  run "$LOH" transcript --archived sucre-api-12 --last 1
  [ "$(jq -r 'length' <<<"$output")" = 1 ]
}

@test "transcript --archived refuses a missing archive and a bad name" {
  run --separate-stderr "$LOH" transcript --archived nope-api-1
  [ "$status" -ne 0 ]
  run --separate-stderr "$LOH" transcript --archived "../x"
  [ "$status" -eq 2 ]
}
