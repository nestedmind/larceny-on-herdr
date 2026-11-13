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

## What it shows

- **The whole cast, always.** Scofield, Sucre, Mahone, Sheba, Whip, Amy, Maya, Opemipo, Yoda, Sara, Matt and the dog Waffles are drawn whether or not they have a terminal. A terminal is matched to a person by its name, or by its `role` label (`coordinator` is Scofield, `reviewer` Amy, `advisor` Yoda, `teacher` Sara). A running agent that matches nobody is drawn as an extra person.
- **Agents only.** Only agent terminals count. A terminal labelled `role=watch` (the `loh-watch` notifier) or one that runs another program (a shell, `loh`) is left out.
- **Floor plan.** The design prototype's, in its units (288 high, at least 480 wide). One repo room per repo in the workspace manifest, each with a pod of four desks, then the leads room (Scofield and Amy) and the meeting room; a corridor; then Matt's room, the kitchen, the lounge, ping pong and the rest room. The office gets the repo list from `loh status --repos`, run in an agent's folder (or the `dir` prop when none runs). A coder whose `task` names a repo that is not in the manifest still gets a room, after the others. A third repo widens the floor: the lounge takes the extra width. Fewer than two repos leaves bare wall at the end of the top row.
- **Where people stand.**
  - A coder that is `working` or `blocked` is at its desk in its task's repo room. `done` goes to the kitchen, `idle` with a task to ping pong (two of them rally), and a coder with no task or no terminal to the lounge. The desk stays the coder's while away, so the others do not move. A fifth coder in a room waits in the lounge.
  - Maya and Opemipo keep a home desk in the repo rooms while running (Maya the third desk of the second repo room, Opemipo the fourth of the first), and coders never take those desks.
  - Scofield and Amy sit at their desks while running; Yoda and Sara at the meeting table.
  - Anyone not running is in the lounge, then the kitchen and the rest room when it is full.
  - Matt is at his desk. Waffles sleeps on her bed, and walks to sit beside Matt while any agent is blocked and needs him.
- **People.** Seen from above: hair (long where the prototype has it), a face turned the way they look, Matt's headset, a ring in the state colour, hands on the keyboard while working, a raised hand and a bubble (`allow?`, `?` or `!`) when blocked, a tick when done, a coffee mug in the kitchen and lounge, paddles and a ball at ping pong. Someone with no terminal is drawn faded.
- **Walking.** When a person's place changes they walk door to door through the corridor (the prototype's paths, each person in a slightly different lane), at the prototype's speed, with swinging arms and a bob. Each leg is a native `left`/`top` transition; a one-shot timer ends each leg so the next starts and the gait stops (at most a handful per walk, never a repeating one). Typing, the ball, screens and the dog use `.loop()`. A change of scale or floor width (a resize, the chat opening, the repo list arriving) does not walk anyone.
- **Lights.** The floor palette is the prototype's. When the app is in dark mode the floor gets the prototype's night shading: dimmed, with each lit screen pooling light on its desk.
- **Screens.** A desk's monitor shows green for a working agent, a blinking amber, blue or pink for a blocked one (permission, question, other), and dim for an owner who is away.
- **Starting someone.** Clicking a name chip with "no pane" asks before it starts anything. For Scofield and Amy the bar offers `loh up`, with Start and Cancel. A coder needs `loh spawn <coder> <repo> <ticket>`, which the office cannot fill in, so it names the command. loh has no command for anyone else, and the bar says so. Clicking someone running keeps the chat behaviour below.
- **No dead space.** The floor is scaled to fit the pane (smaller than life when the pane is narrow), and centred while it fits.
- **Top bar.** Totals of working, blocked, done and idle agents, over the ten agents (one with no terminal counts as idle, as in the prototype).
- **Name tag.** Name, then `repo#ticket`, `PR <n>` and `r<round>`, then the step (or note). A "with Matt" pill shows when `with_matt=1`. Tags are stacked so they do not cover each other.

### What herdr-app cannot do

- No radial gradient (`Background` has solid, linear, slash and checkerboard only), so a screen's night glow is stacked translucent discs.
- No per-frame callback: the arm swing, bob, typing and ball are `.loop()` between two values, not the prototype's sine of the clock. A walker's facing changes at each leg, not smoothly.
- A stroke has no line-cap setting, so the arms' ends are square.
- No visibility event: motion stops when the tab is hidden because native loops and transitions stop when not drawn.

| Agent status | How it shows |
|---|---|
| `working` | Green ring, hands tapping the keyboard, a green monitor |
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

## Chat

Clicking a name tag opens a chat with that agent beside the office, in the same tab. The mod splits its own pane to the right (`pane.split`) and shows the agent's live terminal in the new pane (`terminal.show`), so you type straight to the agent and see what it does. It does not switch to the agent's own tab. Clicking another name swaps the terminal in the same split.

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
