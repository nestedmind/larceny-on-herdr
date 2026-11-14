#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper
load loh_helper

# In these tests the first `hc get <name>` is loh's liveness check. `{}` means
# no such terminal; later replies are the idle polls after `hc run`.
ABSENT='{}'
STARTING='{"state":"live","status":null}'
IDLE='{"state":"live","status":{"state":"idle"}}'
FINISHED='{"state":"finished","status":{"state":"done"}}'

setup() {
  make_workspace
  use_fake_hc_only
  use_hc_script
  export LOH_POLL=0.05
  export LOH_START_TIMEOUT=2
  # A copy of the plugin without watch.sh, so these tests do not depend on
  # whether loh watch exists in this checkout.
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/bin" "$TREE/lib/loh" "$TREE/.claude-plugin"
  cp "$REPO_ROOT/bin/loh" "$TREE/bin/loh"
  cp "$REPO_ROOT"/lib/loh/*.sh "$TREE/lib/loh/"
  rm -f "$TREE/lib/loh/watch.sh"
  cp "$REPO_ROOT/.claude-plugin/plugin.json" "$TREE/.claude-plugin/"
  LOH="$TREE/bin/loh"
}

LIVE='{"state":"live","status":{"state":"idle"},"labels":{"crew":"demo"}}'

@test "up refuses a live scofield that belongs to another crew" {
  hc_reply get.scofield '{"state":"live","status":{"state":"idle"},"labels":{"crew":"sandbox"}}'
  hc_reply get.amy "$LIVE"
  run --separate-stderr "$LOH" up
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"scofield is live for crew 'sandbox', not 'demo'"* ]]
  [[ "$stderr" == *"loh down --all"* ]]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "up refuses a live amy with no crew label" {
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy '{"state":"live","status":{"state":"idle"}}'
  run --separate-stderr "$LOH" up
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"amy is live for crew 'none'"* ]]
}

@test "up starts loh-watch with the exact argv when watch.sh exists" {
  : >"$TREE/lib/loh/watch.sh"
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy "$LIVE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  grep -qxF $'run\t--bg\t--no-parent\t--name\tloh-watch\t--cwd\t'"$WS"$'\t--label\tcrew=demo\t--label\trole=watch\t--\t'"$TREE"$'/bin/loh\twatch\tdemo' "$FAKE_HC_LOG"
  ! grep -q $'^send\t' "$FAKE_HC_LOG"
}

@test "up leaves a live loh-watch alone" {
  : >"$TREE/lib/loh/watch.sh"
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy "$LIVE"
  hc_reply get.loh-watch "$LIVE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  [[ "$output" == *"loh-watch already live"* ]]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
}

@test "up does not start loh-watch when watch.sh is absent" {
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy "$LIVE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  ! grep -q 'loh-watch' "$FAKE_HC_LOG"
}

@test "up says the agent exited when it finishes before going idle" {
  hc_seq get.scofield "$ABSENT" "$FINISHED"
  hc_reply get.amy "$LIVE"
  run --separate-stderr "$LOH" up
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"scofield exited before it was ready"* ]]
  [[ "$stderr" != *"did not reach idle"* ]]
  ! grep -q $'^send\t' "$FAKE_HC_LOG"
}

@test "up starts scofield and amy with the exact hc run argv" {
  hc_seq get.scofield "$ABSENT" "$IDLE"
  hc_seq get.amy "$ABSENT" "$IDLE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  grep -qxF $'run\t--bg\t--no-parent\t--name\tscofield\t--cwd\t'"$WS"$'\t--label\tcrew=demo\t--label\trole=coordinator\t--\tclaude\t--agent\tlarceny:coordinator\t--permission-mode\tauto' "$FAKE_HC_LOG"
  grep -qxF $'run\t--bg\t--no-parent\t--name\tamy\t--cwd\t'"$WS"$'\t--label\tcrew=demo\t--label\trole=reviewer\t--\tclaude\t--agent\tlarceny:reviewer\t--permission-mode\tauto' "$FAKE_HC_LOG"
}

@test "up passes pane_mode from the manifest to claude" {
  sed -i 's/^pane_mode: auto/pane_mode: default/' "$WS/.loh/workspace.md"
  hc_seq get.scofield "$ABSENT" "$IDLE"
  hc_seq get.amy "$ABSENT" "$IDLE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  grep -q -- $'--agent\tlarceny:reviewer\t--permission-mode\tdefault$' "$FAKE_HC_LOG"
  grep -q -- $'--agent\tlarceny:coordinator\t--permission-mode\tdefault$' "$FAKE_HC_LOG"
}

@test "up polls until idle before it sends the founding prompt" {
  hc_seq get.scofield "$ABSENT" "$STARTING" "$STARTING" "$IDLE"
  hc_seq get.amy "$ABSENT" "$IDLE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  send_line=$(grep -n $'^send\tscofield\t' "$FAKE_HC_LOG" | head -1 | cut -d: -f1)
  polls=$(head -n "$send_line" "$FAKE_HC_LOG" | grep -c $'^get\tscofield\t')
  [ "$polls" -eq 4 ]
}

@test "up founding prompt names the workspace, repos and herdr-runtime" {
  hc_seq get.scofield "$ABSENT" "$IDLE"
  hc_seq get.amy "$ABSENT" "$IDLE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  log=$(<"$FAKE_HC_LOG")
  [[ "$log" == *$'send\tscofield\t'*"larceny:coordinator and larceny-on-herdr:herdr-runtime"* ]]
  [[ "$log" == *"workspace \"demo\""* ]]
  [[ "$log" == *"acme/api"* ]]
  [[ "$log" == *$'send\tamy\t'*"larceny:adversarial-review and larceny-on-herdr:herdr-runtime"* ]]
}

@test "up leaves live agents alone and says so" {
  hc_reply get.scofield "$LIVE"
  hc_reply get.amy "$LIVE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  [[ "$output" == *"scofield already live"* ]]
  [[ "$output" == *"amy already live"* ]]
  ! grep -q $'^run\t' "$FAKE_HC_LOG"
  ! grep -q $'^send\t' "$FAKE_HC_LOG"
}

@test "up starts only the agent that is missing" {
  hc_reply get.scofield "$LIVE"
  hc_seq get.amy "$ABSENT" "$IDLE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  ! grep -q $'^run\t.*--name\tscofield' "$FAKE_HC_LOG"
  grep -q $'^run\t.*--name\tamy' "$FAKE_HC_LOG"
}

@test "up removes a finished terminal that holds the name before it runs" {
  hc_seq get.scofield "$FINISHED" "$IDLE"
  hc_reply get.amy "$LIVE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  rm_line=$(grep -n $'^rm\tscofield$' "$FAKE_HC_LOG" | head -1 | cut -d: -f1)
  run_line=$(grep -n $'^run\t.*--name\tscofield' "$FAKE_HC_LOG" | head -1 | cut -d: -f1)
  [ -n "$rm_line" ]
  [ "$rm_line" -lt "$run_line" ]
}

@test "up times out without sending when the agent never goes idle" {
  export LOH_START_TIMEOUT=1
  hc_seq get.scofield "$ABSENT" "$STARTING"
  hc_reply get.amy "$LIVE"
  run --separate-stderr "$LOH" up
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"hc read scofield"* ]]
  ! grep -q $'^send\t' "$FAKE_HC_LOG"
}

@test "up dies without a manifest" {
  rm "$WS/.loh/workspace.md"
  run --separate-stderr "$LOH" up
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"workspace.md"* ]]
}

@test "up adds scofield_args after the fixed arguments" {
  printf 'scofield_args: --channels plugin:discord@claude-plugins-official\n' >>"$WS/.loh/workspace.md"
  hc_seq get.scofield "$ABSENT" "$IDLE"
  hc_seq get.amy "$ABSENT" "$IDLE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  grep -qxF $'run\t--bg\t--no-parent\t--name\tscofield\t--cwd\t'"$WS"$'\t--label\tcrew=demo\t--label\trole=coordinator\t--\tclaude\t--agent\tlarceny:coordinator\t--permission-mode\tauto\t--channels\tplugin:discord@claude-plugins-official' "$FAKE_HC_LOG"
  grep -qxF $'run\t--bg\t--no-parent\t--name\tamy\t--cwd\t'"$WS"$'\t--label\tcrew=demo\t--label\trole=reviewer\t--\tclaude\t--agent\tlarceny:reviewer\t--permission-mode\tauto' "$FAKE_HC_LOG"
}

@test "up adds amy_args to amy only" {
  printf 'amy_args: --model sonnet\n' >>"$WS/.loh/workspace.md"
  hc_seq get.scofield "$ABSENT" "$IDLE"
  hc_seq get.amy "$ABSENT" "$IDLE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  grep -q -- $'--agent\tlarceny:reviewer\t--permission-mode\tauto\t--model\tsonnet$' "$FAKE_HC_LOG"
  grep -q -- $'--agent\tlarceny:coordinator\t--permission-mode\tauto$' "$FAKE_HC_LOG"
}

@test "up treats an empty scofield_args as no key" {
  printf 'scofield_args:\namy_args: ""\n' >>"$WS/.loh/workspace.md"
  hc_seq get.scofield "$ABSENT" "$IDLE"
  hc_seq get.amy "$ABSENT" "$IDLE"
  run "$LOH" up
  [ "$status" -eq 0 ]
  grep -q -- $'--agent\tlarceny:coordinator\t--permission-mode\tauto$' "$FAKE_HC_LOG"
  grep -q -- $'--agent\tlarceny:reviewer\t--permission-mode\tauto$' "$FAKE_HC_LOG"
}

@test "up splits scofield_args without evaluating it" {
  printf 'scofield_args: --x $(touch %s/pwned) * ;\n' "$BATS_TEST_TMPDIR" >>"$WS/.loh/workspace.md"
  hc_seq get.scofield "$ABSENT" "$IDLE"
  hc_seq get.amy "$ABSENT" "$IDLE"
  cd "$WS"
  run "$LOH" up
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  grep -qF -- $'permission-mode\tauto\t--x\t$(touch\t'"$BATS_TEST_TMPDIR"$'/pwned)\t*\t;' "$FAKE_HC_LOG"
}
