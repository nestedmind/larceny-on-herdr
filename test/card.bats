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

@test "card sets place to a room, and accepts the room's other spellings" {
  run "$LOH" card place=lounge
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tplace=lounge' ]
  : >"$FAKE_HC_LOG"
  run "$LOH" card place="Ping Pong"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tplace=pong' ]
  : >"$FAKE_HC_LOG"
  run "$LOH" card place="rest room"
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tplace=rest' ]
  : >"$FAKE_HC_LOG"
  run "$LOH" card place="meeting room"
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tplace=meeting' ]
  : >"$FAKE_HC_LOG"
  run "$LOH" card place=kitchen
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tplace=kitchen' ]
  : >"$FAKE_HC_LOG"
  run "$LOH" card place=desk
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tplace=desk' ]
}

@test "card refuses an unknown room, names the rooms, and calls hc not at all" {
  run --separate-stderr "$LOH" card place=roof
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"roof"* ]]
  [[ "$stderr" == *"lounge, kitchen, ping pong, rest room, meeting room, desk"* ]]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "card place= with no value removes the label" {
  run "$LOH" card place=
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tplace=' ]
}

@test "card sets and clears meeting, and refuses any other value" {
  run "$LOH" card meeting=1
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tmeeting=1' ]
  : >"$FAKE_HC_LOG"
  run "$LOH" card meeting=
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tmeeting=' ]
  : >"$FAKE_HC_LOG"
  run --separate-stderr "$LOH" card meeting=yes
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "card help describes place and meeting" {
  run --separate-stderr "$LOH" card
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"place"* && "$stderr" == *"meeting"* ]]
}

@test "card matt=out and matt= set and clear the away label; other values are refused" {
  run "$LOH" card matt=out
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tmatt=out' ]
  : > "$FAKE_HC_LOG"
  run "$LOH" card matt=
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HC_LOG")" = $'label\tt9\tmatt=' ]
  : > "$FAKE_HC_LOG"
  run --separate-stderr "$LOH" card matt=away
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"matt is out"* ]]
  [ ! -s "$FAKE_HC_LOG" ]
}

@test "card help documents matt=out" {
  run --separate-stderr "$LOH" card
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"matt=out"* ]]
}
