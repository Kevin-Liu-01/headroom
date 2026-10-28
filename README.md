# Headroom

![The macOS Force Quit dialog after the system ran out of application memory, with Claude at 237.35 GB](docs/out-of-memory.png)

Headroom is a macOS app that shows how much memory the Claude and Codex desktop apps, their agent sessions and every process those sessions start are using, and keeps a record of it. A menu bar item shows the agents' total at a glance, and its window holds everything: memory now, the history (a chart from the last hour to the whole record, the peaks, the time spent at warning and critical, and the days, warnings and sessions behind them) and the session restarts. An app window shows the same with the history at full width, and opens only when you ask for it. Both windows also list leftovers: processes that outlived the session, shell or script that started them, with their pids. Headroom takes no messages from agents, and it stops a process in two cases only. One is a session it recommends restarting: a Claude Code session whose own process has grown, once restarting it loses nothing, or when you press its Restart button (see [Restarting a session](#restarting-a-session)). The other is a leftover whose Kill button you click twice (see [Leftovers](#leftovers)).

## Screenshots

These screenshots show a made-up machine and a made-up week. The Claude agents use 39.6 GB and the Codex agents 18.5 GB, so together they cross the 40 GB warning line at 58.1 GB. Over the week, builds pushed the agents past the warning line on three afternoons and a training run went critical on Tuesday. The images are rendered with `HeadroomApp --render docs --demo`, which fixes the clock so both themes show the same times. Without `--demo`, the same command renders the live state and record of the Mac it runs on.

![The Headroom app window in light mode: memory now on the left, a week of history on the right](docs/app-light.png)

![The Headroom app window in dark mode](docs/app-dark.png)

| Light | Dark |
| --- | --- |
| ![The history's list of warnings in light mode](docs/history-warnings-light.png) | ![The history's list of warnings in dark mode](docs/history-warnings-dark.png) |
| ![The menu bar window in light mode](docs/headroom-light.png) | ![The menu bar window in dark mode](docs/headroom-dark.png) |
| ![The menu bar item in light mode](docs/menubar-light.png) | ![The menu bar item in dark mode](docs/menubar-dark.png) |
| ![Settings in light mode](docs/settings-light.png) | ![Settings in dark mode](docs/settings-dark.png) |

The menu bar images are 2x crops. The app icon is three bars that stand on a floor under a ceiling line. The gap between the tallest bar and the line is the headroom.

<img src="docs/icon-1024.png" alt="The Headroom app icon" width="160">

## Why it exists

The Claude desktop app owns every Claude Code session it starts, and the Codex app owns every Codex session it starts. Each app also owns every process those sessions start: MCP servers, test runners, browsers, encoders and model runs. When 25 sessions run at once, the Force Quit dialog shows all of that memory under one name, Claude or ChatGPT. On the Mac this app was written for, one runaway node process reached 457 GB and the system ran out of application memory twice in one day. Headroom shows which session and which process owns the memory, and its record shows when memory ran high, for how long and because of what.

## What it watches

Headroom takes a sample every 20 seconds, and every 5 seconds while memory is high. Each sample reads these values:

- Free memory from `kern.memorystatus_level`, as a percentage of total memory.
- Memory pressure from `kern.memorystatus_vm_pressure_level` and from a `DispatchSource` memory pressure source, which also triggers an immediate sample.
- Swap used from `vm.swapusage`, compressed memory from `host_statistics64` and total memory from `hw.memsize`.
- The physical footprint of every process from `proc_pid_rusage` (`RUSAGE_INFO_V4`, `ri_phys_footprint`). This is the number Activity Monitor shows. The same call gives its CPU time, `ri_user_time` plus `ri_system_time`.
- The parent pid, process group, path, start time and working directory of each process from libproc, and for a process whose parent is launchd, whether launchd started it or adopted it.

Headroom builds the process tree from the parent pids and attributes memory to two agent apps.

| App | The app's processes | A session is |
| --- | --- | --- |
| Claude | The `Claude.app` process plus all its descendants. | A Claude Code process, whose executable path contains `claude-code/` and ends in `claude`, together with its descendants. |
| Codex | The process of the app bundle named ChatGPT or Codex whose identifier is `com.openai.codex`, plus all its descendants. On macOS that bundle is `ChatGPT.app`. Every `codex app-server` process also counts, with its descendants, including the shared daemon that launchd adopts. | A thread of the Codex app, or a `codex` process that runs an agent, together with its descendants. |

