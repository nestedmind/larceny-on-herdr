---
name: herdr-runtime
description: Use when your environment has HC_TERMINAL_ID set (you run in an hc terminal under herdr-core), or when the prompt says the crew runs on herdr instead of subagents. Applies to the larceny coordinator, coders and reviewer.
---

# herdr runtime

The larceny crew runs here as separate Claude Code sessions in `hc` terminals, not as subagents. The `loh` CLI starts them and carries messages. This skill replaces how agents are started, addressed and waited on. Everything else in larceny applies unchanged, including `coder`, `adversarial-review`, `pr-conventions` and the review rounds.

## What this overrides

Paths are in larceny 0.1.4, commit dd27cf1. Where one of these says to use `Agent`, `SendMessage`, `ListAgents`, `isolation: worktree` or a subagent, follow this skill instead.

| larceny section | Replaced by |
|---|---|
| `skills/coordinator/SKILL.md`, "The example team" (dispatch the reviewer with `subagent_type`; coders are subagents) and "Dispatching a ticket" (one subagent per ticket) | Coordinator section below |
| `skills/coordinator/SKILL.md`, "Addressing a persona" (`SendMessage`, `ListAgents`) | `loh say <name> "<text>"`, and `hc ls --json` |
| `docs/agent-lifecycle.md`, "Addressing a persona" and "Auto-spawn on first mention" (`SendMessage`, `ListAgents`, `Agent`) | Same two replacements; start a missing persona with `hc run` |
| `skills/bring-in-personas/SKILL.md`, "Steps" 1 and 2 (`SendMessage`, `ListAgents`, auto-spawn) | Same. Steps 3 to 7 (verbatim replies, labels) apply unchanged |
| `commands/spawn-reviewer.md`, `spawn-advisor.md`, `spawn-teacher.md`, "Then" (the `Agent` call) | `loh up` for the reviewer; `hc run` for Yoda and Sara |
| `commands/wake-up.md`, "Then" steps 2 and 4, and `agents/coordinator.md`, `agents/scofield.md` (one project in the current directory; confirm before spawning subagents) | Workspace rules below. Still confirm with the owner before starting a new round of work |
| `skills/coder/SKILL.md`, "Reviewer protocol" (message the reviewer "using the id the coordinator gave you"; escalate and report as a subagent) | Coder section below |
| `agents/sucre.md`, `mahone.md`, `sheba.md`, `whip.md`, frontmatter `isolation: worktree` | `loh spawn` creates the worktree before the session starts |
| Any wait on a background agent or a Monitor | `hc wait`, with `--timeout` |
| One-project assumptions: `.larceny/config.md` and `.larceny/status.md` read from the current directory, one board (`skills/coordinator/SKILL.md`, "Dispatching a ticket"; `skills/onboarding`) | Workspace rules below |

## Commands

| Command | Does |
|---|---|
| `loh up` | Starts `scofield` and `amy`, each `--no-parent`. Takes no argument: run it from the workspace folder, or set `LOH_WORKSPACE`. Leaves a live one alone |
| `loh spawn <coder> <repo> <ticket> [--model M]` | Makes the worktree, starts the coder with `--outlive-parent`, sends the dispatch prompt |
| `loh say <to> <text>` | Sends a message. Idle target: `hc send --if idle`. Done target: plain `hc send`. Working or blocked: retries (default up to 40 times, 15 s apart). Exits 4 if the target has `with_matt=1`, 11 if it has finished, 3 if it is still busy at the end |
| `loh gh <persona> <args...>` | Runs `gh` as that persona |
| `loh git <persona> <args...>` | Runs `git` as that persona |
| `loh down [--all]` | Default: kills every coder of this crew, working or not. `--all`: kills every terminal with this crew label, standing agents included. Use it to stop the round, never to clear finished coders |

`loh gh` and `loh git` read the token file and set `GH_TOKEN` and the four `GIT_AUTHOR_*` and `GIT_COMMITTER_*` variables themselves. Never write `$(cat <token-file>)` or those variables yourself. The rules in larceny's `coder` skill, "Git identity" (verify authorship after each commit and before each push, never `git config`) still apply, run through `loh git`.

Every agent is an `hc` terminal labelled `crew=<workspace>` and `role=<role>`. Coders also carry `task=<repo>#<n>`. Address each one by name: `scofield`, `amy`, `sucre`.

## Coordinator

