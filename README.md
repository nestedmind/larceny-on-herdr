# larceny-on-herdr

larceny-on-herdr runs the [larceny](https://github.com/nestedmind/larceny) AI dev crew as separate Claude Code sessions in [herdr](https://github.com/herdrdev/herdr) terminals, instead of as subagents. One crew works across a workspace of several repos. A pixel-office view on top comes later.

It uses larceny's crew, process and skills, and changes only how agents start and talk to each other. Larceny decides, herdr executes, the office shows. Neither upstream is forked.

**Status:** phase 1 and the first parts of phases 2 and 3. The crew runs on herdr-core: Scofield dispatches tickets, coders work in their own worktrees, and Amy reviews. The "with Matt" lock and the crew office mod (see [office/README.md](office/README.md)) are in this repo. Status cards and desktop notifications are here too. See [docs/PLAN.md](docs/PLAN.md) for the plan, which is the source of truth.

## Quick start

On a new machine, one command does the setup below (steps 1 and 4, the `PATH` line and the office mod link) and is safe to run again:

```
git clone https://github.com/nestedmind/larceny-on-herdr ~/llm-ws/larceny-on-herdr && ~/llm-ws/larceny-on-herdr/install.sh
```

`install.sh` checks for `hc`, `herdr-app`, `gh`, `git`, `jq` and `claude`, and compares `hc` and herdr-app with the tested versions. A different version is a warning, never a change. For each missing tool it shows the install command and runs it only after you answer yes. herdr-core and `hc` install pinned to the tested version, with `curl -fsSL https://releases.herdr.dev/core/install.sh | HC_VERSION=0.1.20 sh`. herdr-app's installer has no version option, so `install.sh` says it installs the latest herdr-app and that 0.1.16 is the tested one, before it asks. It installs with `curl -fsSL https://releases.herdr.dev/app/install.sh | sh` (macOS on Apple silicon, Linux x86-64 and ARM64). `git`, `jq` and `gh` use `brew` on macOS, or `apt-get`, `dnf` or `pacman` on Linux; with none of those it prints the step and carries on. It runs `gh auth login` when you are not logged in, adds this repo as a marketplace and installs the plugin with `claude plugin` (or prints the two slash commands if that needs a prompt), adds the `PATH` line to `~/.zshrc` or `~/.bashrc` once, and links `office/crew-office` into `~/.config/herdr-app/mods` when that path is free. It never writes token files, runs `gh auth setup-git`, or changes `~/.claude` settings itself. When it finishes it lists what it did, what was already in place and what it skipped.

The manual steps follow. Steps 2 and 3 below are still yours, and `install.sh` repeats them as reminders.

1. **Prerequisites.**
   - herdr-core and its `hc` command. Tested: herdr 0.9.5, `hc` 0.1.20 and herdr-app 0.1.16. herdr-app is needed only for the office window.
   - larceny 0.1.5, which the plugin installs as a dependency. Tested at commit 03a9bfc.
   - `gh`, logged in, plus `git`, `jq` and `bash`.
   - Optional: one token file per persona, `~/.config/larceny/gh-<persona>-token` (for example `gh-sucre-token`), so each agent acts under its own GitHub account. Without a token file, an agent uses your own login.
   - With persona tokens, run `gh auth setup-git` once, so that `git push` uses the token that `loh git` passes to it. It edits your git config, so `loh` does not do it for you.
2. **Start herdr-core from a normal terminal**, never from an agent's shell. Core keeps the environment it starts with. A core started inside Claude Code passes `CLAUDE_CODE_CHILD_SESSION` to every terminal, and Claude then turns transcript saving off. If that happened, run `hc server restart --fresh` from a terminal outside Claude and herdr.
3. **Decline herdr core updates** when herdr-app offers them, until the new version is tested here.
4. **Install the plugin** from this repo as a local marketplace (see below).
5. **Run `loh init`** from inside a repo. It makes the workspace (a sibling folder `<repo>-crew` with `.loh/workspace.md`), starts `scofield` and `amy` with `loh up`, and opens the office tab when herdr-app is running. Each repo needs its own `.larceny/config.md`, which `/larceny:onboard` creates: `loh init` never runs it for you. To start a brand-new project, run `loh init --new <owner>/<name>`. To add a project to a running crew, run `loh init <repo-path> --workspace <workspace-dir>`. Both are safe to run again. The manual steps follow, and `loh init` does them for you:
6. **Write `.loh/workspace.md`** in the workspace folder, the folder that holds your repos (see below).
7. **Run `loh up`** from the workspace. It starts `scofield` and `amy`, and `loh-watch` when the `loh watch` command is present. Then **open herdr-app** and show a terminal in it. Find the terminal's address with `hc ls`, then run `herdr-app do terminal.keep --terminal <tN>`. Or run `hc attach scofield` in a terminal. To see the whole crew as people at desks, install the office mod, described in [office/README.md](office/README.md).
8. **Talk to Scofield.** Describe the work. He picks the repo, writes tickets, and starts coders with `loh spawn`.

## How a ticket moves

1. Scofield picks the repo, writes the ticket, and you approve it. He runs `loh spawn <coder> <repo> <ticket>`.
2. The coder reads the ticket from GitHub, works in its own worktree, runs tests in the foreground, and opens a PR with `loh gh <coder> pr create`.
3. The coder runs `loh say amy "PR #<n> ready for review: …"` and ends its turn. Amy reviews on GitHub and answers the coder by name. Her reply arrives as a new turn.
4. If a finding is still open after round 2, the coder ends its turn with the escalation as its final message, and Scofield, who is waiting on the coder, reads it.
5. After Amy approves the current head, the coder merges with `loh gh <coder> pr merge <n> --squash --delete-branch`, removes its worktree and local branch, and ends its turn with the PR number and head SHA.

## Install and PATH

Add the repo as a local marketplace and install the plugin:

```
/plugin marketplace add <path-to-this-repo>
/plugin install larceny-on-herdr@larceny-on-herdr
```

The plugin declares `larceny` (from the `larceny` marketplace) as a dependency, and the marketplace allows that cross-marketplace install.

Claude Code puts a plugin's `bin/` on the Bash tool's `PATH` while the plugin is enabled, so agents can run `loh` directly. Your own shell and herdr terminals do not get that, so put it on `PATH` by hand:

```
export PATH="<path-to-this-repo>/bin:$PATH"
```

## The workspace manifest

`.loh/workspace.md` lists the workspace's repos. `loh` finds it by walking up from the current folder. Set `LOH_WORKSPACE` to a folder to override that.

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

- `name` is required. Every crew terminal gets the label `crew=<name>`.
- Only `name`, `pane_mode`, `scofield_args`, `amy_args`, `idle_minutes`, `repos` and `board` are allowed at the top level. `board` is accepted and ignored. Any other key is an error, so a typo such as `pane_mod:` cannot quietly fall back to the default.
- `pane_mode` is the Claude permission mode for crew terminals: `default`, `acceptEdits`, `auto`, `plan` or `dontAsk`. The default is `auto`. `bypassPermissions` is refused on purpose.
- `scofield_args` and `amy_args` (optional) add arguments to that standing agent's `claude` command. `loh up` puts them after the fixed arguments (`--agent` and `--permission-mode`). The value is split on whitespace and never evaluated by a shell, so quotes, `$(...)` and `*` are plain text. A value that must hold a space cannot be written. An empty value is the same as no key. `loh` refuses a value that holds `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, `--permission-mode`, `--agent`, `--settings`, `--allowedTools`, `--allowed-tools`, `--permission-prompt-tool`, `--mcp-config` or `--add-dir` (also in the `--flag=value` form), so the arguments cannot undo `pane_mode`, change the agent or widen what it may do. The list is not a complete sandbox: other `claude` flags still pass, so write only arguments you trust. Without them, `loh up` starts both agents as before. To reach Scofield from Discord:

  ```
  scofield_args: --channels plugin:discord@claude-plugins-official
  ```

  Only one session should hold a given Discord bot's channel at a time: if a second one starts with the same bot, the two compete for its messages. Start the flag on one agent only, and stop that session before starting another.
- `idle_minutes` (optional, a whole number above zero, default 3) is how long a person sits at their desk in the office after a turn ends before going to the lounge. `loh status --settings` prints it as JSON.
- Each repo needs `name`, `path` (relative to the workspace folder), `branch` (the default branch) and `github` (`owner/repo`).

The workspace folder also holds what `loh` writes as it runs. `.loh/transcripts/` keeps the chats of coders that were released: one folder per coder and ticket, named `<coder>-<repo>-<ticket>` (with `-2`, `-3` and so on when a name is taken), each a whole copy of that coder's Claude Code session folder. Claude Code keeps these under `~/.claude/projects`, one folder per worktree, and `loh release` moves a finished coder's out of there so that folder does not fill up. Read one back with `loh transcript --archived <folder name>`.

## Commands

`loh` is a small bash CLI over `hc`. Run `loh help` for the list.

| Command | What it does |
| --- | --- |
| `loh init [<repo-path>...] [--workspace <dir>]` | Sets up or extends a workspace in one command. With no repo path the repo is the git top level of the current folder. Without `--workspace` it makes a sibling folder `<repo>-crew` next to the first repo, with `name: <repo>` and `pane_mode: auto` (an existing `<repo>-crew` is extended, so a second run finds the same workspace). With `--workspace <dir>` it adds repos to that workspace's manifest (a folder with no manifest gets a new one). Each entry is filled in from git and `gh`: `name` is the folder name, `path` is absolute, `github` is `owner/repo` from the `origin` remote (a repo with no GitHub origin is refused), and `branch` is the default branch `gh repo view` reports, else `origin/HEAD`. A repo already listed (same path or same GitHub repo) is left alone; a new repo whose name is already listed is refused. The rest of an existing manifest, comments and other keys included, is kept. The new manifest is written to a temporary file, checked with the parser every command uses, and only then moved into place. It then runs `loh up`. If the coordinator was already live and repos were added, it sends him a `loh say --queue` naming them and those with no `.larceny/config.md` yet. It opens the office tab (`herdr-app do tab.new --name office --mod crew-office`) when herdr-app is running and no office is open for the workspace; otherwise it prints that command. With nothing new it says so and changes nothing. It never runs `/larceny:onboard`, changes git config or `~/.claude`, or installs anything. It takes local repos and does not clone. `loh init --new <owner>/<name> [--workspace <dir>]` starts from nothing: it makes the folder `<name>` in the current folder, runs `git init` on `main`, commits a one-line `README.md`, creates the private GitHub repo with `gh repo create --private --source . --push`, and then carries on as `loh init <that folder>`. The commit and push use your own git identity and `gh` login, not a persona's. It refuses before doing anything if the folder exists or the repo is already on GitHub, and cannot be combined with repo paths. If a step fails after the folder exists, it says what was done and what was not, and leaves the folder alone. |
| `loh up` | Takes no argument. Starts the coordinator and the reviewer, named by the crew config (`scofield` and `amy` when it names none), unless they are already live, and `loh-watch` when `loh watch` is present. A name that cannot be a terminal name (letters, digits, `.`, `_`, `-`) is refused. |
| `loh crew [--json]` | Prints the crew's names, resolved as larceny's `docs/crew-resolution.md` says: each repo's `.larceny/config.md` (the first repo that sets a key wins), then the global `global-config.md` for a repo that says `crew: global`, then the shipped names. Both files are read fresh on every call. `--json` prints `coordinator`, `reviewer`, `advisor`, `teacher`, `coders` (the roster in order, without the coordinator, which is the first name of a custom `coders:`) and `person` (the owner, empty when `person:` is set nowhere). `loh up` and the office take their names from here. |
| `loh start <yoda\|sara\|maya\|opemipo>` | Starts that persona in the workspace folder unless it is already live (`yoda` and `sara` are the advisor and teacher seats: the terminal takes the name the crew config gives them, see `loh crew`, and runs larceny's `larceny:advisor` or `larceny:teacher`): a named `hc` terminal, `--no-parent`, labels `crew=<workspace>` and `role=advisor`, `teacher`, `designer` or `researcher`, the manifest's `pane_mode`, and the model that `models:` names for the persona in the repos' `.larceny/config.md` (or the global file when a repo says `crew: global`), if any. The office's Start bar runs it. |
| `loh spawn <coder> <repo> <ticket> [--model M] [--brief <text> \| --brief-file <path>]` | Makes a worktree for the ticket and starts the coder in it. Scofield runs this. `--brief` (or `--brief-file` for long text) puts the dispatch's extra context, such as a hold for the owner's go, in the coder's first prompt. Use one or neither; an empty brief or a missing file is a usage error. If it fails part way, it prints the commands that clean up the terminal, worktree and branch so the spawn can be retried. |
| `loh release <coder> [--force]` | Ends the coder (`hc kill`), waits until `hc get` shows it finished, archives its transcript into the crew folder, then removes the terminal (`hc rm`). The coordinator runs it after a merge is checked. It refuses a name that is not a coder of this workspace (`role=coder`, `crew=<name>`), and a coder that is working or blocked unless `--force` is given. It finds the session folder as `loh transcript` does (the terminal's folder from `hc get`; `LOH_CLAUDE_PROJECTS` overrides the projects folder) and copies it whole to `<workspace>/.loh/transcripts/<coder>-<repo>-<ticket>/`, taking repo and ticket from the coder's `task` label (`-2`, `-3` when the name is taken). The source folder is removed only after the copy has the same files and sizes, and only when the coder's folder was inside `<workspace>/.worktrees/`, so the folders of the coordinator, the reviewer and the main repo are never touched. The coder is ended and awaited first because Claude Code writes a last few KB to the session file as it shuts down; the wait is `LOH_KILL_WAIT` seconds (default 20), after which it archives what is written and says so. If the copy fails, the source is left, the terminal is still removed, and it exits non-zero saying where the transcript is. It prints where the transcript went. |
| `loh down [--all]` | Ends this workspace's coder terminals and nothing else. Each coder's transcript is archived the same way as `loh release` does, after the coder has ended and finished; if an archive fails, the coder is still ended, the source folder is left and `loh down` exits 1. With `--all` it ends every terminal that carries this workspace's `crew` label: `scofield`, `amy`, Yoda and Sara when they are running, and `loh-watch`. Terminals without the label are never touched. If you run it inside one of those terminals, that terminal is ended last. |
| `loh say <to> <text...>` | Sends a message to an agent by name. `<to>` must be a plain lowercase name, and the text may start with `-`. An idle agent gets `hc send --if idle`, and a `done` agent gets a plain `hc send`. A busy agent is retried, up to 40 times and 15 seconds apart, then the exit code is 3; `LOH_SAY_TRIES=0` removes the cap. `loh say --queue <to> <text...>` returns 0 at once and leaves a detached worker that waits with no cap and delivers when the agent is idle. If it finally cannot (the agent finished, is with Matt, or `hc` failed), it sets the sender's card note to `undelivered:<to>: <why>` and `loh watch` announces it. It never forces a message into a dialog. Exit 4 means the agent is with Matt, and exit 11 means its terminal has finished. |
| `loh tell <to> <text...>` | Matt's message to an agent, for the office chat panel. It looks once and sends once: `hc send --if idle` to an idle agent, `hc send --if working` to a working one, a plain `hc send` to a `done` one. It never uses `--force` and never retries. A blocked agent (a permission prompt or a question) is refused with exit 9, because a typed line would answer its dialog; any other status is exit 10, a finished terminal (including one that ends between the look and the send) is exit 11, and any other `hc send` failure is exit 12 (the message may still have gone out). Unlike `loh say`, it sends to an agent that is with Matt. |
| `loh react <emoji>` | An agent reacts to the owner's newest message in its own session (not the launch prompt), including one that came in through Discord. The emoji is one of 👍 ✅ ❌ 👀 ❤️ 😂; anything else is refused with exit 2. It starts no turn and sends nothing: it adds `{id, emoji}` to `<workspace>/.loh/reactions/<agent>.agent.json`, and the office draws it under the message. The same emoji twice changes nothing. Needs a herdr terminal (`HC_TERMINAL_ID`). `loh react --dir` prints the reactions folder. |
| `loh transcript [--archived] <name> [--last N]` | With `--archived`, `<name>` is a folder under `<workspace>/.loh/transcripts/` (see `loh release`): it reads the newest session file in it and asks no terminal; a missing archive is an error. Otherwise it prints the agent's chat from its Claude Code session file as a JSON array of `{role, text, ts, id}` (`id` is the session line's uuid, empty when it has none; user turns and assistant text, oldest first, default 40 turns). Finds the session under `~/.claude/projects` (`LOH_CLAUDE_PROJECTS` overrides) from the terminal's folder, preferring the session of its `--agent`. Prints `[]` when there is none. |
| `loh photos thumbs <folder>` | Makes the small copies of the people's photos that the office chat panel draws (herdr draws a big picture shrunk without smoothing, so it comes out grainy). For each picture in the folder it writes `.thumbs/<name>.<crop>.png`: 128 px square, the `<name>.crop` sidecar's crop (or the default centred square) already applied, `<crop>` being the sidecar's three numbers joined with `-` or `default`. A thumb is made again when its picture is newer, and a changed crop replaces the old thumb. It uses `magick` (ImageMagick), else python3 with PIL; with neither it says so, exits 0 and writes nothing, and the office draws the full pictures. Prints `made <name>` for each thumb. The office runs it itself. |
| `loh gh <persona> <args...>`, `loh git <persona> <args...>` | Run `gh` or `git` as a persona. They read the token file themselves, so agents never put a token on a command line. |
| `loh card k=v...` | Sets the agent's own status card: `step`, `pr`, `round` or `note`. |
| `loh lock <name>`, `loh unlock <name>` | Set or remove the "with Matt" label. `loh say` refuses an agent that has it. |
| `loh open <name>`, `loh close <name>` | `open` locks the agent and shows it in herdr-app. `close` unlocks it. |
| `loh status [--json]` | One line per crew agent: role, task, state, step, PR, round, and whether it is with Matt. `loh status --repos` prints the manifest's repos as JSON, and `loh status --settings` its office settings (`{"idle_minutes":3}`). |
| `loh wake [--timeout S]` | For the coordinator, started in the background. It exits, which gives the coordinator a new turn, as soon as a coder's turn ends, blocks, ends its terminal or changes its note, an `undelivered:` note appears on the coordinator's own card, a review lands, or a workspace repo's PR is opened, closed or merged, or changes its head or mergeability. It prints one line per change, for example `review repo=api number=12 by=amy state=APPROVED head=abc1234`, and exits 0. With nothing to report it prints `timeout after <S>s` at the timeout (default 900), and the coordinator starts it again. It keeps what it last looked at in `.loh/wake-state.json`, so a change made between one exit and the next start is reported by the next run; the first run reports nothing. It follows `hc events` for the crew and polls `gh pr list` per repo every `LOH_WAKE_POLL` seconds (default 30). |
| `loh watch [crew]` | Sends a desktop notification, unless an office tab is open (then the office shows a toast instead), when an agent blocks (`<Name> needs you`) or escalates through `loh card note=escalation:<text>`. `crew` defaults to the manifest `name`. It uses `notify-send` or `osascript`, and prints to stdout when neither is there. If `hc events` ends, it restarts after a growing delay. |
| `loh office [--close]` | Opens the crew's office tab (`herdr-app do tab.new --name office --mod crew-office`, with props `{crew, dir, loh}`) and saves the new tab's id in `<workspace>/.loh/office-tab`. Run it anywhere inside the workspace. You do not need it after pulling office changes: herdr-app 0.1.16 reloads an open mod tab in place when its files change. Use it to open the office, to give it new props (a reload keeps the old ones), and when no tab is open or the saved id is stale. When an id is saved, it opens the new tab first, then closes the old one by that id, whether or not the office is sending its heartbeat (a hidden office tab sends none); a close that fails means the tab is gone already and is only a note. When no id is saved but the heartbeat is fresh (an office opened by hand), it opens a new tab and says to close the old one by hand. `--close` closes the saved tab and clears the file. When herdr-app is not running it says so and prints the command. |
| `loh office lights [on\|off]` | Switches the office lights from a terminal, as the "Lights off" button and the L key do. `on` or `off` is written, with a stamp, to `<workspace>/.loh/office-lights`; the open office picks it up from `loh office-ping` within about 5 s. The last choice wins, from here or from the button, and the office keeps it over a reload and a herdr-app restart. With no argument it prints `on` or `off`: what an open office last reported through its ping (the button and L count), else the last choice made here, else `on`; any other argument prints usage and exits 2. It needs neither herdr-app nor a running office. |
| `loh office-ping` | Takes no argument. Writes the time to `<workspace>/.loh/office-open`. The office runs it every 5 seconds while it is open; `loh watch` sends no desktop notification while that time is under 15 seconds old (`LOH_OFFICE_FRESH` changes the 15), and sends them as before when it is older, missing or not a time. |

Environment variables: `LOH_WORKSPACE` (the workspace folder), `LOH_START_TIMEOUT` (seconds to wait for a new agent to be idle, default 60), `LOH_SAY_TRIES` and `LOH_SAY_DELAY` (the retry count, 0 for no cap, and the seconds between tries for `loh say`), and `LARCENY_CONFIG_DIR` (where the persona token files are, default `~/.config/larceny`).

## The office

`office/crew-office` is a herdr-app mod that draws the crew as people at desks, from `hc` state. [office/README.md](office/README.md) has the details. In short:

```
ln -s "$PWD/office/crew-office" ~/.config/herdr-app/mods/crew-office
herdr-app check ~/.config/herdr-app/mods/crew-office
herdr-app do tab.new --name office --mod crew-office
```

After pulling office changes, the open office reloads by itself (herdr-app 0.1.16) and everyone walks back to their starting places. Run `loh office` from inside the workspace only to open the office, to give it new props, when no tab is open, or when the saved tab id is stale: it opens the office in a new tab and closes the old one.

## Permissions

With `pane_mode: auto`, the default, no allowlist is needed. With `pane_mode: default`, Claude asks before each command. This optional allowlist covers the routine ones. Add it to your user settings, `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(loh *)",
      "Bash(hc send *)",
      "Bash(hc ls*)",
      "Bash(hc get*)",
      "Bash(hc wait*)"
    ]
  }
}
```

Add each repo's test command too, for example `Bash(npm test)`. Do not put these rules in a worktree's `.claude/settings.local.json`. A worktree with permissions in that file makes Claude show the "trust this folder" dialog. herdr reports no status for that dialog, and a prompt sent into it ends the session.

## Troubleshooting

- **An agent is stuck at a dialog.** Read its screen with `hc read <name>`. `loh spawn` waits for the new agent to be idle before it sends the first prompt, and prints this advice when the agent never gets there. Answer the dialog in herdr-app, or with `hc attach <name>`.
- **herdr says `done` while work is still running.** When Claude moves a long command to the background, the turn ends and herdr reports `done` while the command runs. `done` means the turn ended, not that the ticket is finished. The crew runs tests in the foreground, and GitHub says whether a ticket is finished.
- **`loh spawn` failed part way.** It prints the exact `hc kill`, `hc rm`, `git worktree remove` and `git branch -D` commands to clear what it made. Run them, then spawn again.
- **The coordinator restarted.** Coders keep running, because `loh spawn` starts them to outlive their parent. A new Scofield finds the crew with `hc ls --label crew=<name> --json`. You can also run `loh status`.
- **No transcripts are saved.** Core was started from an agent's shell. See step 2 of the quick start.

## Not affiliated with herdr

This is a community project. It is not affiliated with, endorsed by or supported by the herdr project or its authors.

## License

MIT. See [LICENSE](LICENSE).
