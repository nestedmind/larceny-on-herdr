#!/usr/bin/env bats
# Tests for `loh wake`. A scripted hc answers `ls`, `get` and `events`; a
# scripted gh answers `pr list` and `pr view`. Call N of a command reads
# <name>.N and falls back to the highest-numbered earlier file, so a test lists
# only the calls that differ. Call 1 is the baseline.

bats_require_minimum_version 1.5.0
load test_helper

TOOLS="bash env jq cat sed tr cut head tail dirname basename mkdir date printf grep wc mktemp rm timeout ls sort mv"

setup() {
  make_plugin_tree
  cp "$REPO_ROOT/lib/loh/wake.sh" "$PLUGIN_TREE/lib/loh/wake.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  D="$BATS_TEST_TMPDIR/d"
  mkdir -p "$BIN" "$D"
  local t p
  for t in $TOOLS; do
    p="$(command -v "$t" || true)"
    [[ -z "$p" || "$p" != /* ]] || ln -sf "$p" "$BIN/$t"
  done
  cat >"$BIN/pick" <<'SH'
#!/usr/bin/env bash
# pick <prefix> <suffix> <n>: print the highest-numbered file <= n, else <prefix><suffix>.
for ((i = $3; i >= 1; i--)); do
  [[ -f "$1.$i$2" ]] && { cat "$1.$i$2"; exit 0; }
done
[[ -f "$1$2" ]] && cat "$1$2"
exit 0
SH
  cat >"$BIN/hc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$D/hc.log"
case "$1" in
  events)
    n=$(grep -c '^events' "$D/hc.log")
    "$BIN/pick" "$D/events" .jsonl "$n"
    ;;
  ls)
    n=$(grep -c '^ls' "$D/hc.log")
    "$BIN/pick" "$D/ls" .json "$n"
    ;;
  get)
    n=$(grep -c "^get $2 " "$D/hc.log")
    "$BIN/pick" "$D/get-$2" .json "$n"
    ;;
esac
SH
  cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$D/gh.log"
case "$1 $2" in
  "pr list")
    k="${4//\//_}"
    n=$(grep -c "^pr list -R $4 " "$D/gh.log")
    "$BIN/pick" "$D/list-$k" .json "$n"
    ;;
  "pr view") cat "$D/view-$3" ;;
esac
SH
  printf '#!/usr/bin/env bash\n/bin/sleep 0.2\n' >"$BIN/sleep"
  chmod +x "$BIN/pick" "$BIN/hc" "$BIN/gh" "$BIN/sleep"
  export D BIN LOH_WAKE_POLL=1
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS/.loh"
  printf '%s\n' "name: w" "repos:" "  - name: api" "    path: ./api" "    branch: main" "    github: acme/api" >"$WS/.loh/workspace.md"
  export LOH_WORKSPACE="$WS"
  : >"$D/hc.log"
  : >"$D/gh.log"
  echo '{"terminals":[{"address":"t7"}]}' >"$D/ls.json"
  coder 1 working "" ""
  echo '[]' >"$D/list-acme_api.json"
}

# coder <n> <state> <kind> <note>: the Nth answer of `hc get t7`.
coder() {
  jq -nc --arg s "$2" --arg k "$3" --arg n "$4" \
    '{address:"t7",name:"sucre",state:"live",labels:({crew:"w",role:"coder"} + (if $n!="" then {note:$n} else {} end)),
      status:({state:$s} + (if $k!="" then {kind:$k} else {} end))}' >"$D/get-t7.$1.json"
}

# prs <n> <json>: the Nth answer of `gh pr list` for acme/api.
prs() { printf '%s\n' "$2" >"$D/list-acme_api.$1.json"; }

pr_json() { # <head> <mergeable> <reviews-json>
  jq -nc --arg h "$1" --arg m "$2" --argjson r "$3" '[{number:12,headRefOid:$h,mergeable:$m,reviews:$r}]'
}

run_wake() { run --separate-stderr env PATH="$BIN" "$LOH" wake "$@"; }

@test "with nothing changing it runs to the timeout and says so" {
  run_wake --timeout 2
  [ "$status" -eq 0 ]
  [ "$output" = "timeout after 2s" ]
}

@test "a coder's turn ending wakes it" {
  coder 2 idle "" ""
  echo '{"jsonrpc":"2.0","method":"event","params":{"terminal":"t7","type":"status"}}' >"$D/events.jsonl"
  run_wake --timeout 5
  [ "$status" -eq 0 ]
  [ "$output" = "coder name=sucre event=turn-ended state=idle" ]
}

@test "a coder blocking wakes it, with the kind" {
  coder 2 blocked permission ""
  echo '{"method":"event","params":{"terminal":"t7","type":"status"}}' >"$D/events.jsonl"
  run_wake --timeout 5
  [ "$output" = "coder name=sucre event=blocked kind=permission" ]
}

@test "a coder's note changing wakes it" {
  coder 2 working "" "escalation:PR 5 is stuck"
  echo '{"method":"event","params":{"terminal":"t7","type":"labels"}}' >"$D/events.jsonl"
  run_wake --timeout 5
  [ "$output" = "coder name=sucre event=note note=escalation:PR 5 is stuck" ]
}

@test "a coder's terminal going away wakes it" {
  echo '{"terminals":[]}' >"$D/ls.2.json"
  echo '{"method":"event","params":{"terminal":"t7","type":"finished"}}' >"$D/events.jsonl"
  run_wake --timeout 5
  [ "$output" = "coder name=sucre event=gone" ]
}

@test "a coder going from idle to working is not news" {
  coder 1 idle "" ""
  coder 2 working "" ""
  echo '{"method":"event","params":{"terminal":"t7","type":"status"}}' >"$D/events.jsonl"
  run_wake --timeout 2
  [ "$output" = "timeout after 2s" ]
}

@test "an undelivered note on the coordinator's own card wakes it" {
  export HC_TERMINAL_ID=t1
  echo '{"address":"t1","name":"scofield","state":"live","labels":{},"status":{"state":"working"}}' >"$D/get-t1.1.json"
  echo '{"address":"t1","name":"scofield","state":"live","labels":{"note":"undelivered:amy: finished"},"status":{"state":"working"}}' >"$D/get-t1.2.json"
  echo '{"method":"event","params":{"terminal":"t1","type":"labels"}}' >"$D/events.jsonl"
  run_wake --timeout 5
  [ "$output" = "coordinator event=undelivered note=amy: finished" ]
}

@test "a new review wakes it" {
  prs 1 "$(pr_json aaaaaaaa1111 MERGEABLE '[]')"
  prs 2 "$(pr_json aaaaaaaa1111 MERGEABLE '[{"id":"R1","state":"APPROVED","author":{"login":"amy"},"commit":{"oid":"aaaaaaaa1111"}}]')"
  run_wake --timeout 6
  [ "$output" = "review repo=api number=12 by=amy state=APPROVED head=aaaaaaa" ]
}

@test "a PR's head changing wakes it" {
  prs 1 "$(pr_json aaaaaaaa1111 MERGEABLE '[]')"
  prs 2 "$(pr_json bbbbbbbb2222 MERGEABLE '[]')"
  run_wake --timeout 6
  [ "$output" = "pr repo=api number=12 event=head from=aaaaaaa to=bbbbbbb" ]
}

@test "a PR's mergeability changing wakes it, and UNKNOWN does not" {
  prs 1 "$(pr_json aaaaaaaa1111 MERGEABLE '[]')"
  prs 2 "$(pr_json aaaaaaaa1111 UNKNOWN '[]')"
  prs 3 "$(pr_json aaaaaaaa1111 CONFLICTING '[]')"
  run_wake --timeout 8
  [ "$output" = "pr repo=api number=12 event=mergeable from=MERGEABLE to=CONFLICTING" ]
}

@test "a PR opening wakes it" {
  prs 2 "$(pr_json aaaaaaaa1111 MERGEABLE '[]')"
  run_wake --timeout 6
  [ "$output" = "pr repo=api number=12 event=opened head=aaaaaaa" ]
}

@test "a PR leaving the open list wakes it with its final state" {
  prs 1 "$(pr_json aaaaaaaa1111 MERGEABLE '[]')"
  echo '[]' >"$D/list-acme_api.2.json"
  echo MERGED >"$D/view-12"
  run_wake --timeout 6
  [ "$output" = "pr repo=api number=12 event=closed state=MERGED" ]
}

@test "a failing gh call changes nothing" {
  prs 1 "$(pr_json aaaaaaaa1111 MERGEABLE '[]')"
  echo 'not json' >"$D/list-acme_api.2.json"
  run_wake --timeout 4
  [ "$output" = "timeout after 4s" ]
}

@test "it follows hc events for the crew and polls gh for the manifest's repo" {
  run_wake --timeout 2
  grep -qx 'events --label crew=w --json' "$D/hc.log"
  grep -q '^pr list -R acme/api --state open' "$D/gh.log"
}

@test "a bad --timeout is refused" {
  run_wake --timeout 0
  [ "$status" -eq 2 ]
  run_wake --bogus
  [ "$status" -eq 2 ]
}

@test "a coder change between two runs is reported by the next run" {
  run_wake --timeout 1
  [ "$output" = "timeout after 1s" ]
  : >"$D/hc.log"
  coder 1 idle "" ""
  run_wake --timeout 5
  [ "$output" = "coder name=sucre event=turn-ended state=idle" ]
}

@test "a PR review between two runs is reported by the next run, once" {
  prs 1 "$(pr_json aaaaaaaa1111 MERGEABLE '[]')"
  run_wake --timeout 1
  prs 1 "$(pr_json aaaaaaaa1111 MERGEABLE '[{"id":"R1","state":"APPROVED","author":{"login":"amy"},"commit":{"oid":"aaaaaaaa1111"}}]')"
  : >"$D/gh.log"
  run_wake --timeout 5
  [ "$output" = "review repo=api number=12 by=amy state=APPROVED head=aaaaaaa" ]
  run_wake --timeout 1
  [ "$output" = "timeout after 1s" ]
}

@test "a damaged state file is ignored" {
  echo 'garbage' >"$WS/.loh/wake-state.json"
  run_wake --timeout 1
  [ "$output" = "timeout after 1s" ]
}
