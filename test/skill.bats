#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

skill_file() { printf '%s\n' "$REPO_ROOT/skills/herdr-runtime/SKILL.md"; }

# loh commands the skill names that have no lib/loh/<name>.sh yet.
# Every command exists now; add a name here only while a command is still to land.
PENDING=""

# Print the frontmatter block (between the first two --- lines).
frontmatter() {
  awk 'NR==1 && $0!="---" {exit 1} NR>1 && $0=="---" {exit} NR>1 {print}' "$(skill_file)"
}

# Print each distinct `loh <word>` subcommand named in the body.
named_commands() {
  grep -oE '`loh [a-z]+' "$(skill_file)" | sed 's/^`loh //' | sort -u
}

@test "skill file exists" {
  [ -f "$(skill_file)" ]
}

@test "frontmatter parses with name and description" {
  run frontmatter
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: herdr-runtime"* ]]
  [[ "$output" == *"description: Use when "* ]]
}

@test "frontmatter has only name and description" {
  keys=$(frontmatter | grep -oE '^[a-z-]+:' | sort | tr '\n' ' ')
  [ "$keys" = "description: name: " ]
}

@test "description is at most 1024 characters" {
  desc=$(frontmatter | sed -n 's/^description: //p')
  [ "${#desc}" -le 1024 ]
}

@test "description names the HC_TERMINAL_ID trigger" {
  frontmatter | grep -q 'HC_TERMINAL_ID'
}

@test "skill is under 250 lines" {
  [ "$(wc -l <"$(skill_file)")" -lt 250 ]
}

@test "skill cites larceny 0.1.5 and its commit" {
  grep -q 'larceny 0.1.5, commit ' "$(skill_file)"
  ! grep -q 'dd27cf1' "$(skill_file)"
}

@test "plugin.json pins larceny to exactly 0.1.5" {
  grep -q '"version": "=0.1.5"' "$REPO_ROOT/.claude-plugin/plugin.json"
}

@test "skill names the six loh commands" {
  for c in up spawn down say gh git; do
    named_commands | grep -qx "$c" || { echo "missing loh $c"; return 1; }
  done
}

@test "every loh command the skill names exists or is pending" {
  for c in $(named_commands); do
    if [ -f "$REPO_ROOT/lib/loh/$c.sh" ]; then continue; fi
    case " $PENDING " in
      *" $c "*) ;;
      *) echo "loh $c is named but has no lib/loh/$c.sh and is not pending"; return 1 ;;
    esac
  done
}

@test "every hc wait command in the skill carries --timeout" {
  while IFS= read -r line; do
    [[ "$line" == *"--timeout"* ]] || { echo "no --timeout: $line"; return 1; }
  done < <(grep -E '`hc wait ' "$(skill_file)")
}

@test "every hc run command in the skill carries --bg" {
  while IFS= read -r line; do
    [[ "$line" == *"--bg"* ]] || { echo "no --bg: $line"; return 1; }
  done < <(grep -E '`hc run ' "$(skill_file)")
}

@test "the skill has an hc run command to check" {
  grep -qE '`hc run ' "$(skill_file)"
}

@test "the coder merge goes through loh gh" {
  grep -qF 'loh gh <me> pr merge <n> --squash --delete-branch' "$(skill_file)"
}

@test "the loh say row names the done, busy, with_matt and finished behaviour" {
  row=$(grep -F '`loh say <to> <text>`' "$(skill_file)")
  [[ "$row" == *"hc send --if idle"* ]]
  [[ "$row" == *"plain \`hc send\`"* ]]
  [[ "$row" == *"Exits 4"* ]]
  [[ "$row" == *"11 if"* ]]
  [[ "$row" == *"3 if"* ]]
}

@test "the coder retries once on exit 3 then escalates" {
  grep -qF 'exits 3' "$(skill_file)"
  grep -qF 'retry once' "$(skill_file)"
}

@test "the coordinator checks the with_matt label before prompting" {
  grep -qF 'check its `with_matt` label' "$(skill_file)"
}

@test "loh up takes no argument and loh spawn takes --model" {
  run grep -F 'loh up [' "$(skill_file)"
  [ "$status" -ne 0 ]
  grep -qF 'LOH_WORKSPACE' "$(skill_file)"
  grep -qF '`loh spawn <coder> <repo> <ticket> [--model M] [--brief <text> \| --brief-file <path>]`' "$(skill_file)"
}

