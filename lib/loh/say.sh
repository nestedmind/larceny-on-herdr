# shellcheck shell=bash
# loh say <to> <text...>: send a message to a crew agent, by name.
#
# Looks at the target with `hc get`, then sends:
#   idle     hc send --if idle -- <to> <text>
#   done     hc send -- <to> <text>   (agents sit in `done` between turns, and
#                                  --if only accepts idle or working)
#   working, blocked, anything else: wait and look again
# The text may start with "-": it always follows a `--`.
# A busy target is retried up to LOH_SAY_TRIES times (default 40),
# LOH_SAY_DELAY seconds apart (default 15), then exit 3. LOH_SAY_TRIES=0 means
# no cap. It never uses --force, so it never answers another agent's dialog. A
# target labelled with_matt=1 is refused with exit 4. A finished terminal is
# exit 11.
#
# loh say --queue <to> <text...> checks the arguments, starts a detached worker
# that waits with no cap, and returns 0 at once. The worker survives the end of
# the sender's turn. If it finally cannot deliver (the target finished, is with
# Matt, or hc failed), it sets the sender's card note to
# "undelivered:<to>: <why>", which `loh watch` announces.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

queue=""
if [[ "${1:-}" == "--queue" ]]; then
  queue=1
  shift
fi
if [[ $# -lt 2 ]]; then
  echo "Usage: loh say [--queue] <to> <text...>" >&2
  exit 2
fi
to="$1"
shift
text="$*"
# The target goes to hc as a bare argument; a name that starts with "-" would
# be read as an option, so only plain lowercase names are accepted.
if [[ ! "$to" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "loh: invalid target name: $to" >&2
  exit 2
fi

tries="${LOH_SAY_TRIES:-40}"
delay="${LOH_SAY_DELAY:-15}"
[[ "$tries" =~ ^[0-9]+$ ]] || die "LOH_SAY_TRIES must be a whole number (0 = no cap), got: $tries"
[[ "$delay" =~ ^[0-9]+$ ]] || die "LOH_SAY_DELAY must be a whole number of seconds, got: $delay"
need jq

if [[ -n "$queue" ]]; then
  # The worker is this same script with the marker set and no cap on the wait.
  # setsid puts it in its own session, so it outlives the sender's shell.
  launch=(nohup)
  command -v setsid >/dev/null 2>&1 && launch=(setsid nohup)
  LOH_SAY_WORKER=1 LOH_SAY_TRIES=0 "${launch[@]}" bash "${BASH_SOURCE[0]}" "$to" "$text" \
    >/dev/null 2>&1 </dev/null &
  echo "loh: queued for $to; it is delivered when $to is idle, and a failure shows as an undelivered note"
  exit 0
fi

# note_failure <why>: in a queued worker, tell the sender where it reads.
note_failure() {
  [[ -n "${LOH_SAY_WORKER:-}" && -n "${HC_TERMINAL_ID:-}" ]] || return 0
  local n="undelivered:$to: $1"
  hc label "$HC_TERMINAL_ID" "note=${n:0:60}" >/dev/null 2>&1 || true
}

# inspect: refuse (exit 4) when the target is with Matt, stop (exit 11) when it
# has finished, else set $state to its status: idle, done, working, blocked, or
# empty when hc reports none.
inspect() {
  local info flag life
  info="$(hc_json get "$to")" || { note_failure "cannot look up"; die "cannot look up $to"; }
  flag="$(jq -r '.labels.with_matt // ""' <<<"$info")"
  if [[ "$flag" == "1" ]]; then
    echo "loh: $to is with Matt; leave a note on the PR or ticket" >&2
    note_failure "with Matt"
    exit 4
  fi
  life="$(jq -r '.state // ""' <<<"$info")"
  if [[ "$life" != "live" ]]; then
    echo "loh: $to has finished (terminal state: ${life:-unknown})" >&2
    note_failure "finished"
    exit 11
  fi
  state="$(jq -r '.status.state // ""' <<<"$info")"
}

attempt=1
while :; do
  state=""
  inspect
  rc=0
  case "$state" in
    idle) out="$(hc send --if idle -- "$to" "$text" 2>&1)" || rc=$? ;;
    done) out="$(hc send -- "$to" "$text" 2>&1)" || rc=$? ;;
    *) rc=10 out="" ;; # working, blocked or unknown: treat as busy
  esac
  case "$rc" in
    0)
      [[ -z "$out" ]] || printf '%s\n' "$out"
      exit 0
      ;;
    9 | 10) ;; # blocked or status mismatch: the target is busy, try again
    11)
      echo "loh: $to has finished" >&2
      note_failure "finished"
      exit 11
      ;;
    *)
      note_failure "hc send failed"
      die "hc send $to failed (exit $rc): $out"
      ;;
  esac
  if ((tries > 0 && attempt >= tries)); then
    echo "loh: $to is busy (gave up after $tries tries)" >&2
    exit 3
  fi
  attempt=$((attempt + 1))
  sleep "$delay"
done
