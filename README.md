# Headroom

![The macOS Force Quit dialog after the system ran out of application memory, with Claude at 237.35 GB](docs/out-of-memory.png)

Headroom is a macOS menu bar app that watches memory use by the Claude and Codex desktop apps, their agent sessions and every process those sessions start. It alerts the person at the Mac when memory runs low, relays the current memory state to agents through a file, a local HTTP API, a command line tool, hooks for Claude Code and Codex, and an MCP server, and carries out actions when a person clicks them. One part acts on its own: the runaway guard, a small background process that samples every process once a second and stops one whose memory spirals faster than a person can react. The guard starts in observe mode, where it only logs and announces what it would stop.

## Screenshots

These screenshots show a made-up machine. The Claude agents use 39.6 GB, of which 38.4 GB runs in the Claude app and 1.2 GB in a session started from a terminal. The Codex agents use 18.5 GB, of which 14.6 GB runs in the Codex app and 3.9 GB in a terminal session. Neither app crosses its own 40 GB line, but together the agents use 58.1 GB, which crosses the 40 GB line for all agents and puts the advice at hold. One agent request waits for an answer. The demo uses the base lines of 40 and 70 GB. The images are rendered with `HeadroomApp --render docs --demo`, which fixes the clock so both themes show the same times. Without `--demo`, the same command renders the live state of the Mac it runs on.

| Light | Dark |
| --- | --- |
| ![Headroom window in light mode](docs/headroom-light.png) | ![Headroom window in dark mode](docs/headroom-dark.png) |
| ![The menu bar item in light mode](docs/menubar-light.png) | ![The menu bar item in dark mode](docs/menubar-dark.png) |
| ![Settings in light mode](docs/settings-light.png) | ![Settings in dark mode](docs/settings-dark.png) |

The menu bar images are 2x crops. The app icon is three bars that stand on a floor under a ceiling line. The gap between the tallest bar and the line is the headroom.

<img src="docs/icon-1024.png" alt="The Headroom app icon" width="160">

## Why it exists

The Claude desktop app owns every Claude Code session it starts, and the Codex app owns every Codex session it starts. Each app also owns every process those sessions start: MCP servers, test runners, browsers, encoders and model runs. When 25 sessions run at once, the Force Quit dialog shows all of that memory under one name, Claude or ChatGPT. On the Mac this app was written for, one runaway node process reached 457 GB and the system ran out of application memory twice in one day. Headroom shows which session and which process owns the memory before that happens.

## What it watches

Headroom takes a sample every 20 seconds, and every 5 seconds while memory is low. Each sample reads these values:

- Free memory from `kern.memorystatus_level`, as a percentage of total memory.
- Memory pressure from `kern.memorystatus_vm_pressure_level` and from a `DispatchSource` memory pressure source, which also triggers an immediate sample.
- Swap used from `vm.swapusage`, compressed memory from `host_statistics64` and total memory from `hw.memsize`.
- The physical footprint of every process from `proc_pid_rusage` (`RUSAGE_INFO_V4`, `ri_phys_footprint`). This is the number Activity Monitor shows.
- The parent pid, path, start time and working directory of each process from libproc.

Headroom builds the process tree from the parent pids and attributes memory to two agent apps.

| App | The app's processes | A session is |
| --- | --- | --- |
| Claude | The `Claude.app` process plus all its descendants. | A Claude Code process, whose executable path contains `claude-code/` and ends in `claude`, together with its descendants. |
| Codex | The process of the app bundle named ChatGPT or Codex whose identifier is `com.openai.codex`, plus all its descendants. On macOS that bundle is `ChatGPT.app`. Every `codex app-server` process also counts, with its descendants, including the shared daemon that launchd adopts. | A thread of the Codex app, or a `codex` process that runs an agent, together with its descendants. |

Each app's total counts every process of that app's agents once: the app's processes and the app's sessions started from terminals. A process counts toward one app only, so the Claude total plus the Codex total is the agents' total, and an app's total is never smaller than the sessions listed under it. The window and `headroom status` also show how much of each total runs in terminals.

Codex runs in three ways, and Headroom reads the subcommand from each `codex` process's arguments to tell them apart.

