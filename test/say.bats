#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

# say needs different hc answers for `get` and `send`, so this file writes its
# own scripted hc into a per-test bin dir instead of using test/fakes/hc.
#   $BATS_TEST_TMPDIR/get.json   answer to `hc get <to> --json`
#   $BATS_TEST_TMPDIR/send.exits exit codes for successive `hc send` calls,
#                                one per line; the last one repeats
setup() {
  make_plugin_tree
  cp "$REPO_ROOT"/lib/loh/say.sh "$PLUGIN_TREE/lib/loh/say.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat >"$BIN/hc" <<'SH'
#!/usr/bin/env bash
(
  IFS=$'\t'
  printf '%s\n' "$*" >>"$HC_LOG"
)
case "$1" in
  get)
    cat "$HC_DIR/get.json"
    ;;
  send)
    # Parse arguments the way the real hc does (clap): options before `--`,
    # then exactly <TERMINAL> <TEXT>. -h/--help prints usage and exits 0
    # without sending; an unknown option exits 2.
    shift
    pos=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --) shift; pos+=("$@"); break ;;
        -h | --help) echo "Usage: hc send [OPTIONS] <TERMINAL> <TEXT>"; exit 0 ;;
        --if | --timeout) shift 2 ;;
        --force | --json | --wait) shift ;;
        -*) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
        *) pos+=("$1"); shift ;;
      esac
    done
    [[ ${#pos[@]} -eq 2 ]] || { echo "error: need <TERMINAL> <TEXT>" >&2; exit 2; }
    n=$(grep -c '^send' "$HC_LOG")
    code=$(sed -n "${n}p" "$HC_DIR/send.exits")
    [[ -n "$code" ]] || code=$(tail -n 1 "$HC_DIR/send.exits")
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
  printf '0\n' >"$HC_DIR/send.exits"
  export PATH="$BIN:$PATH"
  export LOH_SAY_DELAY=0
}

# set_get <status-state> [with_matt]: canned `hc get` answer for a live
# terminal in that status.
set_get() {
  printf '{"state":"live","status":{"state":"%s"},"labels":{"with_matt":"%s"}}\n' \
    "$1" "${2:-0}" >"$HC_DIR/get.json"
}

@test "say sends with --if idle and never --force" {
  run "$LOH" say amy "review PR 20 please"
  [ "$status" -eq 0 ]
  grep -qxP 'send\t--if\tidle\t--\tamy\treview PR 20 please' "$HC_LOG"
  ! grep -q -- '--force' "$HC_LOG"
}

@test "say joins several text words into one argument" {
  run "$LOH" say amy review PR 20
  [ "$status" -eq 0 ]
  grep -qxP 'send\t--if\tidle\t--\tamy\treview PR 20' "$HC_LOG"
}

@test "say with a missing target or text is a usage error (exit 2)" {
  run --separate-stderr "$LOH" say amy
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh say"* ]]
  run --separate-stderr "$LOH" say
  [ "$status" -eq 2 ]
}

@test "say retries while the target is busy and succeeds when it goes idle" {
  printf '10\n10\n0\n' >"$HC_DIR/send.exits"
  LOH_SAY_TRIES=5 run "$LOH" say amy hi
  [ "$status" -eq 0 ]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 3 ]
}

@test "say treats a blocked target (exit 9) as busy too" {
  printf '9\n0\n' >"$HC_DIR/send.exits"
  LOH_SAY_TRIES=3 run "$LOH" say amy hi
  [ "$status" -eq 0 ]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 2 ]
}

@test "say gives up after LOH_SAY_TRIES attempts with exit 3" {
  printf '10\n' >"$HC_DIR/send.exits"
  LOH_SAY_TRIES=4 run --separate-stderr "$LOH" say amy hi
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"amy is busy"* ]]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 4 ]
}

@test "say defaults to 40 tries (10 minutes at the default 15 s delay)" {
  printf '10\n' >"$HC_DIR/send.exits"
  run --separate-stderr "$LOH" say amy hi
  [ "$status" -eq 3 ]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 40 ]
}

@test "say waits LOH_SAY_DELAY seconds between tries" {
  printf '10\n' >"$HC_DIR/send.exits"
  # a fake sleep records its argument, so the test does not really wait
  printf '#!/usr/bin/env bash\necho "$1" >>"$HC_DIR/sleeps"\n' >"$BIN/sleep"
  chmod +x "$BIN/sleep"
  LOH_SAY_TRIES=3 LOH_SAY_DELAY=7 run "$LOH" say amy hi
  [ "$status" -eq 3 ]
  [ "$(cat "$HC_DIR/sleeps")" = $'7\n7' ]
}

@test "say fails with exit 1 on any other hc error, without retrying" {
  printf '3\n' >"$HC_DIR/send.exits"
  run --separate-stderr "$LOH" say ghost hi
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"status_mismatch"* ]]
  [[ "$stderr" == *"hc send ghost failed"* ]]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 1 ]
}

