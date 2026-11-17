#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper
load loh_helper

# The first `hc get sucre` is loh's liveness check; `{}` means no such
# terminal. Later replies are the idle polls after `hc run`.
ABSENT='{}'
STARTING='{"state":"live","status":null}'
IDLE='{"state":"live","status":{"state":"idle"}}'
FINISHED='{"state":"finished","status":{"state":"done"}}'

setup() {
  make_workspace
  use_fake_hc_only
  use_hc_script
  use_fake_gh
  export LOH_POLL=0.05
  export LOH_START_TIMEOUT=2
  LOH="$REPO_ROOT/bin/loh"
  WT="$WS/.worktrees/sucre-api-12"
}

@test "spawn makes the worktree on <coder>/<ticket>-<slug> from origin/<branch>" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  [ -d "$WT" ]
  [ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "sucre/12-fix-the-login-bug-retries" ]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$WS/api" rev-parse origin/main)" ]
}

@test "spawn reads the issue title with gh issue view -R <github>" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  grep -qxF 'issue view 12 -R acme/api --json title --jq .title' "$FAKE_GH_LOG"
}

@test "spawn caps the slug at 40 characters with no trailing dash" {
  export FAKE_GH_TITLE="Handle the case where the user pastes a very long title into the form"
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD)
  slug="${branch#sucre/12-}"
  [ "${#slug}" -le 40 ]
  [[ "$slug" != *- ]]
  [[ "$slug" == handle-the-case-where-the-user-pastes* ]]
}

@test "spawn copies the repo's .larceny/config.md into the worktree" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  cmp "$WS/api/.larceny/config.md" "$WT/.larceny/config.md"
}

@test "spawn runs hc with the exact argv" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  grep -qxF $'run\t--bg\t--outlive-parent\t--name\tsucre\t--cwd\t'"$WT"$'\t--label\tcrew=demo\t--label\trole=coder\t--label\ttask=api#12\t--\tclaude\t--agent\tlarceny:sucre\t--permission-mode\tauto' "$FAKE_HC_LOG"
}

@test "spawn --model appends --model to the claude argv" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12 --model sonnet
  [ "$status" -eq 0 ]
  grep -qxF $'run\t--bg\t--outlive-parent\t--name\tsucre\t--cwd\t'"$WT"$'\t--label\tcrew=demo\t--label\trole=coder\t--label\ttask=api#12\t--\tclaude\t--agent\tlarceny:sucre\t--permission-mode\tauto\t--model\tsonnet' "$FAKE_HC_LOG"
}

@test "spawn polls until idle and only then sends the prompt" {
  hc_seq get.sucre "$ABSENT" "$STARTING" "$STARTING" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  send_line=$(grep -n $'^send\tsucre\t' "$FAKE_HC_LOG" | head -1 | cut -d: -f1)
  polls=$(head -n "$send_line" "$FAKE_HC_LOG" | grep -c $'^get\tsucre\t')
  [ "$polls" -eq 4 ]
  run_line=$(grep -n $'^run\t' "$FAKE_HC_LOG" | head -1 | cut -d: -f1)
  [ "$run_line" -lt "$send_line" ]
}

@test "spawn dispatch prompt carries the worktree, commands, rules and loh calls" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  log=$(<"$FAKE_HC_LOG")
  [[ "$log" == *"larceny-on-herdr:herdr-runtime"* ]]
  [[ "$log" == *"gh issue view 12 -R acme/api"* ]]
  [[ "$log" == *"$WT"* ]]
  [[ "$log" == *"sucre/12-fix-the-login-bug-retries"* ]]
  [[ "$log" == *"make check"* ]]
  [[ "$log" == *"make lint"* ]]
  [[ "$log" == *"never touch prod"* ]]
  [[ "$log" == *"ask before adding dependencies"* ]]
  [[ "$log" == *"loh gh sucre"* ]]
  [[ "$log" == *"loh git sucre"* ]]
  [[ "$log" == *"loh say amy"* ]]
  [[ "$log" == *"Do not run \`loh say scofield\`"* ]]
  [[ "$log" == *"hc wait --children any"* ]]
  [[ "$log" == *"loh gh sucre pr view <n> --json reviews,headRefOid"* ]]
  [[ "$log" == *"loh gh sucre pr merge <n> --squash --delete-branch"* ]]
  [[ "$log" == *"git branch -D sucre/12-fix-the-login-bug-retries"* ]]
  [[ "$log" == *"Then end your turn; Amy's reply arrives as a new turn"* ]]
  [[ "$log" == *"Merge only after Amy's reply"* ]]
  [[ "$log" == *'loh card note="escalation:<one line>"'* ]]
  [[ "$log" == *"git ls-remote --heads origin sucre/12-fix-the-login-bug-retries"* ]]
  [[ "$log" == *"api -X DELETE repos/"*"/git/refs/heads/sucre/12-fix-the-login-bug-retries"* ]]
  [[ "$log" == *"passing on her verdict"* ]]
  [[ "$log" == *"origin/main"* ]]
}

