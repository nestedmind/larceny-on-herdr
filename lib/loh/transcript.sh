# shellcheck shell=bash
# loh transcript <name> [--last N]: the chat of an agent, from its Claude Code
# session file, as one JSON array on stdout:
#   [{"role":"user"|"assistant","text":"...","ts":"<ISO time>"}, ...]
# oldest first, newest last; N turns (default 40).
#
# Which file: Claude Code keeps sessions in
#   ${LOH_CLAUDE_PROJECTS:-~/.claude/projects}/<cwd, every non-alphanumeric
#   character replaced by "-">/<session>.jsonl
# The agent's cwd and argv come from `hc get`. Several agents can share a
# folder, so a session whose first lines name the agent's `--agent` value
# (`agentSetting`) is preferred; among the candidates the newest file wins.
# Without an --agent the newest file in the folder is used. With one and no
# match (the agent has not written a session yet), or no file at all, it prints [].
#
# Kept: user turns (typed text), assistant text, and messages other agents sent
# in (<hc from="tN name">...</hc>), unwrapped, as {"role":"agent","from":"name"}.
# Left out: thinking, tool calls and results, meta and sub-agent turns,
# <system-reminder> blocks, command echoes and bare <hc>...</hc> notes. Turns are cut to 4000 characters. A half-written last line is
# skipped.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  echo "Usage: loh transcript <name> [--last N]" >&2
  exit 2
}
[[ $# -eq 1 || $# -eq 3 ]] || usage
name="$1"
last=40
if [[ $# -eq 3 ]]; then
  [[ "$2" == "--last" ]] || usage
  last="$3"
fi
if [[ ! "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "loh: invalid target name: $name" >&2
  exit 2
fi
if [[ ! "$last" =~ ^[1-9][0-9]*$ ]]; then
  echo "loh: --last must be a positive integer, got: $last" >&2
  exit 2
fi
need hc
need jq

info="$(hc_json get "$name")" || die "cannot look up $name"
cwd="$(jq -r '.cwd // ""' <<<"$info")"
agent="$(jq -r '(.argv // []) as $a | ([range(0; $a | length - 1) | select($a[.] == "--agent") | $a[. + 1]] | first) // ""' <<<"$info")"
[[ -n "$cwd" ]] || {
  echo "[]"
  exit 0
}

dir="${LOH_CLAUDE_PROJECTS:-$HOME/.claude/projects}/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
file=""
if [[ -d "$dir" ]]; then
  # newest first; names are uuids, so plain ls -t is safe
  # shellcheck disable=SC2012
  files="$(ls -t "$dir"/*.jsonl 2>/dev/null || true)"
  if [[ -n "$agent" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      # Read the lines into a variable first: `head | grep -q` makes head die of SIGPIPE
      # when grep stops at its match, and pipefail then turns that into "no match".
      first="$(head -n 20 "$f")"
      if grep -qF "\"agentSetting\":\"$agent\"" <<<"$first"; then
        file="$f"
        break
      fi
    done <<<"$files"
  fi
  # No --agent to tell sessions apart: the newest file. With one and no match the
  # agent has no session yet, and another agent's file must not stand in for it.
  if [[ -z "$file" && -z "$agent" ]]; then
    file="$(printf '%s\n' "$files" | head -n 1)"
  fi
fi
if [[ -z "$file" ]]; then
  echo "[]"
  exit 0
fi

# shellcheck disable=SC2016
filter='
  fromjson?
  | select((.type == "user" or .type == "assistant") and (.isSidechain | not) and (.isMeta | not))
  | .message.content as $c
  | { role: .type, ts: (.timestamp // ""),
      text: (if ($c | type) == "string" then $c
             elif ($c | type) == "array" then ([$c[] | select(.type == "text") | .text] | join("\n"))
             else "" end) }
  | .text |= (gsub("(?s)<system-reminder>.*?</system-reminder>"; "") | gsub("^\\s+|\\s+$"; ""))
  | select(.text != "" and (.text | test("^<(local-)?command-|^<hc>") | not))
  | if (.text | test("^<hc from=\"")) then
      .role = "agent"
      | .from = (.text | capture("^<hc from=\"(?:\\S+ )?(?<n>[^\"]+)\"").n)
      | .text |= (sub("^<hc from=\"[^\"]*\">\\s*"; "") | sub("\\s*</hc>\\s*$"; ""))
    else . end
  | .text |= (if length > 4000 then .[0:4000] + "…" else . end)'

jq -cR "$filter" "$file" | tail -n "$last" | jq -s .
