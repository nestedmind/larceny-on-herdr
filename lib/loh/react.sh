# shellcheck shell=bash
# loh react <emoji>: an agent reacts to the owner's newest message in its own session.
# loh react --dir:   print the folder the reactions are kept in.
# loh react --set-owner <agent> <json>: write the owner's store of <agent> (the office calls it).
#
# The emoji is one of 👍 ✅ ❌ 👀 ❤️ 😂. The reaction goes on the newest turn of the owner's
# in the calling agent's session (the launch prompt is not one), including a message that came in
# through Discord. It starts no turn and sends nothing: the office reads the file and draws it.
# Reacting with the same emoji again changes nothing.
#
# The file is <workspace>/.loh/reactions/<agent>.agent.json, a list of {"id","emoji"} where id is
# the session line's uuid, as `loh transcript` gives it. The office keeps the owner's own reactions
# in <agent>.owner.json beside it, so each file has one writer. The office cannot write there itself
# (herdr lets a mod write only under its own folder, and gives it no rename), so it saves through
# --set-owner, which takes the whole list as one JSON argument and replaces the file atomically.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SET="👍 ✅ ❌ 👀 ❤️ 😂"

usage() {
  echo "Usage: loh react <emoji>   (one of $SET)" >&2
  echo "       loh react --dir" >&2
  echo "       loh react --set-owner <agent> <json>" >&2
  exit 2
}
if [[ "${1:-}" == "--set-owner" ]]; then
  [[ $# -eq 3 ]] || usage
  need jq
  agent="$2"
  [[ "$agent" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "react --set-owner: not an agent name: $agent"
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$3" || die "react --set-owner: the store is not a JSON list"
  dir="$(workspace_root)/.loh/reactions"
  mkdir -p "$dir"
  jq -c . <<<"$3" >"$dir/$agent.owner.json.tmp.$$"
  mv "$dir/$agent.owner.json.tmp.$$" "$dir/$agent.owner.json"
  exit 0
fi
[[ $# -eq 1 ]] || usage
if [[ "$1" == "--dir" ]]; then
  printf '%s/.loh/reactions\n' "$(workspace_root)"
  exit 0
fi

emoji="$1"
[[ "$emoji" != "❤" ]] || emoji="❤️"
case " $SET " in
  *" $emoji "*) ;;
  *)
    echo "loh: react takes one of $SET, got: $1" >&2
    exit 2
    ;;
esac

[[ -n "${HC_TERMINAL_ID:-}" ]] || die "HC_TERMINAL_ID is not set; loh react works only inside a herdr terminal"
need hc
need jq
name="$(hc_json get "$HC_TERMINAL_ID" | jq -r '.name // ""')" || die "cannot look up this terminal"
[[ -n "$name" ]] || die "this terminal has no name"

turns="$(bash "$(dirname "${BASH_SOURCE[0]}")/transcript.sh" "$name" --last 200)" || die "cannot read the session of $name"
id="$(jq -r '[.[] | select(.role == "user" and (.launch | not))] | last | .id // ""' <<<"$turns")"
[[ -n "$id" ]] || die "no message from the owner in this session to react to"

dir="$(workspace_root)/.loh/reactions"
file="$dir/$name.agent.json"
mkdir -p "$dir"
old="[]"
[[ ! -s "$file" ]] || old="$(cat "$file")"
new="$(jq -c --arg id "$id" --arg e "$emoji" 'if any(.[]; .id == $id and .emoji == $e) then . else . + [{id: $id, emoji: $e}] end' <<<"$old")"
printf '%s\n' "$new" >"$file.tmp.$$"
mv "$file.tmp.$$" "$file"