@test "the coordinator releases a merged coder with loh release, not hc kill and hc rm" {
  grep -qF 'run `loh release <coder>`' "$(skill_file)"
  ! grep -qF 'end its terminal with `hc kill <coder>`' "$(skill_file)"
}

@test "the loh down row says the default kills every coder" {
  row=$(grep -F '`loh down [--all]`' "$(skill_file)")
  [[ "$row" == *"every coder"* ]]
  [[ "$row" == *"working or not"* ]]
}

@test "extra dispatch context goes through --brief, and loh say is for later messages" {
  grep -qF 'fills only its template' "$(skill_file)"
  grep -qF 'with `--brief <text>`, or `--brief-file <path>` for long text' "$(skill_file)"
  grep -qF 'use it only for later messages' "$(skill_file)"
  ! grep -qF 'Send anything else right after with `loh say <coder>`' "$(skill_file)"
}

@test "the coder checks approval through loh gh, not a token read" {
  grep -qF 'loh gh <me> pr view <n> --json reviews,headRefOid' "$(skill_file)"
}

@test "no line tells a coder to run loh say scofield" {
  while IFS= read -r line; do
    [[ "$line" == *"Do not"* ]] || { echo "tells a coder to say scofield: $line"; return 1; }
  done < <(grep -F '`loh say scofield' "$(skill_file)")
  grep -qF 'Do not run `loh say scofield`' "$(skill_file)"
}

@test "the reviewer posts verdicts with post-review.sh" {
  grep -qF 'post-review.sh' "$(skill_file)"
}

@test "every hc run in the skill carries --model" {
  while IFS= read -r line; do
    [[ "$line" == *"--model"* ]] || { echo "no --model: $line"; return 1; }
  done < <(grep -E '`hc run ' "$(skill_file)")
}

@test "the coordinator reads a coder's last message when a wait returns" {
  grep -qF 'read that coder'"'"'s last message with `hc read <coder>`' "$(skill_file)"
}

@test "the skill no longer says a wait returns because a coder sent a message" {
  run grep -F 'sent you a message' "$(skill_file)"
  [ "$status" -ne 0 ]
}

@test "the coordinator waits on Amy with hc wait amy and a timeout" {
  grep -qF '`hc wait amy --timeout <s>`' "$(skill_file)"
}

@test "the reviewer does not loh say the coordinator and ends her turn with the verdict" {
  line=$(grep -F 'Reply to a coder with `loh say <coder> ' "$(skill_file)")
  [[ "$line" == *'Do not `loh say scofield`'* ]]
  [[ "$line" == *"final message"* ]]
}

@test "the approval check names the reviewer login and how to get it" {
  grep -qF 'loh gh amy api user --jq .login' "$(skill_file)"
  grep -qF "\`author.login\` is the reviewer's login" "$(skill_file)"
}

@test "the escalating coder sets a card note and the coordinator clears it" {
  grep -qF 'loh card note="escalation:<one line>"' "$(skill_file)"
  # The clearing belongs to the coordinator: it must sit between "## Coordinator" and "## Coder".
  section=$(awk '/^## Coordinator/{f=1;next} /^## /{f=0} f' "$(skill_file)")
  [[ "$section" == *'hc label <coder> note='* ]]
  coder=$(awk '/^## Coder/{f=1;next} /^## /{f=0} f' "$(skill_file)")
  [[ "$coder" != *'hc label <coder> note='* ]]
}

@test "the coordinator passes Amy's verdict to the coder after waiting on her" {
  grep -qF 'read her verdict with `hc read amy`' "$(skill_file)"
  grep -qF 'pass it to the coder with `loh say <coder>`' "$(skill_file)"
}

@test "the login check runs no other loh gh amy command and escalates on a bad token" {
  grep -qF 'Run no other `loh gh amy` command' "$(skill_file)"
  grep -qF 'do not merge: escalate' "$(skill_file)"
  run grep -F 'stays correct if the reviewer is renamed' "$(skill_file)"
  [ "$status" -ne 0 ]
}

@test "skill never recommends hc send --force" {
  run grep -E 'hc send[^`]*--force' "$(skill_file)"
  [ "$status" -ne 0 ]
}

