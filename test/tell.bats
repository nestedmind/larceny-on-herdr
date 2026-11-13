#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

# tell has one hc get and at most one hc send per run, so this file writes its
# own scripted hc into a per-test bin dir.
#   $BATS_TEST_TMPDIR/get.json   answer to `hc get <to> --json`
#   $BATS_TEST_TMPDIR/send.exit  exit code of `hc send`
setup() {
  make_plugin_tree
  cp "$REPO_ROOT"/lib/loh/tell.sh "$PLUGIN_TREE/lib/loh/tell.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat >"$BIN/hc" <<'SH'
#!/usr/bin/env bash
(
  IFS=$'\t'
  printf '%s\n' "$*" >>"$HC_LOG"
)
case "$1" in
  get) cat "$HC_DIR/get.json" ;;
  send)
    shift
    pos=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --) shift; pos+=("$@"); break ;;
        --if | --timeout) shift 2 ;;
        --force | --json | --wait) shift ;;
        -*) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
        *) pos+=("$1"); shift ;;
      esac
    done
    [[ ${#pos[@]} -eq 2 ]] || { echo "error: need <TERMINAL> <TEXT>" >&2; exit 2; }
    code=$(cat "$HC_DIR/send.exit")
    if [[ "$code" != 0 ]]; then
      printf '{"error":{"kind":"status_mismatch"}}\n' >&2
    else
      printf '%s\t%s\n' "${pos[0]}" "${pos[1]}" >>"$HC_DIR/delivered"
    fi
    exit "$code"
    ;;
esac
SH
  chmod +x "$BIN/hc"
  export HC_LOG="$BATS_TEST_TMPDIR/hc.log" HC_DIR="$BATS_TEST_TMPDIR"
  : >"$HC_LOG"
  set_get idle
  printf '0\n' >"$HC_DIR/send.exit"
  export PATH="$BIN:$PATH"
}

# set_get <status-state> [with_matt] [kind] [msg]
set_get() {
  printf '{"state":"live","status":{"state":"%s","kind":"%s","msg":"%s"},"labels":{"with_matt":"%s"}}\n' \
    "$1" "${3:-}" "${4:-}" "${2:-0}" >"$HC_DIR/get.json"
}

@test "tell sends to an idle agent with --if idle, never --force" {
  run "$LOH" tell scofield "merge api#2"
  [ "$status" -eq 0 ]
  grep -qxP 'send\t--if\tidle\t--\tscofield\tmerge api#2' "$HC_LOG"
  ! grep -q -- '--force' "$HC_LOG"
}

@test "tell joins several words into one text" {
  run "$LOH" tell scofield merge api 2
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_DIR/delivered")" = $'scofield\tmerge api 2' ]
}

@test "tell sends to an agent that is with Matt (it is Matt talking)" {
  set_get idle 1
  run "$LOH" tell scofield hello
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_DIR/delivered")" = $'scofield\thello' ]
}

@test "tell sends to a done agent with a plain send" {
  set_get done
  run "$LOH" tell amy "next one"
  [ "$status" -eq 0 ]
  grep -qxP 'send\t--\tamy\tnext one' "$HC_LOG"
  ! grep -q -- '--if' "$HC_LOG"
}

@test "tell sends to a working agent only if it is still working" {
  set_get working
  run "$LOH" tell amy "also check the tests"
  [ "$status" -eq 0 ]
  grep -qxP 'send\t--if\tworking\t--\tamy\talso check the tests' "$HC_LOG"
}

@test "tell refuses a blocked agent (exit 9), says why and sends nothing" {
  set_get blocked 0 permission "Bash: rm -rf x"
  run --separate-stderr "$LOH" tell amy "yes"
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"amy is waiting on a permission dialog"* ]]
  [[ "$stderr" == *"Bash: rm -rf x"* ]]
  [[ "$stderr" == *"answer it in its terminal"* ]]
  ! grep -q '^send' "$HC_LOG"
}

@test "tell refuses a blocked agent with no kind reported" {
  set_get blocked
  run --separate-stderr "$LOH" tell amy "yes"
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"amy is blocked on a dialog"* ]]
  ! grep -q '^send' "$HC_LOG"
}

@test "tell exits 9 when the agent turns blocked between the look and the send" {
  printf '9\n' >"$HC_DIR/send.exit"
  run --separate-stderr "$LOH" tell amy hi
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"amy is blocked"* ]]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 1 ]
}

@test "tell exits 10 on an unknown status and sends nothing" {
  printf '{"state":"live","status":null,"labels":{}}\n' >"$HC_DIR/get.json"
  run --separate-stderr "$LOH" tell amy hi
  [ "$status" -eq 10 ]
  ! grep -q '^send' "$HC_LOG"
}

@test "tell exits 10 when the status changed at send time" {
  printf '10\n' >"$HC_DIR/send.exit"
  run --separate-stderr "$LOH" tell amy hi
  [ "$status" -eq 10 ]
  [[ "$stderr" == *"changed"* ]]
}

@test "tell exits 11 for a finished terminal and sends nothing" {
  printf '{"state":"finished","status":null,"labels":{}}\n' >"$HC_DIR/get.json"
  run --separate-stderr "$LOH" tell amy hi
  [ "$status" -eq 11 ]
  [[ "$stderr" == *"amy has finished"* ]]
  ! grep -q '^send' "$HC_LOG"
}

@test "tell with a missing target or text is a usage error (exit 2)" {
  run --separate-stderr "$LOH" tell amy
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh tell"* ]]
}

@test "tell rejects a target that is not a plain name, before any hc call" {
  for bad in "-h" "--json" "Amy" "a b" "t7;ls" "1amy"; do
    run --separate-stderr "$LOH" tell "$bad" hi
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"invalid target name"* ]]
  done
  [ ! -s "$HC_LOG" ]
}

@test "tell delivers text that looks like an option" {
  run "$LOH" tell amy "--force x"
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_DIR/delivered")" = $'amy\t--force x' ]
  [ "$(grep -c -- '--force' "$HC_LOG")" -eq 1 ] # only inside the text argument
}

@test "tell exits 12 on any other hc send error, because the message may still have gone out" {
  printf '3\n' >"$HC_DIR/send.exit"
  run --separate-stderr "$LOH" tell amy hi
  [ "$status" -eq 12 ]
  [[ "$stderr" == *"hc send amy failed"* ]]
  [[ "$stderr" == *"may still have gone out"* ]]
}

@test "say still refuses an agent that is with Matt" {
  cp "$REPO_ROOT"/lib/loh/say.sh "$PLUGIN_TREE/lib/loh/say.sh"
  set_get idle 1
  run --separate-stderr "$LOH" say amy hi
  [ "$status" -eq 4 ]
  ! grep -q '^send' "$HC_LOG"
}
