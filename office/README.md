# Crew office

`crew-office/` is a herdr-app mod that draws one crew as people at desks, top-down. It reads only `hc` state (terminal labels and status). It keeps no state of its own beyond which chat is open, and animates with `.frames()`, `.loop()` and `.transition()`, never timers.

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
- **Kitchen.** A coder whose status is `done` walks to the kitchen for a coffee, and back to its desk when it is working again. Four spots; when they are full, a done coder stays at its desk. A coder in the kitchen keeps its desk reserved, so the others do not move.
- **Lounge.** Coders with no task, and anyone with a role the office does not know. Waffles the dog sleeps on her bed here (decoration, not an agent).
- **People.** Seen from above, with hair, a face turned the way they look (desks face their screens), and both hands on the keyboard while `working`. Each person and name tag slides to the new place when an agent's state or task changes (a native transition on `left`/`top`, no timer). A change of scale or floor width (a resize, the chat opening, the repo list arriving) does not slide anyone: only a change of place does.
- **Meeting room.** The advisor and the teacher sit at the table; the wall screen shows how many agents the crew has.
- **No dead space.** The floor is exactly as wide as its rooms and is scaled to fit the pane (smaller than life when the pane is narrow), and centred while it fits.
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

## Chat panel

Clicking a name tag opens a panel on the right of the office (360 px; the floor shrinks to fit the rest). It holds:

- **Card.** Role, state, ticket, PR and round, step, note, and the lock, as far as the labels say.
- **Terminal.** A button that shows the agent's real terminal (see "Terminal" below).
- **Activity.** The last six crew changes since the office opened: an agent starts working, finishes a turn, goes idle, needs you (with the kind), or sets an `escalation:` note. It is built from the same status and `note` label that `loh watch` follows, by comparing each render with the last; changes before the office opened are not shown.
- **Chat.** The conversation with that agent, newest at the bottom: your turns and the agent's text replies, read from its Claude Code session file by `loh transcript`. Tool calls, thinking, sub-agent turns and system reminders are left out. The log is read again when the agent's state, step, note or turn changes (herdr redraws the office then), so a reply appears when the agent finishes its turn; there is no timer.
- **Message box.** "Message <name>" and Send (or Enter). It runs `loh tell <name> <text>` in the agent's folder. The message shows greyed as "sending" until the session file has it. A blocked agent is waiting on a permission prompt or a question, and a typed line would answer it, so Send is off and the panel says so; use the terminal to answer. `loh tell` also refuses, so a state that changes between the click and the send is safe. It sends to an agent that is with Matt; `loh say` between agents still does not. Failures from loh (a finished terminal, a changed status) show under the log.

Esc, or Close, closes the panel while no terminal is docked.

The mod runs `loh` in the agent's folder (the `loh` prop names the command), as it does for the lock. It does not read the session file itself: `readTextFile` stops at 1 MiB (`herdr.d.ts` line 24) and a session file is often larger, so `loh transcript` reads it.

### Terminal

The Terminal button docks the agent's live terminal beside the office, in the same tab. The mod splits its own pane to the right (`pane.split`) and shows the agent's live terminal in the new pane (`terminal.show`), so you type straight to the agent and see what it does. It does not switch to the agent's own tab. The panel hides while the terminal is docked. Clicking another name swaps the terminal in the same split. Esc or "Close chat" closes the split and brings the panel back.

The click then runs `loh lock <name>` in that terminal's own folder (loh finds the workspace by walking up from there; herdr-app itself runs outside any workspace), using the terminal's real name. If the command exits non-zero, the office posts a warning notification with loh's message.

Closing releases the lock with `loh unlock <name>`. "Close chat" puts the split's own terminal back, closes the split only if that worked, and unlocks. If you close the split yourself, the office sees the pane is gone on its next render and unlocks then. Closing a split or tab never ends a terminal shown in it with `terminal.show`.

- **Full screen** (top bar) zooms the office pane (`pane.zoom`) so only the office shows. The button becomes "Show chat (Esc)", and Esc zooms back out while the office has the keyboard.
- When `loh` is not on herdr-app's PATH, the lock command fails and you get the warning, and the chat still opens.
- The office keeps the open chat (which agent, which pane) in memory only. After a reload it forgets it, and an agent still locked can be released with `loh close <name>`.
- A narrow office pane shrinks the floor (the scale can drop below 1) instead of cutting it off.

## Check

```sh
herdr-app check office/crew-office
```

`bats test/office.bats` runs this when `herdr-app` is on PATH and skips it otherwise. It also checks the placement logic in `crew.js` with node.