- The Codex app's threads run inside one `codex app-server` process, either a child of the app or the shared daemon (`codex app-server daemon`). Each thread runs its commands in the thread's folder, so Headroom groups the app server's direct children by working directory and lists each folder as a session. Such a session has no process of its own; its `pid` in `state.json` is negative and stays the same for one app server and folder. The app server itself is not a session.
- The interactive CLI, `codex exec`, `codex review`, `codex resume` and `codex fork` are sessions. The executable is named `codex` in the Codex app (`ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`) and in the npm package `@openai/codex`, and `codex-aarch64-apple-darwin` in the Homebrew cask. The npm launcher, `node .../@openai/codex/bin/codex.js`, counts toward the session it starts.
- Other subcommands, such as `codex app-server proxy`, `codex mcp`, `codex login` and `codex sandbox`, and helpers such as `codex-code-mode-host`, are not sessions. Their memory counts toward the session or app server above them, if any.

Each session is labelled by its working directory, so a person can see which project owns the memory. A session in the home folder is labelled Home folder. A process belongs to the nearest session above it, so a session started inside another session keeps its own processes. A session started from a terminal belongs to the app whose agent it runs, even though it is outside that app's process tree.

For each session and each app Headroom also shows the change in memory over the last 10 minutes. The app keeps the per-session samples in memory, and a change shows once Headroom has 10 minutes of samples. Until then the column shows a dot.

Headroom also lists heavy jobs: browsers, model runs, encoders, builds, test runs, dev servers and containers above 256 MB. A heavy job is the topmost matching process with its whole subtree. The window also shows the memory totals of other apps, and the CLI prints the largest processes overall.

macOS does not let an unprivileged app read the footprint of processes owned by other users, such as `WindowServer` and `kernel_task`. Headroom counts them as unreadable and leaves them out of the totals. Every Claude and Codex process belongs to the person, so the agent totals are complete.

## When it alerts

Headroom watches three totals: all agents together, the Claude agents and the Codex agents. On a new install each has a hold line at 47 percent of the Mac's memory and a critical line at 70 percent, rounded to 5 GB, so a 128 GB Mac holds at 60 GB and turns critical at 90 GB, and a 32 GB Mac at 15 and 20 GB. Free memory and the system's memory pressure have their own lines. The advice is the worst of them.

| Advice | When | What it means |
| --- | --- | --- |
| ok | No line is crossed. | Agents may start heavy jobs. |
| hold | The agents, Claude or Codex reach their hold line, free memory is below 30 percent, or the system reports memory pressure. | Agents start nothing new that is heavy. |
| critical | The agents, Claude or Codex reach their critical line, free memory is below 15 percent, or the system reports critical pressure. | Pause heavy jobs and restart Claude or Codex, whichever holds more memory. All agent state is on disk, so a restart of the app loses no work. |

The settings window changes every line. Settings are stored in `~/Library/Application Support/Headroom/settings.json`, so the CLI, the hooks and the MCP server use the same lines as the app.

Headroom posts a notification each time the advice gets worse. The notification names the largest sessions with their apps and the largest processes, and offers four buttons: Pause heavy jobs, Restart Claude, Restart Codex and Show. While the advice stays at hold or critical, the notification repeats every 5 minutes. When the advice returns to ok for three samples in a row, Headroom posts a recovery note. Headroom also posts a notification each time a single process crosses another 16 GB step.

When macOS does not let Headroom post its own notifications, Headroom posts the same alert as a banner through osascript, without buttons. A crossing or a new agent request also opens the Headroom window under the menu bar item, where the buttons are. The window does not take focus from the app in front.

Every sample summary, alert, note, request, decision and action is appended to `events.jsonl`. The log rotates to `events.1.jsonl` at 10 MB.

## What a person can do

The menu bar item shows a small gauge, the agents' total in GB and a dot. The gauge's column fills toward its top line as the agents' total nears the critical line, so the empty part under the line is the headroom, and a tick on its left marks the hold line. The dot is green for ok, amber for hold and red for critical. A click opens the window under the menu bar item.

The window shows these parts from top to bottom:

1. The head: the agents' total, the advice and its reasons, free memory, swap, compressed memory and pressure.
2. A chart of the agents' total over the last 60 minutes with the hold and critical lines.
3. Pending agent requests with Approve and Deny buttons, when there are any.
4. Claude and Codex, each with its mark, its total, its 10 minute change and its sessions sorted by memory. Each session shows its folder, whether it runs in the app or from a terminal, its change over the last 10 minutes and its total, and expands to its largest processes.
5. The heavy jobs, each with the mark and name of the session that owns it.
6. Notes from agents, when there are any.
7. Other apps.

