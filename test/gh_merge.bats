#!/usr/bin/env bats
# `loh gh <persona> pr merge` flips the merged coder's labels at once.

bats_require_minimum_version 1.5.0
load test_helper
load crew_helper

setup() {
  use_routed_hc
  LOH="$REPO_ROOT/bin/loh"
  export LARCENY_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  mkdir -p "$LARCENY_CONFIG_DIR"
  export FAKE_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$FAKE_GH_LOG"
  PATH="$BATS_TEST_TMPDIR/bin:$REPO_ROOT/test/fakes:$PATH"
  rm -f "$BATS_TEST_TMPDIR/bin/gh"
  printf 'name: sandbox\nrepos:\n  - name: api\n    path: ./api\n    branch: main\n    github: o/api\n  - name: web\n    path: ./web\n    branch: main\n    github: o/web\n' >"$WS/.loh/workspace.md"
  add_terminal sucre t9 '{"crew":"sandbox","role":"coder","task":"api#3","pr":"7"}' idle
  add_terminal mahone t10 '{"crew":"sandbox","role":"coder","task":"web#1","pr":"7"}' idle
}

@test "a merge made through loh gh flips the labels of the coder whose pr it was" {
  run "$LOH" gh scofield pr merge 7 -R o/api --squash
  [ "$status" -eq 0 ]
  [ "$output" = "fake gh ran" ]
  grep -qx $'label\tt9\tpr=\tprdone=1\tprstate=merged' "$FAKE_HC_LOG"
}

@test "another repo's coder with the same pr number is not touched" {
  run "$LOH" gh scofield pr merge 7 -R o/api
  [ "$(grep -c '^label' "$FAKE_HC_LOG")" -eq 1 ]
  ! grep -q $'^label\tt10' "$FAKE_HC_LOG"
}

@test "a failed merge changes no label and keeps gh's exit status" {
  FAKE_GH_EXIT=1 run "$LOH" gh scofield pr merge 7 -R o/api
  [ "$status" -eq 1 ]
  ! grep -q '^label' "$FAKE_HC_LOG"
}

@test "a gh call that is not pr merge changes no label" {
  run "$LOH" gh scofield pr view 7 -R o/api
  [ "$status" -eq 0 ]
  run "$LOH" gh scofield pr close 7 -R o/api
  ! grep -q '^label' "$FAKE_HC_LOG"
}

@test "a merge in a repo the crew does not list changes no label" {
  run "$LOH" gh scofield pr merge 7 -R o/other
  [ "$status" -eq 0 ]
  ! grep -q '^label' "$FAKE_HC_LOG"
}

@test "status --merged takes a pr number and a repo" {
  run "$LOH" status --merged x o/api
  [ "$status" -eq 2 ]
}
