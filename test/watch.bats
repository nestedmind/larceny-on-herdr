#!/usr/bin/env bats
# Tests for `loh watch`. A scripted hc replays event lines and answers
# `hc get`; fake notify-send / osascript record what would be shown. The real
# notifiers are never called: PATH is rebuilt from symlinks in $BIN.

bats_require_minimum_version 1.5.0
load test_helper

# Needed by loh and watch.sh; everything else is deliberately absent.
TOOLS="bash env jq cat sed tr cut head tail dirname basename mkdir date printf grep wc mktemp rm"

setup() {
  make_plugin_tree
  cp "$REPO_ROOT/lib/loh/watch.sh" "$PLUGIN_TREE/lib/loh/watch.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  D="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$BIN" "$D"
  local t p
  for t in $TOOLS; do
    p="$(command -v "$t" || true)"
    [[ -z "$p" || "$p" != /* ]] || ln -sf "$p" "$BIN/$t"
  done
  # hc: `events` replays $D/events.<run>.jsonl (run = how many times events was
  # started, 1-based; falls back to events.jsonl), exits $D/events.exit.
  # `get <addr>` answers $D/get-<addr>.<n>.json (n = call number for that
  # address) or else $D/get-<addr>.json.
  cat >"$BIN/hc" <<'SH'
#!/usr/bin/env bash
(
  IFS=$'\t'
  printf '%s\n' "$*" >>"$D/hc.log"
)
case "$1" in
  events)
    n=$(grep -c '^events' "$D/hc.log")
    f="$D/events.$n.jsonl"
    [[ -f "$f" ]] || f="$D/events.jsonl"
    [[ ! -f "$f" ]] || cat "$f"
    exit "$(cat "$D/events.exit" 2>/dev/null || echo 0)"
    ;;
  get)
    a="$2"
    k="${a//\//_}"
    n=$(grep -c "^get.$a\b" "$D/hc.log")
    f="$D/get-$k.$n.json"
    [[ -f "$f" ]] || f="$D/get-$k.json"
    cat "$f"
    ;;
esac
SH
  cat >"$BIN/notify-send" <<'SH'
#!/usr/bin/env bash
(
  IFS=$'\t'
  printf '%s\n' "$*" >>"$D/notify.log"
)
SH
  cat >"$BIN/sleep" <<'SH'
#!/usr/bin/env bash
echo "$1" >>"$D/sleeps"
SH
  chmod +x "$BIN/hc" "$BIN/notify-send" "$BIN/sleep"
  : >"$D/hc.log"
  export D BIN
  export LOH_WATCH_RESTARTS=0
  export LOH_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$LOH_WORKSPACE/.loh"
}

# status_get <addr> <name> <state> [kind] [msg]: canned `hc get` answer.
status_get() {
  jq -nc --arg a "$1" --arg n "$2" --arg s "$3" --arg k "${4:-}" --arg m "${5:-}" \
    '{address:$a,name:$n,state:"live",labels:{crew:"w"},
      status:({app:"claude-code",state:$s} + (if $k!="" then {kind:$k} else {} end)
              + (if $m!="" then {msg:$m} else {} end))}' >"$D/get-$1.json"
}

# status_ev <addr> <state>: one status event line (shape modelled on hc schema;
# see the note in the PR about what was and was not observed live).
status_ev() {
  jq -nc --arg a "$1" --arg s "$2" --argjson q "$SEQ" \
    '{jsonrpc:"2.0",method:"event",params:{data:{status:{app:"claude-code",state:$s},status_ms:1794531657786,turn:2},seq:$q,terminal:$a,type:"status"}}'
  SEQ=$((SEQ + 1))
}
SEQ=300

# loh runs with PATH reduced to $BIN, so only the fakes and the tools in TOOLS
# exist for it (no real notify-send or osascript).
run_watch() {
  run --separate-stderr env PATH="$BIN" "$LOH" watch w
}

notified() { [[ -f "$D/notify.log" ]] && wc -l <"$D/notify.log" | tr -d ' ' || echo 0; }

@test "watch follows hc events for the crew label" {
  : >"$D/events.jsonl"
  run_watch
  [ "$status" -eq 0 ]
  grep -qxP 'events\t--label\tcrew=w\t--json' "$D/hc.log"
}

# manifest <dir> <line...>: write <dir>/.loh/workspace.md.
manifest() {
  local dir="$1"
  shift
  mkdir -p "$dir/.loh"
  printf '%s\n' "$@" >"$dir/.loh/workspace.md"
  # append a valid repos block unless the caller wrote one
  if ! printf '%s\n' "$@" | grep -q '^repos:'; then
    printf '%s\n' "repos:" "  - name: api" "    path: ./api" "    branch: main" "    github: acme/api" >>"$dir/.loh/workspace.md"
  fi
}

# run_default <dir>: run `loh watch` with no argument in workspace <dir>.
run_default() {
  LOH_WORKSPACE="$1" run --separate-stderr env PATH="$BIN" "$LOH" watch
}

@test "the crew label is the manifest's name:, not the folder name" {
  : >"$D/events.jsonl"
  manifest "$BATS_TEST_TMPDIR/some-folder" "name: larceny-crew"
  run_default "$BATS_TEST_TMPDIR/some-folder"
  [ "$status" -eq 0 ]
  grep -qxP 'events\t--label\tcrew=larceny-crew\t--json' "$D/hc.log"
}

@test "the manifest name has surrounding quotes and spaces stripped" {
  : >"$D/events.jsonl"
  manifest "$BATS_TEST_TMPDIR/q1" 'name:   "double-q"  '
  run_default "$BATS_TEST_TMPDIR/q1"
  grep -qxP 'events\t--label\tcrew=double-q\t--json' "$D/hc.log"
  : >"$D/hc.log"
  manifest "$BATS_TEST_TMPDIR/q2" "name: 'single-q'"
  run_default "$BATS_TEST_TMPDIR/q2"
  grep -qxP 'events\t--label\tcrew=single-q\t--json' "$D/hc.log"
}

@test "an explicit crew argument overrides the manifest name" {
  : >"$D/events.jsonl"
  manifest "$LOH_WORKSPACE" "name: from-manifest"
  run --separate-stderr env PATH="$BIN" "$LOH" watch other-crew
  [ "$status" -eq 0 ]
  grep -qxP 'events\t--label\tcrew=other-crew\t--json' "$D/hc.log"
}

@test "without a manifest or a crew argument it fails clearly and runs no hc" {
  rm -rf "$BATS_TEST_TMPDIR/bare"
  mkdir -p "$BATS_TEST_TMPDIR/bare"
  run_default "$BATS_TEST_TMPDIR/bare"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"workspace.md"* ]]
  [ ! -s "$D/hc.log" ]
}

@test "a manifest with no name: fails clearly" {
  manifest "$BATS_TEST_TMPDIR/noname" "pane_mode: auto"
  run_default "$BATS_TEST_TMPDIR/noname"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"name:"* ]]
  [ ! -s "$D/hc.log" ]
}

@test "a manifest name with odd characters is refused" {
  manifest "$BATS_TEST_TMPDIR/odd" "name: bad name;x"
  run_default "$BATS_TEST_TMPDIR/odd"
  [ "$status" -eq 1 ]
  [ ! -s "$D/hc.log" ]
}

@test "indented name: lines inside repos are not the crew name" {
  : >"$D/events.jsonl"
  manifest "$BATS_TEST_TMPDIR/nested" "name: top" "repos:" "  - name: other" "    path: ./o" "    branch: main" "    github: acme/o"
  run_default "$BATS_TEST_TMPDIR/nested"
  grep -qxP 'events\t--label\tcrew=top\t--json' "$D/hc.log"
}

@test "a blocked agent gets one notification titled '<Name> needs you'" {
  status_get t11 amy blocked permission "Bash: rm -rf build"
  status_ev t11 blocked >"$D/events.jsonl"
  run_watch
  [ "$status" -eq 0 ]
  [ "$(notified)" -eq 1 ]
  grep -q $'Amy needs you\tpermission: Bash: rm -rf build' "$D/notify.log"
}

@test "two blocked events in one block give one notification" {
  status_get t11 amy blocked permission "first"
  { status_ev t11 blocked; status_ev t11 blocked; } >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 1 ]
}

@test "a second block after the agent resumed notifies again" {
  printf '%s\n' \
    "$(jq -nc '{state:"live",name:"amy",labels:{},status:{state:"blocked",kind:"question",msg:"one"}}')" >"$D/get-t11.1.json"
  printf '%s\n' \
    "$(jq -nc '{state:"live",name:"amy",labels:{},status:{state:"working"}}')" >"$D/get-t11.2.json"
  printf '%s\n' \
    "$(jq -nc '{state:"live",name:"amy",labels:{},status:{state:"blocked",kind:"question",msg:"two"}}')" >"$D/get-t11.3.json"
  { status_ev t11 blocked; status_ev t11 working; status_ev t11 blocked; } >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 2 ]
  grep -q 'question: one' "$D/notify.log"
  grep -q 'question: two' "$D/notify.log"
}

@test "each agent is notified once per block" {
  status_get t11 amy blocked permission "a"
  status_get t12 sucre blocked question "b"
  { status_ev t11 blocked; status_ev t12 blocked; status_ev t11 blocked; } >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 2 ]
}

@test "non-blocked status events notify nothing" {
  status_get t11 amy working
  { status_ev t11 working; status_ev t11 done; status_ev t11 idle; } >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 0 ]
}

@test "recorded non-status events (created, labels, foreground, finished, removed) notify nothing" {
  cp "$REPO_ROOT/test/fixtures/events-real-nonstatus.jsonl" "$D/events.jsonl"
  run_watch
  [ "$status" -eq 0 ]
  [ "$(notified)" -eq 0 ]
  # only the one labels event costs an hc get; created/foreground/finished/removed do not
  [ "$(grep -c '^get' "$D/hc.log")" -eq 1 ]
}

@test "the body is cut to 120 characters" {
  long="$(printf 'x%.0s' $(seq 1 300))"
  status_get t11 amy blocked permission "$long"
  status_ev t11 blocked >"$D/events.jsonl"
  run_watch
  body="$(cut -f3 "$D/notify.log")"
  [ "${#body}" -eq 120 ]
  [[ "$body" == "permission: xxx"* ]]
}

@test "a block with no kind shows just the message; newlines become spaces" {
  status_get t11 amy blocked "" $'line one\nline two'
  status_ev t11 blocked >"$D/events.jsonl"
  run_watch
  [ "$(cut -f3 "$D/notify.log")" = "line one line two" ]
}

@test "a terminal that was blocked at startup (snapshot line) is notified" {
  status_get t15 scofield blocked question "which repo?"
  jq -nc '{channel:null,seq:1,terminals:[{address:"t15",name:"scofield",state:"live",labels:{crew:"w"},status:{state:"blocked",kind:"question"}}]}' >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 1 ]
  grep -q $'Scofield needs you\tquestion: which repo?' "$D/notify.log"
}

@test "an escalation note from the coordinator is notified once" {
  jq -nc '{name:"scofield",state:"live",labels:{note:"escalation:#18 needs a design call"},status:{state:"working"}}' >"$D/get-t15.json"
  lab='{"jsonrpc":"2.0","method":"event","params":{"data":{"labels":{"crew":"w","note":"escalation:#18 needs a design call"}},"seq":9,"terminal":"t15","type":"labels"}}'
  printf '%s\n%s\n' "$lab" "$lab" >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 1 ]
  grep -q $'Scofield escalates\t#18 needs a design call' "$D/notify.log"
}

@test "a label change that is not an escalation notifies nothing" {
  jq -nc '{name:"scofield",state:"live",labels:{note:"working on #18"},status:{state:"working"}}' >"$D/get-t15.json"
  printf '%s\n' '{"jsonrpc":"2.0","method":"event","params":{"data":{"labels":{"note":"working on #18"}},"seq":9,"terminal":"t15","type":"labels"}}' >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 0 ]
}

@test "an escalation note already present at startup is not re-announced" {
  jq -nc '{name:"scofield",state:"live",labels:{note:"escalation:old"},status:{state:"done"}}' >"$D/get-t15.json"
  jq -nc '{channel:null,seq:1,terminals:[{address:"t15",name:"scofield",state:"live",labels:{note:"escalation:old"},status:{state:"done"}}]}' >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 0 ]
}

@test "malformed event lines are skipped without stopping the watch" {
  status_get t11 amy blocked permission "x"
  { echo 'not json'; status_ev t11 blocked; } >"$D/events.jsonl"
  run_watch
  [ "$status" -eq 0 ]
  [ "$(notified)" -eq 1 ]
}

@test "the notification text is passed as arguments, not interpreted" {
  status_get t11 amy blocked permission '$(touch /tmp/pwned) "; rm -rf x'
  status_ev t11 blocked >"$D/events.jsonl"
  run_watch
  grep -qF '$(touch /tmp/pwned) "; rm -rf x' "$D/notify.log"
}

@test "without notify-send it uses osascript, passing text as argv" {
  rm "$BIN/notify-send"
  cat >"$BIN/osascript" <<'SH'
#!/usr/bin/env bash
(
  IFS=$'\t'
  printf '%s\n' "$*" >>"$D/osa.log"
)
SH
  chmod +x "$BIN/osascript"
  status_get t11 amy blocked permission 'say "hi"'
  status_ev t11 blocked >"$D/events.jsonl"
  run_watch
  [ "$(wc -l <"$D/osa.log" | tr -d ' ')" -eq 1 ]
  grep -qF 'permission: say "hi"' "$D/osa.log"
  grep -qF 'Amy needs you' "$D/osa.log"
}

@test "with neither notifier it prints to stdout" {
  rm "$BIN/notify-send"
  status_get t11 amy blocked permission "go on?"
  status_ev t11 blocked >"$D/events.jsonl"
  run_watch
  [ "$status" -eq 0 ]
  [ "$output" = "Amy needs you: permission: go on?" ]
}

@test "it restarts hc events after it exits, with a growing backoff" {
  status_get t11 amy blocked permission "x"
  status_ev t11 blocked >"$D/events.1.jsonl"
  : >"$D/events.2.jsonl"
  : >"$D/events.3.jsonl"
  LOH_WATCH_RESTARTS=2 run_watch
  [ "$status" -eq 0 ]
  [ "$(grep -c '^events' "$D/hc.log")" -eq 3 ]
  [ "$(cat "$D/sleeps")" = $'1\n2' ]
}

@test "the backoff stops growing at LOH_WATCH_BACKOFF_MAX" {
  : >"$D/events.jsonl"
  LOH_WATCH_RESTARTS=5 LOH_WATCH_BACKOFF_MAX=4 run_watch
  [ "$(cat "$D/sleeps")" = $'1\n2\n4\n4\n4' ]
}

@test "dedup state survives an hc events restart" {
  status_get t11 amy blocked permission "x"
  status_ev t11 blocked >"$D/events.1.jsonl"
  status_ev t11 blocked >"$D/events.2.jsonl"
  LOH_WATCH_RESTARTS=1 run_watch
  [ "$(notified)" -eq 1 ]
}

@test "a terminal address that looks like an option never reaches hc get" {
  for bad in "-h" "--json" "-x y"; do
    jq -nc --arg a "$bad" '{jsonrpc:"2.0",method:"event",params:{data:{status:{state:"blocked"}},seq:1,terminal:$a,type:"status"}}'
  done >"$D/events.jsonl"
  run_watch
  [ "$status" -eq 0 ]
  [ "$(notified)" -eq 0 ]
  ! grep -q '^get' "$D/hc.log"
}

@test "machine-qualified addresses like m1/t7 are still looked up" {
  jq -nc '{name:"amy",state:"live",labels:{},status:{state:"blocked",kind:"question",msg:"q"}}' >"$D/get-m1_t7.json"
  status_ev m1/t7 blocked >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 1 ]
  grep -qxP 'get\tm1/t7\t--json' "$D/hc.log"
}

# note_get <n> <note>: the nth `hc get t15` answer, with that note.
note_get() {
  jq -nc --arg n "$2" '{name:"scofield",state:"live",status:{state:"working"},labels:(if $n=="" then {} else {note:$n} end)}' >"$D/get-t15.$1.json"
}

labels_ev() {
  jq -nc --arg n "$1" --argjson q "$SEQ" '{jsonrpc:"2.0",method:"event",params:{data:{labels:(if $n=="" then {crew:"w"} else {crew:"w",note:$n} end)},seq:$q,terminal:"t15",type:"labels"}}'
  SEQ=$((SEQ + 1))
}

snapshot_line() {
  jq -nc '{channel:null,seq:1,terminals:[{address:"t15",name:"scofield",state:"live",labels:{crew:"w"},status:{state:"working"}}]}'
}

@test "an escalation raised while hc events was restarting is announced from the next snapshot" {
  snapshot_line >"$D/events.1.jsonl"
  snapshot_line >"$D/events.2.jsonl"
  note_get 1 ""
  note_get 2 "escalation:need Matt"
  LOH_WATCH_RESTARTS=1 run_watch
  [ "$status" -eq 0 ]
  [ "$(notified)" -eq 1 ]
  grep -q $'Scofield escalates\tneed Matt' "$D/notify.log"
}

@test "only the very first snapshot suppresses an escalation already present" {
  snapshot_line >"$D/events.1.jsonl"
  snapshot_line >"$D/events.2.jsonl"
  jq -nc '{name:"scofield",state:"live",status:{state:"working"},labels:{note:"escalation:old"}}' >"$D/get-t15.json"
  LOH_WATCH_RESTARTS=1 run_watch
  [ "$(notified)" -eq 0 ]
}

@test "a note cleared and then raised again notifies twice" {
  note_get 1 "escalation:A"
  note_get 2 "resolved"
  note_get 3 "escalation:A"
  { labels_ev "escalation:A"; labels_ev "resolved"; labels_ev "escalation:A"; } >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 2 ]
}

@test "a note removed entirely (no note key) is forgotten too" {
  note_get 1 "escalation:A"
  note_get 2 ""
  note_get 3 "escalation:A"
  { labels_ev "escalation:A"; labels_ev ""; labels_ev "escalation:A"; } >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 2 ]
}

@test "a missed resync snapshot (terminals array at any depth) is handled as a fresh snapshot" {
  snapshot_line >"$D/events.jsonl"
  jq -nc '{jsonrpc:"2.0",method:"missed",params:{snapshot:{seq:50,terminals:[{address:"t15",name:"scofield",state:"live",labels:{note:"escalation:during the gap"},status:{state:"working"}}]}}}' >>"$D/events.jsonl"
  note_get 1 ""
  note_get 2 "escalation:during the gap"
  run_watch
  [ "$status" -eq 0 ]
  [ "$(notified)" -eq 1 ]
  grep -q 'during the gap' "$D/notify.log"
}

@test "a heartbeat line notifies nothing and costs no hc get" {
  printf '%s\n' '{"jsonrpc":"2.0","method":"heartbeat","params":{}}' >"$D/events.jsonl"
  run_watch
  [ "$(notified)" -eq 0 ]
  ! grep -q '^get' "$D/hc.log"
}

@test "watch is listed by loh help" {
  run "$LOH" help
  [[ "$output" == *"watch"* ]]
}
