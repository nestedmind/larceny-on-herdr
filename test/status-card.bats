#!/usr/bin/env bats
# Tests for hooks/status-card.sh. The sample hook JSON in test/fixtures/hooks
# follows the input examples in the Claude Code hooks reference
# (https://code.claude.com/docs/en/hooks). hc is the fake from test/fakes.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  # Only the fake hc goes on PATH: these tests need the real git and jq, and
  # test/fakes also holds fakes for git and gh.
  mkdir -p "$BATS_TEST_TMPDIR/hcbin"
  cp "$REPO_ROOT/test/fakes/hc" "$BATS_TEST_TMPDIR/hcbin/hc"
  PATH="$BATS_TEST_TMPDIR/hcbin:$PATH"
  export FAKE_HC_LOG="$BATS_TEST_TMPDIR/hc.log"
  : >"$FAKE_HC_LOG"
  HOOK="$REPO_ROOT/hooks/status-card.sh"
  FIX="$REPO_ROOT/test/fixtures/hooks"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  export HC_TERMINAL_ID=t9
}

# fixture <name> [jq args... filter]: print a fixture with __CWD__ replaced by
# the test repo, after applying the optional jq arguments and filter.
fixture() {
  local f="$FIX/$1.json"
  shift
  if [[ $# -gt 0 ]]; then
    jq "$@" <"$f" | sed "s|__CWD__|$REPO|g"
  else
    sed "s|__CWD__|$REPO|g" "$f"
  fi
}

# bats `run` cannot take a pipe, so the hook reads its stdin from a file.
run_hook_pipe() {
  local in="$BATS_TEST_TMPDIR/in.json"
  cat >"$in"
  run bash "$HOOK" <"$in"
}

hc_calls() { cat "$FAKE_HC_LOG"; }

label_line() { printf 'label\tt9\t%s\n' "$1"; }

@test "does nothing and exits 0 outside herdr" {
  unset HC_TERMINAL_ID
  run_hook_pipe < <(fixture user-prompt-submit)
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "UserPromptSubmit sets step to reading the prompt" {
  run_hook_pipe < <(fixture user-prompt-submit)
  [ "$status" -eq 0 ]
  [ "$(hc_calls)" = "$(label_line 'step=reading the prompt')" ]
}

@test "PreToolUse Edit sets step to editing the repo-relative file" {
  run_hook_pipe < <(fixture pre-edit)
  [ "$status" -eq 0 ]
  [ "$(hc_calls)" = "$(label_line 'step=editing src/app.js')" ]
}

@test "PreToolUse Write sets step to editing the repo-relative file" {
  run_hook_pipe < <(fixture pre-write)
  [ "$(hc_calls)" = "$(label_line 'step=editing docs/new.md')" ]
}

@test "PreToolUse Bash npm test is running tests with no project config" {
  run_hook_pipe < <(fixture pre-bash)
  [ "$(hc_calls)" = "$(label_line 'step=running tests')" ]
}

@test "PreToolUse Bash matches the test command from .larceny/config.md" {
  mkdir -p "$REPO/.larceny"
  printf 'test: bats test/\nlint: shellcheck bin/loh\n' >"$REPO/.larceny/config.md"
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "bats test/loh.bats"')
  [ "$(hc_calls)" = "$(label_line 'step=running tests')" ]
}

@test "PreToolUse Bash git command shows git and the subcommand" {
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "git status --short"')
  [ "$(hc_calls)" = "$(label_line 'step=git status')" ]
}

@test "PreToolUse Bash gh command shows gh and the subcommand" {
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "gh issue view 16"')
  [ "$(hc_calls)" = "$(label_line 'step=gh issue')" ]
}

@test "PreToolUse Bash through loh git shows the git subcommand" {
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "loh git sheba-ns commit -m x"')
  [ "$(hc_calls)" = "$(label_line 'step=git commit')" ]
}

@test "PreToolUse Bash skips leading VAR=value words" {
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "FOO=1 git push origin main"')
  [ "$(hc_calls)" = "$(label_line 'step=git push')" ]
}

@test "PreToolUse Bash other command is running a command" {
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "ls -la"')
  [ "$(hc_calls)" = "$(label_line 'step=running a command')" ]
}

@test "PreToolUse for another tool is running a command" {
  run_hook_pipe < <(fixture pre-bash '.tool_name = "Grep" | .tool_input = {pattern: "x"}')
  [ "$(hc_calls)" = "$(label_line 'step=running a command')" ]
}

@test "Stop sets step to idle" {
  run_hook_pipe < <(fixture stop)
  [ "$status" -eq 0 ]
  [ "$(hc_calls)" = "$(label_line 'step=idle')" ]
}

@test "PostToolUse gh pr create sets pr from the URL in the result" {
  run_hook_pipe < <(fixture post-bash)
  [ "$status" -eq 0 ]
  [ "$(hc_calls)" = "$(label_line 'pr=88')" ]
}

@test "PostToolUse gh pr create through loh gh sets pr" {
  run_hook_pipe < <(fixture post-bash '.tool_input.command = "loh gh sheba-ns pr create --base main"')
  [ "$(hc_calls)" = "$(label_line 'pr=88')" ]
}

@test "PostToolUse for a command that is not pr create sets nothing" {
  run_hook_pipe < <(fixture post-bash '.tool_input.command = "gh pr view 5"')
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "PostToolUse pr create without a PR URL sets nothing" {
  run_hook_pipe < <(fixture post-bash '.tool_response.stdout = "a pull request create failed"')
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "label values are cut to 60 characters" {
  local long
  long="$(printf 'a%.0s' {1..100}).js"
  run_hook_pipe < <(fixture pre-edit --arg f "$REPO/$long" '.tool_input.file_path = $f')
  local value
  value="$(cut -f3 "$FAKE_HC_LOG")"
  [[ "$value" == "step=editing ..."*".js" ]]
  [ "${#value}" -eq $((5 + 60)) ]
}

@test "label values lose newlines and control characters" {
  run_hook_pipe < <(fixture pre-edit --arg f "$REPO/we"$'\n'"ird"$'\x01'"name.js" '.tool_input.file_path = $f')
  [ "$(hc_calls)" = "$(label_line 'step=editing weirdname.js')" ]
}

@test "a file outside the repo keeps its absolute path" {
  run_hook_pipe < <(fixture pre-edit '.tool_input.file_path = "/etc/hosts"')
  [ "$(hc_calls)" = "$(label_line 'step=editing /etc/hosts')" ]
}

@test "hooks fired inside a subagent do not touch the card" {
  run_hook_pipe < <(fixture pre-edit '.agent_id = "sub1"')
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "exits 0 on empty input" {
  run_hook_pipe < <(:)
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "exits 0 on input that is not JSON" {
  run_hook_pipe < <(printf 'not json at all')
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "exits 0 on JSON with an unknown event" {
  run_hook_pipe < <(fixture stop '.hook_event_name = "SomethingNew"')
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "exits 0 when hc fails" {
  export FAKE_HC_EXIT=1
  run_hook_pipe < <(fixture stop)
  [ "$status" -eq 0 ]
}

@test "exits 0 when hc is not installed" {
  PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin"
  hash -r
  if command -v hc >/dev/null 2>&1; then skip "hc exists in the base PATH"; fi
  run_hook_pipe < <(fixture stop)
  [ "$status" -eq 0 ]
}

@test "hooks.json wires the events to the script with short timeouts" {
  local f="$REPO_ROOT/hooks/hooks.json"
  jq -e '.hooks | has("UserPromptSubmit") and has("PreToolUse") and has("PostToolUse") and has("Stop") and has("StopFailure")' "$f"
  run jq -r '[.hooks[][].hooks[] | select(.type == "command") | .command] | unique | .[]' "$f"
  [ "$status" -eq 0 ]
  [ "$output" = '${CLAUDE_PLUGIN_ROOT}/hooks/status-card.sh' ]
  run jq -e '[.hooks[][].hooks[] | .timeout] | all(. != null and . <= 10)' "$f"
  [ "$status" -eq 0 ]
}

@test "status-card.sh is executable" {
  [ -x "$HOOK" ]
}

@test "StopFailure sets step to idle" {
  run_hook_pipe < <(fixture stop '.hook_event_name = "StopFailure"')
  [ "$status" -eq 0 ]
  [ "$(hc_calls)" = "$(label_line 'step=idle')" ]
}

@test "writes labels when no timeout command is on PATH" {
  local bin="$BATS_TEST_TMPDIR/nopath" t
  mkdir -p "$bin"
  for t in env bash jq git cat tr sed grep dirname head; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  cp "$REPO_ROOT/test/fakes/hc" "$bin/hc"
  PATH="$bin" run command -v timeout
  [ "$status" -ne 0 ]
  PATH="$bin" run command -v gtimeout
  [ "$status" -ne 0 ]
  local in="$BATS_TEST_TMPDIR/in.json"
  fixture stop >"$in"
  run env PATH="$bin" "$(command -v bash)" "$HOOK" <"$in"
  [ "$status" -eq 0 ]
  [ "$(hc_calls)" = "$(label_line 'step=idle')" ]
}

@test "git -C <dir> shows the real subcommand" {
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "git -C /home/x/repo status"')
  [ "$(hc_calls)" = "$(label_line 'step=git status')" ]
}

@test "git -c <k=v> and --git-dir and --work-tree values are skipped" {
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "git -c user.name=x commit -m hi"')
  [ "$(hc_calls)" = "$(label_line 'step=git commit')" ]
  : >"$FAKE_HC_LOG"
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "git --git-dir /a/.git --work-tree /a log"')
  [ "$(hc_calls)" = "$(label_line 'step=git log')" ]
}

@test "loh git <persona> -C <dir> shows the real subcommand" {
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "loh git sheba -C /home/x/repo commit -m hi"')
  [ "$(hc_calls)" = "$(label_line 'step=git commit')" ]
}

@test "gh -R <repo> and --repo <repo> show the real subcommand" {
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "gh -R nestedmind/larceny-on-herdr pr view 24"')
  [ "$(hc_calls)" = "$(label_line 'step=gh pr')" ]
  : >"$FAKE_HC_LOG"
  run_hook_pipe < <(fixture pre-bash '.tool_input.command = "gh --repo o/r issue list"')
  [ "$(hc_calls)" = "$(label_line 'step=gh issue')" ]
}

@test "PostToolUse gh -R <repo> pr create sets pr" {
  run_hook_pipe < <(fixture post-bash '.tool_input.command = "gh -R nestedmind/x pr create --fill"')
  [ "$(hc_calls)" = "$(label_line 'pr=88')" ]
}

@test "PostToolUse loh gh <persona> -R <repo> pr create sets pr" {
  run_hook_pipe < <(fixture post-bash '.tool_input.command = "loh gh sheba -R o/r pr create --fill"')
  [ "$(hc_calls)" = "$(label_line 'pr=88')" ]
}

@test "the repo root comes from the edited file, not from cwd" {
  local other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other/src"
  git init -q "$other"
  run_hook_pipe < <(fixture pre-edit --arg f "$other/src/a.js" '.tool_input.file_path = $f')
  [ "$(hc_calls)" = "$(label_line 'step=editing src/a.js')" ]
}

@test "a new file in a folder that does not exist yet is still relative to its repo" {
  local other="$BATS_TEST_TMPDIR/other2"
  mkdir -p "$other"
  git init -q "$other"
  run_hook_pipe < <(fixture pre-edit --arg f "$other/new/dir/b.js" '.tool_input.file_path = $f')
  [ "$(hc_calls)" = "$(label_line 'step=editing new/dir/b.js')" ]
}

@test "a long path keeps its end, where the file name is" {
  local long
  long="$(printf 'd%.0s' {1..80})/target.js"
  run_hook_pipe < <(fixture pre-edit --arg f "$REPO/$long" '.tool_input.file_path = $f')
  local value
  value="$(cut -f3 "$FAKE_HC_LOG")"
  [[ "$value" == *"/target.js" ]]
  [ "${#value}" -eq $((5 + 60)) ]
}

@test "a relative cwd ends the hook quickly instead of looping" {
  local in="$BATS_TEST_TMPDIR/in.json"
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  fixture pre-bash '.tool_input.command = "ls"' | sed "s|$REPO|rel|g" >"$in"
  cd "$BATS_TEST_TMPDIR/empty"
  run timeout 3 bash "$HOOK" <"$in"
  [ "$status" -eq 0 ]
}