Each list shows six rows until the person clicks Show more, so the heavy jobs stay in view when many sessions run.

Each process has Pause (SIGSTOP), Resume (SIGCONT) and Quit icon buttons, each with a tooltip and an accessibility label. The Quit confirmation offers Quit (SIGTERM) and Force quit (SIGKILL). For a heavy job, Pause and Force quit act on the whole process tree, and Quit sends SIGTERM to the job's top process so it can shut its children down. Every action that stops a process asks for confirmation first. Before it sends a signal, Headroom checks that the pid still belongs to the process the person saw, so a pid that the system reused after the process exited is never signalled. A paused process keeps its memory but stops growing, and the system can compress or swap that memory.

Pause heavy jobs pauses the jobs that agents and tools started. It leaves out apps that the person opened from `/Applications`, such as their own Google Chrome, and the confirmation names them. Each of those apps still has its own Pause button.

The footer has Restart Claude, Restart Codex and Settings, then icon buttons for the event log and Quit Headroom, and a Launch at login checkbox. A restart button shows only while its app runs. A restart asks the app to quit, waits for it to exit and opens it again. If the app does not quit within 30 seconds, Headroom asks whether to force quit it. Sessions started from a terminal keep running through a restart. On macOS the Codex app is `ChatGPT.app`, so the confirmation says that ChatGPT's chat windows close too. When the Codex app server runs apart from the app as the shared daemon, it keeps running through the restart with its memory, and the confirmation names `codex app-server daemon restart`, which restarts it. Launch at login uses `SMAppService` and is off until the person turns it on.

The window does not take focus from the app in front when it opens on a crossing. A click outside the window or the Escape key closes it.

## Runaway guard

On 2026-10-13 an agent ran a `git grep` with a 130-word pattern and no `-I` over a repository with binary assets. It grew from 42.6 GB to 166 GB in about 55 seconds, roughly 2 GB a second, on a Mac with 128 GB. The app alerted at every 16 GB step, but at that speed a person has seconds, not minutes. The guard covers that case.

`headroom guard run` reads every process's physical footprint once a second (`proc_pid_rusage`, the number Activity Monitor shows, which includes compressed memory) and watches two kinds of units: each process, and each command an agent ran together with its children, so a swarm of workers that each grow a little counts as one job. It stops a unit when one of these rules holds:

| Rule | When | Default |
| --- | --- | --- |
| growth | The unit grew at least 1 GB a second through the last 5 seconds, with at least 4 of the 5 one-second steps up, and holds at least 16 GB. | 1 GB/s, 5 s, 16 GB |
| ceiling | The unit holds more than 64 GB and grew over the last 5 seconds. | 64 GB |
| leak | The unit holds more than 32 GB and gained at least 8 GB over the last 2 minutes, with most 10-second steps up. | 32 GB, 8 GB, 2 min |
| low-memory | Free memory is below 10 percent: the fastest-growing unit of at least 2 GB. | 10 % |

The floors keep ordinary work alone: a 14 GB model that loads at 3.5 GB a second, a dev server that creeps up to 25 GB, a build that climbs to 9 GB over a minute, and a large process that maps 8 GB at once and then holds steady are all left running. When a job fires but one process inside it accounts for most of the growth, the guard stops that process alone, not the shell and the siblings around it.

Some work is costly to lose, such as a deploy gate that takes hours. `gentlePatterns` in `guard.json` lists text such as `/scratchpad/i223`; a process whose command line or working directory contains it is gentle. The guard never stops a job that holds a gentle process and never picks a gentle process under the low-memory rule. It still stops a gentle process on its own when it crosses the growth, ceiling or leak rule, because a single process that runs away past 16 GB takes everything else down with it. macOS does not show other processes' environments, so the mark cannot come from an environment variable.

A stop sends SIGTERM and, one second later, SIGKILL to whatever is still alive, after checking that each pid still names the process that was sampled. After a stop the guard waits 2 seconds before it stops anything else. It never stops:

- the Claude app and its helpers, or a Claude Code session;
- the Codex app (ChatGPT.app) or a `codex` process;
- an app the person opened, such as Google Chrome or a terminal (its helper processes, such as a runaway browser tab, can be stopped);
- launchd, WindowServer and processes under `/System`, `/usr/libexec`, `/usr/sbin` and `/sbin`;
- another user's processes, or Headroom itself.

