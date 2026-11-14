#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  # shellcheck source=../lib/loh/common.sh
  source "$REPO_ROOT/lib/loh/common.sh"
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS/.loh"
  export LOH_WORKSPACE="$WS"
}

write_manifest() {
  cat >"$WS/.loh/workspace.md"
}

@test "manifest_load reads name, pane_mode and repos" {
  write_manifest <<'MD'
# .loh/workspace.md
name: demo
pane_mode: default
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
  - name: web
    path: ./web
    branch: trunk
    github: acme/web
MD
  manifest_load
  [ "$WS_ROOT" = "$WS" ]
  [ "$WS_NAME" = "demo" ]
  [ "$WS_PANE_MODE" = "default" ]
  [ "${#REPO_NAMES[@]}" -eq 2 ]
  [ "${REPO_NAMES[0]}" = "api" ]
  [ "${REPO_PATHS[0]}" = "./api" ]
  [ "${REPO_BRANCHES[0]}" = "main" ]
  [ "${REPO_GITHUBS[0]}" = "acme/api" ]
  [ "${REPO_NAMES[1]}" = "web" ]
  [ "${REPO_BRANCHES[1]}" = "trunk" ]
  [ "${REPO_GITHUBS[1]}" = "acme/web" ]
}

@test "manifest_load defaults pane_mode to auto and accepts quotes" {
  write_manifest <<'MD'
name: "demo"
repos:
  - name: 'api'
    path: ./api
    branch: main
    github: acme/api
MD
  manifest_load
  [ "$WS_NAME" = "demo" ]
  [ "$WS_PANE_MODE" = "auto" ]
  [ "${REPO_NAMES[0]}" = "api" ]
}

@test "manifest_load dies when the manifest is missing" {
  run --separate-stderr manifest_load
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"workspace.md"* ]]
}

@test "manifest_load dies when name is missing" {
  write_manifest <<'MD'
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
MD
  run --separate-stderr manifest_load
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"name:"* ]]
}

@test "manifest_load dies when there are no repos" {
  write_manifest <<'MD'
name: demo
MD
  run --separate-stderr manifest_load
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"repos"* ]]
}

@test "manifest_load dies naming the repo and the missing field" {
  write_manifest <<'MD'
name: demo
repos:
  - name: api
    path: ./api
    github: acme/api
MD
  run --separate-stderr manifest_load
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"api"* ]]
  [[ "$stderr" == *"branch"* ]]
}

@test "manifest_load dies on a line it cannot parse" {
  write_manifest <<'MD'
name: demo
this is not a key
repos:
  - name: api
MD
  run --separate-stderr manifest_load
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"line 2"* ]]
}

@test "manifest_load dies on an invalid pane_mode" {
  write_manifest <<'MD'
name: demo
pane_mode: yolo
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
MD
  run --separate-stderr manifest_load
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pane_mode"* ]]
}

@test "manifest_load dies on an unknown top-level key such as pane_mod" {
  write_manifest <<'MD'
name: demo
pane_mod: default
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
MD
  run --separate-stderr manifest_load
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"line 2"* ]]
  [[ "$stderr" == *"pane_mod"* ]]
}

@test "manifest_load defaults idle_minutes to 3 and reads it when set" {
  write_manifest <<'MD'
name: demo
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
MD
  manifest_load
  [ "$WS_IDLE_MINUTES" = "3" ]
  write_manifest <<'MD'
name: demo
idle_minutes: "12"
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
MD
  manifest_load
  [ "$WS_IDLE_MINUTES" = "12" ]
}

@test "manifest_load dies on an idle_minutes that is not a whole number above zero" {
  local bad
  for bad in 0 -1 2.5 soon; do
    write_manifest <<MD
name: demo
idle_minutes: $bad
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
MD
    run --separate-stderr manifest_load
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"idle_minutes"* ]]
  done
}

@test "manifest_load accepts the board key" {
  write_manifest <<'MD'
board: github-project acme/1
name: demo
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
MD
  manifest_load
  [ "$WS_NAME" = "demo" ]
}

@test "manifest_load refuses pane_mode bypassPermissions" {
  write_manifest <<'MD'
name: demo
pane_mode: bypassPermissions
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
MD
  run --separate-stderr manifest_load
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pane_mode"* ]]
}

@test "manifest_load dies on a duplicate repo name" {
  write_manifest <<'MD'
name: demo
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
  - name: api
    path: ./api2
    branch: main
    github: acme/api2
MD
  run --separate-stderr manifest_load
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"duplicate"* ]]
}

@test "repo_lookup sets REPO_I and dies on an unknown repo" {
  write_manifest <<'MD'
name: demo
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
  - name: web
    path: ./web
    branch: main
    github: acme/web
MD
  manifest_load
  repo_lookup web
  [ "$REPO_I" -eq 1 ]
  run --separate-stderr repo_lookup nope
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"nope"* ]]
}

@test "config_values prints each value for a key in a larceny config" {
  cat >"$BATS_TEST_TMPDIR/config.md" <<'MD'
# Larceny config
test: bats test/
rules: one
rules: two (unconfirmed)
MD
  run config_values "$BATS_TEST_TMPDIR/config.md" test
  [ "$output" = "bats test/" ]
  run config_values "$BATS_TEST_TMPDIR/config.md" rules
  [ "${lines[0]}" = "one" ]
  [ "${lines[1]}" = "two (unconfirmed)" ]
  run config_values "$BATS_TEST_TMPDIR/config.md" lint
  [ -z "$output" ]
}

@test "manifest_load refuses scofield_args and amy_args that change permissions, the agent or settings" {
  local key flag
  for key in scofield_args amy_args; do
    for flag in --dangerously-skip-permissions --allow-dangerously-skip-permissions \
      "--permission-mode bypassPermissions" --permission-mode=bypassPermissions \
      "--agent larceny:yoda" --agent=larceny:yoda "--settings x.json" --settings=x.json \
      "--channels a --dangerously-skip-permissions"; do
      printf 'name: demo\n%s: %s\nrepos:\n  - name: api\n    path: ./api\n    branch: main\n    github: o/api\n' "$key" "$flag" >"$BATS_TEST_TMPDIR/m.md"
      run --separate-stderr bash -c "source '$REPO_ROOT/lib/loh/common.sh'; manifest_path() { echo '$BATS_TEST_TMPDIR/m.md'; }; workspace_root() { echo '$BATS_TEST_TMPDIR'; }; manifest_load"
      [ "$status" -ne 0 ] || { echo "accepted: $key: $flag"; return 1; }
      [[ "$stderr" == *"$key"* ]] || { echo "no key named for: $flag: $stderr"; return 1; }
    done
  done
}
