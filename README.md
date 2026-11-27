# CC:Tweaked Task Hub

A hub computer that keeps everyone's tasks and shows them on a monitor. Each monitor
block column is one person: their current task at the top, the queue below it.

```
+---------------+---------------+
|     Alex      |     Sam       |
| Now:          | Now:          |
| Fix the       | Build wheat   |
| reactor       | farm          |
|               |               |
| Next:         | Next:         |
| 2 Sort chests | 2 Mine iron   |
| 3 Craft pipes |               |
+---------------+---------------+
```

## Files

| File           | Goes on                         | Purpose                                         |
|----------------|---------------------------------|-------------------------------------------------|
| `hub.lua`      | The hub computer                | Stores tasks, draws the monitor, serves clients |
| `display.lua`  | Each display node               | Mirrors the hub's board on its own monitor      |
| `taskview.lua` | Hub and every display node      | Shared monitor drawing code (required by both)  |
| `tasks.lua`    | Any computer / pocket computer  | Remote control of the hub over rednet           |
| `pager.lua`    | Hub, display nodes and clients  | Wraps and pages long replies to fit the screen  |
| `taskgui.lua`  | Hub, display nodes and clients  | Clickable task UI for advanced/pocket computers |
| `update.lua`   | Optional, on any of the above   | Pulls the latest files from a git repository    |

## Setup

1. Place an **Advanced Computer** and attach an **Advanced Monitor** at least
   1 wide and 2 tall (touching the computer or via wired modems).
2. Attach a **Wireless** or **Ender Modem** to the hub if people should manage
   tasks remotely or you want display nodes.
3. Copy `hub.lua`, `taskview.lua`, `pager.lua` and `taskgui.lua` into the same folder on the hub. Either paste
   them with `edit`, or drop the files into
   `saves/<world>/computercraft/computer/<id>/`.
4. To start it on boot, create `startup.lua` on the hub containing
   `shell.run("hub")`.
5. Copy `tasks.lua`, `pager.lua` and `taskgui.lua` onto each player's computer or
   wireless pocket computer (or use `update client`, see below).

### Clickable UI

Running `tasks` with no arguments on an **advanced** computer or **advanced pocket
computer** opens a clickable UI. Basic computers have no mouse, so they get the text
prompt instead. `tasks cli` forces the prompt and `tasks gui` forces the UI.

The hub and display nodes show the same UI on their own terminal (the computer's
screen, not the monitor) when they're advanced computers:

- **Hub:** the UI edits tasks directly. `x` drops to the `hub>` prompt instead of
  stopping the hub, and typing `gui` there opens the UI again. The main screen has
  an extra **Update all** row above the other buttons that runs `pushupdate` after a
  Yes/No check. Start with `hub cli` to begin at the prompt.
- **Display node:** the UI sends commands to the hub like a client does, while the
  monitor keeps showing the board. `x` shows the node's status text, and pressing
  `G` brings the UI back. Start with `display cli` to leave the terminal as status
  text only.

Everyone shares the `tasks.person` setting for **Me**, so each computer can
remember its own person.

### Editing on the monitor

The monitors on the hub and display nodes are touch screens too. Tap anywhere in a
person's column (or anywhere on an empty board) and the monitor switches to the same
UI for that person, with Add, Done, Top, Skip, Edit, Clear and the People screen. There's
no **Me** button, because a shared monitor doesn't belong to anyone.

