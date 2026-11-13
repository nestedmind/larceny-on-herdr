# Crew office

`crew-office/` is a herdr-app mod that draws one crew as people at desks, top-down. It reads only `hc` state (terminal labels and status). It keeps no state of its own, and animates with `.frames()` and `.loop()`, never timers.

## Install

herdr-app reads mods from `~/.config/herdr-app/mods/`. Link or copy the folder there:

```sh
ln -s "$PWD/office/crew-office" ~/.config/herdr-app/mods/crew-office
herdr-app check ~/.config/herdr-app/mods/crew-office
```

A copy works too (`cp -r`), but a symlink picks up changes on save, because herdr-app hot-reloads a mod when its files change.

## Open it

As a pane beside your shell:

```sh
herdr-app do pane.split --direction right --mod crew-office
```

Or as its own tab: `herdr-app do tab.new --name office --mod crew-office`.

Props (optional, set as `props` on a layout block or on `pane.split` / `tab.new`):

| Prop | Meaning |
|---|---|
| `crew` | Workspace to show. Default: the `crew` label with the most live terminals |
| `loh` | Path of the `loh` command to run on click and to list repos. Default: `loh` on herdr-app's PATH |

## What it shows

- **Agents only.** Only agent terminals are drawn. A terminal labelled `role=watch` (the `loh-watch` notifier) or one that runs another program (a shell, `loh`) is left out.
- **Repo rooms.** One room per repo in the workspace manifest, with four desks each, even when no coder is working. The office gets the list from `loh status --repos`, run in an agent's folder, so the manifest is read in one place only. A coder whose `task` names a repo that is not in the manifest still gets a room, after the others. A fifth coder in a repo waits in the lounge. If `loh` fails, the rooms from coders' `task` labels still show.
- **Leads room.** The coordinator and the reviewer, at their own desks.
- **Meeting room.** The advisor and the teacher.
- **Lounge.** Coders with no task, and anyone with a role the office does not know.
- **No dead space.** The floor is exactly as wide as its rooms and is scaled to fit the pane, centred.
- **Top bar.** Totals of working, blocked, done and idle agents.
- **Name tag.** Name, then `repo#ticket`, `PR <n>` and `r<round>`, then the step (or note). A "with Matt" pill shows when `with_matt=1`.

| Agent status | How it shows |
|---|---|
| `working` | Green dots animate beside the person |
| `blocked` | A raised hand and a bubble: amber `allow?` for a permission prompt, blue `?` for a question, pink `!` for anything else |
| `done` | A green tick |
| `idle` | Plain, at the desk |

The floor colours follow the app's light or dark appearance. Everything else uses the theme.

## Labels it reads

Set by `loh`, the status-card hooks and the lock. The office shows what is there and leaves out what is not.

| Label | Used for |
|---|---|
| `crew` | Which workspace's terminals to show (required) |
| `role` | `coordinator`, `reviewer`, `advisor`, `teacher` or `coder` picks the room; `watch` hides the terminal |
| `task` | `<repo>#<n>`: the repo room and the ticket on the tag |
| `step`, `pr`, `round`, `note` | Lines on the name tag (cut to 60 characters) |
| `with_matt` | `1` shows "with Matt" and rings the person |

Status comes from the terminal itself (`idle`, `working`, `blocked`, `done`). For a blocked agent the kind (`permission` or `question`) is read from the terminal's report; if herdr-app does not expose it, the bubble shows `!`.

## Click

Clicking a name tag focuses that agent: `agent.focus` if the terminal already has a pane, otherwise `terminal.keep` to give it one. It then runs `loh lock <name>` in that terminal's own folder (loh finds the workspace by walking up from there; herdr-app itself runs outside any workspace), using the terminal's real name. If the command exits non-zero, the office posts a warning notification with loh's message.

Mods can run commands (`exec` in `herdr.d.ts`), so this works. Limits:

- When `loh` is not on herdr-app's PATH, the command fails, you get the warning, and the click has only focused.
- The mod cannot tell when you leave the agent's pane, so it never unlocks. Run `loh close <name>` (or `loh unlock <name>`) when you are done.

## Check

```sh
herdr-app check office/crew-office
```

`bats test/office.bats` runs this when `herdr-app` is on PATH and skips it otherwise. It also checks the placement logic in `crew.js` with node.
