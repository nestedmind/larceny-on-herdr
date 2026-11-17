# shellcheck shell=bash
# loh wake [--timeout S]: exit as soon as something the coordinator must act on
# changes. The coordinator runs it in the background; its exit starts a new turn
# for the coordinator, which then reads the printed lines and re-arms it.
#
# It takes a baseline of the crew and the workspace's open pull requests, then
# prints one line per change and exits 0:
#   coder name=<n> event=turn-ended state=<state>   a coder stopped working
#   coder name=<n> event=blocked kind=<kind>        a coder is blocked
#   coder name=<n> event=gone                       a coder's terminal ended
#   coder name=<n> event=note note=<text>           a coder's note changed
#                                                   (escalation:... is one)
#   coordinator event=undelivered note=<text>       a queued `loh say` failed
#   pr repo=<r> number=<n> event=opened head=<sha>
#   pr repo=<r> number=<n> event=head from=<sha> to=<sha>
#   pr repo=<r> number=<n> event=mergeable from=<v> to=<v>
#   pr repo=<r> number=<n> event=closed state=<MERGED|CLOSED>
#   review repo=<r> number=<n> by=<login> state=<state> head=<sha>
# With nothing to report it prints `timeout after <S>s` and exits 0 at the
# timeout (default 900), so the coordinator can re-arm it. Any line other than
# `timeout ...` means look.
#
# Crew side: `hc events` says when to look; the coders (role=coder) and the
# coordinator's own card (HC_TERMINAL_ID) are then read with `hc get`. GitHub
# side: `gh pr list` per manifest repo every LOH_WAKE_POLL seconds (default
# 30), two calls a minute per repo. A failed call changes nothing. A mergeable
# value of UNKNOWN (GitHub still computing) is ignored. If `hc events` ends,
# it is started again after 1 s, doubling up to 16 s.
#
# Written for bash 3.2 (macOS): no associative arrays; diffs are done by jq.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { echo "Usage: loh wake [--timeout S]" >&2; }

timeout=900
case "${1:-}" in
  "") ;;
  --timeout)
    [[ $# -eq 2 && "$2" =~ ^[1-9][0-9]*$ ]] || {
      usage
      exit 2
    }
    timeout="$2"
    ;;
  *)
    usage
    exit 2
    ;;
esac
poll="${LOH_WAKE_POLL:-30}"
[[ "$poll" =~ ^[1-9][0-9]*$ ]] || die "LOH_WAKE_POLL must be a positive integer, got: $poll"
need hc
need jq
manifest_load
crew="$WS_NAME"

# hc side ------------------------------------------------------------------

