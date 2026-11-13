#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper
load loh_helper

setup() {
  make_workspace
  use_fake_hc_only
  use_hc_script
  LOH="$REPO_ROOT/bin/loh"
  hc_reply ls '{"terminals":[
    {"address":"t1","name":"scofield","state":"live"},
    {"address":"t2","name":"amy","state":"live"},
    {"address":"t3","name":"sucre","state":"live"},
    {"address":"t4","name":"mahone","state":"live"},
    {"address":"t5","name":"stranger","state":"live"},
    {"address":"t6","name":"other-crew","state":"live"},
    {"address":"t7","name":"loh-watch","state":"live"}]}'
  hc_reply get.scofield '{"state":"live","labels":{"crew":"demo","role":"coordinator"}}'
  hc_reply get.amy '{"state":"live","labels":{"crew":"demo","role":"reviewer"}}'
  hc_reply get.sucre '{"state":"live","labels":{"crew":"demo","role":"coder","task":"api#12"}}'
  hc_reply get.mahone '{"state":"live","labels":["crew=demo","role=coder","task=api#13"]}'
  hc_reply get.stranger '{"state":"live","labels":{}}'
  hc_reply get.other-crew '{"state":"live","labels":{"crew":"elsewhere","role":"coder"}}'
  hc_reply get.loh-watch '{"state":"live","labels":{"crew":"demo","role":"watch"}}'
  unset HC_TERMINAL_ID
}

@test "down kills only this crew's coders" {
  run "$LOH" down
  [ "$status" -eq 0 ]
  grep -qxF $'kill\tsucre' "$FAKE_HC_LOG"
  grep -qxF $'kill\tmahone' "$FAKE_HC_LOG"
  ! grep -q $'^kill\tscofield' "$FAKE_HC_LOG"
  ! grep -q $'^kill\tamy' "$FAKE_HC_LOG"
  ! grep -q $'^kill\tstranger' "$FAKE_HC_LOG"
  ! grep -q $'^kill\tother-crew' "$FAKE_HC_LOG"
}

@test "down --all also ends scofield and amy but still skips other crews" {
  run "$LOH" down --all
  [ "$status" -eq 0 ]
  for n in sucre mahone scofield amy; do
    grep -qxF $'kill\t'"$n" "$FAKE_HC_LOG"
  done
  ! grep -q $'^kill\tstranger' "$FAKE_HC_LOG"
  ! grep -q $'^kill\tother-crew' "$FAKE_HC_LOG"
}

@test "down --all ends loh-watch too, and plain down leaves it" {
  run "$LOH" down
  ! grep -qxF $'kill\tloh-watch' "$FAKE_HC_LOG"
  : >"$FAKE_HC_LOG"
  run "$LOH" down --all
  grep -qxF $'kill\tloh-watch' "$FAKE_HC_LOG"
}

@test "down --all run inside scofield ends everyone else first and scofield last" {
  export HC_TERMINAL_ID=t1
  run "$LOH" down --all
  [ "$status" -eq 0 ]
  for n in amy sucre mahone loh-watch scofield; do
    grep -qxF $'kill\t'"$n" "$FAKE_HC_LOG"
  done
  last=$(grep '^kill' "$FAKE_HC_LOG" | tail -n 1)
  [ "$last" = $'kill\tscofield' ]
  [[ "$output" == *"ended amy"* ]]
  [[ "$output" == *"ended scofield (this terminal, last)"* ]]
  ! grep -q $'^kill\tstranger' "$FAKE_HC_LOG"
}

@test "down from inside a coder that is not in scope still ends the coders" {
  export HC_TERMINAL_ID=t5
  run "$LOH" down
  [ "$status" -eq 0 ]
  grep -qxF $'kill\tsucre' "$FAKE_HC_LOG"
  grep -qxF $'kill\tmahone' "$FAKE_HC_LOG"
}

@test "down says what it ended" {
  run "$LOH" down
  [ "$status" -eq 0 ]
  [[ "$output" == *"ended sucre"* ]]
  [[ "$output" == *"ended mahone"* ]]
}

@test "down with nothing to end exits 0" {
  hc_reply ls '{"terminals":[]}'
  run "$LOH" down
  [ "$status" -eq 0 ]
  ! grep -q $'^kill\t' "$FAKE_HC_LOG"
}

@test "down rejects an unknown option" {
  run --separate-stderr "$LOH" down --nuke
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh down"* ]]
}
