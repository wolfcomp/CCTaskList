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
| `update.lua`   | Optional, on any of the above   | Pulls the latest files from a git repository    |

## Setup

1. Place an **Advanced Computer** and attach an **Advanced Monitor** at least
   1 wide and 2 tall (touching the computer or via wired modems).
2. Attach a **Wireless** or **Ender Modem** to the hub if people should manage
   tasks remotely or you want display nodes.
3. Copy `hub.lua` and `taskview.lua` into the same folder on the hub. Either paste
   them with `edit`, or drop the files into
   `saves/<world>/computercraft/computer/<id>/`.
4. To start it on boot, create `startup.lua` on the hub containing
   `shell.run("hub")`.
5. Copy `tasks.lua` onto each player's computer or wireless pocket computer.

### Display nodes

A display node is a computer with a monitor and a modem that shows the same board
as the hub, anywhere in modem range (or anywhere at all with ender modems).

1. Place a computer, an Advanced Monitor (any size, at least 1x2) and a modem.
2. Copy `display.lua` and `taskview.lua` into the same folder on it.
3. Add `shell.run("display")` to its `startup.lua`.

The hub pushes the board to every node the moment anything changes. Nodes also
poll every 15 seconds, so they catch up after a hub restart or a missed message.
If the hub stops answering, the node keeps showing the last known board with
`Hub offline` on the bottom row. Each node lays out columns for its own monitor
size, so a small node can page through people while a wide one shows them all.

## Layout rules

- One person per monitor block column. A 1-wide monitor shows one person at a time;
  a 3-wide monitor shows three side by side.
- If there are more people than columns, pages rotate every 8 seconds (tap the
  monitor to flip early) and a `Page x/y` line appears at the bottom.
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
| `skip <person>`           | Send the current task to the back of the queue |
| `clear <person>`          | Remove all of a person's tasks                 |
| `list [person]`           | Everyone's current task, or one person's queue |
| `addperson <name>`        | Add a person with no tasks (shows as Idle)     |
| `delperson <name>`        | Remove a person and their tasks                |
| `help`                    | Show the command list                          |
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
- Every file is downloaded before anything is written, so a failed fetch leaves
  the computer on its old version.
- Saved data (`tasks.dat`, `.settings`) is never touched.
- If a task program was installed *as* `startup.lua` (or `startup`), the updater
  recognises it by its first line (`-- Task hub:`, `-- Display node:`, ...) and
  updates it too, along with the files it needs next to it (`taskview.lua`). A
  wrapper startup like `shell.run("hub")` isn't a copy, so it is left alone.
  To override detection: `set tasks.startup_file hub.lua`, or
  `set tasks.startup_file none` to never touch startup.
- GitHub's raw CDN caches files for up to about 5 minutes after a push.
- A fork can change `DEFAULT_URL` / `DEFAULT_BRANCH` at the top of `update.lua`
  so its computers don't need the `update url` step.

To check for updates on every boot, run the updater first in `startup.lua`. If the
repository can't be reached, the program still starts on its current version:

```lua
shell.run("update")
shell.run("hub")   -- or "display"
```

## Config

Constants at the top of `hub.lua`:

- `MONITOR_NAME`: pin a specific monitor (`"top"`, `"monitor_0"`), otherwise the first found.
- `TEXT_SCALE`: `0.5` gives 15 characters per block column. Raising it fits fewer, bigger letters.
- `PAGE_SECONDS`: page rotation interval.
- `HOSTNAME` / `PROTOCOL` / `STATE_PROTOCOL`: change them here, in `tasks.lua` and in
  `display.lua` to run several independent hubs.

`display.lua` has the same `MONITOR_NAME`, `TEXT_SCALE` and `PAGE_SECONDS` settings,
plus `POLL_SECONDS` for how often it checks in with the hub.
