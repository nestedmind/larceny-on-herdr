# larceny-on-herdr

larceny-on-herdr runs the [larceny](https://github.com/nestedmind/larceny) AI dev crew as separate Claude Code sessions in [herdr](https://github.com/herdrdev/herdr) terminals, instead of as subagents. One crew works across a workspace of several repos. A pixel-office view on top comes later.

It uses larceny's crew, process and skills, and changes only how agents start and talk to each other. Larceny decides, herdr executes, the office shows. Neither upstream is forked.

**Status:** phase 1 and the first parts of phases 2 and 3. The crew runs on herdr-core: Scofield dispatches tickets, coders work in their own worktrees, and Amy reviews. The "with Matt" lock and the crew office mod (see [office/README.md](office/README.md)) are in this repo. Status cards and desktop notifications are here too. See [docs/PLAN.md](docs/PLAN.md) for the plan, which is the source of truth.

## Quick start

1. **Prerequisites.**
   - herdr-core and its `hc` command. Tested: herdr 0.9.5, `hc` 0.1.20 and herdr-app 0.1.15. herdr-app is needed only for the office window.
   - larceny 0.1.4, which the plugin installs as a dependency. Tested at commit dd27cf1.
   - `gh`, logged in, plus `git`, `jq` and `bash`.
   - Optional: one token file per persona, `~/.config/larceny/gh-<persona>-token` (for example `gh-sucre-token`), so each agent acts under its own GitHub account. Without a token file, an agent uses your own login.
   - With persona tokens, run `gh auth setup-git` once, so that `git push` uses the token that `loh git` passes to it. It edits your git config, so `loh` does not do it for you.
2. **Start herdr-core from a normal terminal**, never from an agent's shell. Core keeps the environment it starts with. A core started inside Claude Code passes `CLAUDE_CODE_CHILD_SESSION` to every terminal, and Claude then turns transcript saving off. If that happened, run `hc server restart --fresh` from a terminal outside Claude and herdr.
3. **Decline herdr core updates** when herdr-app offers them, until the new version is tested here.
4. **Install the plugin** from this repo as a local marketplace (see below).
5. **Write `.loh/workspace.md`** in the workspace folder, the folder that holds your repos (see below). Each repo needs its own `.larceny/config.md`, which `/larceny:onboard` creates.
6. **Run `loh up`** from the workspace. It starts `scofield` and `amy`, and `loh-watch` when the `loh watch` command is present.
7. **Open herdr-app** and show a terminal in it. Find the terminal's address with `hc ls`, then run `herdr-app do terminal.keep --terminal <tN>`. Or run `hc attach scofield` in a terminal. To see the whole crew as people at desks, install the office mod, described in [office/README.md](office/README.md).
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
- Only `name`, `pane_mode`, `idle_minutes`, `repos` and `board` are allowed at the top level. `board` is accepted and ignored. Any other key is an error, so a typo such as `pane_mod:` cannot quietly fall back to the default.
- `pane_mode` is the Claude permission mode for crew terminals: `default`, `acceptEdits`, `auto`, `plan` or `dontAsk`. The default is `auto`. `bypassPermissions` is refused on purpose.
- `idle_minutes` (optional, a whole number above zero, default 3) is how long a person sits at their desk in the office after a turn ends before going to the lounge. `loh status --settings` prints it as JSON.
- Each repo needs `name`, `path` (relative to the workspace folder), `branch` (the default branch) and `github` (`owner/repo`).

## Commands

`loh` is a small bash CLI over `hc`. Run `loh help` for the list.

| Command | What it does |
| --- | --- |
| `loh up` | Takes no argument. Starts `scofield` and `amy`, unless they are already live, and `loh-watch` when `loh watch` is present. |
| `loh spawn <coder> <repo> <ticket> [--model M]` | Makes a worktree for the ticket and starts the coder in it. Scofield runs this. If it fails part way, it prints the commands that clean up the terminal, worktree and branch so the spawn can be retried. |
| `loh down [--all]` | Ends this workspace's coder terminals and nothing else. With `--all` it ends every terminal that carries this workspace's `crew` label: `scofield`, `amy`, Yoda and Sara when they are running, and `loh-watch`. Terminals without the label are never touched. If you run it inside one of those terminals, that terminal is ended last. |
| `loh say <to> <text...>` | Sends a message to an agent by name. `<to>` must be a plain lowercase name, and the text may start with `-`. An idle agent gets `hc send --if idle`, and a `done` agent gets a plain `hc send`. A busy agent is retried, up to 40 times and 15 seconds apart, then the exit code is 3. It never forces a message into a dialog. Exit 4 means the agent is with Matt, and exit 11 means its terminal has finished. |
| `loh tell <to> <text...>` | Matt's message to an agent, for the office chat panel. It looks once and sends once: `hc send --if idle` to an idle agent, `hc send --if working` to a working one, a plain `hc send` to a `done` one. It never uses `--force` and never retries. A blocked agent (a permission prompt or a question) is refused with exit 9, because a typed line would answer its dialog; any other status is exit 10, a finished terminal (including one that ends between the look and the send) is exit 11, and any other `hc send` failure is exit 12 (the message may still have gone out). Unlike `loh say`, it sends to an agent that is with Matt. |
| `loh transcript <name> [--last N]` | Prints the agent's chat from its Claude Code session file as a JSON array of `{role, text, ts}` (user turns and assistant text, oldest first, default 40 turns). Finds the session under `~/.claude/projects` (`LOH_CLAUDE_PROJECTS` overrides) from the terminal's folder, preferring the session of its `--agent`. Prints `[]` when there is none. |
| `loh gh <persona> <args...>`, `loh git <persona> <args...>` | Run `gh` or `git` as a persona. They read the token file themselves, so agents never put a token on a command line. |
| `loh card k=v...` | Sets the agent's own status card: `step`, `pr`, `round` or `note`. |
| `loh lock <name>`, `loh unlock <name>` | Set or remove the "with Matt" label. `loh say` refuses an agent that has it. |
| `loh open <name>`, `loh close <name>` | `open` locks the agent and shows it in herdr-app. `close` unlocks it. |
| `loh status [--json]` | One line per crew agent: role, task, state, step, PR, round, and whether it is with Matt. `loh status --repos` prints the manifest's repos as JSON, and `loh status --settings` its office settings (`{"idle_minutes":3}`). |
| `loh watch [crew]` | Sends a desktop notification when an agent blocks (`<Name> needs you`) or escalates through `loh card note=escalation:<text>`. `crew` defaults to the manifest `name`. It uses `notify-send` or `osascript`, and prints to stdout when neither is there. If `hc events` ends, it restarts after a growing delay. |

Environment variables: `LOH_WORKSPACE` (the workspace folder), `LOH_START_TIMEOUT` (seconds to wait for a new agent to be idle, default 60), `LOH_SAY_TRIES` and `LOH_SAY_DELAY` (the retry count and the seconds between tries for `loh say`), and `LARCENY_CONFIG_DIR` (where the persona token files are, default `~/.config/larceny`).

## The office

`office/crew-office` is a herdr-app mod that draws the crew as people at desks, from `hc` state. [office/README.md](office/README.md) has the details. In short:

```
ln -s "$PWD/office/crew-office" ~/.config/herdr-app/mods/crew-office
herdr-app check ~/.config/herdr-app/mods/crew-office
herdr-app do tab.new --name office --mod crew-office
```

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
