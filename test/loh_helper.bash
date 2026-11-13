# Helpers for the up/spawn/down tests. Load after test_helper:
#   load test_helper
#   load loh_helper

# use_fake_hc_only: like use_fake_hc, but puts only the fake hc on PATH. The
# up/spawn/down tests drive real git against a temp repo, so any fake git or
# gh in test/fakes must not shadow the real ones.
use_fake_hc_only() {
  export FAKE_HC_LOG="$BATS_TEST_TMPDIR/hc.log"
  : >"$FAKE_HC_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/hcbin"
  ln -sf "$REPO_ROOT/test/fakes/hc" "$BATS_TEST_TMPDIR/hcbin/hc"
  PATH="$BATS_TEST_TMPDIR/hcbin:$PATH"
}

# Per-call fake hc responses: sets FAKE_HC_SCRIPT to a fresh directory.
# See test/fakes/hc for the file naming.
use_hc_script() {
  FAKE_HC_SCRIPT="$BATS_TEST_TMPDIR/hcscript"
  mkdir -p "$FAKE_HC_SCRIPT"
  export FAKE_HC_SCRIPT
}

# hc_reply <key> <json>: write the response file for a script key.
hc_reply() {
  printf '%s\n' "$2" >"$FAKE_HC_SCRIPT/$1"
}

# hc_seq <key> <json>...: write K.1, K.2, ... for a sequence of replies.
hc_seq() {
  local key="$1" i=1
  shift
  for json in "$@"; do
    printf '%s\n' "$json" >"$FAKE_HC_SCRIPT/$key.$i"
    i=$((i + 1))
  done
}

# Build a workspace in $WS with a manifest and a repo "api" (path ./api, a
# real git repo cloned from a bare origin, with a .larceny/config.md).
# Needs git; touches no network.
make_workspace() {
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS/.loh"
  cat >"$WS/.loh/workspace.md" <<'MD'
# workspace
name: demo
pane_mode: auto
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
MD
  local seed="$BATS_TEST_TMPDIR/seed" origin="$BATS_TEST_TMPDIR/origin.git"
  local id=(-c user.name=t -c user.email=t@example.invalid)
  git init -q -b main "$seed"
  echo hi >"$seed/README"
  git -C "$seed" add README
  git -C "$seed" "${id[@]}" commit -q -m init
  git clone -q --bare "$seed" "$origin"
  git clone -q "$origin" "$WS/api"
  mkdir -p "$WS/api/.larceny"
  cat >"$WS/api/.larceny/config.md" <<'MD'
# Larceny config
test: make check
lint: make lint
build: none
rules: never touch prod
rules: ask before adding dependencies
MD
  export LOH_WORKSPACE="$WS"
}

# A stub gh on PATH that answers every call with an issue title.
use_fake_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/ghbin"
  export FAKE_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$FAKE_GH_LOG"
  cat >"$BATS_TEST_TMPDIR/ghbin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
printf '%s\n' "${FAKE_GH_TITLE:-Fix the Login Bug: retries!}"
SH
  chmod +x "$BATS_TEST_TMPDIR/ghbin/gh"
  PATH="$BATS_TEST_TMPDIR/ghbin:$PATH"
}