# hc_snapshot: print {"coders":{name:{state,kind,note}},"self":"<note>"}.
# Returns 1 when hc cannot list.
hc_snapshot() {
  local listing coders='{}' addr info self=""
  listing="$(hc_json ls --label "crew=$crew" --label role=coder 2>/dev/null)" || return 1
  while IFS= read -r addr; do
    # An address goes to hc as a bare argument: refuse one that looks like an option.
    [[ "$addr" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || continue
    info="$(hc_json get "$addr" 2>/dev/null)" || continue
    coders="$(jq -c --argjson i "$info" '
      . + ($i | {((.name // .address) | tostring): {
        state: (if .state == "live" then (.status.state // "unknown") else "gone" end),
        kind: (.status.kind // ""),
        note: ((.labels.note // "") | tostring | gsub("[\\r\\n]+"; " ") | .[0:120])}})' <<<"$coders" 2>/dev/null)" || continue
  done < <(jq -r '.terminals[]?.address // empty' <<<"$listing" 2>/dev/null)
  if [[ -n "${HC_TERMINAL_ID:-}" && "$HC_TERMINAL_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
    self="$(hc_json get "$HC_TERMINAL_ID" 2>/dev/null |
      jq -r '(.labels.note // "") | tostring | gsub("[\\r\\n]+"; " ") | .[0:120]' 2>/dev/null)" || self=""
  fi
  jq -cn --argjson c "$coders" --arg s "$self" '{coders: $c, self: $s}'
}

# hc_diff <old> <new>: the lines for what changed.
hc_diff() {
  jq -nr --argjson old "$1" --argjson new "$2" '
    (($new.coders | to_entries[]) as $e
    | ($old.coders[$e.key]) as $o
    | if $o == null then empty
      else
        (if $e.value.state == "blocked" and $o.state != "blocked"
           then "coder name=\($e.key) event=blocked kind=\($e.value.kind)"
         elif $o.state == "working" and $e.value.state != "working" and $e.value.state != "blocked"
           then "coder name=\($e.key) event=turn-ended state=\($e.value.state)"
         else empty end),
        (if $e.value.note != $o.note and $e.value.note != ""
           then "coder name=\($e.key) event=note note=\($e.value.note)" else empty end)
      end),
    (($old.coders | keys[]) as $k
    | select($new.coders[$k] == null) | "coder name=\($k) event=gone"),
    (if $new.self != $old.self and ($new.self | startswith("undelivered:"))
       then "coordinator event=undelivered note=\($new.self | ltrimstr("undelivered:"))" else empty end)'
}

# GitHub side ----------------------------------------------------------------

# gh_snapshot <old>: print {"<repo>#<n>":{repo,number,head,mergeable,reviews}}.
# A repo whose call fails keeps its old entries.
gh_snapshot() {
  local old="$1" all='{}' i one
  local tmo=()
  if command -v timeout >/dev/null 2>&1; then tmo=(timeout 20); fi
  for i in "${!REPO_NAMES[@]}"; do
    [[ -n "${REPO_GITHUBS[i]}" ]] || continue
    if one="$("${tmo[@]}" gh pr list -R "${REPO_GITHUBS[i]}" --state open --limit 100 \
      --json number,headRefOid,mergeable,reviews 2>/dev/null)" &&
      one="$(jq -c --arg repo "${REPO_NAMES[i]}" --argjson old "$old" '
        [.[] | {key: "\($repo)#\(.number)", value: {
          repo: $repo, number: .number, head: .headRefOid,
          mergeable: (.mergeable // "UNKNOWN"),
          reviews: ([.reviews[]? | select(.state != "PENDING")
            | {key: (.id | tostring),
               value: {by: (.author.login // ""), state: .state, head: ((.commit.oid // "")[0:7])}}]
            | from_entries)}}]
        | from_entries
        | with_entries(if .value.mergeable == "UNKNOWN" and ($old[.key] != null)
            then .value.mergeable = $old[.key].mergeable else . end)' <<<"$one" 2>/dev/null)"; then
      all="$(jq -c --argjson a "$one" '. + $a' <<<"$all")"
    else
      all="$(jq -c --argjson old "$old" --arg repo "${REPO_NAMES[i]}" \
        '. + ($old | with_entries(select(.value.repo == $repo)))' <<<"$all")"
    fi
  done
  printf '%s\n' "$all"
}

# gh_diff <old> <new>: the lines for what changed.
gh_diff() {
  jq -nr --argjson old "$1" --argjson new "$2" '
    (($new | to_entries[]) as $e
    | ($old[$e.key]) as $o
    | if $o == null then
        "pr repo=\($e.value.repo) number=\($e.value.number) event=opened head=\($e.value.head[0:7])"
      else
        (if $e.value.head != $o.head
           then "pr repo=\($e.value.repo) number=\($e.value.number) event=head from=\($o.head[0:7]) to=\($e.value.head[0:7])"
           else empty end),
        (if $e.value.mergeable != $o.mergeable
           then "pr repo=\($e.value.repo) number=\($e.value.number) event=mergeable from=\($o.mergeable) to=\($e.value.mergeable)"
           else empty end),
        ($e.value.reviews | to_entries[] | select($o.reviews[.key] == null)
           | "review repo=\($e.value.repo) number=\($e.value.number) by=\(.value.by) state=\(.value.state) head=\(.value.head)")
      end),
    (($old | to_entries[]) as $g
    | select($new[$g.key] == null)
    | "pr repo=\($g.value.repo) number=\($g.value.number) event=closed")'
}

# close_state <line>: add the final state (MERGED or CLOSED) to a closed line.
close_state() {
  local line="$1" repo num github i st=CLOSED
  if [[ "$line" =~ repo=([^\ ]+)\ number=([0-9]+) ]]; then
    repo="${BASH_REMATCH[1]}"
    num="${BASH_REMATCH[2]}"
    for i in "${!REPO_NAMES[@]}"; do
      [[ "${REPO_NAMES[i]}" == "$repo" ]] && github="${REPO_GITHUBS[i]}"
    done
    if [[ -n "${github:-}" ]]; then
      st="$(gh pr view "$num" -R "$github" --json state --jq .state 2>/dev/null)" || st=CLOSED
      [[ "$st" == MERGED || "$st" == CLOSED ]] || st=CLOSED
    fi
  fi
  printf '%s state=%s\n' "$line" "$st"
}

# Main loop ------------------------------------------------------------------

hc_old="$(hc_snapshot)" || hc_old='{"coders":{},"self":""}'
gh_old="$(gh_snapshot '{}')"
last_poll=$SECONDS
deadline=$((SECONDS + timeout))
ev_pid=""

open_events() {
  exec 3< <(hc_json events --label "crew=$crew" 2>/dev/null || true)
  ev_pid=$!
}
close_events() {
  exec 3<&-
  [[ -z "$ev_pid" ]] || kill "$ev_pid" 2>/dev/null || true
  ev_pid=""
}
trap close_events EXIT

# report <lines>: print and exit when there are any.
report() {
  local out="$1" line
  [[ -n "$out" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" == pr\ *event=closed ]]; then close_state "$line"; else printf '%s\n' "$line"; fi
  done <<<"$out"
  exit 0
}

check_hc() {
  local new
  new="$(hc_snapshot)" || return 0
  report "$(hc_diff "$hc_old" "$new")"
  hc_old="$new"
}
check_gh() {
  local new
  new="$(gh_snapshot "$gh_old")"
  report "$(gh_diff "$gh_old" "$new")"
  gh_old="$new"
}

open_events
delay=1
while :; do
  rc=0
  line=""
  IFS= read -r -t 1 line <&3 || rc=$?
  if ((rc == 0)); then
    check_hc
  elif ((rc <= 128)); then
    # hc events ended: look once, then start it again after a growing pause.
    check_hc
    close_events
    sleep "$delay"
    delay=$((delay * 2))
    ((delay <= 16)) || delay=16
    open_events
  fi
  if ((SECONDS - last_poll >= poll)); then
    last_poll=$SECONDS
    check_hc
    check_gh
  fi
  if ((SECONDS >= deadline)); then
    echo "timeout after ${timeout}s"
    exit 0
  fi
done
