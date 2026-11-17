# shellcheck shell=bash
# loh transcript [--archived] <name> [--last N]: the chat of an agent, from its Claude Code
# session file, as one JSON array on stdout:
#   [{"role":"user"|"assistant","text":"...","ts":"<ISO time>","id":"<session line uuid>"}, ...]
# oldest first, newest last; N turns (default 40). The session's first user turn carries
# "launch":true when it is the launch prompt loh sent (a pasted block), even when it
# is older than the N turns shown.
#
# --archived reads a transcript that `loh release` (or `loh down`) archived: <name> is the
# folder name under <workspace>/.loh/transcripts/ (<coder>-<repo>-<ticket>, with -2, -3 when
# that was taken), the newest session file in it is used, and no terminal is asked. A missing
# archive is an error.
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
# in (<hc from="tN name">...</hc>), unwrapped, as {"role":"agent","from":"name"}. A long message arrives
# with <pasted_content id="..."> around the <hc from> block: that wrapper goes too. A paste with no <hc from> inside is Matt's own turn; its wrapper is dropped too.
# Left out: thinking, tool calls and results, meta and sub-agent turns,
# <system-reminder> blocks, command echoes, <task-notification> blocks, compaction summaries and bare <hc>...</hc> notes.
# A Discord message (<channel source="discord" ...> or source="plugin:discord:discord", text inside) is Matt's turn with
# the text unwrapped and "via":"discord". A Discord message that starts a turn is a user line with isMeta and origin.kind "channel", kept
# the same way. A message Matt sent while the agent was working is not a user
# line: it is an attachment of type queued_command with origin.kind "human" (or "channel" when the prompt is a <channel> wrapper), kept as his user turn. Turns are kept whole,
# because the chat panel shows full replies. A half-written last line is skipped.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  echo "Usage: loh transcript [--archived] <name> [--last N]" >&2
  exit 2
}
archived=""
if [[ "${1:-}" == "--archived" ]]; then
  archived=1
  shift
fi
[[ $# -eq 1 || $# -eq 3 ]] || usage
name="$1"
last=40
if [[ $# -eq 3 ]]; then
  [[ "$2" == "--last" ]] || usage
  last="$3"
fi
if [[ -n "$archived" ]]; then
  # a folder name: starts with a letter or digit, so "." and ".." are out; no "/"
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "loh: invalid archive name: $name" >&2
    exit 2
  fi
elif [[ ! "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "loh: invalid target name: $name" >&2
  exit 2
fi
if [[ ! "$last" =~ ^[1-9][0-9]*$ ]]; then
  echo "loh: --last must be a positive integer, got: $last" >&2
  exit 2
fi
need jq

agent=""
if [[ -n "$archived" ]]; then
  dir="$(workspace_root)/.loh/transcripts/$name"
  [[ -d "$dir" ]] || die "no archived transcript named $name"
else
  need hc
  info="$(hc_json get "$name")" || die "cannot look up $name"
  cwd="$(jq -r '.cwd // ""' <<<"$info")"
  agent="$(jq -r '(.argv // []) as $a | ([range(0; $a | length - 1) | select($a[.] == "--agent") | $a[. + 1]] | first) // ""' <<<"$info")"
  [[ -n "$cwd" ]] || {
    echo "[]"
    exit 0
  }
  dir="$(claude_session_dir "$cwd")"
fi
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
  | select(
      ((.type == "user" or .type == "assistant") and (.isSidechain | not)
          and ((.isCompactSummary or .isVisibleInTranscriptOnly) | not)
          and ((.isMeta | not)
               or (.type == "user" and .origin.kind == "channel"
                   and (.message.content | type == "string" and test("^\\s*<channel ")))))
      or (.type == "attachment" and .attachment.type == "queued_command"
          and ((.attachment.origin.kind // .origin.kind) as $k
               | $k == "human" or ($k == "channel" and (.attachment.prompt | type == "string" and test("^\\s*<channel "))))))
  | (if .type == "attachment" then (.attachment.prompt // "") else .message.content end) as $c
  | { role: (if .type == "attachment" then "user" else .type end), ts: (.timestamp // ""), id: (.uuid // ""),
      text: (if ($c | type) == "string" then $c
             elif ($c | type) == "array" then ([$c[] | select(.type == "text") | .text] | join("\n"))
             else "" end) }
  | .text |= (gsub("(?s)<system-reminder>.*?</system-reminder>"; "") | gsub("^\\s+|\\s+$"; ""))
  | select(.text != "" and (.text | test("^<(local-)?command-|^<hc>|^<task-notification>") | not))
  | if (.text | test("^<channel source=\"(plugin:discord:)?discord\"[^>]*>")) then
      .via = "discord"
      | .text |= (sub("^<channel [^>]*>\\s*"; "") | sub("\\s*</channel>\\s*$"; ""))
    else . end
  | if (.text | test("^<pasted_content id=\"[^\"]*\">[\\s\\S]*</pasted_content id=\"[^\"]*\">$")) then
      .pasted = true
      | .text |= (sub("^<pasted_content id=\"[^\"]*\">\\s*"; "") | sub("\\s*</pasted_content id=\"[^\"]*\">$"; ""))
    else . end
  | if (.text | test("^<hc from=\"")) then
      .role = "agent"
      | .from = (.text | capture("^<hc from=\"(?:\\S+ )?(?<n>[^\"]+)\"").n)
      | .text |= (sub("^<hc from=\"[^\"]*\">\\s*"; "") | sub("\\s*</hc>\\s*$"; ""))
    else . end'
# The session's first user turn is flagged "launch":true when it was a paste (the filter above sets "pasted"
# and strips the wrapper), unless an agent turn comes before it. It is set here, where the whole session is
# visible, before the last N turns are cut; "pasted" is not part of the output.
# shellcheck disable=SC2016
mark='(map(.role != "assistant") | index(true)) as $i
  | if $i != null and .[$i].role != "user" then null else $i end as $i
  | if $i != null and .[$i].pasted then .[$i].launch = true else . end
  | .[] | del(.pasted)'
jq -cR "$filter" "$file" | jq -cs "$mark" | tail -n "$last" | jq -s .
