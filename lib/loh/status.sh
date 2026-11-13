# shellcheck shell=bash
# loh status [--json]: one line per crew agent.
# loh status --repos: the manifest's repos as a JSON array (name, path, branch,
# github), in manifest order. The office mod reads the repo rooms from this, so
# the manifest is still parsed in one place (manifest_load).
# loh status --settings: the manifest's office settings as a JSON object
# ({"idle_minutes": 3}); the office reads the idle time from here.
#
# loh status --prs: ask GitHub whether the pull request of each crew agent that
# has a `pr` label is still open. A merged or closed one has its `pr` label
# cleared (hc label <agent> pr=), so the agent stops waiting on review. This
# catches a merge or close done by someone else: the coder's own `gh pr merge`
# or `gh pr close` is caught by hooks/status-card.sh. Prints a JSON array of the
# labels it cleared ({name, pr, state}). One `gh pr view` per agent with a pr
# label, none for the rest; a failed call keeps the label. The office runs it
# every few minutes, never per render.
#
# Lists this workspace's terminals with `hc ls --label crew=<name>`, then reads
# each one with `hc get` for its labels (role, task, step, pr, round,
# with_matt) and its herdr state (and kind when blocked).
set -euo pipefail
# shellcheck source=lib/loh/lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/lock.sh"

usage() { echo "Usage: loh status [--json | --repos | --settings | --prs]" >&2; }

json=""
repos=""
settings=""
prs=""
case "${1:-}" in
  "") ;;
  --repos)
    repos=1
    shift
    ;;
  --settings)
    settings=1
    shift
    ;;
  --prs)
    prs=1
    shift
    ;;
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

if [[ -n "$settings" ]]; then
  manifest_load
  jq -cn --argjson idle "$WS_IDLE_MINUTES" '{idle_minutes: $idle}'
  exit 0
fi

if [[ -n "$repos" ]]; then
  manifest_load
  for i in "${!REPO_NAMES[@]}"; do
    jq -cn --arg name "${REPO_NAMES[i]}" --arg path "${REPO_PATHS[i]}" \
      --arg branch "${REPO_BRANCHES[i]}" --arg github "${REPO_GITHUBS[i]}" \
      '{name: $name, path: $path, branch: $branch, github: $github}'
  done | jq -s '.'
  exit 0
fi

if [[ -n "$prs" ]]; then
  manifest_load
  crew="$WS_NAME"
  listing="$(hc_json ls --label "crew=$crew")" || die "hc ls failed"
  tmo=()
  if command -v timeout >/dev/null 2>&1; then tmo=(timeout 10); fi
  cleared=()
  while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    info="$(hc_json get "$addr")" || continue
    IFS=$'\t' read -r name pr task < <(jq -r '[.name, (.labels.pr // ""), (.labels.task // "")] | @tsv' <<<"$info")
    [[ -n "$pr" && "$task" == *"#"* ]] || continue
    github=""
    for i in "${!REPO_NAMES[@]}"; do
      [[ "${REPO_NAMES[i]}" == "${task%%#*}" ]] && github="${REPO_GITHUBS[i]}"
    done
    [[ -n "$github" ]] || continue
    state="$("${tmo[@]}" gh pr view "$pr" -R "$github" --json state --jq .state 2>/dev/null)" || continue
    case "$state" in
      MERGED | CLOSED)
        hc label "$addr" "pr=" "prdone=1" >/dev/null 2>&1 || continue
        cleared+=("$(jq -cn --arg n "$name" --arg p "$pr" --arg s "$state" '{name: $n, pr: $p, state: $s}')")
        ;;
    esac
  done < <(jq -r '.terminals[]?.address' <<<"$listing")
  if ((${#cleared[@]} == 0)); then echo '[]'; else printf '%s\n' "${cleared[@]}" | jq -sc '.'; fi
  exit 0
fi

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
