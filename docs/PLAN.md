# larceny-on-herdr: plan

Nov 13, 2026 · @Matt Adesanya

larceny-on-herdr runs a coordinated AI dev crew as separate Claude Code sessions under herdr-core. It is built on larceny.

## Goal and vision

larceny-on-herdr turns larceny's dev crew into separate Claude Code sessions in herdr, with a pixel office as the window onto them. Version 1 uses larceny's crew, process and skills unchanged except for how agents start and talk.

The rule for every design choice: **larceny decides, herdr executes, the office shows.** GitHub stays the record, so no decision lives only in a terminal.

What done looks like, on a normal day:

1. You open the office on a workspace: a folder of several repos. One office opens with one crew at their desks: Scofield, four coders, Amy, Yoda and Sara.
2. You click Scofield and describe the work. He works out which repo it belongs to, writes tickets there, you approve, and he dispatches. Each coder walks to a desk: a fresh Claude session in its own terminal and worktree.
3. You glance instead of watching. Typing means working, wandering means idle, and a raised hand means someone needs a person. A raised hand also sends a desktop notification.
4. You click any agent to open a sidebar: a status card on top, the live session below. You chat directly. Their desk shows "with Matt", and the crew leaves that agent alone until you close it.
5. Coders hand pull requests to Amy directly. Round 3 brings Scofield in, and round 5 raises a hand for you.
6. A merge sets off confetti, clears the coder's session and frees the desk for the next ticket.
7. You close the window and the sessions keep running. You reopen it later and everyone is where you left them.

Steps 3 to 6 need the office and the status cards, which are phases 2 and 3. Phase 1 delivers the crew itself, without the office.

Out of scope for v1: cloud or headless runs, running the crew in CI, changing larceny's process rules, and Windows.

## Phase 0 results

Phase 0 ran from Nov 12 to Nov 13, 2026, on herdr 0.9.5, herdr-core (`hc`) 0.1.20, herdr-app 0.1.15 and larceny 0.1.4 at commit dd27cf1.

| Spike | Question | Result |
| --- | --- | --- |
| 1 | Can a plugin's agent load `larceny:coder` plus its own skill? | Yes, with the Skill tool. `skills:` frontmatter is preloaded for subagents only, so an agent started with `claude --agent` gets nothing preloaded. |
| Hand run | Does a larceny coder in a herdr pane reach a merged PR? | Yes. Sucre took a ticket to an approved PR that Matt merged. |
| 2 | Can a herdr-app mod handle click, panels and metadata? | Yes to click and panels. There is no `pane report-metadata` in herdr-core, and labels replace it. A two-desk proof worked. |
| 3 | Does herdr read Claude's state correctly? | Mostly. `blocked`, `working` and `done` were right on two real tickets. Two mismatches are listed below. |
| 4 | Does a larceny coordinator work over a two-repo workspace? | Yes, with larceny unchanged. It needs three additions, listed below. |

What the spikes changed in the design:

- **The crew runs under herdr-core, not the `herdr` TUI.** herdr-app cannot see TUI panes: they are separate servers, and `hc ls` lists only herdr-app's own terminals. Every agent is an `hc` terminal. herdr-app shows one with `herdr-app do terminal.keep --terminal <tN>`.
- **Skills are loaded with the Skill tool.** The first prompt to each agent tells it to load its larceny skills and `larceny-on-herdr:herdr-runtime`. Spike 1 and the hand run both showed this works, and the agent's own larceny files run unchanged, so there are no agent wrappers.
- **Coders create their worktrees themselves.** `isolation: worktree` in a coder's frontmatter is ignored when the agent starts with `claude --agent`. A coder that starts in a worktree recognises it and works there.
- **Messages between agents need our own relay.** larceny's `SendMessage` cannot cross terminals. `hc send` does, and the receiver sees the sender in a `<hc from="t5 sucre">…</hc>` tag, so the office can draw messages without a log of ours. Two coders messaged Amy and Amy replied to them by name, with nobody relaying by hand.
- **Status cards use `hc label`.** herdr-core has no `report-metadata`. A mod reads labels as `terminals()[i].labels`. Labels persist across turns. Whether a label change alone redraws a mod is untested.
- **Claude reports status under herdr-core.** `hc get` returns `{"state":"blocked","kind":"permission"}` with the command in `msg`, so the office can tell a permission prompt from other blocks. A dispatched turn counts as working from the moment it is sent.
- **Parent and child.** A child terminal ends when its parent's program ends. `--outlive-parent` survives that, so coders start with it and standing agents with `--no-parent`. A coordinator restart then leaves the coders running.
- **Larceny's coordinator over several repos.** It picked the right repo for each request, asked when a request fitted two repos, followed each repo's `.larceny/config.md`, and opened no duplicate ticket. The gaps: it keeps one status file per repo, nothing tells it to dispatch through herdr, and it improvised a dispatch without `--outlive-parent` and with the wrong permission mode.