- Start the standing agents with `loh up`. Do not start a coder or the reviewer with the `Agent` tool.
- Dispatch each ticket with `loh spawn <coder> <repo> <ticket>`. Resolve the coder name and `models:` by `docs/crew-resolution.md` first, as larceny says, and pass a resolved model as `--model M`. `loh spawn` fills only its template: the ticket, worktree, branch, the repo's commands and rules. Send anything else right after with `loh say <coder>`: what has landed, the board-move commands, the isolation values ("Dispatching a ticket").
- Keep at most 4 live coders. Count them with `hc ls --label crew=<workspace> --label role=coder --json`.
- After a coder reports its merge and you have checked GitHub, end its terminal with `hc kill <coder>`, then `hc rm <coder>`. A finished coder stays live until you do, so it would count against the cap and block its name from being used again.
- Before you prompt an agent, check its `with_matt` label. While it is `1` the owner is working with that agent: `loh say` refuses (exit 4), so write what you need to the ticket or PR instead of prompting.
- Wait with `hc wait --children any --timeout <seconds>`. Always pass `--timeout`. A return means a coder's turn ended, or it blocked or hit an error. When it returns for a coder, read that coder's last message with `hc read <coder>` before you act: coders end their turn with their report or escalation, not a `loh say`. Then read GitHub for the ticket's state. A return does not mean the ticket is done. Once you take a coder's escalation, clear its note with `hc label <coder> note=` (`loh card` sets only your own card), so `loh watch` does not keep announcing it.
- After a restart, find the crew with `hc ls --json`, filtered by your `crew` label, and adopt what is live. Coders survive a coordinator restart.
- Read every PR diff yourself, as `skills/coordinator` says. Rounds 1 and 2 are coder and Amy. Take rounds 3 to 5, and raise round 5 to the owner. When you prompt Amy yourself in those rounds, `loh say amy "..."` and then wait on her with `hc wait amy --timeout <s>`: she runs `--no-parent`, so a `--children` wait never sees her. When her wait returns, read her verdict with `hc read amy` or on GitHub, and pass it to the coder with `loh say <coder>`: the coder treats that message as the approval relay.
- Start Yoda or Sara only when needed, by a named terminal: `hc run --bg --no-parent --name yoda --label crew=<workspace> --label role=advisor -- claude --agent larceny:yoda --permission-mode <pane_mode> --model <resolved>`. Resolve `models:` first ("Model overrides" in `docs/agent-lifecycle.md`) and leave `--model` off when it names none for that persona. Then send a first `loh say yoda "..."` as the spawn command's founding prompt describes. For the teacher use `--name sara`, `role=teacher` and `larceny:sara`, or the names the roster resolves to. `--bg` returns at once, and the labels let `hc ls` recovery and `loh down` find them. This is the one case where you pass `pane_mode` yourself; take it from `.loh/workspace.md` (default `auto`).

### Workspace rules

- Read `.loh/workspace.md` first. It lists the repos. Each ticket belongs to exactly one repo. Pick it from the owner's words, and ask the owner when they do not settle it.
- Load that repo's `.larceny/config.md` for commands, board and `models:`. Crew settings still resolve by `docs/crew-resolution.md`. Do not run onboarding at the workspace root when the manifest and the repo configs exist.
- Keep coordination state in `.loh/status.md`, one row per stream, with a project column. Do not keep per-repo status files. GitHub stays the truth when they disagree.
- Persona token files decide identity. A config key like `identities: later` does not override a token file that exists.
- The manifest's `pane_mode:` sets the permission mode for crew panes. `loh` applies it, so do not pass a mode to `loh`. The only exception is the Yoda and Sara `hc run` above.

## Coder

You started in a worktree that `loh spawn` made on your branch. Do not create another. `worktree-parallel-work` section 1 applies: you are already in a linked worktree. The repo's `.larceny/config.md` was copied into it.

- Run `gh` as `loh gh <me> ...` and `git` as `loh git <me> ...`, where `<me>` is your persona name.
- Run tests and lint in the foreground. A command you let go to the background ends your turn and herdr reports it as done while it still runs.
- When the PR is open and CI is green, message the reviewer: `loh say amy "<repo> PR #<n> ready: <one-line summary>"`. Then end your turn. Amy answers you by name, and her message arrives as a new turn.
- Rounds 1 and 2 are between you and Amy. After round 2 without agreement, end your turn with the escalation as your final message: `<repo> PR #<n> escalation: <open findings and your position>`. Before you end the turn, run `loh card note="escalation:<one line>"`, so `loh watch` notifies the owner. Do not run `loh say scofield`. The coordinator waits in `hc wait --children any --timeout <s>`, which counts as working, so a message would not be delivered. Its wait returns when your turn ends, and it reads your terminal.
- Check the approval with `loh gh <me> pr view <n> --json reviews,headRefOid`: a formal review whose `author.login` is the reviewer's login, state APPROVED, on the current `headRefOid`. Get the reviewer's login with `loh gh amy api user --jq .login`. It reads the reviewer's token without showing it to you. Run no other `loh gh amy` command. If it fails because Amy's token file is missing, or returns the owner's own login instead of a persona account, do not merge: escalate. A review by any other login, the owner's included, does not count. Never use the `$(cat token)` block from the `coder` skill. After approval of the current head, squash-merge with `loh gh <me> pr merge <n> --squash --delete-branch`, so the merge is made as your persona. Then remove your worktree, delete the local and remote branches (`coder`, "Cleanup after merge"), and end the turn with a short report as your final message: PR number, head, merge result, cleanup result. Do not `loh say scofield`. Your parent gets herdr's note when the turn ends.
- If `loh say` exits 3 (the target is busy), wait and retry once. If it exits 3 again, end your turn with what you could not deliver as your final message.
- A push after approval makes the approval stale. Ask Amy again.

## Reviewer

- Review on GitHub under your persona account, following `adversarial-review`. Post each verdict with its `post-review.sh`, which reads the token itself and checks the review landed on the current head. Use `loh gh amy ...` for every other `gh` call. Review the change yourself and dispatch no subagents.
- A message from a coder or the coordinator arrives as `<hc from="tN name">...</hc>`. The name in the tag is the sender. Reply to a coder with `loh say <coder> "<verdict and PR head>"`. Do not `loh say scofield`: the coordinator is usually inside `hc wait`, which counts as working, so the message would retry for minutes and block your turn. When the sender is the coordinator, post the verdict on GitHub and end your turn with it as your final message. The coordinator waits on you with `hc wait amy --timeout <s>`.
- Rounds 1 and 2 are yours with the coder. Stay a standing terminal between reviews.

## Safety

- Never use `--force` with `hc send`. Never answer another agent's permission or trust dialog. If an agent is blocked, tell the coordinator by name, and the coordinator tells the owner.
- Never print, log or commit a token.
- Address agents by name. A pane or terminal id (`t5`) changes, so it is never an address.
- Pass `--timeout` on every `hc wait`. A timeout means the agent is still running: read its state with `hc get <name>` before you retry or resend.
- Do not fork or modify herdr or larceny.