@test "reviewer section has Amy dispatch one background subagent per PR and drops the no-subagents rule" {
  run grep -F 'dispatch no subagents' "$(skill_file)"
  [ "$status" -ne 0 ]
  section=$(awk '/^## Reviewer/{f=1;next} /^## /{f=0} f' "$(skill_file)")
  [[ "$section" == *'one reviewer subagent for that PR'* ]]
  [[ "$section" == *'`Agent` tool'* ]]
  [[ "$section" == *'in the background'* ]]
  [[ "$section" == *'posts nothing and messages no one'* ]]
}

@test "reviewer section makes Amy the gate before any verdict" {
  section=$(awk '/^## Reviewer/{f=1;next} /^## /{f=0} f' "$(skill_file)")
  [[ "$section" == *'read the diff yourself'* ]]
  [[ "$section" == *'keep it, correct it, or throw it out with a reason'* ]]
  [[ "$section" == *'concurrency, boundaries'* ]]
  [[ "$section" == *'never posted as it is'* ]]
  [[ "$section" == *'never counts as an approval'* ]]
}

@test "reviewer section gives a follow-up round a fresh subagent and caps them at 4" {
  section=$(awk '/^## Reviewer/{f=1;next} /^## /{f=0} f' "$(skill_file)")
  [[ "$section" == *'fresh subagent'* ]]
  [[ "$section" == *"earlier review on GitHub"* ]]
  [[ "$section" == *'At most 4 review subagents run at once'* ]]
  [[ "$section" == *'wait in order'* ]]
}

@test "override table lists the larceny rules that forbid reviewer subagents" {
  table=$(awk '/^## What this overrides/{f=1;next} /^## /{f=0} f' "$(skill_file)")
  [[ "$table" == *'`agents/reviewer.md`'* ]]
  [[ "$table" == *'`agents/amy.md`'* ]]
  [[ "$table" == *'`skills/adversarial-review/SKILL.md`'* ]]
  [[ "$table" == *'Reviewer section below'* ]]
}

@test "the hc wait row covers coders and standing agents, not review subagents" {
  table=$(awk '/^## What this overrides/{f=1;next} /^## /{f=0} f' "$(skill_file)")
  run grep -F '| Any wait on a background agent or a Monitor |' "$(skill_file)"
  [ "$status" -ne 0 ]
  [[ "$table" == *"Any wait on a coder or a standing agent"* ]]
}

@test "the subagent brief forbids posting and messaging" {
  section=$(awk '/^## Reviewer/{f=1;next} /^## /{f=0} f' "$(skill_file)")
  [[ "$section" == *'forbid it `post-review.sh`, `gh pr review` and `loh say`'* ]]
}

# Print the Coordinator section (up to the next "## " heading).
coordinator_section() {
  awk '/^## Coordinator$/ {on=1; next} /^## / {on=0} on' "$(skill_file)"
}

@test "coordinator section has a waiting-on-the-owner rule that reaches Discord" {
  sect=$(coordinator_section)
  [[ "$sect" == *"Waiting on the owner"* ]]
  [[ "$sect" == *"same report"* ]]
  [[ "$sect" == *"every later report"* ]]
  [[ "$sect" == *"10 minutes"* ]]
  [[ "$sect" == *"Discord"* ]]
  [[ "$sect" == *"idle on a hold"* ]]
}
@test "waiting-on-the-owner rule fits the wake timeout, the Discord chat id and one reminder per item" {
  line=$(coordinator_section | grep 'Waiting on the owner')
  [[ "$line" == *"start \`loh wake --timeout 300\`"* ]]
  [[ "$line" != *"\`hc wait\` with"* ]]
  [[ "$line" == *"first turn at least 10 minutes after the report"* ]]
  [[ "$line" == *"record the chat id in \`.loh/status.md\`"* ]]
  [[ "$line" == *"A Discord answer counts as an answer"* ]]
  [[ "$line" == *"longer wake interval"* ]]
  [[ "$line" == *"when you reported"* ]]
  [[ "$line" == *"chat id of a Discord message the owner sent"* ]]
  [[ "$line" == *".loh/status.md"* ]]
  [[ "$line" == *"Discord could not be reached"* ]]
  [[ "$line" == *"one Discord reminder per waiting item"* ]]
}