Every decision becomes a `guard` event in `events.jsonl` with the rule, the process, its size and growth, the command line, and the agent session that owns it, and a notification names the same. A stopped command shows the agent exit code 143 (SIGTERM) or 137 (SIGKILL); `headroom guard status` says why.

```sh
headroom guard install          # run the guard at login with launchd (com.kevinliu.headroom.guard)
headroom guard status           # running or not, the mode, the rules, the fastest growers, recent stops
headroom guard arm              # stop runaways
headroom guard observe          # only log and announce what would be stopped
headroom guard uninstall
```

The rules live in `guard.json` beside the other files, and a missing key keeps its default:

```json
{ "armed": true, "growthGBPerSecond": 1, "windowSeconds": 5, "growthFloorGB": 16, "ceilingGB": 64,
  "leakFloorGB": 32, "leakGainGB": 8, "leakWindowSeconds": 120, "lowFreePercent": 10, "cooldownSeconds": 2,
  "gentlePatterns": ["/scratchpad/i223"] }
```

The guard rereads the file every 10 seconds. A pass over about 650 processes and jobs takes 15 to 20 ms, so the guard uses about 1 percent of one core and 14 MB. It runs apart from the app, so it keeps working when the window is closed or the app hangs.

## How agents use it

Headroom gives agents five ways to read the memory state. All five agree, because they read the same state and use the same policy.

### State files

The app writes `~/Library/Application Support/Headroom/state.json` after every sample. The file holds the advice, the reasons, the thresholds, the agents' total, the Claude and Codex totals with the part of each in the app (`appGB`) and the Codex app server's pid (`hostPid`), the system numbers, the sessions with their app and 10 minute change, the heavy jobs, the largest processes, pending requests and recent notes. Its `version` is 2. Version 2 added `snapshot.codex`, `snapshot.agents`, and `app`, `startTime` and `trendGB` on each session, and renamed the session field `inClaudeApp` to `inApp`.

`history.jsonl` in the same folder holds one line per sample for the last 60 minutes: the agents', Claude and Codex totals and free memory. The app rewrites it after each sample, so it never holds more than an hour. `events.jsonl` holds the event log.

### Command line

The `headroom` command works without the app. When `state.json` is older than 60 seconds, it samples the machine directly.

```sh
headroom status                 # advice, agent totals, free memory, sessions by app, heavy jobs
headroom status --json          # the same document as state.json
headroom can-start --gb 8       # exit 0 when an 8 GB job may start now, 1 when not
headroom wait --gb 8 --timeout 20 && ffmpeg -i in.mov out.mp4
headroom note "Encoding the launch film" --gb 6
headroom request --action pause --pid 4242 --reason "ffmpeg is at 30 GB" --wait
headroom history                # the last 60 minutes, one row per minute
headroom events --follow
headroom doctor
headroom guard status           # the runaway guard: mode, rules, fastest growers, recent stops
```

`can-start` answers yes when the advice is ok, the free memory after the job stays above the hold line, and the agents' total after the job stays below the critical line. `history --all` prints every sample and `history --json` prints the points as JSON. `wait` checks every 10 seconds and exits with code 75 when the timeout passes. `request --wait` exits 0 when the person approves and 1 when the person denies.

### Local HTTP API

The app serves an HTTP API on `127.0.0.1:7341`. It does not listen on any other address. POST endpoints need the token in `~/Library/Application Support/Headroom/token`, which has mode 0600.

```sh
curl -s localhost:7341/v1/status
curl -s 'localhost:7341/v1/can-start?gb=8&label=encode'
# {"advice":"ok","freeGB":101.2,"gb":8,"label":"encode","ok":true,"reason":"101 GB free. A job of 8.0 GB leaves 93.2 GB (73 percent)."}

TOKEN=$(cat ~/Library/Application\ Support/Headroom/token)
curl -s -X POST localhost:7341/v1/notes -H "Authorization: Bearer $TOKEN" \
  -d '{"text":"Encoding the launch film","gb":6,"label":"film"}'
curl -s -X POST localhost:7341/v1/requests -H "Authorization: Bearer $TOKEN" \
  -d '{"action":"pause","pid":4242,"reason":"ffmpeg is at 30 GB"}'
curl -s localhost:7341/v1/requests/<id>    # pending, approved, denied, failed or expired
```

