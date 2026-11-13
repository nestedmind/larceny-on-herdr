# shellcheck shell=bash
# loh status [--json]: one line per crew agent.
#
# Lists this workspace's terminals with `hc ls --label crew=<name>`, then reads
# each one with `hc get` for its labels (role, task, step, pr, round,
# with_matt) and its herdr state (and kind when blocked).
set -euo pipefail
# shellcheck source=lib/loh/lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/lock.sh"

usage() { echo "Usage: loh status [--json]" >&2; }

json=""
case "${1:-}" in
  "") ;;
  --json)
    json=1
    shift
    ;;
  *)
    usage
    exit 2
    ;;
esac
if [[ $# -gt 0 ]]; then
  usage
  exit 2
fi

need jq
crew="$(crew_name)"
listing="$(hc_json ls --label "crew=$crew")" || die "hc ls failed"

rows=()
while IFS= read -r addr; do
  [[ -n "$addr" ]] || continue
  info="$(hc_json get "$addr")" || continue
  rows+=("$(jq -c '{
      name: .name,
      address: .address,
      role: (.labels.role // null),
      task: (.labels.task // null),
      state: (.status.state // "unknown"),
      kind: (.status.kind // null),
      step: (.labels.step // null),
      pr: (.labels.pr // null),
      round: (.labels.round // null),
      with_matt: ((.labels.with_matt // "") == "1")
    }' <<<"$info")")
done < <(jq -r '.terminals[]?.address' <<<"$listing")

if ((${#rows[@]} == 0)); then
  agents='[]'
else
  agents="$(printf '%s\n' "${rows[@]}" | jq -s 'sort_by(.name)')"
fi

if [[ -n "$json" ]]; then
  jq '.' <<<"$agents"
  exit 0
fi

if [[ "$agents" == '[]' ]]; then
  echo "no crew agents are running for $crew"
  exit 0
fi

jq -r '.[] | [
    .name,
    (.role // "-"),
    (.task // "-"),
    (if .kind then "\(.state) (\(.kind))" else .state end),
    (.step // "-"),
    (if .pr then "PR #\(.pr)" else "-" end),
    (if .round then "round \(.round)" else "-" end),
    (if .with_matt then "with Matt" else "" end)
  ] | @tsv' <<<"$agents" |
  while IFS=$'\t' read -r name role task state step pr round matt; do
    line="$(printf '%-10s %-9s %-9s %-20s %-24s %-7s %-8s %s' \
      "$name" "$role" "$task" "$state" "$step" "$pr" "$round" "$matt")"
    printf '%s\n' "${line%"${line##*[![:space:]]}"}"
  done