@test "spawn failure after the worktree exists prints the cleanup commands" {
  export LOH_START_TIMEOUT=1
  hc_seq get.sucre "$ABSENT" "$STARTING"
  run --separate-stderr "$LOH" spawn sucre api 12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"did not reach idle within 1s"* ]]
  [[ "$stderr" == *"  hc kill sucre"* ]]
  [[ "$stderr" == *"  hc rm sucre"* ]]
  [[ "$stderr" == *"  git -C $WS/api worktree remove --force $WT"* ]]
  [[ "$stderr" == *"  git -C $WS/api branch -D sucre/12-fix-the-login-bug-retries"* ]]
}

@test "spawn says the agent exited when it finishes before going idle" {
  hc_seq get.sucre "$ABSENT" "$FINISHED"
  run --separate-stderr "$LOH" spawn sucre api 12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"sucre exited before it was ready"* ]]
  [[ "$stderr" != *"did not reach idle"* ]]
  [[ "$stderr" == *"hc rm sucre"* ]]
  ! grep -q $'^send\t' "$FAKE_HC_LOG"
}

@test "spawn does not print cleanup commands on success" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run --separate-stderr "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"clean up"* ]]
}

@test "two spawns into one repo at once both fetch successfully" {
  # Move origin forward so both spawns have a ref to update.
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/pusher"
  git -C "$BATS_TEST_TMPDIR/pusher" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m more
  git -C "$BATS_TEST_TMPDIR/pusher" push -q origin main
  hc_seq get.sucre "$ABSENT" "$IDLE"
  hc_seq get.mahone "$ABSENT" "$IDLE"
  "$LOH" spawn sucre api 12 >"$BATS_TEST_TMPDIR/a.out" 2>&1 &
  pa=$!
  "$LOH" spawn mahone api 13 >"$BATS_TEST_TMPDIR/b.out" 2>&1 &
  pb=$!
  ra=0
  rb=0
  wait "$pa" || ra=$?
  wait "$pb" || rb=$?
  [ "$ra" -eq 0 ] || cat "$BATS_TEST_TMPDIR/a.out"
  [ "$rb" -eq 0 ] || cat "$BATS_TEST_TMPDIR/b.out"
  [ "$ra" -eq 0 ]
  [ "$rb" -eq 0 ]
  [ -d "$WS/.worktrees/sucre-api-12" ]
  [ -d "$WS/.worktrees/mahone-api-13" ]
}

@test "spawn dispatch prompt does not summarise the ticket" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  ! grep -q "Login Bug" "$FAKE_HC_LOG"
  ! grep -q '{{' "$FAKE_HC_LOG"
}

@test "spawn never sends when the agent stays at status null (trust dialog)" {
  export LOH_START_TIMEOUT=1
  hc_seq get.sucre "$ABSENT" "$STARTING"
  run --separate-stderr "$LOH" spawn sucre api 12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"hc read sucre"* ]]
  ! grep -q $'^send\t' "$FAKE_HC_LOG"
}

@test "spawn refuses when a live terminal holds the name" {
  hc_reply get.sucre "$IDLE"
  run --separate-stderr "$LOH" spawn sucre api 12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"sucre"*"live"* ]]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
  [ ! -d "$WT" ]
}

@test "spawn removes a finished terminal that holds the name first" {
  hc_seq get.sucre "$FINISHED" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  rm_line=$(grep -n $'^rm\tsucre$' "$FAKE_HC_LOG" | head -1 | cut -d: -f1)
  run_line=$(grep -n $'^run\t' "$FAKE_HC_LOG" | head -1 | cut -d: -f1)
  [ -n "$rm_line" ]
  [ "$rm_line" -lt "$run_line" ]
}

@test "spawn dies on an unknown repo" {
  run --separate-stderr "$LOH" spawn sucre nope 12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"nope"* ]]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "spawn dies on a non-numeric ticket" {
  run --separate-stderr "$LOH" spawn sucre api twelve
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"ticket"* ]]
}

@test "spawn dies on a coder name that is not a plain lowercase name" {
  run --separate-stderr "$LOH" spawn "../x" api 12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"coder"* ]]
}

@test "spawn dies when the repo has no .larceny/config.md" {
  rm "$WS/api/.larceny/config.md"
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run --separate-stderr "$LOH" spawn sucre api 12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"config.md"* ]]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "spawn stops before hc run when git worktree add fails" {
  git -C "$WS/api" branch sucre/12-fix-the-login-bug-retries origin/main
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run --separate-stderr "$LOH" spawn sucre api 12
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"worktree"* ]]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
  ! grep -q $'^send\t' "$FAKE_HC_LOG"
}

@test "spawn with too few arguments prints usage" {
  run --separate-stderr "$LOH" spawn sucre api
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh spawn"* ]]
}

