#!/usr/bin/env bats
# `loh office`: open the crew's office tab, or reload it.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  make_plugin_tree
  cp "$REPO_ROOT/lib/loh/office.sh" "$PLUGIN_TREE/lib/loh/office.sh"
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS/.loh" "$WS/api/deep" "$BATS_TEST_TMPDIR/stubs"
  printf 'name: demo\nrepos:\n  - name: api\n    path: ./api\n    branch: main\n    github: acme/api\n' >"$WS/.loh/workspace.md"
  export FAKE_APP_LOG="$BATS_TEST_TMPDIR/app.log"
  : >"$FAKE_APP_LOG"
  ln -sf "$REPO_ROOT/test/fakes/herdr-app" "$BATS_TEST_TMPDIR/stubs/herdr-app"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  cd "$WS/api/deep"
}

fresh_heartbeat() { date +%s >"$WS/.loh/office-open"; }

@test "a first open makes the office tab with the crew, dir and loh props, and saves its id" {
  run "$LOH" office
  [ "$status" -eq 0 ]
  [ "$(grep -c $'^do\ttab.new' "$FAKE_APP_LOG")" -eq 1 ]
  line="$(grep $'^do\ttab.new' "$FAKE_APP_LOG")"
  [[ "$line" == $'do\ttab.new\t--name\toffice\t--mod\tcrew-office\t--folder\t'"$WS"$'\t--props\t'* ]]
  props="${line##*--props$'\t'}"
  [ "$(jq -r .crew <<<"$props")" = demo ]
  [ "$(jq -r .dir <<<"$props")" = "$WS" ]
  [ "$(jq -r .loh <<<"$props")" = "$PLUGIN_TREE/bin/loh" ]
  [ "$(cat "$WS/.loh/office-tab")" = tb1 ]
  ! grep -q $'^do\ttab.close' "$FAKE_APP_LOG"
}

@test "a reload opens the new tab first, then closes the old one by its id, then saves the new id" {
  fresh_heartbeat
  echo tbOLD >"$WS/.loh/office-tab"
  run "$LOH" office
  [ "$status" -eq 0 ]
  grep $'^do\t' "$FAKE_APP_LOG" | cut -f2 >"$BATS_TEST_TMPDIR/order"
  [ "$(cat "$BATS_TEST_TMPDIR/order")" = $'tab.new\ntab.close' ]
  grep -qxF $'do\ttab.close\t--id\ttbOLD' "$FAKE_APP_LOG"
  [ "$(cat "$WS/.loh/office-tab")" = tb1 ]
}

@test "an office opened by hand gets a new tab, and the output says to close the old one by hand" {
  fresh_heartbeat
  run "$LOH" office
  [ "$status" -eq 0 ]
  [ "$(grep -c $'^do\ttab.new' "$FAKE_APP_LOG")" -eq 1 ]
  ! grep -q $'^do\ttab.close' "$FAKE_APP_LOG"
  [[ "$output" == *"close the old one by hand"* ]]
  [ "$(cat "$WS/.loh/office-tab")" = tb1 ]
}

@test "a failed close is a warning: exit 0, new id saved" {
  fresh_heartbeat
  echo tbOLD >"$WS/.loh/office-tab"
  export FAKE_APP_CLOSE_EXIT=1
  run --separate-stderr "$LOH" office
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"could not close"* ]]
  [ "$(cat "$WS/.loh/office-tab")" = tb1 ]
}

@test "a saved id with a stale heartbeat is not closed: that tab is gone" {
  echo tbOLD >"$WS/.loh/office-tab"
  echo 1 >"$WS/.loh/office-open"
  run "$LOH" office
  [ "$status" -eq 0 ]
  ! grep -q $'^do\ttab.close' "$FAKE_APP_LOG"
  [ "$(cat "$WS/.loh/office-tab")" = tb1 ]
}

@test "--close closes the saved tab and clears the file" {
  echo tbOLD >"$WS/.loh/office-tab"
  run "$LOH" office --close
  [ "$status" -eq 0 ]
  grep -qxF $'do\ttab.close\t--id\ttbOLD' "$FAKE_APP_LOG"
  [ ! -e "$WS/.loh/office-tab" ]
}

@test "--close with no saved tab says so and closes nothing" {
  run "$LOH" office --close
  [ "$status" -eq 0 ]
  [[ "$output" == *"no office tab is saved"* ]]
  ! grep -q $'^do\ttab.close' "$FAKE_APP_LOG"
}

@test "--close that fails keeps the file and exits 1" {
  echo tbOLD >"$WS/.loh/office-tab"
  export FAKE_APP_CLOSE_EXIT=1
  run --separate-stderr "$LOH" office --close
  [ "$status" -eq 1 ]
  [ "$(cat "$WS/.loh/office-tab")" = tbOLD ]
}

@test "when herdr-app is not running it says so, prints the command and changes nothing" {
  export FAKE_APP_RUNNING=0
  echo tbOLD >"$WS/.loh/office-tab"
  run "$LOH" office
  [ "$status" -eq 0 ]
  [[ "$output" == *"herdr-app is not available"* ]]
  [[ "$output" == *"herdr-app do tab.new --name office --mod crew-office"* ]]
  ! grep -q $'^do\t' "$FAKE_APP_LOG"
  [ "$(cat "$WS/.loh/office-tab")" = tbOLD ]
}

@test "a failed tab.new exits 1, prints the command and keeps the saved id" {
  fresh_heartbeat
  echo tbOLD >"$WS/.loh/office-tab"
  export FAKE_APP_NEW_EXIT=1
  run --separate-stderr "$LOH" office
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not open the office tab"* ]]
  ! grep -q $'^do\ttab.close' "$FAKE_APP_LOG"
  [ "$(cat "$WS/.loh/office-tab")" = tbOLD ]
}

@test "an argument other than --close is a usage error" {
  run --separate-stderr "$LOH" office now
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh office"* ]]
}

@test "outside a workspace it fails" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr "$LOH" office
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"no .loh/workspace.md"* ]]
}

@test "loh help lists office" {
  run "$LOH" help
  [[ "$output" == *"  office"* ]]
}

@test "init builds the office props and command through the shared helpers" {
  grep -q 'office_props' "$REPO_ROOT/lib/loh/init.sh"
  grep -q 'office_props' "$REPO_ROOT/lib/loh/office.sh"
  ! grep -q "jq -cn --arg crew" "$REPO_ROOT/lib/loh/init.sh"
}