A request names an action (`pause`, `resume`, `quit`, `restart-claude` or `restart-codex`), a pid for the first three, and a reason. Headroom shows it in the window and as a notification with Approve and Deny buttons. A request that nobody answers expires after 30 minutes.

### Hooks for Claude Code and Codex

`headroom hook` is a `PreToolUse` handler for the Bash tool. It follows the [Claude Code hook schema](https://code.claude.com/docs/en/hooks). `headroom hook --codex` is the same handler for [Codex hooks](https://learn.chatgpt.com/docs/hooks), which send the same input for a Bash call. It reads the hook JSON on stdin and checks whether the command is heavy: ffmpeg, a Python model run, Playwright or a browser, `next dev` or `next build`, a package build, vitest, docker, `swift build`, `xcodebuild` and similar commands.

- When the advice is ok, or the command is not heavy, the hook prints nothing and the command runs as usual.
- When the advice is hold, the hook prints `additionalContext` with the memory state. It sets no permission decision, so the command goes through the normal permission flow. Claude Code delivers the context with the command's result, so the text tells the agent to run `headroom wait` before its next heavy command or to leave that job for later.
- When the advice is critical, the Claude Code hook returns `"permissionDecision": "ask"` with the reason. The person decides whether the command runs.
- Codex parses `"ask"` in a `PreToolUse` hook but does not support it yet, and a hook that returns it fails. At critical the Codex hook therefore returns a `systemMessage` that the person sees and `additionalContext` for the agent, and the command runs. Headroom does not deny commands on its own.

The hook fails open. On any error it exits 0 with no output. It reads `state.json` and samples directly only when that file is older than 60 seconds. A command that waits for memory before its heavy part, such as `headroom wait --gb 8 && ffmpeg ...`, is not flagged again.

To test the hook at each advice level, set `HEADROOM_FORCE_ADVICE` to `ok`, `hold` or `critical`. The CLI, the hook and the MCP server then use that advice and add a reason that names the variable. The app ignores the variable.

```sh
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"pnpm build"}}' \
  | HEADROOM_FORCE_ADVICE=critical headroom hook
```

`headroom install-hook --print` prints the configuration for both agents. Headroom does not edit Claude or Codex settings. For Claude Code, add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "/Users/you/.local/bin/headroom hook", "timeout": 5 }
        ]
      }
    ]
  }
}
```

For Codex, add this to `~/.codex/config.toml`. Codex asks the person to review a new hook with `/hooks` before it runs it.

```toml
[[hooks.PreToolUse]]
matcher = "^Bash$"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "/Users/you/.local/bin/headroom hook --codex"
timeout = 5
```

### MCP server

`headroom mcp` is a stdio MCP server with four tools: `status`, `can_start`, `note` and `request`. The status names both apps, and `request` takes `restart-claude` and `restart-codex`. Add it with the Claude Code CLI or the Codex CLI:

```sh
claude mcp add --scope user headroom -- ~/.local/bin/headroom mcp
codex mcp add headroom -- ~/.local/bin/headroom mcp
```

The Codex command writes this entry to `~/.codex/config.toml`, which can also be added by hand:

```toml
[mcp_servers.headroom]
command = "/Users/you/.local/bin/headroom"
args = ["mcp"]
```

## Agent skill

`skills/headroom/SKILL.md` teaches an agent when and how to use Headroom: check `headroom can-start` before a build, a browser test run, a dev server, a model run, a long encode or more agents, wait when the advice is hold, announce large jobs, and ask the person before stopping a process the agent did not start. Copy the folder to `~/.claude/skills/headroom` for Claude Code or to `~/.codex/skills/headroom` for Codex.

## Install

Headroom needs macOS 14 or later and Swift 6. The build script builds in release, assembles `Headroom.app` with its icon, signs it ad hoc, installs it to `~/Applications`, installs the CLI to `~/.local/bin/headroom` and launches the app.

Run the script from a checkout of this repository:

```sh
scripts/build-app.sh
```

`scripts/build-app.sh --no-launch` installs without launching. `scripts/build-app.sh --no-install` only assembles `build/Headroom.app`. Launch at login stays off until it is turned on in the window.

Headroom asks for permission to post notifications at its first launch. When notifications are off, the window says so and its Turn on button opens the notification settings. Alerts still reach the log and the menu bar colour, and a crossing or an agent request opens the window. On macOS 26.4 an ad hoc or self-signed build receives the answer "Notifications are not allowed for this application", and no Headroom entry appears in the notification settings. A build signed with a Developer ID should be allowed. Set `HEADROOM_SIGN_IDENTITY` to the identity's name before running `scripts/build-app.sh` to sign with it. Until then, Headroom falls back to osascript banners.

`build-app.sh` copies the Inter font and its license into the app bundle. Run the tests with `swift test`. Render the screenshots with `~/Applications/Headroom.app/Contents/MacOS/Headroom --render docs`. From a checkout, `swift build -c release` builds the app as `.build/release/HeadroomApp`. On a case-insensitive disk `.build/release/Headroom` is the CLI. `HeadroomApp --snapshot-window <file>.png` opens the live window after one sample, writes it to the file and exits, without serving the API, posting notifications or writing state.

## Look

The window uses the tokens, type and line rules of the General Translation brand deck. Light is a white surface with ink `#070707` text and dark is an ink surface with `#f2f2f0` text. Text has three steps: ink, ink-2 and titanium. Lists are ruled rows with a 9 percent line between rows and an 18 percent line between sections, drawn edge to edge. In dark mode the lines are 10 and 22 percent, as in the deck's dark theme. Every row has one 16 point leading slot for its icon, mark or chevron, so every title starts at the same edge, and every figure ends at the same right edge. Section heads have more space under them than above them. Controls round at 6 points and the window stays square. Colour appears only on icons and the status dot: green for ok, amber for hold and red for critical. GT blue marks the current value on the chart. The chart's area is an ordered dither on an 8 by 8 Bayer screen, one cell per point, and it is the window's only texture.

