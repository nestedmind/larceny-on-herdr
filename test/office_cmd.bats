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

@test "a failed close is only a note: exit 0, no warning, the old id replaced by the new one" {
  fresh_heartbeat
  echo tbOLD >"$WS/.loh/office-tab"
  export FAKE_APP_CLOSE_EXIT=1
  run --separate-stderr "$LOH" office
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: could not close the old office tab tbOLD"* ]]
  [[ "$stderr" != *warning* ]]
  [ "$(cat "$WS/.loh/office-tab")" = tb1 ]
}

@test "a saved id with a stale heartbeat is still closed: a hidden office tab sends no heartbeat" {
  echo tbOLD >"$WS/.loh/office-tab"
  echo 1 >"$WS/.loh/office-open"
  run "$LOH" office
  [ "$status" -eq 0 ]
  grep $'^do\t' "$FAKE_APP_LOG" | cut -f2 >"$BATS_TEST_TMPDIR/order"
  [ "$(cat "$BATS_TEST_TMPDIR/order")" = $'tab.new\ntab.close' ]
  grep -qxF $'do\ttab.close\t--id\ttbOLD' "$FAKE_APP_LOG"
  [ "$(cat "$WS/.loh/office-tab")" = tb1 ]
}

@test "a saved id with no heartbeat file at all is closed too, and no by-hand message is printed" {
  echo tbOLD >"$WS/.loh/office-tab"
  run "$LOH" office
  [ "$status" -eq 0 ]
  grep -qxF $'do\ttab.close\t--id\ttbOLD' "$FAKE_APP_LOG"
  [[ "$output" != *"by hand"* ]]
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

@test "a failed tab.new shows herdr-app's own error as well as the command" {
  export FAKE_APP_NEW_EXIT=1
  run --separate-stderr "$LOH" office
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"tab.new failed: boom"* ]]
  [[ "$stderr" == *"herdr-app do tab.new --name office"* ]]
}

@test "a stderr line on a successful tab.new still saves the tab id" {
  export FAKE_APP_WARN=1
  run "$LOH" office
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/.loh/office-tab")" = tb1 ]
}

@test "with no space open it makes one with space.new, then opens the tab" {
  export FAKE_APP_SPACE=0
  run "$LOH" office
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened the office tab"* ]]
  [ "$(grep -n $'^do\tspace.new' "$FAKE_APP_LOG" | cut -d: -f1)" -lt "$(grep -n $'^do\ttab.new' "$FAKE_APP_LOG" | cut -d: -f1)" ]
  [ "$(cat "$WS/.loh/office-tab")" = tb1 ]
}

@test "with a space open it does not call space.new" {
  run "$LOH" office
  [ "$status" -eq 0 ]
  ! grep -q $'^do\tspace.new' "$FAKE_APP_LOG"
}

@test "when space.new fails it shows herdr-app's error and opens no tab" {
  export FAKE_APP_SPACE=0 FAKE_APP_SPACE_EXIT=1
  run --separate-stderr "$LOH" office
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"space.new failed: boom"* ]]
  ! grep -q $'^do\ttab.new' "$FAKE_APP_LOG"
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

# loh office lights [on|off]

lights_file() { echo "$WS/.loh/office-lights"; }

@test "office lights off writes the choice and a stamp, and on writes it again with a newer stamp" {
  run "$LOH" office lights off
  [ "$status" -eq 0 ]
  read -r s1 t1 <"$(lights_file)"
  [ "$s1" = off ]
  [[ "$t1" =~ ^[0-9]+$ ]]
  run "$LOH" office lights on
  [ "$status" -eq 0 ]
  read -r s2 t2 <"$(lights_file)"
  [ "$s2" = on ]
  [ "$t2" -gt "$t1" ]
}

@test "office lights off twice still gives a new stamp, so the second one wins over a button press between" {
  "$LOH" office lights off
  read -r _ t1 <"$(lights_file)"
  "$LOH" office lights off
  read -r _ t2 <"$(lights_file)"
  [ "$t2" -gt "$t1" ]
}

@test "office lights with no argument prints the current state, on when none was set" {
  run "$LOH" office lights
  [ "$status" -eq 0 ]
  [ "$output" = on ]
  "$LOH" office lights off
  run "$LOH" office lights
  [ "$output" = off ]
  [ ! -e "$WS/.loh/office-lights.tmp" ]
}

