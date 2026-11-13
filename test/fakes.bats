#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper
load loh_helper

setup() {
  use_fake_hc
  use_hc_script
}

@test "fake hc without FAKE_HC_SCRIPT still prints {}" {
  unset FAKE_HC_SCRIPT
  run hc get x --json
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "fake hc replays a sequence and repeats the last reply" {
  hc_seq get.a '{"n":1}' '{"n":2}'
  run hc get a --json
  [ "$output" = '{"n":1}' ]
  run hc get a --json
  [ "$output" = '{"n":2}' ]
  run hc get a --json
  [ "$output" = '{"n":2}' ]
}

@test "fake hc prefers <sub>.<arg2> over <sub> and falls back to FAKE_HC_JSON" {
  hc_reply get.a '{"who":"a"}'
  hc_reply get '{"who":"any"}'
  run hc get a --json
  [ "$output" = '{"who":"a"}' ]
  run hc get b --json
  [ "$output" = '{"who":"any"}' ]
  run hc send b hi
  [ "$output" = "{}" ]
}

@test "fake hc takes the exit status from <key>.exit" {
  echo 3 >"$FAKE_HC_SCRIPT/get.gone.exit"
  run hc get gone --json
  [ "$status" -eq 3 ]
}