Each app's total counts every process of that app's agents once: the app's processes and the app's sessions started from terminals. A process counts toward one app only, so the Claude total plus the Codex total is the agents' total, and an app's total is never smaller than the sessions listed under it. The windows and `headroom status` also show how much of each total runs in terminals.

Codex runs in three ways, and Headroom reads the subcommand from each `codex` process's arguments to tell them apart.

- The Codex app's threads run inside one `codex app-server` process, either a child of the app or the shared daemon (`codex app-server daemon`). Each thread runs its commands in the thread's folder, so Headroom groups the app server's direct children by working directory and lists each folder as a session. Such a session has no process of its own; its `pid` in `state.json` is negative and stays the same for one app server and folder. The app server itself is not a session.
- The interactive CLI, `codex exec`, `codex review`, `codex resume` and `codex fork` are sessions. The executable is named `codex` in the Codex app (`ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`) and in the npm package `@openai/codex`, and `codex-aarch64-apple-darwin` in the Homebrew cask. The npm launcher, `node .../@openai/codex/bin/codex.js`, counts toward the session it starts.
- Other subcommands, such as `codex app-server proxy`, `codex mcp`, `codex login` and `codex sandbox`, and helpers such as `codex-code-mode-host`, are not sessions. Their memory counts toward the session or app server above them, if any.

Each session is labelled by its working directory, so a person can see which project owns the memory. A session in the home folder is labelled Home folder. A process belongs to the nearest session above it, so a session started inside another session keeps its own processes. A session started from a terminal belongs to the app whose agent it runs, even though it is outside that app's process tree.

For each session and each app Headroom also shows the change in memory over the last 10 minutes. A change shows once Headroom has 10 minutes of samples; until then the column shows a dot.

