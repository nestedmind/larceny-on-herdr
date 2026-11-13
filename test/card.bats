#!/usr/bin/env bats
# Tests for `loh card`, with the fake hc from test/fakes.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  use_fake_hc
  LOH="$REPO_ROOT/bin/loh"
  export HC_TERMINAL_ID=t9
}

@test "card sets one allowed field on the agent's own terminal" {
  run "$LOH" card step="writing tests"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tstep=writing tests' ]
}

@test "card sets several fields in one hc call" {
  run "$LOH" card pr=88 round=2 note="waiting on Amy"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tpr=88\tround=2\tnote=waiting on Amy' ]
}

@test "card with an empty value passes it on so hc removes the label" {
  run "$LOH" card note=
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tnote=' ]
}

@test "card refuses the protected keys and calls hc not at all" {
  local key
  for key in with_matt crew role task ctx; do
    run --separate-stderr "$LOH" card "$key=x"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"$key"* ]]
    [[ "$stderr" == *"set by loh"* ]]
  done
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "card refuses a protected key even next to an allowed one" {
  run "$LOH" card step=ok with_matt=1
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "card refuses a key that is not on the allowed list" {
  run --separate-stderr "$LOH" card colour=red
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"colour"* ]]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "card refuses an argument without an equals sign" {
  run "$LOH" card step
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "card with no arguments prints usage and exits 2" {
  run --separate-stderr "$LOH" card
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh card"* ]]
}

@test "card outside a herdr terminal fails clearly" {
  unset HC_TERMINAL_ID
  run --separate-stderr "$LOH" card step=x
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"HC_TERMINAL_ID"* ]]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "card cuts values to 60 characters and strips control characters" {
  local long
  long="$(printf 'b%.0s' {1..100})"
  run "$LOH" card step="x"$'\n'"y${long}"
  [ "$status" -eq 0 ]
  local value
  value="$(cut -f3 "$FAKE_HC_LOG")"
  [ "${#value}" -eq $((5 + 60)) ]
  [[ "$value" == step=xybbb* ]]
}
