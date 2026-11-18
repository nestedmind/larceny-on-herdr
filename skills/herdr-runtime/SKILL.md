---
name: herdr-runtime
description: Use when your environment has HC_TERMINAL_ID set (you run in an hc terminal under herdr-core), or when the prompt says the crew runs on herdr instead of subagents. Applies to the larceny coordinator, coders and reviewer.
---

# herdr runtime

The larceny crew runs here as separate Claude Code sessions in `hc` terminals, not as subagents. The `loh` CLI starts them and carries messages. This skill replaces how agents are started, addressed and waited on. Everything else in larceny applies unchanged, including `coder`, `adversarial-review`, `pr-conventions` and the review rounds.

## What this overrides

Paths are in larceny 0.1.5, commit 03a9bfc. Where one of these says to use `Agent`, `SendMessage`, `ListAgents`, `isolation: worktree` or a subagent, follow this skill instead.

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
| Any wait on a coder or a standing agent, or a Monitor (review subagents are not waited on: Amy's turn resumes when each returns) | `hc wait`, with `--timeout` |
| `agents/reviewer.md` ("Do not dispatch subagents", Amy's founding prompt from `loh up`), `agents/amy.md` (same line) and `skills/adversarial-review/SKILL.md` ("never dispatch a subagent") | Reviewer section below: Amy dispatches one review subagent per PR and gates its findings |
| One-project assumptions: `.larceny/config.md` and `.larceny/status.md` read from the current directory, one board (`skills/coordinator/SKILL.md`, "Dispatching a ticket"; `skills/onboarding`) | Workspace rules below |

## Commands

| Command | Does |
|---|---|
| `loh up` | Starts `scofield` and `amy`, each `--no-parent`. Takes no argument: run it from the workspace folder, or set `LOH_WORKSPACE`. Leaves a live one alone |
| `loh spawn <coder> <repo> <ticket> [--model M] [--brief <text> \| --brief-file <path>]` | Makes the worktree, starts the coder with `--outlive-parent`, sends the dispatch prompt, with the brief under its own heading before the closing instructions |
| `loh say <to> <text>` | Sends a message. Idle target: `hc send --if idle`. Done target: plain `hc send`. Working or blocked: retries (default up to 40 times, 15 s apart; `LOH_SAY_TRIES=0` for no cap). `loh say --queue` hands the wait to a detached worker and returns 0 at once; if it finally fails, your card note becomes `undelivered:<to>: <why>` and `loh watch` announces it. Exits 4 if the target has `with_matt=1`, 11 if it has finished, 3 if it is still busy at the end |
| `loh gh <persona> <args...>` | Runs `gh` as that persona |
| `loh git <persona> <args...>` | Runs `git` as that persona |
| `loh wake [--timeout S]` | Run it in the background. Exits when a coder's turn ends, blocks, ends its terminal or changes its note, when a `loh say --queue` of yours fails, or when a review lands or a PR's head, mergeability or state changes in a workspace repo. Prints one line per change; at the timeout (default 900) prints `timeout after <S>s` |
| `loh release <coder> [--force]` | Archives the coder's transcript into `.loh/transcripts/`, then ends it. Refuses a non-coder, and a working coder without `--force` |
| `loh down [--all]` | Default: archives the transcript of, and kills, every coder of this crew, working or not. `--all`: kills every terminal with this crew label, standing agents included. Use it to stop the round, never to clear finished coders |
| `loh office lights [on\|off]` | Switches the office lights, as the office's own button does: the open office follows within about 5 s, and the last choice, from here or from the button, wins. With no argument prints `on` or `off`. Needs no herdr-app |

`loh gh` and `loh git` read the token file and set `GH_TOKEN` and the four `GIT_AUTHOR_*` and `GIT_COMMITTER_*` variables themselves. Never write `$(cat <token-file>)` or those variables yourself. The rules in larceny's `coder` skill, "Git identity" (verify authorship after each commit and before each push, never `git config`) still apply, run through `loh git`.

Every agent is an `hc` terminal labelled `crew=<workspace>` and `role=<role>`. Coders also carry `task=<repo>#<n>`. Address each one by name: `scofield`, `amy`, `sucre`.

## Coordinator

- Start the standing agents with `loh up`. Do not start a coder or the reviewer with the `Agent` tool.
- Dispatch each ticket with `loh spawn <coder> <repo> <ticket>`. Resolve the coder name and `models:` by `docs/crew-resolution.md` first, as larceny says, and pass a resolved model as `--model M`. `loh spawn` fills only its template: the ticket, worktree, branch, the repo's commands and rules. Pass anything else for this dispatch in the first prompt with `--brief <text>`, or `--brief-file <path>` for long text: a hold for the owner's go, a placeholder to use, what has landed, the board-move commands, the isolation values ("Dispatching a ticket"). A `loh say <coder>` only arrives once the coder is idle, after their first turn, so use it only for later messages.
- Keep at most 4 live coders. Count them with `hc ls --label crew=<workspace> --label role=coder --json`.
- After a coder reports its merge and you have checked GitHub, run `loh release <coder>`. It archives the coder's transcript into `.loh/transcripts/` and ends its terminal (`hc kill`, then `hc rm`); it refuses a coder that is still working unless you pass `--force`. A finished coder stays live until you release it, so it would count against the cap and block its name from being used again.
- After an office change merges, do nothing: herdr-app 0.1.16 reloads the open office tab by itself when the checkout's files change (the office walks back to its starting places). Run `loh office` from the workspace only when the change adds or changes a prop, when no office tab is open, or when the saved tab id is stale. If the office did not reload and its mod was linked while herdr-app was running, restart herdr-app, or run `loh office` as a fallback; it opens a new tab and closes the old one.
- Before you prompt an agent, check its `with_matt` label. While it is `1` the owner is working with that agent: `loh say` refuses (exit 4), so write what you need to the ticket or PR instead of prompting.
- Stay awake for the owner with `loh wake`, not by waiting. A blocking `hc wait` holds your turn, so you cannot talk to the owner or hear that a PR was approved. After every dispatch and every report, start `loh wake --timeout 900` as a background command (`run_in_background`). It exits, which starts a new turn for you, when something you must act on changes, and prints one line per change: `coder name=<n> event=turn-ended|blocked|gone|note`, `coordinator event=undelivered`, `pr repo=<r> number=<n> event=opened|head|mergeable|closed`, `review repo=<r> number=<n> by=<login> state=<state> head=<sha>`. It remembers what it last reported, so a change during your own turn is reported when you start it again. A lone `timeout after <S>s` means nothing changed: start it again. On any other line, read what changed (`hc read <coder>`, GitHub), act, and start it again before your turn ends. Report to the owner on a merge, an approval ready for their look, an escalation and a blocker. Use `hc wait` only for the short wait on Amy below.
- Wait with `hc wait --children any --timeout <seconds>`. Always pass `--timeout`. A return means a coder's turn ended, or it blocked or hit an error. When it returns for a coder, read that coder's last message with `hc read <coder>` before you act: coders end their turn with their report or escalation, not a `loh say`. Then read GitHub for the ticket's state. A return does not mean the ticket is done. Once you take a coder's escalation, clear its note with `hc label <coder> note=` (`loh card` sets only your own card), so `loh watch` does not keep announcing it. The coder's next prompt also clears a note that starts with `escalation:` (the status-card hook does it), so your answer ends the escalation even if you forget; any other note stays.
- After a restart, find the crew with `hc ls --json`, filtered by your `crew` label, and adopt what is live. Coders survive a coordinator restart.
- Read every PR diff yourself, as `skills/coordinator` says. Rounds 1 and 2 are coder and Amy. Take rounds 3 to 5, and raise round 5 to the owner. When you prompt Amy yourself in those rounds, `loh say amy "..."` and then wait on her with `hc wait amy --timeout <s>`: she runs `--no-parent`, so a `--children` wait never sees her. When her wait returns, read her verdict with `hc read amy` or on GitHub, and pass it to the coder with `loh say <coder>`: the coder treats that message as the approval relay.
- Start Yoda or Sara only when needed, by a named terminal: `hc run --bg --no-parent --name yoda --label crew=<workspace> --label role=advisor -- claude --agent larceny:yoda --permission-mode <pane_mode> --model <resolved>`. Resolve `models:` first ("Model overrides" in `docs/agent-lifecycle.md`) and leave `--model` off when it names none for that persona. Then send a first `loh say yoda "..."` as the spawn command's founding prompt describes. For the teacher use `--name sara`, `role=teacher` and `larceny:sara`, or the names the roster resolves to. `--bg` returns at once, and the labels let `hc ls` recovery and `loh down` find them. This is the one case where you pass `pane_mode` yourself; take it from `.loh/workspace.md` (default `auto`).
- Waiting on the owner: whenever anything waits on the owner (an approved PR held for their go, a decision, an escalation, a blocked agent), say so in the same report, for example "#N approved, waiting on your merge". Repeat it in every later report until the owner answers. While something waits, start `loh wake --timeout 300` instead of 900, so you wake every 5 minutes, and note when you reported. If the owner has not answered in the terminal by your first turn at least 10 minutes after the report, and a Discord channel is connected (the Discord reply tool is available), send the same reminder there, only to the chat id of a Discord message the owner sent earlier (this session, or one recorded in `.loh/status.md`); when the owner first writes on Discord, record the chat id in `.loh/status.md`. A Discord answer counts as an answer. With no such chat id, say in the terminal that Discord could not be reached. If the owner asks for a longer wake interval, use that until told otherwise. Send one Discord reminder per waiting item; send again only when a new item starts waiting. Never leave a coder idle on a hold without telling the owner.

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
- When the PR is open and CI is green, message the reviewer with `loh say --queue amy "<repo> PR #<n> ready: <one-line summary>"`. It returns at once and the message waits for Amy however long she is busy, so it survives the end of your turn. A plain `loh say` gives up after about 10 minutes, and its exit status would go unread once your turn ended. Then end your turn. Amy answers you by name, and her message arrives as a new turn.
- Rounds 1 and 2 are between you and Amy. After round 2 without agreement, end your turn with the escalation as your final message: `<repo> PR #<n> escalation: <open findings and your position>`. Before you end the turn, run `loh card note="escalation:<one line>"`, so `loh watch` notifies the owner. Do not run `loh say scofield`. The coordinator waits in `hc wait --children any --timeout <s>`, which counts as working, so a message would not be delivered. Its wait returns when your turn ends, and it reads your terminal.
- Check the approval with `loh gh <me> pr view <n> --json reviews,headRefOid`: a formal review whose `author.login` is the reviewer's login, state APPROVED, on the current `headRefOid`. Get the reviewer's login with `loh gh amy api user --jq .login`. It reads the reviewer's token without showing it to you. Run no other `loh gh amy` command. If it fails because Amy's token file is missing, or returns the owner's own login instead of a persona account, do not merge: escalate. A review by any other login, the owner's included, does not count. Never use the `$(cat token)` block from the `coder` skill. After approval of the current head, squash-merge with `loh gh <me> pr merge <n> --squash --delete-branch`, so the merge is made as your persona. Then remove your worktree, delete the local and remote branches (`coder`, "Cleanup after merge"), and end the turn with a short report as your final message: PR number, head, merge result, cleanup result. Do not `loh say scofield`. Your parent gets herdr's note when the turn ends.
- If a foreground `loh say` exits 3 (the target is busy), wait and retry once. If it exits 3 again, end your turn with what you could not deliver as your final message. A `--queue` send has no exit status to read after you end your turn: a failure shows as your `undelivered:` card note.
- A push after approval makes the approval stale. Ask Amy again.

## Reviewer

- Review on GitHub under your persona account, following `adversarial-review`. Post each verdict with its `post-review.sh`, which reads the token itself and checks the review landed on the current head. Use `loh gh amy ...` for every other `gh` call.
- You are the review coordinator. When a "PR #N ready" message arrives, dispatch one reviewer subagent for that PR with the `Agent` tool, running in the background. It runs the full `adversarial-review` against the PR and its ticket and returns its findings with evidence. It posts nothing and messages no one: `adversarial-review` tells a reviewer to post, so in its brief forbid it `post-review.sh`, `gh pr review` and `loh say`. You stay free to take the next PR while it runs.
- You are the gate. Before any verdict, read the diff yourself, check every finding against the code (keep it, correct it, or throw it out with a reason), and look for what the subagent missed: concurrency, boundaries, the ticket's acceptance criteria. Only then post the verdict with `post-review.sh` under your account and reply to the coder with `loh say`. A subagent's report is never posted as it is, and never counts as an approval on its own.
- A follow-up round (a new head after changes requested) gets a fresh subagent, given the PR's earlier review on GitHub as context. Check that every earlier finding was addressed.
- At most 4 review subagents run at once, matching the coder cap. Beyond that, PRs wait in order.
- A message from a coder or the coordinator arrives as `<hc from="tN name">...</hc>`. The name in the tag is the sender. Reply to a coder with `loh say <coder> "<verdict and PR head>"`. Do not `loh say scofield`: the coordinator is usually inside `hc wait`, which counts as working, so the message would retry for minutes and block your turn. When the sender is the coordinator, post the verdict on GitHub and end your turn with it as your final message. The coordinator waits on you with `hc wait amy --timeout <s>`.
- Rounds 1 and 2 are yours with the coder. Stay a standing terminal between reviews.

## Going to a room

Every agent does this, Maya and Opemipo included, whatever channel Matt asks in (the terminal, Discord, the office's message box). When Matt tells you to go somewhere, run `loh card place=<room>` on your own card, then answer him. The office moves you once your turn has ended, and you stay until your next prompt starts a turn.

- Rooms: lounge, kitchen, ping pong, rest room, meeting room, and `desk` ("back to your desk"; you stay seated until the idle time runs out).
- `loh card` refuses any other room. Then tell Matt which rooms exist.

Meetings: when Matt says "let's meet", "let's collaborate" or "let's sync" in the meeting room, run `loh card meeting=1`. Matt sits there with you. A new prompt does not clear it. When Matt names several agents in one ask, also run `hc label <name> meeting=1` for each one he named. When he says "meeting's over" or "back to your desk", run `loh card meeting=` and `hc label <name> meeting=` for each other agent in the meeting. "<name>, you can go" clears that one agent only. Starting a named agent who has no session needs ticket #48 and is not part of this.

## Safety

- Never use `--force` with `hc send`. Never answer another agent's permission or trust dialog. If an agent is blocked, tell the coordinator by name, and the coordinator tells the owner.
- Never print, log or commit a token.
- Address agents by name. A pane or terminal id (`t5`) changes, so it is never an address.
- Pass `--timeout` on every `hc wait`. A timeout means the agent is still running: read its state with `hc get <name>` before you retry or resend.
- Do not fork or modify herdr or larceny.