Headroom also lists heavy jobs: browsers, model runs, encoders, builds, test runs, dev servers and containers above 256 MB. A heavy job is the topmost matching process with its whole subtree. It lists leftovers too, the processes no agent counts any more because whatever started them has ended (see [Leftovers](#leftovers)). The windows also show the memory totals of other apps, and the CLI prints the largest processes overall.

macOS does not let an unprivileged app read the footprint of processes owned by other users, such as `WindowServer` and `kernel_task`. Headroom counts them as unreadable and leaves them out of the totals. Every Claude and Codex process belongs to the person, so the agent totals are complete.

## Levels

Headroom watches three totals: all agents together, the Claude agents and the Codex agents. On a new install each has a warning line at 47 percent of the Mac's memory and a critical line at 70 percent, rounded to 5 GB, so a 128 GB Mac warns at 60 GB and turns critical at 90 GB, and a 32 GB Mac at 15 and 20 GB. Free memory and the system's memory pressure have their own lines. The level is the worst of them.

The agents' lines measure the agents' work: everything in an app's total except the sessions' own Claude Code and Codex processes. A session's own process grows with its conversation and only a restart frees it, so counting it would keep the level up for as long as one session stayed bloated. A session whose own process passes 16 GB, or that keeps half a CPU core busy for 10 minutes, gets a note under the level instead. Free memory and pressure still count everything.

| Level | When |
| --- | --- |
| ok | No line is crossed. |
| warning | The agents', Claude's or Codex's work reaches its warning line, free memory is below 30 percent, or the system reports memory pressure while free memory is below 30 percent. |
| critical | The agents', Claude's or Codex's work reaches its critical line, free memory is below 15 percent, or the system reports critical pressure. |

The settings window changes every line, the sampling and the age at which leftovers are listed. Settings are stored in `~/Library/Application Support/Headroom/settings.json`, so the CLI uses the same lines as the app.

Headroom posts a notification each time the level gets worse, naming the largest sessions and processes. While the level stays at warning or critical, the notification repeats every 5 minutes. When the level returns to ok for three samples in a row, Headroom posts a recovery note. While the level is at warning or critical, it also posts a notification each time a single process crosses another 16 GB step; with memory to spare, a big process is nothing to act on, so it stays quiet. Clicking a notification opens the menu bar window. When macOS does not let Headroom post its own notifications, Headroom posts the same text as a banner through osascript.

## Restarting a session

A Claude Code session's own process grows with its conversation and only a restart frees it. When a desktop session's own process passes the process alert step (16 GB by default), its note in the windows says so and has a Restart button. A restart stops the process; the conversation is on disk, and the Claude app resumes the session on your next message.

A restart loses nothing when all of these hold, read from the process table and the last 512 KB of the session's conversation file:

- its last turn ended with a reply at least 10 minutes ago;
- no message waits in its queue: nothing was enqueued after that reply, or everything was taken;
- the last turn set no ScheduleWakeup, CronCreate, Monitor or RemoteTrigger, whose work outlives the turn;
- none of its subagents wrote in the last 10 minutes, and no Bash tool shell of its, in the foreground or the background, is running;
- its own process used less than 5 percent of a CPU core over the last 10 minutes.

When they hold, the button is ink and Headroom restarts the session on its own, the largest first and one at a time, unless Settings turns that off. When they do not, the note says why, such as "Not yet: it replied 3 min ago", and the button reads Restart anyway, which asks first. A session started from a terminal and a Codex thread are never restarted: neither would come back on its own. Before it signals, Headroom checks that the pid still names the same process; it sends SIGTERM, and SIGKILL 30 seconds later if the process is still there. Each restart posts a notification and a `restart` event in the log. `headroom status --restart` prints the same check for every desktop session.

## Leftovers

When a session, a shell or a script ends, launchd adopts the processes it started. Their parent becomes launchd, pid 1, so no agent's tree counts them and no other row shows them. On the Mac this app was written for, test browsers, stuck searches, dev servers and scripts ran this way for days. Headroom lists them as leftovers, with their pids, so you can kill them. It never stops one on its own, and nothing an agent does can make it.

A leftover follows these rules, checked at every sample:

- Its top process has launchd as its parent and belongs to you, and launchd did not start it itself. launchd also starts apps and launch agents, and those are not leftovers. The kernel keeps the pid version of the process that started each process (`proc_pidinfo` with `PROC_PIDUNIQIDENTIFIERINFO`, `p_orig_ppidversion`), so Headroom counts only the processes that launchd adopted. When the kernel does not say, a parent of pid 1 is enough.
- It runs from the home folder, `/opt/homebrew` or `/usr/local`, or it is a test browser, a search or a shell. A test browser is Chrome for Testing, `chrome-headless-shell`, or a Chromium, Firefox or WebKit build in a Puppeteer, Playwright or Selenium cache.
- App bundles in `/Applications` and `~/Applications`, such as Headroom itself, your Google Chrome, system services, every process that counts toward Claude or Codex, and the agents' own processes are never leftovers.
- One leftover is one job: the adopted processes that share a process group and started within 2 seconds of each other, each with its subtree. The commands of one pipeline are one job. A test browser also takes its two `chrome_crashpad_handler` processes, which launchd adopts as soon as they start, a moment after the browser and with pids just above its pid.
- Its kind is browser, search, dev server or process. A search is ugrep, rg, grep or find. A dev server is `pnpm dev` or `pnpm exec`, `next dev`, `vite`, `vercel-static-preview` and the like. A process is other node, python, bun and ffmpeg work. An adopted shell takes the kind of the first process under it that has one, and is a process when none has, so a chain script that sleeps between its steps stays listed. Claude Code runs its own binary as ugrep for its searches, and its Bash tool can pipe `tail -F` into that ugrep, so a search left behind can wait for days.
- Its top process is at least 30 minutes old. Settings changes the age.

Each leftover shows its kind, its command, its folder, every pid, its age, its memory and when it was last active. The command is the first arguments of the process that gives the leftover its kind, with paths cut to their last part; for an agent's shell, it is the command inside the Bash tool's wrapper. The folder is that process's working directory. The memory is the footprint of all its processes together.

Headroom reads the CPU time of every process at every sample and keeps it in memory only. A leftover was last active at the last sample at which the CPU time of its processes grew by at least 1 percent of one core since the sample before, which is 0.2 seconds in a 20 second sample, or at which one of its processes did so on its own, also before it was left behind. A stuck ugrep that uses 0.03 seconds every 20 seconds is not active, and a test browser with an animated page, at 0.9 seconds every 8 seconds, is. Until Headroom has seen a leftover active, it says "not active since Headroom started" with the time Headroom started, or since the leftover started when that was later.

The menu bar window and the app window show the leftovers in a section after the heavy jobs, largest first, under a head such as "5 leftovers, 4.3 GB". The pids are text you can select and copy. A leftover's Kill button asks for a second click within 5 seconds. That click sends SIGTERM to every pid of the leftover, and 5 seconds later SIGKILL to any that is still running. Before each signal Headroom checks that the pid still names the same process, by its owner and start time, so a pid that was reused is left alone. Each kill writes a `kill` event in the log with the program, the folder's name and the pids. Headroom posts no notification about leftovers.

`headroom leftovers` prints the same list as a table of kind, age, memory, last active, folder and command, with the pids on a line under each leftover. `headroom leftovers --json` prints the leftovers as `state.json` holds them.

## The record

Every sample folds into the minute it falls in. When a minute ends, Headroom writes it as one line to `history/<day>.jsonl` in its folder, one file per local day, and when an hour ends, it writes the hour as one line to `history/hours.jsonl`. Each line holds:

- for the agents, Claude, Codex, the Mac's memory in use and free memory: the lowest, average and highest value, written as `[min, avg, max]`;
- the most swap and compressed memory, and the Mac's total memory;
- the worst level, and the minutes with samples, at warning and at critical (a minute counts once, at its worst level);
- when the agents' total peaked, and the three largest sessions and processes at that moment.

Minutes are kept for 90 days and hours for good. A minute's line is about 600 bytes, so a day of minutes is under 1 MB and a year of hours about 5 MB. When the Mac sleeps or Headroom is not running, nothing is written and nothing is filled in, so gaps show as gaps. After a quit or a crash, the next start writes any hour it missed from the minutes on disk.

The first start of version 2 also builds the record's first days from version 1's log: version 1 wrote a summary of every sample to `events.jsonl` and `events.1.jsonl`, with the totals, free memory, swap, the advice and the three largest sessions and processes. Those samples become minutes and hours before the record's first minute, with hold read as warning, once; `history/.imported-v1` marks it done.

`history.jsonl` beside it holds every sample of the last 60 minutes for the menu bar window's chart.

## The app window

It opens only from the menu bar window's Open Headroom button. Starting Headroom, opening it again from Finder or Spotlight, and clicking a notification show the menu bar window instead, and at login only the menu bar item appears. While the app window is open, Headroom has a Dock icon and menus; when it closes, Headroom goes back to the menu bar.

The left column is memory now, in the menu bar window's rows: the agents' total and level with its reasons, free memory, swap, compressed memory and pressure, then Claude and Codex with their sessions, the heavy jobs, the leftovers and other apps.

The right column is the history:

1. **Range**: 1 hour, 6 hours, 24 hours, 7 days, 30 days, 90 days or the whole record. ⌘1 to ⌘7 choose them, and ⌘R reloads.
2. **Measure**: the agents together, Claude, Codex, the Mac's memory in use, or swap.
3. **Chart**: each point covers a stretch of time, from one minute for the last hour to a day for a long record. The ink line is the stretch's peak and the dithered area its average. The warning and critical lines are hair rules; for memory in use they are the free memory lines, under a rule at the Mac's total memory. A strip under the chart marks where the record has samples, and, in amber and red, the minutes at warning and critical. Hovering shows a stretch's time, peak and average, level, and the largest sessions at its peak.
4. **Figures** for the range: the peak and when it happened, the average, the most memory in use, the lowest free memory, the most swap, and the time at warning and at critical.
5. **Lists**: Days, one row per day with its peak, average, memory in use, lowest free memory, time at warning and critical, and the largest session at the peak; Warnings, each stretch at warning or critical with its time, peak and the two largest sessions, where dips back to ok shorter than 5 minutes belong to the stretch; and Sessions, ranked by their largest total in the range, with how long each was among the three largest.

Warnings need minutes, so they reach back 90 days at most. The window reloads its range every minute while it is open, and releases everything it read when it closes.

## The menu bar

The menu bar item shows a small gauge, the agents' total in GB and a dot. The gauge's column fills toward its top line as the agents' total nears the critical line, so the empty part under the line is the headroom, and a tick on its left marks the warning line. The dot is green for ok, amber for warning and red for critical. A click opens the menu bar window under the item. It holds everything the app window does: the head with the level, its reasons and each session's Restart button; the history with the same ranges, measures, chart, figures and Days, Warnings and Sessions lists, sized to the window; Claude and Codex with their sessions, the heavy jobs, the leftovers with their Kill buttons and other apps; and a footer with Open Headroom, Settings, the event log, Quit Headroom and Launch at login. The session, heavy job and leftover lists show six rows and the history's lists five until Show more is clicked, and the window scrolls when it is taller than the screen. A click outside the window or the Escape key closes it. Launch at login uses `SMAppService` and is off until it is turned on.

## Command line

The `headroom` command works without the app. When `state.json` is older than 60 seconds, it samples the Mac directly. The record is written only by the app.

```sh
headroom status                 # the level, the agents' totals, free memory, leftovers, sessions by app, heavy jobs
headroom status --json          # the same document as state.json
headroom status --restart       # for every desktop session, whether a restart would lose anything
headroom leftovers              # processes that outlived what started them: kind, age, memory, last active, folder, command, pids
headroom leftovers --json       # the same leftovers as state.json holds them
headroom history                # the last 24 hours in up to 36 rows: peak, average, level and largest session
headroom history 7d             # any range: 1h, 6h, 24h, 7d, 30d, 90d, all, or Nh or Nd
headroom days 30d               # one row per day
headroom episodes 7d            # each stretch at warning or critical
headroom events --follow        # the app's log: starts, alerts, pressure changes, kills and settings
headroom doctor                 # the app's state file, the record's files and a direct sample
```

`history`, `days` and `episodes` take `--json` and print the rollups.

Two commands remain for scripts that ask before they start a large job. Nothing in Headroom stops a job from starting (Kevin, 2026-10-21: "never stop agents from starting new stuff"), so both always answer yes; they only describe the room left.

```sh
headroom can-start --gb 8       # prints "yes:" and how tight memory would be; always exits 0
headroom wait --gb 8 && ffmpeg -i in.mov out.mp4   # returns at once
```

The note says when memory is already at warning or critical, when a job would leave free memory under the warning line or push the agents' work past the critical line, or when it needs more than is free.

## Upgrading from 1.x

Version 2 removes everything that agents talked to: the local HTTP API on port 7341 and its token, the MCP server, the `PreToolUse`, `SessionStart` and `UserPromptSubmit` hooks, agent notes and requests with their Approve and Deny buttons, session watch and rescue, the runaway guard, and the window's Pause, Quit and Restart Claude or Codex buttons. 2.1 brings back one action: restarting a bloated desktop session when nothing would be lost. `headroom hook` now exits 0 with no output, so a hook that is still configured lets every command run; remove it from `~/.claude/settings.json` or `~/.codex/config.toml`. `headroom note`, `request`, `mcp`, `sessions`, `session`, `rescue` and `guard` say they were removed and exit 1; remove a `headroom` MCP server with `claude mcp remove headroom` or `codex mcp remove headroom`. `scripts/build-app.sh` removes the guard's LaunchAgent, `com.kevinliu.headroom.guard`, if it is installed.

Version 1's files stay in `~/Library/Application Support/Headroom` until they are deleted by hand: `token`, `guard.json`, `guard-state.json`, `hook-warned.json`, `sessions.json`, `sessions-scan.json`, `sessions-history.jsonl`, `recovery/` and `rescues/`. The record starts with version 2; version 1 kept only the last 60 minutes.

In `state.json`, version 3 replaces `advice` (ok, hold, critical) with `level` (ok, warning, critical) and drops `pendingRequests` and `notes`. Version 2.2 adds `snapshot.leftovers`; a state file without it reads as one with no leftovers.

## Install

Headroom needs macOS 14 or later and Swift 6. The build script builds in release, assembles `Headroom.app` with its icon, signs it ad hoc, installs it to `~/Applications`, installs the CLI to `~/.local/bin/headroom` and launches the app, which shows its menu bar window.

```sh
scripts/build-app.sh
```

`scripts/build-app.sh --no-launch` installs without launching. `scripts/build-app.sh --no-install` only assembles `build/Headroom.app`. Launch at login stays off until it is turned on in the menu bar window. `Headroom --background` starts in the menu bar without opening the window.

Headroom asks for permission to post notifications at its first launch. On macOS 26.4 an ad hoc or self-signed build receives the answer "Notifications are not allowed for this application", and no Headroom entry appears in the notification settings. A build signed with a Developer ID should be allowed. Set `HEADROOM_SIGN_IDENTITY` to the identity's name before running `scripts/build-app.sh` to sign with it. Until then, Headroom falls back to osascript banners.

`build-app.sh` copies the Inter font and its license into the app bundle. Run the tests with `swift test`. Render the screenshots with `~/Applications/Headroom.app/Contents/MacOS/Headroom --render docs`. From a checkout, `swift build -c release` builds the app as `.build/release/HeadroomApp`. On a case-insensitive disk `.build/release/Headroom` is the CLI. `HeadroomApp --snapshot-window <file>.png` opens the live menu bar window after one sample, writes it to the file and exits, and `--snapshot-app <file>.png` does the same for the app window once its history has loaded. Neither writes state, the record or the log.

## Look

The windows use the tokens, type and line rules of the General Translation brand deck. Light is a white surface with ink `#070707` text and dark is an ink surface with `#f2f2f0` text. Text has three steps: ink, ink-2 and titanium. Lists are ruled rows with a 9 percent line between rows and an 18 percent line between sections, drawn edge to edge. In dark mode the lines are 10 and 22 percent, as in the deck's dark theme. Every row has one 16 point leading slot for its icon, mark or chevron, so every title starts at the same edge, and every figure ends at the same right edge. Section heads have more space under them than above them. Controls round at 6 points and the windows stay square. Colour appears only on icons, the status dots and the level strip under the history chart: green for ok, amber for warning and red for critical. GT blue marks the current value on a chart. A chart's area is an ordered dither on an 8 by 8 Bayer screen, one cell per point, and it is the windows' only texture.

The type is rsms InterVariable 4.1, bundled in `Resources/Fonts` with its SIL Open Font License and registered at launch. Weights stop at 500. The totals use tabular figures with the `cv11` and `ss01` features, and tracking tightens with size. Meaning icons are Heroicons 20 solid (MIT). The Claude mark (CC0, from thesvg.org) keeps its own colour, `#D97757`, and the Codex mark (MIT, from thesvg.org) takes the text colour. Both marks belong to their owners and label the apps they name.

## Footprint

Headroom's own memory and CPU use were measured for version 1 on 2026-10-12 on a 128 GB Mac with about 1,000 processes and 12 agent sessions, under a load average between 140 and 240. Version 2 samples the same way and adds one appended line a minute.

| Measure | Result | Method |
| --- | --- | --- |
| Physical footprint, windows closed | 15 to 16 MB | `footprint -p <pid>` every 10 seconds for 2 minutes |
| Physical footprint, menu bar window open | 37 MB in 5 of 7 runs; 86 MB and 102 MB in the other 2, at a load average near 280 | `proc_pid_rusage` in `--snapshot-window` runs on 2026-10-13 |
| CPU, windows closed | 0.48 to 0.69 percent over 2 minutes | CPU time from `ps -o time` divided by wall time, in two runs |
| One sample | 83 ms for 985 processes in one run, and 980 ms for 1,013 processes at a load average of 244 | `headroom doctor`, which samples without the app's cache |
| Version 2, app window open | 54 MB after it settles | `footprint -p <pid>` on 2026-10-16, a minute after launch |

When a window first appears, macOS charges the process for the window's graphics memory; on the 2026-10-16 Mac this reached 185 MB for about a second, as "Owned physical footprint (unmapped) (graphics)", and became reclaimable once the window was drawn. The windows exist only while they are open. Closing one releases its views and, for the app window, the history it read, so a closed window costs no memory and no drawing per sample.

## Privacy

Everything stays on the Mac, and Headroom makes no network requests and listens on no port. The state, the settings, the record and the log are files in `~/Library/Application Support/Headroom` that only the person's account can read. Headroom reads process paths, the arguments of interpreters such as node and python and of `codex` processes, the working directories of agent sessions and of the Codex app server's direct children, the arguments, working directory and original parent of each of your processes that launchd adopted, and the `Info.plist` of app bundles named ChatGPT or Codex to find the Codex app. The record holds session folder names and process names with their memory; the log holds alerts, which name the same, and kills, which name the program, the folder's name and the pids. Neither holds file contents or command lines. `state.json` holds each leftover's shortened command and its folder, and is replaced at every sample. For a session with a restart note, Headroom reads the end of its conversation file under `~/.claude/projects` to tell whether a restart would lose anything, and keeps nothing from it.

## License

Headroom is released under the MIT license. See [LICENSE](LICENSE).