- Monitors have no keyboard, so every button that needs text (**Add**, **Edit**,
  **New** and the header's **+**) switches the monitor to a full-screen on-screen
  keyboard (for **Edit** it starts with the task's current text). The
  top row says what's being asked for, the white row below shows what you've typed,
  and the keys (digits, letters and `- , . '`) grow to fill the monitor. The bottom
  row has Shift, Space, Del, Cancel and **OK**, shown as `↑ _ < x OK` on monitors
  narrower than 30 characters. Shift applies to the next letter only, and **OK** with
  nothing typed cancels.
- If the monitor UI ever hits an error, the monitor shows it for 8 seconds before
  going back to the board.
- `x` in the header goes back to the board, and so does 60 seconds without a tap
  (`MONITOR_IDLE_SECONDS`).
- Only taps on that monitor count, so someone using the computer's own screen at
  the same time doesn't interfere.
- This needs an Advanced Monitor, since basic monitors can't be touched.
- On narrow monitors (1 block wide is 14 characters at the default text scale) the
  buttons are cramped but still work. A 2-wide monitor (36 characters) gives more
  room than a pocket computer.
- On big monitors the editing UI uses a larger text scale than the board, so buttons
  and keyboard keys get physically bigger instead of tiny. It picks the largest scale
  that still leaves at least 26x20 characters (a pocket computer's screen). Up to 3x3
  stays at the board's scale; 4x4 and up get bigger text (for example about 39x26
  at scale 1 on a 4x4). The board's own scale comes back when the UI closes. Change
  the minimum with `uiMinWidth` / `uiMinHeight` in the `taskview.new` options.

```
+--------------------------+
|<<    Alex (me)    >> + x|  tap < > to switch person, the name for People, + to add one
|1 Fix the reactor         |  yellow 1 = current task
|2 Sort chests             |  tap a task to select it (highlighted)
|3 Craft pipes for the    ^|  scroll bar appears when the list is long
|  north base             v|  (mouse wheel and Up/Down also scroll)
|                          |
|  Add    Done #2   Top #2 |
| Skip  Edit  Clear  Me    |
|Done: Sort chests         |  status line / typing line
+--------------------------+
```

| Button   | Action                                                         |
|----------|----------------------------------------------------------------|
| Add      | Type a task on the bottom row, Enter to add (blank cancels)    |
| Done     | Finish the selected task, or the current one if none selected  |
| Top      | Make the selected task the current one                         |
| Edit     | Change the selected task (or the current one); its text starts filled in |
| Skip     | Send the current task to the back                              |
| Clear    | Remove all of this person's tasks (asks Yes/No first)          |
| Me / Not me | Remember (or forget) this person as you, like `tasks as`    |
| + (green, header) | Add a person (one-word name) and switch to them       |
| x        | Close the UI                                                   |

The **People** screen (tap the name in the header) lists everyone with their task
count. Tap a person to select them and tap again (or **Open**) to view their tasks.
**New** (or the header's **+**) adds a person (one-word name), and **Remove** deletes
the selected person after a Yes/No check. When nobody exists yet, tapping the
"Nobody here yet" message adds someone too.

The UI updates live: the hub pushes every change, so other people's edits show up
straight away, and it re-syncs every 30 seconds in case a push was missed. Update
notices from `pushupdate` still apply while the UI is open.

### Text replies

Replies are wrapped to the screen width. The bottom row is kept for typing: a reply
that fits in the rows above it prints normally. A taller one (such as `help` on a
26x20 pocket computer) opens a pager: rows 1-19 show one page and row 20 is a
navigation bar (`1/3 Space B:back Q:done`).

| Key                                | Action                    |
|------------------------------------|---------------------------|
| Space, Enter, Down, Page Down, `n` | Next page (done on last)  |
| `b`, Up, Page Up, `p`              | Previous page             |
| `q`                                | Done                      |

When you're done, the last page stays on rows 1-19 and the prompt comes back on
row 20. On narrow screens, `help` puts each command on its own line with the
description indented below it.

### Display nodes

A display node is a computer with a monitor and a modem that shows the same board
as the hub, anywhere in modem range (or anywhere at all with ender modems).

1. Place a computer, an Advanced Monitor (any size, at least 1x2) and a modem.
2. Copy `display.lua`, `taskview.lua`, `pager.lua` and `taskgui.lua` into the same
   folder on it (or use `update display`).
3. Add `shell.run("display")` to its `startup.lua`.

The hub pushes the board to every node the moment anything changes. Nodes also
poll every 15 seconds, so they catch up after a hub restart or a missed message.
If the hub stops answering, the node keeps showing the last known board with
`Hub offline` on the bottom row. Each node lays out columns for its own monitor
size, so a small node can page through people while a wide one shows them all.

## Layout rules

- One person per monitor block column. A 1-wide monitor shows one person at a time;
  a 3-wide monitor shows three side by side.
- If there are more people than columns, pages rotate every 8 seconds. A row of
  person buttons appears along the bottom, one per
  person in their column colour, with the people on screen lit up. Tap a name to
  jump to that person; their page stays up for 30 seconds before rotation carries
  on. Names wrap onto extra rows if needed (up to a quarter of the monitor height).
  If they still don't fit, or the monitor is a basic one that can't be touched, a
  `Page x/y` line is shown instead; tap it to flip early.
- Tapping a person's column opens the editing UI on the monitor (see
  [Editing on the monitor](#editing-on-the-monitor)).
- Long tasks word-wrap. If a queue doesn't fit, the last line shows `+N more`.
- Data is saved to `tasks.dat` on the hub after every change, so it survives
  restarts and chunk unloads.

## Commands

Typed at the `hub>` prompt, or from a client as `tasks <command>` (or run `tasks`
alone for a prompt). Person names are single words and case-insensitive.

| Command                   | Effect                                         |
|---------------------------|------------------------------------------------|
| `add <person> <task>`     | Queue a task (creates the person if new)       |
| `done <person> [n]`       | Finish the current task, or task number `n`    |
| `top <person> <n>`        | Make task `n` the current task                 |
| `edit <person> <n> <text>` | Replace the text of task `n`                  |
| `skip <person>`           | Send the current task to the back of the queue |
| `clear <person>`          | Remove all of a person's tasks                 |
| `list [person]`           | Everyone's current task, or one person's queue |
| `addperson <name>`        | Add a person with no tasks (shows as Idle)     |
| `delperson <name>`        | Remove a person and their tasks                |
| `help`                    | Show the command list                          |
| `pushupdate`              | Update the hub, then remotes (hub prompt only) |
| `gui`                     | Open the clickable UI (hub prompt only)        |
| `exit`                    | Stop the hub (hub prompt only)                 |

Example from a pocket computer:

```
tasks add Alex Fix the reactor
tasks add Sam Build wheat farm
tasks done Alex
```

### Remembering who you are (client only)

Each client can remember one person, saved in that computer's settings so it
survives reboots:

```
tasks as Alex          -- remember Alex (or: set tasks.person Alex)
tasks as               -- show who you're adding as
tasks as none          -- forget
```

While a person is remembered, the prompt shows it (`tasks (Alex)> `) and the
person can be left out:

| You type             | Sent to the hub        |
|----------------------|------------------------|
| `add Fix the pump`   | `add Alex Fix the pump`|
| `done` / `done 3`    | `done Alex` / `done Alex 3` |
| `top 2`, `skip`, `clear` | same, for Alex     |
| `edit 2 Mine gold`   | `edit Alex 2 Mine gold` |
| `done Sam`           | `done Sam` (a name still wins) |
| `add @Sam Mine iron` | `add Sam Mine iron`    |

`add` always uses the remembered person unless you write `@name`, because a task
can start with any word. Without a remembered person, commands work as before.

## Updates from git

`update.lua` pulls new versions from
[wolfcomp/CCTaskList](https://github.com/wolfcomp/CCTaskList) (branch `master`)
by default. It needs the CC:Tweaked HTTP API enabled (the default).

One-time setup on a computer:

```
wget https://raw.githubusercontent.com/wolfcomp/CCTaskList/master/update.lua update.lua
update hub                                        -- or: display / client
```

To pull from a fork or another branch instead:

```
update url https://github.com/<you>/<repo> [branch]
```

After that:

| Command          | Effect                                                    |
|------------------|-----------------------------------------------------------|
| `update`         | Update the task files already on this computer            |
| `update check`   | List new or changed files without writing anything        |
| `update <role>`  | Install `hub`, `display` or `client` files (plus updater) |
| `update url`     | Show the repository and branch in use                     |

- You can paste the repository page URL: GitHub, GitLab, Codeberg/Gitea/Forgejo
  links (including `/tree/<branch>/<folder>` style links) are converted to raw-file
  URLs. Any other host: give the raw base URL, so that `<url>/hub.lua` is the file.
- `update.lua` updates itself first. If the repository has a newer updater, it
  checks that the new copy loads, saves it, and lets the new version finish the run
  at the same commit. New files or changed dependencies are then handled by the
  updater that knows about them.
- Every other file is downloaded before anything is written, so a failed fetch
  leaves the computer on its old version.
- Saved data (`tasks.dat`, `.settings`) is never touched.
- If a task program was installed *as* `startup.lua` (or `startup`), the updater
  recognises it by its first line (`-- Task hub:`, `-- Display node:`, ...) and
  updates it too, along with the files it needs next to it (`taskview.lua`, `pager.lua`,
  `taskgui.lua`). A
  wrapper startup like `shell.run("hub")` isn't a copy, so it is left alone.
  To override detection: `set tasks.startup_file hub.lua`, or
  `set tasks.startup_file none` to never touch startup.
- GitHub's raw CDN keeps serving old copies of a branch for minutes after a push,
  so on GitHub the updater asks the API for the branch's latest commit and downloads
  `raw.githubusercontent.com/<user>/<repo>/<commit>/...` instead. A commit URL
  never serves stale files. `update ref` prints the hash it would use.
- `--ref <commit|branch|tag>` on any update command pulls that exact version
  (handy for rolling back: `update --ref 66c0ea7...`, the full 40-character hash).
- If the GitHub API is rate limited (60 requests an hour per server IP), or the
  repository isn't on GitHub, it falls back to the branch URL with `no-cache`
  headers and a unique `?nocache=` query string to force a cache miss.
- A fork can change `DEFAULT_URL` / `DEFAULT_BRANCH` at the top of `update.lua`
  so its computers don't need the `update url` step.

To check for updates on every boot, run the updater first in `startup.lua`. If the
repository can't be reached, the program still starts on its current version:

```lua
shell.run("update")
shell.run("hub")   -- or "display"
```

### Pushing an update from the hub

After pushing to git, type `pushupdate` at the `hub>` console, or tap **Update all**
in the hub's UI. The hub:

1. Looks up the latest commit hash.
2. Updates its own files to that commit. If that fails, it stops there and the
   remotes are not told.
3. If anything changed, it shuts down and starts again on the new version, so it's
   up and answering before any remote comes back. Tasks are kept, because they're
   saved in `tasks.dat`.
4. Broadcasts an update notice carrying the hash, so every remote installs exactly
   the same version without asking the GitHub API itself. If the hub was already up
   to date, it skips the restart and broadcasts straight away.

The notice waits in the `tasks.pending_push` setting while the hub restarts. If the
hub crashes or the computer reboots in between, the notice goes out the next time the
hub starts.

On receiving the notice (only from the hub they're connected to):

- **Display nodes** run their updater and restart if anything changed.
- **`tasks` clients with the prompt open** do the same. One-shot `tasks <command>`
  runs aren't listening, so they pick up changes the next time `update` runs.

Every remote needs `update.lua` installed for this to work. A computer that's off,
out of range or in an unloaded chunk misses the notice. Running `update` from
`startup.lua` covers those the next time they boot. `pushupdate` only works at the
hub console, so a remote client can't trigger a network-wide update.

## Config

Constants at the top of `hub.lua`:

- `MONITOR_NAME`: pin a specific monitor (`"top"`, `"monitor_0"`), otherwise the first found.
- `TEXT_SCALE`: `0.5` fits 14 characters on a 1-wide monitor and 36 on a 2-wide one.
  Raising it fits fewer, bigger letters.
- `PAGE_SECONDS`: page rotation interval.
- `MONITOR_IDLE_SECONDS`: how long the monitor's editing UI stays open without a tap.
- `HOSTNAME` / `PROTOCOL` / `STATE_PROTOCOL`: change them here, in `tasks.lua` and in
  `display.lua` to run several independent hubs.

`display.lua` has the same `MONITOR_NAME`, `TEXT_SCALE`, `PAGE_SECONDS` and
`MONITOR_IDLE_SECONDS` settings,
plus `POLL_SECONDS` for how often it checks in with the hub.
