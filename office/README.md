# Crew office

`crew-office/` is a herdr-app mod that draws one crew as people at desks, top-down. It reads only `hc` state (terminal labels and status). It keeps no state of its own beyond which chat is open, and animates with `.loop()` and `.transition()`, with no repeating timer.

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
| `dir` | A folder inside the workspace, used to find it (repo list, `loh up`) when no agent is running |
| `idleMinutes` | Minutes a person sits at their desk after a turn ends before going to the lounge. Default: the workspace's `idle_minutes` (`loh status --settings`), else 3 |

## What it shows

- **The whole cast, always.** Scofield, Sucre, Mahone, Sheba, Whip, Amy, Maya, Opemipo, Yoda, Sara, Matt and the dog Waffles are drawn whether or not they have a terminal. A terminal is matched to a person by its name, or by its `role` label (`coordinator` is Scofield, `reviewer` Amy, `advisor` Yoda, `teacher` Sara). A running agent that matches nobody is drawn as an extra person.
- **Agents only.** Only agent terminals count. A terminal labelled `role=watch` (the `loh-watch` notifier) or one that runs another program (a shell, `loh`) is left out.
- **Floor plan.** The design prototype's, in its units (288 high, at least 480 wide). One repo room per repo in the workspace manifest, each with a pod of four desks, then the leads room (Scofield and Amy) and the meeting room; a corridor; then Matt's room, the kitchen, the lounge, ping pong and the rest room. The office gets the repo list from `loh status --repos`, run in an agent's folder (or the `dir` prop when none runs). A coder whose `task` names a repo that is not in the manifest still gets a room, after the others. The floor is measured in its own stage under the bar, so it takes all the room there. A third repo widens the floor, and the extra width is shared by the rooms of each row.
- **Where people stand** (ticket #26; the table is Matt's, 2026-11-13). Where someone stands follows what their session is doing, as the prototype's state machine does.

  | Situation | Where |
  |---|---|
  | A session that is open: working, done or blocked | At its own desk, facing it. A turn that ends does not send anyone anywhere. |
  | Idle for the idle time (3 minutes) with no ticket: Scofield, Amy, Yoda, Sara, a coder without a ticket | The lounge (the kitchen when it is full), with a mug. Work starting again sends them back to their desk. |
  | A coder with a ticket and no PR | At its desk, however long it is idle |
  | A coder with a PR and nothing in hand (waiting on its review) | The kitchen, with a mug; ping pong after about 15 s, or about 2 s when someone is alone at the table |
  | A coder whose PR is at round 5 or later (with Matt) | Ping pong |
  | Compacting (`ctx=compact`) or just cleared (`ctx=clear`) | The rest room, with `zz`. After a compaction, back at the desk. After a clear, the lounge once the rest is over (4 s) |
  | No session | The lounge, faded. Maya and Opemipo are at a home desk while they run |
  | Matt | At his desk while he is typing in herdr (see below); otherwise away in the lounge with a mug |

  - **Idle time.** Counted from the render that first sees a person not working or blocked, and a `done` that turns `idle` does not restart it. A person first seen idle counts from `status_ms` when herdr gives it (a mod's `terminals()` is the `hc ls` shape and may not), else from the first sight. The default is 3 minutes. Two settings change it: the `idleMinutes` prop (a number of minutes), and `idle_minutes:` in the workspace manifest, which the office reads from `loh status --settings`. The prop wins; a value that is not a positive number is ignored.
  - **Seats are kept.** Someone keeps their spot in a room, and their desk, while they stay in it; only a person who arrives or leaves moves. A person with no session is a stand-in and gives way to one who arrives. The rest room is for compacting and clearing only: a full kitchen or lounge never overflows into it.
  - **Desks.** In the coder's task's repo room, else a free desk in another room. A working or blocked coder with no free desk takes the desk of a coder who is not working or blocked.
  - **Time moves people.** herdr renders the office when something changes, and after a turn nothing does. Layout reports when time alone changes something next, and the office sets one `timer.after` for it (never a repeating timer).
  - **Matt typing.** The mod sees keys only in its own views, so Matt counts as typing for 20 s after a key in the office's message box (the prototype's away time), and while the keyboard is in a terminal he opened from the office (the docked chat or a full-terminal window: herdr's `focused()` is that agent's terminal). Keys typed in a terminal he opened some other way are invisible to a mod.
  - Waffles sleeps on her bed, and walks to sit beside Matt while any agent is blocked and needs him.
- **People.** Seen from above: hair (long where the prototype has it), a face turned the way they look, Matt's headset, a ring in the state colour, hands on the keyboard while working, a raised hand and a bubble (`allow?` or `?`) for a permission or question, the prototype's flag (pole and blinking pink pennant) for any other block, a coffee mug in the kitchen and lounge, `zz` in the rest room, paddles and a ball at ping pong. Someone with no terminal is drawn faded.
- **Walking.** When a person's place changes they walk door to door through the corridor (the prototype's paths, each person in a slightly different lane), at the prototype's speed, with swinging arms and a bob. The whole walk goes to the renderer in one render, as a chain of nested movers: each leg is a native `left`/`top` transition that starts, with a native delay, when the leg before it ends, so the renderer's own clock takes the walker round every corner and no timer has to land on time for them not to stop. The name tag is carried by a second chain with the same times, so it stays with the person. One-shot timers do only two small things: turn the walker to face the next leg, and end the gait just after the last one (never a repeating timer). A render for any other reason describes the same chain and leaves the walk alone. A new place has to hold for 2.5 seconds before anyone sets off for it, so a state that flips back within moments (an agent that answers a message in a few seconds) moves nobody. A walk that has begun is never redirected: the person finishes it, and the next walk starts from where they stopped, so every walk starts at a place in a room and goes by the doors. Typing, the ball, screens and the dog use `.loop()`. A change of scale or floor width (a resize, the chat opening, the repo list arriving) does not walk anyone. Click a figure (a small target over the body) and it does what its name tag does.
- **Keeping renders short.** herdr stops a script's render at about 50 ms. The floor is about a thousand shapes, so its paths are written as percentages of its box (they do not depend on the scale), neighbouring shapes of one colour that do not overlap share a path (up to 300 commands, so no path takes long to build), and the paths are built about 12 ms at a time over a few renders when the plan changes, the last finished floor staying on screen (stretched to the new box) meanwhile. The last four plans are kept, and the two most recent finished ones (the panel open and closed) are never pushed out, so opening and closing the panel again costs nothing. The night layers are built the same way, once per set of lit screens, and the last finished night stays until the new one is built. Describing the finished floor again costs about 10 microseconds a path plus 1.4 a command, which is 33 ms for the 22,744 commands of six repos at 3840x2100, so the floor is a retained nested view of its own (`Floor` in `main.js`): herdr runs its `render()` when the office asks for it, once when a plan has finished building, and not with each render of the office. The office's own render is then about 8 ms at 2, 4 and 6 repos. Its paths are percentages and the view fills the floor box, so a new scale needs no render of it. The click targets over the figures are drawn above the night layers.
- **Lights.** The floor palette is the prototype's. When the app is in dark mode the floor gets the prototype's night shading: dimmed, with each lit screen pooling light on its desk.
- **Screens.** A desk's monitor shows green for a working agent, a blinking amber, blue or pink for a blocked one (permission, question, other), and dim for an owner who is away.
- **Starting someone.** Clicking the name chip of someone with no terminal asks before it starts anything. Scofield and Amy: the bar offers `loh up` with Start and Cancel. A coder: a form with a repo from the manifest and a ticket number (digits; type them, Enter starts, Esc cancels) that runs `loh spawn <coder> <repo> <ticket>` on Start. loh has no command for anyone else, and the bar says so. Clicking someone running keeps the chat behaviour below. loh runs in the `dir` prop folder if set, else a running agent's folder, else a pane's folder in this tab. The Start prompt names the folder.
- **Fills the pane.** The floor follows the pane's aspect ratio instead of a fixed 5:3. It is never smaller than the prototype's 480 by 288 plan: extra width is shared across the rooms of each row, and extra height across the two rows and the corridor, in proportion to their height. People, desks and furniture keep their size and are never stretched. A room's furniture and the people at it stay together and grow away from the middle, and plants, shelves and counters keep to their wall. One scale is used on both axes, so at most a thin margin (8 px) is left, painted in the prototype's stage colour (`#d5dae3` light, `#0b0e14` dark), never the theme's canvas colour.
- **Top bar.** Totals of working, blocked, done and idle agents, over the ten agents (one with no terminal counts as idle, as in the prototype).
- **Name tag.** Name, then `repo#ticket`, `PR <n>` and `r<round>`, then the step (or note). A "with Matt" pill shows when `with_matt=1`. Tags at rest are stacked so they do not cover each other; a walker's tag moves with them.

