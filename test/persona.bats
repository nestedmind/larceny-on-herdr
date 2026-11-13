#!/usr/bin/env bats
# Tests for `loh gh` and `loh git`.

bats_require_minimum_version 1.5.0
load test_helper

TOKEN="ghp_SECRETtokenVALUE0123456789"

setup() {
  make_plugin_tree
  cp "$REPO_ROOT/lib/loh/gh.sh" "$REPO_ROOT/lib/loh/git.sh" "$PLUGIN_TREE/lib/loh/"
  export LARCENY_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$LARCENY_CONFIG_DIR"
  printf '%s\n' "$TOKEN" >"$LARCENY_CONFIG_DIR/gh-whip-token"
  export FAKE_GH_LOG="$BATS_TEST_TMPDIR/gh.log" FAKE_GH_ENV="$BATS_TEST_TMPDIR/gh.env"
  export FAKE_GIT_LOG="$BATS_TEST_TMPDIR/git.log" FAKE_GIT_ENV="$BATS_TEST_TMPDIR/git.env"
  : >"$FAKE_GH_LOG" >"$FAKE_GH_ENV" >"$FAKE_GIT_LOG" >"$FAKE_GIT_ENV"
  printf '{"id":331368271,"login":"whip-ns"}\n' >"$BATS_TEST_TMPDIR/user.json"
  export FAKE_GH_USER_JSON="$BATS_TEST_TMPDIR/user.json"
  export PATH="$REPO_ROOT/test/fakes:$PATH"
  unset GH_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
}

# Fail if the token text appears in the given files or in $output/$stderr.
assert_no_token_anywhere() {
  [[ "${output:-}" != *"$TOKEN"* ]]
  [[ "${stderr:-}" != *"$TOKEN"* ]]
  ! grep -rqF "$TOKEN" "$FAKE_GH_LOG" "$FAKE_GIT_LOG"
  if [[ -d "$XDG_CACHE_HOME" ]]; then
    ! grep -rqF "$TOKEN" "$XDG_CACHE_HOME"
  fi
}

# ---- loh gh ---------------------------------------------------------------

@test "gh passes its arguments through and sets GH_TOKEN from the persona file" {
  run "$LOH" gh whip pr view 20 --json title
  [ "$status" -eq 0 ]
  [ "$output" = "fake gh ran" ]
  [ "$(cat "$FAKE_GH_LOG")" = $'pr\tview\t20\t--json\ttitle' ]
  [ "$(cat "$FAKE_GH_ENV")" = "GH_TOKEN=$TOKEN" ]
}

@test "gh returns gh's exit status" {
  FAKE_GH_EXIT=4 run "$LOH" gh whip pr view 1
  [ "$status" -eq 4 ]
}

@test "gh honours LARCENY_CONFIG_DIR and picks the file for the named persona" {
  printf 'other-token\n' >"$LARCENY_CONFIG_DIR/gh-amy-token"
  run "$LOH" gh amy issue list
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_ENV")" = "GH_TOKEN=other-token" ]
}

@test "gh falls back to the ambient login silently when the token file is missing" {
  export GH_TOKEN="ambient-token"
  run --separate-stderr "$LOH" gh nobody pr list
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(cat "$FAKE_GH_ENV")" = "GH_TOKEN=ambient-token" ]
}

@test "gh with no token file and no ambient token leaves GH_TOKEN unset" {
  run "$LOH" gh nobody pr list
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_ENV")" = "GH_TOKEN=<unset>" ]
}

@test "gh dies, without printing the path's contents, when the token file is unreadable" {
  chmod 000 "$LARCENY_CONFIG_DIR/gh-whip-token"
  if [ -r "$LARCENY_CONFIG_DIR/gh-whip-token" ]; then skip "running as a user that ignores file modes"; fi
  run --separate-stderr "$LOH" gh whip pr list
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not readable"* ]]
  [ ! -s "$FAKE_GH_LOG" ]
}

@test "gh never leaks the token into argv, stdout, stderr or the identity cache" {
  FAKE_GH_EXIT=1 FAKE_GH_STDERR="gh: HTTP 401" run --separate-stderr \
    "$LOH" gh whip api repos/nestedmind/larceny-on-herdr
  [ "$status" -eq 1 ]
  # the token did reach gh, through the environment only
  [ "$(cat "$FAKE_GH_ENV")" = "GH_TOKEN=$TOKEN" ]
  assert_no_token_anywhere
}

@test "gh rejects invalid persona names with exit 2 and runs nothing" {
  for bad in "Whip" "1whip" "wh ip" "../x" "whip;ls" "-x" ""; do
    run --separate-stderr "$LOH" gh "$bad" pr list
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"invalid persona"* ]] || [[ "$stderr" == *"Usage: loh gh"* ]]
  done
  [ ! -s "$FAKE_GH_LOG" ]
}