@test "spawn tells the coder the configured reviewer and coordinator" {
  printf 'coders: Mia, Ana\nreviewer: Gretchen\n' >>"$WS/api/.larceny/config.md"
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  log=$(<"$FAKE_HC_LOG")
  [[ "$log" == *'loh say gretchen "PR #<n> ready for review'* ]]
  [[ "$log" == *"Gretchen reviews on GitHub"* ]]
  [[ "$log" == *"Merge only after Gretchen's reply"* ]]
  [[ "$log" == *'Do not run `loh say mia`'* ]]
  [[ "$log" != *"loh say amy"* && "$log" != *"loh say scofield"* && "$log" != *"Amy"* ]]
}

# --- --brief / --brief-file: dispatch context in the first prompt -----------

@test "spawn --brief puts the text in the first prompt under its own heading, between context and closing instructions" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12 --brief "Hold for Matt's go before merging."
  [ "$status" -eq 0 ]
  log=$(<"$FAKE_HC_LOG")
  [[ "$log" == *$'\n## From the coordinator, for this dispatch:\n\nHold for Matt\'s go before merging.\n\n## Identity'* ]]
  [[ "${log%%From the coordinator*}" == *"never touch prod"* ]]
  [[ "${log#*From the coordinator}" == *"## Identity: use loh"* ]]
  [ "$(grep -c $'^send\tsucre\t' "$FAKE_HC_LOG")" -eq 1 ]
}

@test "spawn --brief-file reads a multi-line brief from the file" {
  printf 'First line.\n\nSecond paragraph.\n' >"$BATS_TEST_TMPDIR/brief.md"
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12 --brief-file "$BATS_TEST_TMPDIR/brief.md"
  [ "$status" -eq 0 ]
  log=$(<"$FAKE_HC_LOG")
  [[ "$log" == *$'## From the coordinator, for this dispatch:\n\nFirst line.\n\nSecond paragraph.\n\n## Identity'* ]]
}

@test "spawn without a brief sends the prompt with no brief heading and the sections joined as before" {
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12
  [ "$status" -eq 0 ]
  log=$(<"$FAKE_HC_LOG")
  [[ "$log" != *"From the coordinator"* ]]
  [[ "$log" != *"{{"* ]]
  [[ "$log" == *$'- ask before adding dependencies\n\n## Identity: use loh'* ]]
}

@test "spawn --brief keeps &, backslashes, {{placeholders}} and newlines verbatim" {
  brief=$'a & b \\1 \\\\ {{coder}} {{rules}} {{brief}}\nline two $HOME `x` "q"'
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12 --brief "$brief"
  [ "$status" -eq 0 ]
  log=$(<"$FAKE_HC_LOG")
  [[ "$log" == *$'\n\n'"$brief"$'\n\n## Identity'* ]]
}

@test "spawn --brief-file keeps special characters verbatim" {
  printf '%s\n' 'x & y \0 {{ticket}} {{base}}' 'second $(echo no)' >"$BATS_TEST_TMPDIR/b.md"
  hc_seq get.sucre "$ABSENT" "$IDLE"
  run "$LOH" spawn sucre api 12 --brief-file "$BATS_TEST_TMPDIR/b.md"
  [ "$status" -eq 0 ]
  log=$(<"$FAKE_HC_LOG")
  [[ "$log" == *$'\n\nx & y \\0 {{ticket}} {{base}}\nsecond $(echo no)\n\n## Identity'* ]]
}

@test "spawn with both --brief and --brief-file is a usage error and spawns nothing" {
  echo hi >"$BATS_TEST_TMPDIR/b.md"
  run --separate-stderr "$LOH" spawn sucre api 12 --brief x --brief-file "$BATS_TEST_TMPDIR/b.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh spawn"* ]]
  [ ! -e "$WT" ]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "spawn with an empty --brief is a usage error and spawns nothing" {
  run --separate-stderr "$LOH" spawn sucre api 12 --brief ""
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"empty"* ]]
  [ ! -e "$WT" ]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "spawn with a whitespace-only --brief-file is a usage error and spawns nothing" {
  printf '  \n\n' >"$BATS_TEST_TMPDIR/b.md"
  run --separate-stderr "$LOH" spawn sucre api 12 --brief-file "$BATS_TEST_TMPDIR/b.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"empty"* ]]
  [ ! -e "$WT" ]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "spawn with a missing --brief-file is a usage error and spawns nothing" {
  run --separate-stderr "$LOH" spawn sucre api 12 --brief-file "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"nope.md"* ]]
  [ ! -e "$WT" ]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "spawn --brief without a value is a usage error" {
  run --separate-stderr "$LOH" spawn sucre api 12 --brief
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh spawn"* ]]
}

@test "spawn usage line shows --brief and --brief-file" {
  run --separate-stderr "$LOH" spawn sucre api
  [[ "$stderr" == *"--brief <text>"* && "$stderr" == *"--brief-file <path>"* ]]
}