### What herdr-app cannot do

- No radial gradient (`Background` has solid, linear, slash and checkerboard only), so a screen's night glow is stacked translucent discs.
- No per-frame callback and no stepped easing: the arm swing, bob, typing taps and ball are `.loop()` between two values (smooth, not the prototype's square wave). The screen cursor steps with `.frames()` as a text glyph. A walker's facing changes at each leg, not smoothly, and the arms' swing may start again at a turn, because the facing is drawn from script.
- A stroke has no line-cap setting, so the arms' ends are square.
- No visibility event: motion stops when the tab is hidden because native loops and transitions stop when not drawn.

| Agent status | How it shows |
|---|---|
| `working` | Green ring, hands tapping the keyboard, a green monitor |
| `blocked` | A ring and a blinking monitor. Permission or question: a raised hand and a bubble (amber `allow?`, blue `?`). Anything else: a flag with a blinking pink pennant |
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
| `ctx` | `compact` while the context compacts, `clear` after a clear: the person is in the rest room. The status-card hooks write it (PreCompact, and SessionStart for the sources `compact` and `clear`); the next turn removes it |

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

- **Full screen** (top bar, always there) shows only the office until Esc. It does three things, and Esc or the button (now "Exit full screen (Esc)") undoes exactly those:
  - `pane.zoom` on the office pane, so the chat split is hidden (only when another pane shares the tab, and only if the pane is not zoomed already);
  - `layout.hide` on herdr's chrome nodes `sidebar`, `tabs`, `panel` and `status`, but only those that `layout()` reports as visible. The ones it hid are remembered, so a bar you had hidden stays hidden. If the layout cannot be read, nothing is hidden;
  - the window's full screen (`toggle_fullscreen`), only if the window is not full screen already.
  Esc works while the office has the keyboard. Each undo step checks first that there is still something to undo, so a bar you brought back by hand is left alone.
- **Getting the chrome back.** Full screen saves its plan (which bars it hid, and the office pane that owns it) in herdr's shared state as `crew-office.fullscreen`. Closing or reloading the office, or quitting herdr, tries to undo it with `herdr-app do layout.show` and `pane.zoom` run through `exec`, and forgets the plan only if those succeeded. That is best effort: herdr gives `close` 250 ms, and a crash or a forced quit skips it. When it did not work, the saved plan stays, and the next office to start acts on it: it carries on with it if it is the same pane (a reload, or the only office pane open), re-shows the bars if the owner pane is gone, and leaves it alone if another office pane is still open. Pressing Full screen never writes over a saved plan. Recovery re-shows the bars that full-screen mode hid and takes the window out of full screen only if full-screen mode turned it on. After a failed restore it can therefore override what you did in the meantime, for example show a bar you hid again on purpose. If the bars are missing, press Ctrl+Shift+B for the sidebar and Ctrl+Shift+L to switch layouts (or `herdr-app do layout.show --id sidebar`, and likewise `tabs`, `panel` and `status`). F11 leaves window full screen if the window manager provides it.
- When `loh` is not on herdr-app's PATH, the lock command fails and you get the warning, and the chat still opens.
- The office keeps the open chat (which agent, which pane) in memory only. After a reload it forgets it, and an agent still locked can be released with `loh close <name>`.
- A narrow office pane shrinks the floor (the scale can drop below 1) instead of cutting it off.

## Check

```sh
herdr-app check office/crew-office
```

`bats test/office.bats` runs this when `herdr-app` is on PATH and skips it otherwise. It also checks the placement logic in `crew.js` with node.
