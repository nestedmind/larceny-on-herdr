#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper
load loh_helper

ABSENT='{}'
IDLE='{"state":"live","status":{"state":"idle"}}'
FINISHED='{"state":"finished","status":{"state":"done"}}'
LIVE='{"state":"live","status":{"state":"idle"},"labels":{"crew":"demo"}}'

setup() {
  make_workspace
  use_fake_hc_only
  use_hc_script
  export LOH_POLL=0.05
  export LOH_START_TIMEOUT=2
  export LARCENY_CONFIG_DIR="$BATS_TEST_TMPDIR/larceny-global"
  mkdir -p "$LARCENY_CONFIG_DIR"
  LOH="$REPO_ROOT/bin/loh"
}

@test "start yoda runs a named, parentless advisor terminal in the workspace folder" {
  hc_seq get.yoda "$ABSENT" "$IDLE"
  run "$LOH" start yoda
  [ "$status" -eq 0 ]
  grep -qxF $'run\t--bg\t--no-parent\t--name\tyoda\t--cwd\t'"$WS"$'\t--label\tcrew=demo\t--label\trole=advisor\t--\tclaude\t--agent\tlarceny:yoda\t--permission-mode\tauto' "$FAKE_HC_LOG"
  [[ "$output" == *"started yoda"* ]]
}

@test "start sara, maya and opemipo use their own role and agent" {
  for n in sara maya opemipo; do hc_seq "get.$n" "$ABSENT" "$IDLE"; done
  run "$LOH" start sara
  [ "$status" -eq 0 ]
  run "$LOH" start maya
  [ "$status" -eq 0 ]
  run "$LOH" start opemipo
  [ "$status" -eq 0 ]
  grep -qxF $'run\t--bg\t--no-parent\t--name\tsara\t--cwd\t'"$WS"$'\t--label\tcrew=demo\t--label\trole=teacher\t--\tclaude\t--agent\tlarceny:sara\t--permission-mode\tauto' "$FAKE_HC_LOG"
  grep -qxF $'run\t--bg\t--no-parent\t--name\tmaya\t--cwd\t'"$WS"$'\t--label\tcrew=demo\t--label\trole=designer\t--\tclaude\t--agent\tmaya\t--permission-mode\tauto' "$FAKE_HC_LOG"
  grep -qxF $'run\t--bg\t--no-parent\t--name\topemipo\t--cwd\t'"$WS"$'\t--label\tcrew=demo\t--label\trole=researcher\t--\tclaude\t--agent\topemipo\t--permission-mode\tauto' "$FAKE_HC_LOG"
}

@test "start passes pane_mode from the manifest" {
  sed -i 's/^pane_mode: auto/pane_mode: plan/' "$WS/.loh/workspace.md"
  hc_seq get.yoda "$ABSENT" "$IDLE"
  run "$LOH" start yoda
  [ "$status" -eq 0 ]
  grep -q -- $'--agent\tlarceny:yoda\t--permission-mode\tplan$' "$FAKE_HC_LOG"
}

@test "start passes the model a repo's models block names for that persona" {
  printf 'models: default\n  yoda: opus\n  sara: haiku\n' >>"$WS/api/.larceny/config.md"
  hc_seq get.yoda "$ABSENT" "$IDLE"
  run "$LOH" start yoda
  [ "$status" -eq 0 ]
  grep -q -- $'--agent\tlarceny:yoda\t--permission-mode\tauto\t--model\topus$' "$FAKE_HC_LOG"
}

@test "start leaves --model off when models names none for the persona" {
  printf 'models: default\n  sara: haiku\n' >>"$WS/api/.larceny/config.md"
  hc_seq get.yoda "$ABSENT" "$IDLE"
  run "$LOH" start yoda
  [ "$status" -eq 0 ]
  ! grep -q -- '--model' "$FAKE_HC_LOG"
}

@test "start leaves --model off when models is harness-default with no override" {
  printf 'models: harness-default\n' >>"$WS/api/.larceny/config.md"
  hc_seq get.yoda "$ABSENT" "$IDLE"
  run "$LOH" start yoda
  [ "$status" -eq 0 ]
  ! grep -q -- '--model' "$FAKE_HC_LOG"
}

@test "start reads models from the global file when the repo says crew: global" {
  printf 'crew: global\n' >>"$WS/api/.larceny/config.md"
  printf 'models: default\n  yoda: sonnet\n' >"$LARCENY_CONFIG_DIR/global-config.md"
  hc_seq get.yoda "$ABSENT" "$IDLE"
  run "$LOH" start yoda
  [ "$status" -eq 0 ]
  grep -q -- $'--model\tsonnet$' "$FAKE_HC_LOG"
}

@test "start ignores the global models block when the repo does not follow global" {
  printf 'models: default\n  yoda: sonnet\n' >"$LARCENY_CONFIG_DIR/global-config.md"
  hc_seq get.yoda "$ABSENT" "$IDLE"
  run "$LOH" start yoda
  [ "$status" -eq 0 ]
  ! grep -q -- '--model' "$FAKE_HC_LOG"
}

@test "start sends a founding prompt naming the workspace, repos and herdr-runtime" {
  hc_seq get.maya "$ABSENT" "$IDLE"
  run "$LOH" start maya
  [ "$status" -eq 0 ]
  log=$(<"$FAKE_HC_LOG")
  [[ "$log" == *$'send\tmaya\t'*"larceny-on-herdr:herdr-runtime"* ]]
  [[ "$log" == *"workspace \"demo\""* ]]
  [[ "$log" == *"acme/api"* ]]
}

@test "start leaves a live agent of this crew alone" {
  hc_reply get.yoda "$LIVE"
  run "$LOH" start yoda
  [ "$status" -eq 0 ]
  [[ "$output" == *"yoda already live"* ]]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "start refuses an agent that is live for another crew" {
  hc_reply get.yoda '{"state":"live","status":{"state":"idle"},"labels":{"crew":"other"}}'
  run --separate-stderr "$LOH" start yoda
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"yoda is live for crew 'other', not 'demo'"* ]]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "start removes a finished terminal that holds the name, then starts" {
  hc_seq get.yoda "$FINISHED" "$IDLE"
  run "$LOH" start yoda
  [ "$status" -eq 0 ]
  grep -q $'^rm\tyoda' "$FAKE_HC_LOG"
  grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "start refuses a name it cannot start and a missing name" {
  run --separate-stderr "$LOH" start scofield
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh start <yoda|sara|maya|opemipo>"* ]]
  run --separate-stderr "$LOH" start
  [ "$status" -eq 2 ]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}
