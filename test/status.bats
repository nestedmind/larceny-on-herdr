#!/usr/bin/env bats
# Tests for loh status, with the routed fake hc.

bats_require_minimum_version 1.5.0
load test_helper
load crew_helper

setup() {
  use_routed_hc
  LOH="$REPO_ROOT/bin/loh"
  add_terminal amy t11 '{"crew":"sandbox","role":"reviewer"}' idle
  add_terminal sucre t9 '{"crew":"sandbox","role":"coder","task":"api#3","step":"editing src/a.js","pr":"4","round":"1"}' working
  add_terminal mahone t10 '{"crew":"sandbox","role":"coder","task":"web#1","step":"git push"}' blocked permission
  add_terminal whip t12 '{"crew":"sandbox","role":"coder","task":"api#5","with_matt":"1"}' idle
}

@test "status asks hc for this crew's terminals only" {
  run "$LOH" status
  [ "$status" -eq 0 ]
  grep -qx $'ls\t--label\tcrew=sandbox\t--json' "$FAKE_HC_LOG"
}

@test "status prints one line per agent" {
  run "$LOH" status
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 4 ]
}

@test "status shows an idle agent with no task and dashes for empty fields" {
  run "$LOH" status
  line="$(printf '%s\n' "$output" | grep '^amy')"
  [[ "$line" == *reviewer* ]]
  [[ "$line" == *idle* ]]
  [[ "$line" != *"with Matt"* ]]
  [[ "$line" == *" - "* ]]
}

@test "status shows a working agent with task, step, PR and round" {
  run "$LOH" status
  line="$(printf '%s\n' "$output" | grep '^sucre')"
  [[ "$line" == *coder* ]]
  [[ "$line" == *api#3* ]]
  [[ "$line" == *working* ]]
  [[ "$line" == *"editing src/a.js"* ]]
  [[ "$line" == *"PR #4"* ]]
  [[ "$line" == *"round 1"* ]]
}

@test "status shows the kind of a blocked agent" {
  run "$LOH" status
  line="$(printf '%s\n' "$output" | grep '^mahone')"
  [[ "$line" == *"blocked (permission)"* ]]
}

@test "status marks a locked agent with Matt" {
  run "$LOH" status
  line="$(printf '%s\n' "$output" | grep '^whip')"
  [[ "$line" == *"with Matt"* ]]
}

@test "status with no live agents prints a message and exits 0" {
  printf '{"hidden_finished":0,"terminals":[]}\n' >"$FAKE_HC_DIR/ls.json"
  run "$LOH" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no crew agents"* ]]
}

@test "status --json prints the same data as a JSON array" {
  run "$LOH" status --json
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -eq 4 ]
  [ "$(jq -r '.[] | select(.name == "sucre") | .task' <<<"$output")" = "api#3" ]
  [ "$(jq -r '.[] | select(.name == "sucre") | .pr' <<<"$output")" = "4" ]
  [ "$(jq -r '.[] | select(.name == "mahone") | .kind' <<<"$output")" = "permission" ]
  [ "$(jq -r '.[] | select(.name == "mahone") | .state' <<<"$output")" = "blocked" ]
  [ "$(jq -r '.[] | select(.name == "whip") | .with_matt' <<<"$output")" = "true" ]
  [ "$(jq -r '.[] | select(.name == "amy") | .with_matt' <<<"$output")" = "false" ]
}

@test "status --json prints an empty array with no agents" {
  printf '{"hidden_finished":0,"terminals":[]}\n' >"$FAKE_HC_DIR/ls.json"
  run "$LOH" status --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "status rejects an unknown option with exit 2" {
  run --separate-stderr "$LOH" status --bogus
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh status"* ]]
}

@test "status --repos prints the manifest's repos as a JSON array, in manifest order" {
  printf 'name: sandbox\nrepos:\n  - name: web\n    path: ./web\n    branch: main\n    github: o/web\n  - name: api\n    path: ./api\n    branch: dev\n    github: o/api\n' >"$WS/.loh/workspace.md"
  run "$LOH" status --repos
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.[].name]' <<<"$output")" = '["web","api"]' ]
  [ "$(jq -r '.[1].branch' <<<"$output")" = "dev" ]
  [ "$(jq -r '.[1].github' <<<"$output")" = "o/api" ]
}

@test "status --repos does not call hc" {
  printf 'name: sandbox\nrepos:\n  - name: api\n    path: ./api\n    branch: main\n    github: o/api\n' >"$WS/.loh/workspace.md"
  run "$LOH" status --repos
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "status --repos fails with a message when the manifest has no repos" {
  run "$LOH" status --repos
  [ "$status" -eq 1 ]
  [[ "$output" == *"no repos"* ]]
}

@test "status rejects --repos together with --json" {
  run "$LOH" status --repos --json
  [ "$status" -eq 2 ]
}
