# shellcheck shell=bash
# loh tell <to> <text...>: Matt types a message into a crew agent's session.
#
# For the office's chat panel, where Matt himself is typing. Looks at the
# target with `hc get`, then sends once:
#   idle     hc send --if idle -- <to> <text>
#   working  hc send --if working -- <to> <text>   (the agent queues it)
#   done     hc send -- <to> <text>   (agents sit in `done` between turns, and
#                                      --if only accepts idle or working)
#   blocked  refused, exit 9: the agent is waiting on a permission prompt or a
#            question, and a typed line would answer it
#   other    refused, exit 10
# Exit 11 also covers an hc send error of kind not_found (the terminal ended after the look).
# Exit 12: hc send failed in some other way, so the message may or may not have gone out.
# It never uses --force and never waits or retries. A target labelled
# with_matt=1 is allowed (that is the point); `loh say`, which agents use among
# themselves, still refuses it. A finished terminal is exit 11.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: loh tell <to> <text...>" >&2
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
need jq

info="$(hc_json get "$to")" || die "cannot look up $to"
life="$(jq -r '.state // ""' <<<"$info")"
if [[ "$life" != "live" ]]; then
  echo "loh: $to has finished (terminal state: ${life:-unknown})" >&2
  exit 11
fi
state="$(jq -r '.status.state // ""' <<<"$info")"

# blocked_msg: say what the agent is waiting on.
blocked_msg() {
  local kind msg what
  kind="$(jq -r '.status.kind // ""' <<<"$info")"
  msg="$(jq -r '(.status.msg // "") | tostring | gsub("[\\r\\n]+"; " ") | .[0:200]' <<<"$info")"
  if [[ -n "$kind" ]]; then
    what="a $kind dialog"
    [[ "$kind" == "permission" || "$kind" == "question" ]] || what="a dialog ($kind)"
    printf 'loh: %s is waiting on %s' "$to" "$what" >&2
  else
    printf 'loh: %s is blocked on a dialog' "$to" >&2
  fi
  [[ -z "$msg" ]] || printf ': %s' "$msg" >&2
  printf '; answer it in its terminal\n' >&2
}

rc=0
case "$state" in
  idle) out="$(hc send --if idle -- "$to" "$text" 2>&1)" || rc=$? ;;
  working) out="$(hc send --if working -- "$to" "$text" 2>&1)" || rc=$? ;;
  done) out="$(hc send -- "$to" "$text" 2>&1)" || rc=$? ;;
  blocked)
    blocked_msg
    exit 9
    ;;
  *)
    echo "loh: $to is not ready for a message (status: ${state:-unknown})" >&2
    exit 10
    ;;
esac

case "$rc" in
  0)
    [[ -z "$out" ]] || printf '%s\n' "$out"
    ;;
  9)
    echo "loh: $to is blocked on a dialog; answer it in its terminal" >&2
    exit 9
    ;;
  10)
    echo "loh: $to changed status before the message went out; nothing was sent" >&2
    exit 10
    ;;
  11)
    echo "loh: $to has finished" >&2
    exit 11
    ;;
  *)
    # hc's error is JSON; not_found means the terminal ended before the send, so nothing went out.
    kind="$(jq -r '.error.kind // ""' <<<"$out" 2>/dev/null || true)"
    if [[ "$kind" == "not_found" ]]; then
      echo "loh: $to has finished" >&2
      exit 11
    fi
    # hc may have typed the message before it failed: say so with its own exit code, which the
    # office panel treats as "not sure" (the text stays out of the box; check the log).
    echo "loh: hc send $to failed (exit $rc): $out; the message may still have gone out" >&2
    exit 12
    ;;
esac