The type is rsms InterVariable 4.1, bundled in `Resources/Fonts` with its SIL Open Font License and registered at launch. Weights stop at 500. The totals use tabular figures with the `cv11` and `ss01` features, and tracking tightens with size. Meaning icons are Heroicons 20 solid (MIT). The Claude mark (CC0, from thesvg.org) keeps its own colour, `#D97757`, and the Codex mark (MIT, from thesvg.org) takes the text colour. Both marks belong to their owners and label the apps they name.

## Footprint

Headroom's own memory and CPU use were measured on 2026-10-12 on a 128 GB Mac with about 1,000 processes and 12 agent sessions. Other sessions were running browser tests and model jobs at the time, and the load average was between 140 and 240, so the times are slower than on an idle Mac.

| Measure | Result | Method |
| --- | --- | --- |
| Physical footprint, window closed | 15 to 16 MB | `footprint -p <pid>` every 10 seconds for 2 minutes |
| Physical footprint, window open | 37 MB in 5 of 7 runs; 86 MB and 102 MB in the other 2, at a load average near 280 | `proc_pid_rusage` in `--snapshot-window` runs on 2026-10-13, with the window drawn after the first sample |
| CPU, window closed | 0.48 to 0.69 percent over 2 minutes | CPU time from `ps -o time` divided by wall time, in two runs |
| One sample | 83 ms for 985 processes in one run, and 980 ms for 1,013 processes at a load average of 244 | `headroom doctor`, which samples without the app's cache |
| Hook, state file fresh | 31 ms per call, including process start | median of 10 calls |

The window exists only while it is open. Closing it releases its views, so a closed window costs no memory and no drawing per sample. The hook samples directly only when `state.json` is older than 60 seconds, which happens when the app is not running.

## Privacy

Everything stays on the Mac. Headroom makes no network requests beyond its own API on `127.0.0.1`. The HTTP API listens only on `127.0.0.1`, rejects requests whose Host header names another machine, and needs a token for every POST. The state, the settings, the token and the log are files in `~/Library/Application Support/Headroom` that only the person's account can read. Headroom reads process paths, the arguments of interpreters such as node and python and of `codex` processes, the working directories of agent sessions and of the Codex app server's direct children, and the `Info.plist` of app bundles named ChatGPT or Codex to find the Codex app. `headroom doctor` reads `~/.claude/settings.json`, `~/.claude.json`, `~/.codex/config.toml` and `~/.codex/hooks.json` to report whether the hooks and the MCP server are set up, and changes none of them. The log holds process names, pids, session folder names, agent notes and the first 200 characters of each command the hook flags, and the first 400 characters of the command line of each process the guard stops or would stop. It never holds file contents.

## License

Headroom is released under the MIT license. See [LICENSE](LICENSE).
