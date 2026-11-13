# shellcheck shell=bash
# loh watch [crew]: desktop notifications for a crew.
#
# Follows `hc events --json --label crew=<crew>` and notifies when
#   - an agent becomes blocked: "<Name> needs you", body "<kind>: <msg>";
#   - an agent's `note` label becomes "escalation:<text>" (what
#     `loh card note=escalation:...` sets): "<Name> escalates", body <text>.
# Bodies are cut to 120 characters. An agent is notified once per block, and an
# escalation once per distinct note. An event only tells us *which* terminal
# changed, so the status, kind, msg and note are read with `hc get`, which is
# the source of truth.
#
# Notifier: notify-send, else osascript, else a line on stdout. Text is always
# passed as arguments, never spliced into a script. Never needs root.
#
# If `hc events` exits, it is started again after 1 s, doubling up to
# LOH_WATCH_BACKOFF_MAX seconds (default 30); the delay resets after a run of
# 60 s or more. LOH_WATCH_RESTARTS limits the restarts (default -1: forever;
# used by tests).
#
# The crew is the `name:` of .loh/workspace.md, the value `loh up` and
# `loh spawn` put in their crew=<name> label; an argument overrides it.
#
# Written for bash 3.2 (macOS): no associative arrays or ${var^}.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [[ $# -gt 1 ]]; then
  echo "Usage: loh watch [crew]" >&2
  exit 2
fi
need hc
need jq
if [[ $# -eq 1 ]]; then
  crew="$1"
else
  manifest_load # dies with a clear message on a missing or malformed manifest
  crew="$WS_NAME"
fi

restarts="${LOH_WATCH_RESTARTS:--1}"
max_backoff="${LOH_WATCH_BACKOFF_MAX:-30}"
[[ "$restarts" =~ ^-?[0-9]+$ ]] || die "LOH_WATCH_RESTARTS must be an integer, got: $restarts"
[[ "$max_backoff" =~ ^[1-9][0-9]*$ ]] || die "LOH_WATCH_BACKOFF_MAX must be a positive integer, got: $max_backoff"

# notify <title> <body>
notify() {
  local title="$1" body="$2"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -- "$title" "$body" || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e 'on run argv' \
      -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
      -e 'end run' -- "$body" "$title" || true
  else
    printf '%s: %s\n' "$title" "$body"
  fi
}

# cut_body <text>: one line, at most 120 characters.
cut_body() {
  local t="${1//$'\r'/ }"
  t="${t//$'\n'/ }"
  printf '%s' "${t:0:120}"
}

# capitalise <word>
capitalise() {
  local first rest="${1:1}"
  first="$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')"
  printf '%s%s' "$first" "$rest"
}

# State per terminal lives in variables B_<key> (1 while a block has been
# announced) and N_<key> (last note seen), key = address with non-alphanumerics
# replaced by "_".
key_of() { printf '%s' "${1//[^A-Za-z0-9]/_}"; }

forget() {
  local k
  k="$(key_of "$1")"
  printf -v "B_$k" '%s' ""
  printf -v "N_$k" '%s' ""
}

# check <address> <mode>: read the terminal and notify as needed. Mode "snap"
# (the startup snapshot) records escalation notes without announcing them.
check() {
  local addr="$1" mode="$2" info k bv nv name state kind msg note body
  # The address comes from an event and goes to hc as a bare argument, so an
  # address starting with "-" would be read as an option. Real addresses are
  # like t11 or machine/t7.
  [[ "$addr" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 0
  k="$(key_of "$addr")"
  bv="B_$k"
  nv="N_$k"
  if ! info="$(hc_json get "$addr" 2>/dev/null)"; then
    forget "$addr"
    return 0
  fi
  local sep=$'\x1f'
  IFS="$sep" read -r name state kind msg note < <(
    jq -r '[ (.name // ""),
             (if .state == "live" then (.status.state // "") else "gone" end),
             (.status.kind // ""),
             ((.status.msg // "") | tostring | gsub("[\\r\\n]+"; " ")),
             ((.labels.note // "") | tostring | gsub("[\\r\\n]+"; " ")) ] | join("\u001f")' <<<"$info" 2>/dev/null
  ) || return 0
  [[ -n "$name" ]] || name="$addr"
  name="$(capitalise "$name")"

  if [[ "$state" == "blocked" ]]; then
    if [[ -z "${!bv:-}" ]]; then
      if [[ -n "$kind" && -n "$msg" ]]; then
        body="$kind: $msg"
      elif [[ -n "$kind$msg" ]]; then
        body="$kind$msg"
      else
        body="blocked"
      fi
      notify "$name needs you" "$(cut_body "$body")"
      printf -v "$bv" '%s' 1
    fi
  else
    printf -v "$bv" '%s' ""
  fi

  if [[ "$note" == escalation:* && "$note" != "${!nv:-}" && "$mode" != "snap" ]]; then
    notify "$name escalates" "$(cut_body "${note#escalation:}")"
  fi
  printf -v "$nv" '%s' "$note"
}

# SNAPSHOT_SEEN is set once the first snapshot has been handled. Only that
# first snapshot records escalation notes without announcing them (what was
# already pending before the watch started). Every later snapshot, after an
# `hc events` restart or a `missed` resync, announces notes it has not seen:
# the stored N_* values already prevent repeats.
SNAPSHOT_SEEN=""

# handle <line>: act on one line of `hc events --json`. The first line is a
# snapshot ({"terminals":[...]}); later lines are JSON-RPC "event" objects.
# Any other line that carries a terminals array at any depth (hc documents a
# `missed` message followed by a fresh snapshot, whose exact shape was not
# observed) is treated as a snapshot too. Which terminals to look at is decided
# here; the facts come from check().
handle() {
  local line="$1" kind addr snap_mode="event"
  [[ -n "$SNAPSHOT_SEEN" ]] || snap_mode="snap"
  while IFS=$'\t' read -r kind addr; do
    case "$kind" in
      snap)
        check "$addr" "$snap_mode"
        SNAPSHOT_SEEN=1
        ;;
      seen) SNAPSHOT_SEEN=1 ;; # a terminals array, even an empty one, is a snapshot
      chk) check "$addr" event ;;
      gone) forget "$addr" ;;
    esac
  done < <(jq -r '
    if type == "object" and .method == "event" then
      .params as $p
      | if ($p.type == "finished" or $p.type == "removed") then "gone\t\($p.terminal)"
        elif $p.type == "labels" then "chk\t\($p.terminal)"
        elif (($p.type // "") | tostring | test("status"))
          or (($p.data.status.state? // "") == "blocked")
          or (($p.data.state? // "") == "blocked")
        then "chk\t\($p.terminal)"
        else empty end
    else
      [.. | .terminals? | arrays] as $lists
      | (if ($lists | length) > 0 then "seen\t-" else empty end),
        ($lists[] | .[] | .address? | strings | "snap\t\(.)")
    end' <<<"$line" 2>/dev/null || true)
}

delay=1
n=0
while :; do
  started=$SECONDS
  while IFS= read -r line; do
    handle "$line"
  done < <(hc_json events --label "crew=$crew" || true)
  if ((restarts >= 0 && n >= restarts)); then
    exit 0
  fi
  n=$((n + 1))
  if ((SECONDS - started >= 60)); then
    delay=1
  fi
  echo "loh: hc events ended; restarting in ${delay}s" >&2
  sleep "$delay"
  delay=$((delay * 2))
  if ((delay > max_backoff)); then
    delay=$max_backoff
  fi
done