@test "say refuses when the target carries with_matt=1 (exit 4) and sends nothing" {
  set_get idle 1
  run --separate-stderr "$LOH" say amy hi
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"amy is with Matt; leave a note on the PR or ticket"* ]]
  ! grep -q '^send' "$HC_LOG"
}

@test "say ignores with_matt=0" {
  set_get idle 0
  run "$LOH" say amy hi
  [ "$status" -eq 0 ]
}

@test "say checks the lock again before each retry" {
  printf '10\n0\n' >"$HC_DIR/send.exits"
  # lock appears after the first send
  sleep_sets_status idle 1
  chmod +x "$BIN/sleep"
  LOH_SAY_TRIES=5 run --separate-stderr "$LOH" say amy hi
  [ "$status" -eq 4 ]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 1 ]
}

# A fake sleep that moves the target to status $1 (with_matt $2, default 0)
# once, so the next retry sees it.
sleep_sets_status() {
  printf '#!/usr/bin/env bash\nprintf "%%s" '"'"'{"state":"live","status":{"state":"%s"},"labels":{"with_matt":"%s"}}'"'"' >"$HC_DIR/get.json"\n' "$1" "${2:-0}" >"$BIN/sleep"
  chmod +x "$BIN/sleep"
}

@test "say sends a plain hc send, never --if or --force, to an agent that is done" {
  set_get done
  run "$LOH" say amy "next review"
  [ "$status" -eq 0 ]
  grep -qxP 'send\t--\tamy\tnext review' "$HC_LOG"
  ! grep -q -- '--if' "$HC_LOG"
  ! grep -q -- '--force' "$HC_LOG"
}

@test "say retries a working agent without sending, then sends once it is done" {
  set_get working
  sleep_sets_status done
  LOH_SAY_TRIES=3 run "$LOH" say amy hi
  [ "$status" -eq 0 ]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 1 ]
  grep -qxP 'send\t--\tamy\thi' "$HC_LOG"
}

@test "say retries a blocked agent without sending, then sends once it is idle" {
  set_get blocked
  sleep_sets_status idle
  LOH_SAY_TRIES=3 run "$LOH" say amy hi
  [ "$status" -eq 0 ]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 1 ]
  grep -qxP 'send\t--if\tidle\t--\tamy\thi' "$HC_LOG"
}

@test "say gives up with exit 3 on an agent that stays working, sending nothing" {
  set_get working
  LOH_SAY_TRIES=3 run --separate-stderr "$LOH" say amy hi
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"amy is busy"* ]]
  ! grep -q '^send' "$HC_LOG"
}

@test "say treats an unknown status as busy" {
  printf '{"state":"live","status":null,"labels":{}}\n' >"$HC_DIR/get.json"
  LOH_SAY_TRIES=2 run --separate-stderr "$LOH" say amy hi
  [ "$status" -eq 3 ]
  ! grep -q '^send' "$HC_LOG"
}

@test "say exits 11 for a finished terminal and sends nothing" {
  printf '{"state":"finished","status":null,"labels":{}}\n' >"$HC_DIR/get.json"
  run --separate-stderr "$LOH" say amy hi
  [ "$status" -eq 11 ]
  [[ "$stderr" == *"amy has finished"* ]]
  ! grep -q '^send' "$HC_LOG"
}

@test "say exits 11 when hc send itself reports finished" {
  printf '11\n' >"$HC_DIR/send.exits"
  run --separate-stderr "$LOH" say amy hi
  [ "$status" -eq 11 ]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 1 ]
}

@test "say retries a done agent that turns out blocked at send time" {
  set_get done
  printf '9\n0\n' >"$HC_DIR/send.exits"
  LOH_SAY_TRIES=3 run "$LOH" say amy hi
  [ "$status" -eq 0 ]
  [ "$(grep -c '^send' "$HC_LOG")" -eq 2 ]
}

@test "say delivers text that looks like an option: -h is sent, not treated as help" {
  run "$LOH" say amy "-h is the flag I meant"
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_DIR/delivered")" = $'amy\t-h is the flag I meant' ]
}

@test "say delivers a bare -h" {
  run "$LOH" say amy -h
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_DIR/delivered")" = $'amy\t-h' ]
}

@test "say delivers text starting with --force and never forces" {
  run "$LOH" say amy --force x
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_DIR/delivered")" = $'amy\t--force x' ]
  grep -qxP 'send\t--if\tidle\t--\tamy\t--force x' "$HC_LOG"
  [ "$(grep -c -- '--force' "$HC_LOG")" -eq 1 ] # only inside the text argument
}

@test "say delivers option-like text to a done agent too (plain send)" {
  set_get done
  run "$LOH" say amy "- a markdown bullet"
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_DIR/delivered")" = $'amy\t- a markdown bullet' ]
  grep -qxP 'send\t--\tamy\t- a markdown bullet' "$HC_LOG"
}

@test "say rejects a target that is not a plain name, before any hc call" {
  for bad in "-h" "--json" "-x" "Amy" "a b" "../x" "amy;ls" "1amy"; do
    run --separate-stderr "$LOH" say "$bad" hi
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"invalid target name"* ]]
  done
  [ ! -s "$HC_LOG" ]
}