Mismatches between herdr's states and reality:

| Mismatch | Effect | Mitigation |
| --- | --- | --- |
| Claude moves a long command to the background, the turn ends, and herdr reports `done` while the command runs. | A wait returns early. The office would show confetti or idle too soon. | Coders run tests in the foreground. `done` means the turn ended, and GitHub says whether the ticket is finished. |
| Startup dialogs report `status: null`, not `blocked`. A worktree whose `.claude/settings.local.json` holds permissions triggers the trust dialog, and `hc send` pasted the prompt into it. Enter chose "No, exit", and the session ended. | The first prompt is lost and the session dies. | `loh spawn` waits for `status.state == idle` before the first send. The allowlist goes in user scope, not in the worktree. |

Cost and context. Two machines were used. The first ran WSL (spikes 1 and 2 and the hand run, Nov 12). The test machine runs Ubuntu 26.04 (spikes 3 and 4, Nov 13).

- On the first machine (WSL), a fresh session started at about 228k input tokens (spike 1), because of many plugins, MCP servers and CLAUDE.md. A one-off subagent run cost about $2.2 on Sonnet. Another machine's baseline will differ. Long-lived terminals amortise this, and many short sessions do not.
- On the Ubuntu test machine (spike 3), the cost is mostly the one-off cache write of the startup context. Sucre's first run wrote 384k tokens to cache and read 986k over 24 calls. Mahone wrote 169k and read 1.3M. A fresh Amy wrote 110k. A standing Amy reviewing a second PR wrote 34k and read 838k, so a warm standing reviewer is cheap.
- Compaction was not measured. Scofield's context across several repos is the likeliest to fill, so all coordination state lives in `.loh/status.md` and GitHub.

Permission prompts in `--permission-mode default`: most were compound commands that carry `GH_TOKEN=$(cat …)` or inline `GIT_AUTHOR_*`, which Claude Code always asks about. A plain allowlist does not cover them, so `loh gh` and `loh git` read the token themselves and one allowlist entry covers them. Auto mode, Matt's default, handled every prompt.

Other notes:

- Start herdr-core from a normal terminal, never from an agent's shell. Core keeps its starting environment, and one started inside Claude Code passes `CLAUDE_CODE_CHILD_SESSION` to every pane, which turns transcript saving off. Fix: `hc server restart --fresh` from outside Claude and herdr.
- The first `hc` call turns on systemd linger, so the core outlives logins.
- herdr-app offers core updates in its window (0.1.21 was offered at once), so keeping the pin means declining them.
- A herdr-app mod shows a desk only for terminals with agent status. A plain shell is an "empty desk".
- `--model` is honoured: Sucre ran on Sonnet and Amy on Opus.
- Amy's approval comment, posted through the ambient login, puts the attribution line first and `APPROVED at <sha>` on line 3. A check that reads only the first line misses it.
- Terminal names stay taken by a finished terminal until it is removed, so `loh spawn` removes a finished one before it reuses a name.

## How larceny works today