@test "gh without a command is a usage error" {
  run --separate-stderr "$LOH" gh whip
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh gh <persona> <args...>"* ]]
}

# ---- loh git --------------------------------------------------------------

@test "git passes argv through with the persona identity and GH_TOKEN set" {
  run "$LOH" git whip commit -m "Add a thing"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GIT_LOG")" = $'commit\t-m\tAdd a thing' ]
  run cat "$FAKE_GIT_ENV"
  [[ "$output" == *"GIT_AUTHOR_NAME=whip-ns"* ]]
  [[ "$output" == *"GIT_AUTHOR_EMAIL=331368271+whip-ns@users.noreply.github.com"* ]]
  [[ "$output" == *"GIT_COMMITTER_NAME=whip-ns"* ]]
  [[ "$output" == *"GIT_COMMITTER_EMAIL=331368271+whip-ns@users.noreply.github.com"* ]]
  [[ "$output" == *"GH_TOKEN=$TOKEN"* ]]
}

@test "git looks the identity up with the persona's token and caches it" {
  run "$LOH" git whip status
  [ "$status" -eq 0 ]
  cache="$XDG_CACHE_HOME/larceny-on-herdr/identity-whip"
  [ -f "$cache" ]
  grep -qF "whip-ns" "$cache"
  grep -qF "331368271+whip-ns@users.noreply.github.com" "$cache"
  [ "$(grep -c $'^api\tuser' "$FAKE_GH_LOG")" -eq 1 ]
  [ "$(cat "$FAKE_GH_ENV")" = "GH_TOKEN=$TOKEN" ]
  assert_no_token_anywhere
}

@test "git uses the cache on the second call and does not call gh again" {
  "$LOH" git whip status
  : >"$FAKE_GH_LOG"
  printf '{"id":1,"login":"changed"}\n' >"$FAKE_GH_USER_JSON"
  run "$LOH" git whip status
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_LOG" ]
  tail -n 6 "$FAKE_GIT_ENV" | grep -q "GIT_AUTHOR_NAME=whip-ns"
}

@test "git returns git's exit status" {
  FAKE_GIT_EXIT=128 run "$LOH" git whip push
  [ "$status" -eq 128 ]
}

@test "git fails clearly, caches nothing, when gh api user fails" {
  FAKE_GH_API_EXIT=1 run --separate-stderr "$LOH" git whip status
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not read the GitHub identity for whip"* ]]
  [ ! -e "$XDG_CACHE_HOME/larceny-on-herdr/identity-whip" ]
  [ ! -s "$FAKE_GIT_LOG" ]
  assert_no_token_anywhere
}

@test "git fails clearly, caches nothing, when gh api user returns no login" {
  printf '{"message":"Bad credentials"}\n' >"$FAKE_GH_USER_JSON"
  run --separate-stderr "$LOH" git whip status
  [ "$status" -eq 1 ]
  [ ! -e "$XDG_CACHE_HOME/larceny-on-herdr/identity-whip" ]
}

@test "git with no token file runs git unchanged, with no identity variables" {
  run "$LOH" git nobody log
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GIT_LOG")" = "log" ]
  run cat "$FAKE_GIT_ENV"
  [[ "$output" == *"GIT_AUTHOR_NAME=<unset>"* ]]
  [[ "$output" == *"GH_TOKEN=<unset>"* ]]
  [ ! -s "$FAKE_GH_LOG" ]
}

@test "git never runs git config itself" {
  "$LOH" git whip status
  ! grep -q '^config' "$FAKE_GIT_LOG"
}

@test "git never leaks the token when git fails" {
  FAKE_GIT_EXIT=1 run --separate-stderr "$LOH" git whip push origin main
  [ "$status" -eq 1 ]
  assert_no_token_anywhere
}

@test "git rejects invalid persona names with exit 2 and runs nothing" {
  for bad in "Whip" "1whip" "../x" "whip;ls" "-x"; do
    run --separate-stderr "$LOH" git "$bad" status
    [ "$status" -eq 2 ]
  done
  [ ! -s "$FAKE_GIT_LOG" ]
  [ ! -s "$FAKE_GH_LOG" ]
}

@test "git rejects a persona whose cached login is malformed" {
  mkdir -p "$XDG_CACHE_HOME/larceny-on-herdr"
  printf 'bad name\nx@y\n' >"$XDG_CACHE_HOME/larceny-on-herdr/identity-whip"
  run --separate-stderr "$LOH" git whip status
  [ "$status" -eq 1 ]
  [ ! -s "$FAKE_GIT_LOG" ]
}

@test "git without a command is a usage error" {
  run --separate-stderr "$LOH" git whip
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh git <persona> <args...>"* ]]
}
