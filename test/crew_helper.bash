# Helpers for the lock, open and status tests. Load after test_helper.

# use_routed_hc: put the routed fake hc and the fake herdr-app on PATH, with
# their logs and canned answers in the test's temp dir, and create a workspace
# named "sandbox" that LOH_WORKSPACE points at.
use_routed_hc() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$REPO_ROOT/test/fakes/hc-routed" "$bin/hc"
  cp "$REPO_ROOT/test/fakes/herdr-app" "$bin/herdr-app"
  chmod +x "$bin/hc" "$bin/herdr-app"
  PATH="$bin:$PATH"
  export FAKE_HC_LOG="$BATS_TEST_TMPDIR/hc.log"
  export FAKE_APP_LOG="$BATS_TEST_TMPDIR/app.log"
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc-data"
  : >"$FAKE_HC_LOG"
  : >"$FAKE_APP_LOG"
  mkdir -p "$FAKE_HC_DIR"
  printf '{"hidden_finished":0,"terminals":[]}\n' >"$FAKE_HC_DIR/ls.json"
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS/.loh"
  printf 'name: sandbox\npane_mode: auto\n' >"$WS/.loh/workspace.md"
  export LOH_WORKSPACE="$WS"
}

# add_terminal <name> <address> <labels-json> [state] [kind]: make `hc get`
# answer for the terminal (by name and by address) and list it in `hc ls`.
# The JSON follows the shape of real `hc get --json` output.
add_terminal() {
  local name="$1" addr="$2" labels="$3" state="${4:-idle}" kind="${5:-}"
  local status
  if [[ -n "$kind" ]]; then
    status="{\"app\":\"claude-code\",\"state\":\"$state\",\"kind\":\"$kind\",\"msg\":\"Bash: git push\"}"
  else
    status="{\"app\":\"claude-code\",\"state\":\"$state\"}"
  fi
  local doc
  doc="{\"address\":\"$addr\",\"name\":\"$name\",\"state\":\"live\",\"labels\":$labels,\"status\":$status}"
  printf '%s\n' "$doc" >"$FAKE_HC_DIR/get-$name.json"
  printf '%s\n' "$doc" >"$FAKE_HC_DIR/get-$addr.json"
  jq --arg a "$addr" --arg n "$name" --arg s "$state" \
    '.terminals += [{address: $a, name: $n, state: "live", status: $s}]' \
    "$FAKE_HC_DIR/ls.json" >"$FAKE_HC_DIR/ls.tmp"
  mv "$FAKE_HC_DIR/ls.tmp" "$FAKE_HC_DIR/ls.json"
}