Larceny is about 5,100 lines of prompt instructions, not code: 12 agent files, 5 commands, 19 skills and 9 docs. Dispatch and messaging live in a handful of those instructions, and most of the crew starts as a standalone session. Read at [v0.1.4, commit dd27cf1](https://github.com/nestedmind/larceny) (30 Sep 2026).

| Role | Agent files | Standalone | How larceny starts it now |
| --- | --- | --- | --- |
| Coordinator | `coordinator.md`, `scofield.md` | Yes: `claude --agent larceny:coordinator` or `/larceny:wake-up` (spike 4) | As the main session |
| Coders | `sucre.md`, `mahone.md`, `sheba.md`, `whip.md` | Yes: Sucre and Mahone ran standalone (spike 3) | `Agent` tool, one per ticket, with `isolation: worktree` in frontmatter |
| Reviewer | `amy.md`, `reviewer.md` | Yes: `claude --agent larceny:reviewer` | `Agent` tool via `/larceny:spawn-reviewer` or `subagent_type: larceny:reviewer` |
| Advisor, teacher | `yoda.md`, `advisor.md`, `sara.md`, `teacher.md` | Yes | `Agent` tool via spawn commands, or auto-spawn when named |

What ties larceny to subagents:

- The coordinator skill says coders "are subagents" and dispatches the reviewer with `subagent_type`.
- Personas are addressed with `SendMessage({to: "<name>"})`, and liveness is checked with `ListAgents` (`docs/agent-lifecycle.md`, `skills/bring-in-personas`).
- The coder skill messages the reviewer "using the id the coordinator gave you" and ends with a report that returns to the coordinator.
- Spawned personas are background agents that end with the session, and GitHub comments cannot wake one (`docs/limitations.md`).

What is mechanism-neutral and carries over as is:

- The lifecycle rule already matches terminals: Amy, Yoda and Sara are persistent, coders are fresh per ticket.
- One ticket, one worktree, one branch, one pull request; coders read the ticket from source.
- Board moves, per-persona GitHub identities and token files, isolation of shared ports and containers.
- Review rounds 1–2 coder and reviewer, 3–5 coordinator, then the owner.
- `worktree-parallel-work` detects an existing worktree and works in it, so a coder started inside a worktree that `loh spawn` made works as is (hand run).

## Architecture

Each agent runs as its own Claude session in an `hc` terminal. larceny-on-herdr changes how they are started and how they talk, and nothing else.

The layers, top to bottom:

1. **Office view** (phase 3, we build): a herdr-app mod over `hc` state. Spike 2 proved the API, and the two-desk proof is the reference.
2. **larceny-on-herdr** (we build): the `loh` CLI and the `herdr-runtime` skill, in one Claude Code plugin. It depends on larceny.
3. **larceny** (upstream, unchanged): personas, process and skills, and the agent files.
4. **herdr-core and herdr-app** (upstream, no forks): `hc` runs and labels terminals, and herdr-app draws them.
5. **Claude Code sessions**, one per terminal.

Every terminal carries labels: `crew=<workspace>`, `role=<role>`, and `task=<repo>#<n>` for coders. Agents are addressed by name, never by terminal id.

A ticket's path through the terminals:

1. Scofield picks the repo, writes the ticket there, and you approve it.
2. `loh spawn sucre api 3` fetches the repo, makes a worktree on `sucre/3-<slug>` under `<workspace>/.worktrees/`, copies the repo's `.larceny/config.md`, and starts Sucre as an `hc` terminal with `--outlive-parent`. It waits for `idle`, then sends the dispatch prompt.
3. Sucre loads his larceny skills and `herdr-runtime`, reads the ticket from source, works, runs tests in the foreground, opens a PR and moves the card to In review.
4. `loh say amy "api PR #4 ready: …"`. Amy reviews on GitHub under her own account and replies with `loh say sucre …`. Rounds 1 and 2 stay between them.
5. Still open after round 2, Sucre escalates with `loh say scofield …`. Still open at round 5, Scofield raises it with you.
6. On approval of the current head, Sucre squash-merges, removes his worktree and branches, and ends his turn with a short report. Scofield waits with `hc wait --children any --timeout <s>` and assigns the next ticket.

Recovery: a fresh coordinator lists its crew with `hc ls --json`, filtered by its `crew` label, and adopts it. Coders survive a coordinator restart because of `--outlive-parent`.

## Workspace and projects

One office and one crew work across every repo in a workspace; the project is context each agent carries, not a room. Each person's card shows what they are on, for example *web · 13*.

- **Workspace.** A folder with a manifest, `.loh/workspace.md`, that lists each repo. You open the office there, and `loh` finds the workspace by walking up from the current folder, or from `LOH_WORKSPACE`.
- **One crew.** One Scofield, one Amy, four coders, Yoda and Sara, shared across all repos. The coder cap is 4 live coders, a number in the skill and not in code.
- **Switching projects.** Scofield picks the repo from your instruction ("the login bug in web") or from the conversation. If neither settles it, he asks. Every ticket belongs to exactly one repo.
- **Agents carry the project.** A coder is spawned per ticket into a worktree of that ticket's repo. Amy is told the repo with each review request. Yoda and Sara take the project from whoever asks them.
- **Cross-repo work.** Scofield splits a feature that spans repos into linked tickets, one per repo, and orders them by dependency.
- **State.** Each repo keeps its own `.larceny/config.md` for its test, lint and build commands. Scofield keeps one workspace status file, `.loh/status.md`, with a project column. Per-repo status files are not used.
- **Manifest rules.** `name:` is required, and it is the value of the `crew=` label on every crew terminal. Each repo needs `name`, `path` (relative to the workspace folder), `branch` (the default branch) and `github` (`owner/repo`). A missing key or a malformed manifest stops the commands that load it (`up`, `spawn`, `down`, `watch`) with a clear message.
- **Permission mode.** The manifest's `pane_mode:` key sets the Claude permission mode for crew terminals. It must be `default`, `acceptEdits`, `auto`, `plan` or `dontAsk`, and the default is `auto`. `bypassPermissions` is refused on purpose, so that a crew terminal can never skip every permission check.
- **Board.** One GitHub Project holding issues from all the repos, with a repo field to filter on, fits one office best. One board per repo also works. Spike 4 ran with `board: later`, so this is untested.

Example manifest:

```
# .loh/workspace.md
name: acme
pane_mode: auto
repos:
  - name: api
    path: ./api
    branch: main
    github: acme/api
  - name: web
    path: ./web
    branch: main
    github: acme/web
```

## The change list

Eleven larceny instructions change, and nothing else in larceny does. Ten spawn, address or wait on agents and get a herdr replacement; the eleventh lets one coordinator work across the workspace's repos. Every replacement has one home: a `loh` command, the `herdr-runtime` skill, or both. The skill says it overrides exactly these sections, each with its larceny path at commit dd27cf1.

| # | Instruction today | Where | Replaced by | Home |
| --- | --- | --- | --- | --- |
| 1 | Coders are subagents started with the `Agent` tool | `skills/coordinator` (Dispatching, team roles); `agents/coordinator.md`, `scofield.md` | `loh spawn <coder> <repo> <ticket>`: worktree in the ticket's repo, then an `hc` terminal running `claude --agent larceny:<coder>` with `--outlive-parent`, then the dispatch prompt | `loh spawn`; skill coordinator section |
| 2 | Reviewer dispatched with `subagent_type: larceny:reviewer` | `skills/coordinator` | A standing terminal named `amy`, started by `loh up` with `--no-parent` | `loh up`; skill |
| 3 | `SendMessage({to: "<name>"})` | `skills/coordinator`, `docs/agent-lifecycle.md`, `skills/bring-in-personas` | `loh say <to> <text>`, which sends to an idle or done agent and retries while it is busy (see the `loh` table) | `loh say`; skill |
| 4 | `ListAgents` to check who is running | `docs/agent-lifecycle.md`, `skills/bring-in-personas` | `hc ls --json`, filtered by the `crew` label | skill |
| 5 | Auto-spawn on first mention via `Agent` | `docs/agent-lifecycle.md` | The coordinator starts Yoda or Sara with a named `hc run --no-parent` | skill |
| 6 | Spawn commands start background agents | `commands/spawn-reviewer`, `spawn-advisor`, `spawn-teacher` | Same name resolution, but start a named `hc run --no-parent` terminal | skill |
| 7 | Coder messages the reviewer by id | `skills/coder`, Reviewer protocol | `loh say amy "<repo> PR #<n> ready: <summary>"`; Amy replies to the coder by name with `loh say` | `loh say`; skill |
| 8 | Coder escalates and reports back as a subagent return | `skills/coder` | `loh say scofield …` for escalation. The final report goes to the ticket and `.loh/status.md`, and the coder ends its turn | skill |
| 9 | `isolation: worktree` makes the harness create the worktree | `agents/<coder>.md` frontmatter | `loh spawn` creates the worktree before the session starts. The key is ignored standalone (hand run) | `loh spawn` |
| 10 | Waiting with a Monitor that only fires while its agent runs | larceny issue #153 | `hc wait --children any --timeout <s>`, held by herdr | skill |
| 11 | The coordinator reads one project: config and status from the current directory, one board | `agents/coordinator.md`, `commands/wake-up.md`, `skills/coordinator` | Read `.loh/workspace.md`; pick the repo per request and ask when unclear; load that repo's `.larceny/config.md`; keep `.loh/status.md` with a project column; one shared board or one per repo; follow the token files for identity even when config says `identities: later` | skill |

New behaviour larceny has no equivalent for:

- **`loh gh <persona> <args…>` and `loh git <persona> <args…>`** run `gh` or `git` as a persona. They read the token file and set `GH_TOKEN` and the four `GIT_*` identity variables themselves, so agents never write `$(cat token)`. The token is never printed. This keeps one allowlist entry, `Bash(loh *)`, enough in default mode.
- **`loh down [--all]`** ends the workspace's coder terminals. With `--all` it ends every terminal that carries the workspace's `crew` label: `scofield`, `amy`, Yoda and Sara when they are running, and `loh-watch`.
- Phase 2: status cards, the "with Matt" lock and notifications, described under the office view.

**How the override ships.** The `larceny-on-herdr` plugin depends on larceny, if the plugin format supports a dependency, and adds `loh` and `herdr-runtime`. Larceny's own agents run unchanged, so there are no wrapper agents. `loh` sends each agent a first prompt that tells it to load its larceny skills plus `larceny-on-herdr:herdr-runtime` with the Skill tool. The skill's frontmatter triggers when `HC_TERMINAL_ID` is set.

## The `loh` CLI

`loh` is a small bash CLI over `hc`. Phase 1 has only these commands. Phase 2 adds `loh card`, `lock`, `unlock`, `open`, `close`, `status` and `watch`. It uses `hc wait --children` and `hc ls` and `hc events --label` as they are, so there is no `loh wait` or `loh ls`.

| Command | What it does |
| --- | --- |
| `loh up` | Takes no argument: it finds the workspace from the current folder or from `LOH_WORKSPACE`. Starts `scofield` (`larceny:coordinator`) and `amy` (`larceny:reviewer`), each `--no-parent`, with `crew` and `role` labels. An agent that is already live is left alone. Before the first prompt it waits for `idle`, with a timeout. |
| `loh spawn <coder> <repo> <ticket>` | Described in the ticket path above. It refuses if a live terminal holds the name, and removes a finished one first. If the agent never reaches `idle`, it sends nothing and prints how to read the terminal. |
| `loh say <to> <text>` | Looks at the target with `hc get`, then sends. An `idle` target gets `hc send --if idle`. A `done` target gets a plain `hc send`, because agents sit in `done` between turns and `--if` accepts only `idle` or `working`. A `working` or `blocked` target is retried, 40 times and 15 seconds apart by default, then exit 3. Never `--force`, so it never answers another agent's dialog. Exit 4 when the target has a `with_matt=1` label, exit 11 when the terminal has finished. |
| `loh gh <persona> <args…>`, `loh git <persona> <args…>` | Run as a persona, as described above. A missing token file falls back to the ambient login. |
| `loh down [--all]` | Ends this workspace's coder terminals and nothing else. With `--all` it ends every terminal that carries this workspace's `crew` label, which includes Yoda, Sara and, from phase 2, `loh-watch`. Terminals without the label are never touched. |

## The office view

The office is a view over herdr's state and holds no state of its own except the "with Matt" label. It is a herdr-app mod, built in phase 3 and driven by `hc` data.

Mod facts from spike 2:

- A mod is `mods/<name>/main.js` plus `mod.json`, in `~/.config/herdr-app/`. It hot-reloads on save, and `herdr-app check <folder>` validates it.
- Click handlers, panels, native animation and absolute positioning are available. A shipped mod already focuses an agent on click.
- A mod reads agent status (`idle`, `working`, `blocked`, `done`), each terminal's folder and branch, and its labels. There is no role field, so roles come from `role=` labels.
- The API is versioned and its type file is rewritten at each start, so a herdr-app update can break the mod. The repaint is whole-window, so animations use `.frames()` and `.loop()`, not timers.
- A desk shows only for terminals with agent status.
- **Render deadline (found in phase 3, ticket #8).** herdr stops a mod's `render()` after about 50 ms. A render that spins for 50 ms passes `herdr-app check`, one that spins for 55 ms is "interrupted". `herdr-app check` shares the engine and the limit, so a copy of a mod that times its own `render()` and throws the time as its error message is the way to measure it. The limit is per host call, so three renders in one call add up. A render cut off keeps nothing: the window shows the last frame that worked, with a banner "This view could not be re-rendered; showing the last version that worked / interrupted", and the next render starts from scratch. A render that does the same heavy work every time is cut off every time. Measured costs in that engine: about 6 microseconds for each command when building a path (13 ms for one 2300-command path), and, each time a render describes a `paint_path` element with a path it already built, about 10 microseconds for the element plus about 1.4 for each command in its path (8070 commands in 315 paths took 11 ms, 13902 in 464 took 21 ms, 22744 in 647 took 33 ms, measured at 3840x2100). A plain `div()` costs 2 to 3. So heavy things (a floor of a thousand shapes) are built a few milliseconds at a time over several renders and cached, and, because describing them again costs as much on every render, they sit in a retained nested view of their own (`cx.new(Class)`): Per gpui-kit.d.ts (`View.render`), a view's `render()` runs when that view is invalidated (by `cx.notify()`, a reload or a theme change), not on every frame, so the floor is meant to be described once per plan and not once per render. This is the type file's statement and has not been observed: that a parent's render does not re-run a nested view when herdr's live data changes is unconfirmed, and so is how a cached floor looks for the frame after the panel closes or reopens. A check on 2026-11-13 found the live window not repainting (its frame did not change while an agent went working and back), so nothing could be counted. `herdr-app check` renders the top view only and never runs a nested view's render, so it does not time that one. Path coordinates also take percentages of the painted box, so a cached path does not depend on the scale.
- **Animation (found in phase 3, ticket #8).** `transition` animates a change only for an element that already had a transition in the render before. An element that gets its first transition in the same render as the change jumps. A transition's `delay` holds the element at its old value until it starts, so a walk round several corners can be handed over in one render as nested elements, each moving by one leg with a delay equal to the legs before it, with no timer. A walk is not redirected once handed over (ticket #16): the office holds a new place for 2.5 s before anyone sets off, and a walker who is on the way finishes first, so every route starts at a spot in a room and goes by the doors (checked over every pair of places and many start points along their paths: no leg crosses a wall).

Parts of the office:

- **Scene.** One desk per agent. State drives behaviour: working types, blocked raises a hand, done throws confetti, idle wanders to the kitchen or lounge.
- **Status card.** Agent, ticket, current step, PR and review round, for example *Mahone · api · #412 · writing tests · PR #88, round 2*. Each agent publishes its own with `hc label`, called from Claude Code hooks so it updates without the agent remembering to. The `kind` in `hc get` separates a permission prompt from other blocks.
- **Sidebar.** The card on top and the agent's live session below, by `herdr-app do terminal.keep --terminal <tN>`. Typing there is chatting with the agent. herdr-app resolves addresses (`t9`), not names, so the mod looks the address up.
- **Chat panel width and full terminal (ticket #10).** The divider between the floor and the chat panel is herdr's own `h_resizable` group. When a drag ends, the width is clamped (260 px up to half the office) and kept per crew in shared state. "Full terminal" opens an overlay window (`openOverlay` with a layout: a slim bar from this mod above the agent's `{ terminal }` block), as herdr documents for a window with a terminal. It changes no pane, so full-screen mode and its saved plan are untouched. Esc goes to the terminal in such a window, so the bar's Back button is the way out; the office moves the keyboard to the terminal when it opens the window. The docked chat and the window each hold the agent's with-Matt lock (counted in module state, so a restart starts clean, and run through one queue per agent), and the last one to go unlocks it.
- **"With Matt" lock.** Set when a sidebar opens and cleared when it closes, as a `with_matt=1` label. `loh say` checks it before any prompt. The agent writes anything you change directly to the ticket or PR.
- **Speech bubbles and activity feed.** Drawn from `hc events` and the `<hc from=…>` tag on messages. `loh` keeps no message log.
- **Notifications.** A desktop notification whenever an agent blocks. A top bar shows office-wide totals: working, blocked, done, idle.

herdr-app runs on Apple Silicon Macs and on Linux with Vulkan (x86-64 and ARM64). The test machine runs Ubuntu 26.04, x86-64, Wayland. The first machine ran WSL. Where herdr-app cannot run, the crew still works from the terminal and the office is unavailable. Windows is out of scope.

## Setup

There is no setup command, `doctor` or `install.sh`. A README checklist covers it.

1. **Prerequisites:** herdr-core and `hc` 0.1.20, herdr 0.9.5, larceny 0.1.4, `gh` logged in, and optionally persona token files under `~/.config/larceny/`. herdr-app 0.1.15 is needed for the office.
2. **Install the plugin** from this repo as a local marketplace.
3. **Write `.loh/workspace.md`** in the workspace root.
4. **Run `loh up`**, then open herdr-app, where `herdr-app do terminal.keep --terminal <tN>` shows a terminal. Talk to Scofield.

Rules:

- Start herdr-core from a normal terminal, never from an agent's shell.
- Decline herdr core updates until the new version is tested here. Install the version we tested, not the latest.
- The test machine install ran `herdr integration install claude` (integration v11), which wrote `~/.claude/hooks/herdr-agent-state.sh` and one `SessionStart` hook in `~/.claude/settings.json`. Whether `hc` reports Claude's state without it was not tested.
- For `pane_mode: default`, the README documents an optional allowlist for user-scope settings: `Bash(loh *)`, `Bash(hc send *)`, `Bash(hc ls*)`, `Bash(hc get*)` and `Bash(hc wait*)`, plus each repo's test command, for example `Bash(npm test)`. It does not go in a worktree's `settings.local.json`, because that triggers the trust dialog.
- The README says this is a community project, not affiliated with herdr or larceny.

## Repo layout

Phase 1 builds the first part. Folders marked with a later phase do not exist yet.

```
larceny-on-herdr/
  .claude-plugin/
    plugin.json                   # plugin larceny-on-herdr 0.1.0, depends on larceny if supported
    marketplace.json              # installable as a local marketplace
  bin/loh                         # bash dispatcher: loh <cmd> runs lib/loh/<cmd>.sh
  lib/loh/
    common.sh                     # die, need, hc_json, workspace_root, manifest parser
    up.sh  spawn.sh  down.sh
    say.sh  gh.sh  git.sh
    prompts/coder.md              # the dispatch prompt template
  skills/herdr-runtime/SKILL.md   # the eleven overrides, in one skill
  test/                           # bats tests; test/fakes/hc records argv and replays JSON
  .github/workflows/ci.yml        # shellcheck and bats on push to main and on PRs
  hooks/                          # phase 2: status-card hooks
  office/                         # phase 3: herdr-app mod
  README.md                       # quick start, permissions, troubleshooting
  LICENSE                         # MIT
  docs/PLAN.md                    # this plan
```

Tests run against a fake `hc`, so they never need a live herdr. Lint is `shellcheck bin/loh lib/loh/*.sh` and tests are `bats test/`.

## Phases

Phase 0 is done. Each later phase is usable on its own, and the office waits until the agents behind it work.

| Phase | Scope | Gate to move on |
| --- | --- | --- |
| 0 · Spikes | Done: findings in this plan | A hand-started coder took a ticket to a merged PR (met) |
| 1 · herdr dispatch, no office | Plugin skeleton and `loh` dispatcher; `loh up`, `spawn`, `down`; `loh say`, `gh`, `git`; the `herdr-runtime` skill; README quick start and permissions | Scofield, in an `hc` terminal, ships two parallel sandbox tickets through Amy with no subagents |
| 2 · Status cards and the lock | Status cards from Claude Code hooks with `hc label`; the "with Matt" label that `loh say` checks; a desktop notification when an agent blocks | You can see and steer any agent from the terminal |
| 3 · The office | The herdr-app mod over `hc` state: desks driven by agent state, click-to-sidebar, speech bubbles and the activity feed | One glance answers who needs me |
| 4 · Hardening | A check that flags upstream larceny changes to the overridden sections; reviewing the permission allowlist; the coder cap in code if the skill's number proves too soft | — |

Each gate is the test for moving on. No dates are set yet.

Cut from v1: `/setup`, `doctor` and `install.sh` (the README checklist replaces them), Windows work, the polling bridge that wakes a coder when a review lands on GitHub (Amy prompts the coder directly), and the coder cap as code.

## Risks and open questions

The four unknowns that phase 0 set out to answer are resolved. The risks that remain:

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| herdr reports `done` while a background command runs | Waits return early and the office shows confetti too soon | Coders run tests in the foreground; `done` means the turn ended, and GitHub says whether the ticket is finished |
| Startup dialogs report no status | A prompt typed into the trust dialog ends the session | `loh spawn` waits for `idle`, and on a timeout sends nothing; the allowlist lives in user scope |
| Every default-mode session asks permission prompts | Many raised hands for routine `git`, `gh` and test commands, and compound commands with inline tokens are always asked about | `loh gh` and `loh git` read tokens themselves; the optional allowlist names `loh`, read-only `hc` and each repo's test command; auto mode is the default `pane_mode`. |
| Core keeps its starting environment | Started from an agent's shell, it turns transcript saving off in every pane | Start core from a normal terminal; `hc server restart --fresh` fixes it |
| Scofield's context spans several repos | It fills faster and compacts more often | Keep all state in `.loh/status.md`, load one repo's details at a time, restart Scofield on a schedule |
| Scofield picks the wrong repo | Work lands in the wrong place | He asks when the instruction and context don't settle it; every ticket and card names its repo |
| Larceny's coordinator improvises a dispatch | It started coders as children without `--outlive-parent` and with the wrong permission mode | Override #1 is explicit, and `loh spawn` fixes both flags |
| You and Scofield prompt the same agent at once | Collisions and a stale plan | The "with Matt" label (phase 2), plus `loh say`, which waits while the target is busy and never forces a message in |
| A timed-out prompt may still have been delivered, and waits have no default timeout | Duplicate prompts or hangs | Always pass `--timeout`; read the terminal with `hc read <name>` before any retry |
| Terminal addresses change | Prompts go to the wrong place | Address agents by name only, never by terminal id |
| A finished terminal still holds its name | The next coder cannot start under that name | `loh spawn` removes a finished terminal before reusing the name, and refuses a live one |
| Standing agents' context grows | Amy gets slower and vaguer | Restart standing agents after a set number of reviews, as larceny already advises; coders stay fresh per ticket |
| Six to eight sessions on one machine | Plan limits, memory, CPU, and about 228k startup tokens per session on the first machine | A cap of 4 live coders, written in the skill; long-lived standing agents amortise the startup cost |
| herdr, herdr-app and larceny change fast | Breakage, stale overrides, a mod broken by an API change | Pin the tested herdr and larceny versions (herdr 0.9.5, `hc` 0.1.20, herdr-app 0.1.15, larceny 0.1.4 at dd27cf1); decline core updates; phase 4 adds a check on the overridden sections |
| Whether a label change alone redraws a mod is untested | Status cards might lag | Test it in phase 2 before phase 3 relies on it |
| Amy's approval comment has its attribution line first | A check that reads only the first line misses `APPROVED at <sha>` | Read the whole comment, and prefer the formal review |

Decisions for you:

- [ ] Board for v1: one shared GitHub Project across the workspace's repos, one per repo, or Linear (works, but undocumented, [#72](https://github.com/nestedmind/larceny/issues/72)).
- [ ] Whether to offer the dispatch switch upstream to larceny once phase 1 works.

Decided under Matt's autonomy grant on 2026-11-13 (Matt can reverse any of them): the crew runs under herdr-core through `hc`; no agent wrappers; `loh` has only the commands above; recovery by `crew` label; the `.loh/workspace.md` manifest with `pane_mode`, and the refusal of `bypassPermissions`; the optional allowlist in user scope; v1 cuts as listed under Phases; the phase 1 gate; the coder cap of 4.

## Rules for this repo

- This file is the source of truth, and it changes through a reviewed PR.
- Never fork or modify herdr or larceny.
- Record the larceny commit tested (dd27cf1) and the herdr versions.
- Always pass `--timeout` on herdr waits, and address agents by name.

## Sources

- [larceny repository](https://github.com/nestedmind/larceny), read at commit dd27cf1
- [larceny issue #153: per-PR reviewer and the Monitor problem](https://github.com/nestedmind/larceny/issues/153)
- [herdr repository](https://github.com/herdrdev/herdr)
- [herdr socket API](https://herdr.dev/docs/socket-api/)
- [herdr agent automation](https://herdr.dev/docs/preview/agent-automation/)
- [herdr full developer docs](https://herdr.dev/llms-full.txt)
- [Bitdoze: herdr app layouts and mods](https://www.bitdoze.com/herdr-app-layouts-mods/)