@test "office lights with another argument prints usage and exits 2, writing nothing" {
  run --separate-stderr "$LOH" office lights dim
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh office lights [on|off]"* ]]
  run --separate-stderr "$LOH" office lights on now
  [ "$status" -eq 2 ]
  [ ! -e "$(lights_file)" ]
}

@test "office lights does not need herdr-app" {
  PATH="/usr/bin:/bin" run "$LOH" office lights off
  [ "$status" -eq 0 ]
  [ -s "$(lights_file)" ]
}

@test "office-ping prints the lights record for the office, none when none was set" {
  cp "$REPO_ROOT/lib/loh/office-ping.sh" "$PLUGIN_TREE/lib/loh/office-ping.sh"
  run "$LOH" office-ping
  [ "$status" -eq 0 ]
  [ "$output" = "chime on" ]
  "$LOH" office lights off
  read -r _ t <"$(lights_file)"
  run "$LOH" office-ping
  [ "$output" = $'lights off '"$t"$'\nchime on' ]
}

@test "office lights stamps stay increasing when the clock gives only seconds or goes back" {
  printf '#!/bin/sh\n[ "$1" = "+%%s%%N" ] && echo "1700000000%%N" || echo 1700000000\n' >"$BATS_TEST_TMPDIR/stubs/date"
  chmod +x "$BATS_TEST_TMPDIR/stubs/date"
  "$LOH" office lights off
  read -r _ t1 <"$(lights_file)"
  [ "$t1" = 1700000000000000000 ]
  "$LOH" office lights off
  read -r _ t2 <"$(lights_file)"
  [ "$t2" = 1700000000000000001 ]
}

@test "office-ping --lights records what the office shows, and bad arguments are usage" {
  cp "$REPO_ROOT/lib/loh/office-ping.sh" "$PLUGIN_TREE/lib/loh/office-ping.sh"
  run "$LOH" office-ping --lights off
  [ "$status" -eq 0 ]
  read -r s t <"$WS/.loh/office-lights-shown"
  [ "$s" = off ]
  [[ "$t" =~ ^[0-9]+$ ]]
  run "$LOH" office-ping --lights on --seen 123
  [ "$status" -eq 0 ]
  read -r s t u <"$WS/.loh/office-lights-shown"
  [ "$s $u" = "on 123" ]
  for bad in "--lights" "--lights dim" "off" "--dark on" "--seen 5" "--lights on --seen x"; do
    run --separate-stderr "$LOH" office-ping $bad
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"Usage: loh office-ping [--lights on|off] [--seen <stamp>]"* ]]
  done
}

@test "office lights with no argument prints what an open office reports, over the last terminal choice" {
  cp "$REPO_ROOT/lib/loh/office-ping.sh" "$PLUGIN_TREE/lib/loh/office-ping.sh"
  "$LOH" office lights on
  read -r _ t <"$(lights_file)"
  "$LOH" office-ping --lights off --seen "$t"
  run "$LOH" office lights
  [ "$output" = off ]
}

@test "office lights right after a command prints the command's choice, before and after the ping that delivers it" {
  cp "$REPO_ROOT/lib/loh/office-ping.sh" "$PLUGIN_TREE/lib/loh/office-ping.sh"
  "$LOH" office-ping --lights on
  "$LOH" office lights off
  run "$LOH" office lights
  [ "$output" = off ]
  read -r _ t <"$(lights_file)"
  "$LOH" office-ping --lights on
  run "$LOH" office lights
  [ "$output" = off ]
  "$LOH" office-ping --lights off --seen "$t"
  run "$LOH" office lights
  [ "$output" = off ]
  "$LOH" office-ping --lights on --seen "$t"
  run "$LOH" office lights
  [ "$output" = on ]
  # another crew's later stamp, kept in the office's one seen key, also means it has applied this one
  "$LOH" office-ping --lights on --seen "$((t + 1000))"
  run "$LOH" office lights
  [ "$output" = on ]
}

@test "office lights with no argument falls back to the last terminal choice when the office has stopped pinging" {
  cp "$REPO_ROOT/lib/loh/office-ping.sh" "$PLUGIN_TREE/lib/loh/office-ping.sh"
  "$LOH" office lights on
  "$LOH" office-ping --lights off
  echo $(($(date +%s) - 60)) >"$WS/.loh/office-open"
  run "$LOH" office lights
  [ "$output" = on ]
}
