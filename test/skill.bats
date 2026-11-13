#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

skill_file() { printf '%s\n' "$REPO_ROOT/skills/herdr-runtime/SKILL.md"; }

# loh commands the skill names that have not landed yet.
# Remove a name from this list when its lib/loh/<name>.sh exists.
PENDING="up spawn down say gh git"

# Phase 2 commands: the skill must not document them yet.
PHASE2="card lock status"

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

@test "skill cites larceny commit dd27cf1" {
  grep -q 'dd27cf1' "$(skill_file)"
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

@test "skill does not document phase 2 commands" {
  for c in $PHASE2; do
    if grep -qE "loh $c( |\`|\$)" "$(skill_file)"; then
      echo "loh $c must not be documented yet"; return 1
    fi
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
  grep -qF 'loh gh <me> pr merge <n> --squash' "$(skill_file)"
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
  grep -qF '`loh spawn <coder> <repo> <ticket> [--model M]`' "$(skill_file)"
}

@test "the coordinator ends a merged coder with hc kill then hc rm" {
  grep -qF 'hc kill <coder>' "$(skill_file)"
  grep -qF 'hc rm <coder>' "$(skill_file)"
}

@test "the loh down row says the default kills every coder" {
  row=$(grep -F '`loh down [--all]`' "$(skill_file)")
  [[ "$row" == *"every coder"* ]]
  [[ "$row" == *"working or not"* ]]
}

@test "extra dispatch context goes through loh say after spawn" {
  grep -qF 'fills only its template' "$(skill_file)"
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

@test "skill never recommends hc send --force" {
  run grep -E 'hc send[^`]*--force' "$(skill_file)"
  [ "$status" -ne 0 ]
}
