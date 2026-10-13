# Headroom

![The macOS Force Quit dialog after the system ran out of application memory, with Claude at 231.98 GB](docs/out-of-memory.png)

Headroom is a macOS menu bar app that watches memory use by the Claude desktop app, its Claude Code agent sessions and every process they start. It alerts the person at the Mac when memory runs low, relays the current memory state to agents through a file, a local HTTP API, a command line tool, a Claude Code hook and an MCP server, and carries out actions only when a person clicks them. Headroom never pauses, stops or kills a process on its own.

## Screenshots

These screenshots show a made-up machine with Claude at 46.8 GB, which puts the advice at hold, and one agent request waiting for an answer. They are rendered with `Headroom --render docs --demo`. Without `--demo`, the same command renders the live state of the Mac it runs on.

| Light | Dark |
| --- | --- |
| ![Headroom window in light mode](docs/headroom-light.png) | ![Headroom window in dark mode](docs/headroom-dark.png) |

## Why it exists

The Claude desktop app owns every Claude Code session it starts. It also owns every process those sessions start: MCP servers, test runners, browsers, encoders and model runs. When 25 sessions run at once, the Force Quit dialog shows all of that memory under one name, Claude. On the Mac this app was written for, one runaway node process reached 457 GB and the system ran out of application memory twice in one day. Headroom shows which session and which process owns the memory before that happens.

## What it watches

Headroom takes a sample every 20 seconds, and every 5 seconds while memory is low. Each sample reads these values:

- Free memory from `kern.memorystatus_level`, as a percentage of total memory.
- Memory pressure from `kern.memorystatus_vm_pressure_level` and from a `DispatchSource` memory pressure source, which also triggers an immediate sample.
- Swap used from `vm.swapusage`, compressed memory from `host_statistics64` and total memory from `hw.memsize`.
- The physical footprint of every process from `proc_pid_rusage` (`RUSAGE_INFO_V4`, `ri_phys_footprint`). This is the number Activity Monitor shows.
- The parent pid, path, start time and working directory of each process from libproc.

Headroom builds the process tree from the parent pids. The Claude total is the `Claude.app` process plus all its descendants. An agent session is a Claude Code process, whose executable path contains `claude-code/` and ends in `claude`, together with its descendants. Each session is labelled by its working directory, so a person can see which project owns the memory. A process belongs to the nearest session above it, so a session started inside another session keeps its own processes.

Headroom also lists heavy jobs: browsers, model runs, encoders, builds, test runs, dev servers and containers above 256 MB. A heavy job is the topmost matching process with its whole subtree. The window also shows the memory totals of other apps and the largest processes overall.

macOS does not let an unprivileged app read the footprint of processes owned by other users, such as `WindowServer` and `kernel_task`. Headroom counts them as unreadable and leaves them out of the totals. Every Claude process belongs to the person, so the Claude total is complete.

## When it alerts

The advice is one of three levels.

| Advice | When | What it means |
| --- | --- | --- |
| ok | No line is crossed. | Agents may start heavy jobs. |
| hold | Claude uses 40 GB or more, free memory is below 30 percent, or the system reports memory pressure. | Agents start nothing new that is heavy. |
| critical | Claude uses 70 GB or more, free memory is below 15 percent, or the system reports critical pressure. | Pause heavy jobs and restart Claude. All agent state is on disk, so a restart of the app loses no work. |

The settings window changes every line. Settings are stored in `~/Library/Application Support/Headroom/settings.json`, so the CLI and the hook use the same lines as the app.

Headroom posts a notification each time the advice gets worse. The notification names the largest sessions and processes and offers three buttons: Pause heavy jobs, Restart Claude and Show. While the advice stays at hold or critical, the notification repeats every 5 minutes. When the advice returns to ok for three samples in a row, Headroom posts a recovery note. Headroom also posts a notification each time a single process crosses another 16 GB step.

When macOS does not let Headroom post its own notifications, Headroom posts the same alert as a banner through osascript, without buttons. A crossing or a new agent request also opens the Headroom window under the menu bar item, where the buttons are. The window does not take focus from the app in front.

Every sample summary, alert, note, request, decision and action is appended to `events.jsonl`. The log rotates to `events.1.jsonl` at 10 MB.

## What a person can do

The menu bar item shows the Claude total in GB next to a dot. The dot is green for ok, amber for hold and red for critical. A click opens the window. The window shows the Claude total, free memory, swap, compressed memory and pressure. It lists the agent sessions sorted by memory, and each session expands to its largest processes. It lists the heavy jobs and any pending agent requests with Approve and Deny buttons. The session and job lists show six rows each until the person clicks Show more, so the heavy jobs stay in view when many sessions run.

Each process has Pause (SIGSTOP), Resume (SIGCONT) and Quit buttons. The Quit confirmation offers Quit (SIGTERM) and Force quit (SIGKILL). For a heavy job, Pause and Force quit act on the whole process tree, and Quit sends SIGTERM to the job's top process so it can shut its children down. Every action that stops a process asks for confirmation first. Before it sends a signal, Headroom checks that the pid still belongs to the process the person saw, so a pid that the system reused after the process exited is never signalled. A paused process keeps its memory but stops growing, and the system can compress or swap that memory.

Pause heavy jobs pauses the jobs that agents and tools started. It leaves out apps that the person opened from `/Applications`, such as their own Google Chrome, and the confirmation names them. Each of those apps still has its own Pause button.

The footer has Restart Claude, Open log, Settings, Quit Headroom and a Launch at login checkbox. Restart Claude asks Claude to quit, waits for it to exit and opens it again. If Claude does not quit within 30 seconds, Headroom asks whether to force quit it. Launch at login uses `SMAppService` and is off until the person turns it on.

## How agents use it

Headroom gives agents five ways to read the memory state. All five agree, because they read the same state and use the same policy.

### State files

The app writes `~/Library/Application Support/Headroom/state.json` after every sample. The file holds the advice, the reasons, the thresholds, the Claude total, the system numbers, the sessions, the heavy jobs, the largest processes, pending requests and recent notes. `events.jsonl` in the same folder holds the history.

### Command line

The `headroom` command works without the app. When `state.json` is older than 60 seconds, it samples the machine directly.

```sh
headroom status                 # advice, Claude total, free memory, sessions, heavy jobs
headroom status --json          # the same document as state.json
headroom can-start --gb 8       # exit 0 when an 8 GB job may start now, 1 when not
headroom wait --gb 8 --timeout 20 && ffmpeg -i in.mov out.mp4
headroom note "Encoding the launch film" --gb 6
headroom request --action pause --pid 4242 --reason "ffmpeg is at 30 GB" --wait
headroom events --follow
headroom doctor
```

`can-start` answers yes when the advice is ok, the free memory after the job stays above the warning line, and the Claude total after the job stays below the critical line. `wait` checks every 10 seconds and exits with code 75 when the timeout passes. `request --wait` exits 0 when the person approves and 1 when the person denies.

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

A request names an action (`pause`, `resume`, `quit` or `restart-claude`), a pid and a reason. Headroom shows it in the window and as a notification with Approve and Deny buttons. A request that nobody answers expires after 30 minutes.

### Claude Code hook

`headroom hook` is a `PreToolUse` handler for the Bash tool. It follows the [Claude Code hook schema](https://code.claude.com/docs/en/hooks). It reads the hook JSON on stdin and checks whether the command is heavy: ffmpeg, a Python model run, Playwright or a browser, `next dev` or `next build`, a package build, vitest, docker, `swift build`, `xcodebuild` and similar commands.

- When the advice is ok, or the command is not heavy, the hook prints nothing and the command runs as usual.
- When the advice is hold, the hook prints `additionalContext` with the memory state. It sets no permission decision, so the command goes through the normal permission flow. Claude Code delivers the context with the command's result, so the text tells the agent to run `headroom wait` before its next heavy command or to leave that job for later.
- When the advice is critical, the hook returns `"permissionDecision": "ask"` with the reason. The person decides whether the command runs.

The hook fails open. On any error it exits 0 with no output. It reads `state.json` and samples directly only when that file is older than 60 seconds. A command that waits for memory before its heavy part, such as `headroom wait --gb 8 && ffmpeg ...`, is not flagged again.

To test the hook at each advice level, set `HEADROOM_FORCE_ADVICE` to `ok`, `hold` or `critical`. The CLI, the hook and the MCP server then use that advice and add a reason that names the variable. The app ignores the variable.

```sh
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"pnpm build"}}' \
  | HEADROOM_FORCE_ADVICE=critical headroom hook
```

`headroom install-hook --print` prints the snippet to add to `~/.claude/settings.json`. Headroom does not edit Claude settings.

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

### MCP server

`headroom mcp` is a stdio MCP server with four tools: `status`, `can_start`, `note` and `request`. Add it with the Claude Code CLI:

```sh
claude mcp add --scope user headroom -- ~/.local/bin/headroom mcp
```

## Install

Headroom needs macOS 14 or later and Swift 6. The build script builds in release, assembles `Headroom.app` with its icon, signs it ad hoc, installs it to `~/Applications`, installs the CLI to `~/.local/bin/headroom` and launches the app.

Run the script from a checkout of this repository:

```sh
scripts/build-app.sh
```

`scripts/build-app.sh --no-launch` installs without launching. `scripts/build-app.sh --no-install` only assembles `build/Headroom.app`. Launch at login stays off until it is turned on in the window.

Headroom asks for permission to post notifications at its first launch. When notifications are off, the window says so and its Turn on button opens the notification settings. Alerts still reach the log and the menu bar colour, and a crossing or an agent request opens the window. On macOS 26.4 an ad hoc or self-signed build receives the answer "Notifications are not allowed for this application", and no Headroom entry appears in the notification settings. A build signed with a Developer ID should be allowed. Set `HEADROOM_SIGN_IDENTITY` to the identity's name before running `scripts/build-app.sh` to sign with it. Until then, Headroom falls back to osascript banners.

Run the tests with `swift test`. Render the screenshots with `~/Applications/Headroom.app/Contents/MacOS/Headroom --render docs`.

## Footprint

Headroom's own memory and CPU use were measured on a 128 GB Mac with about 860 processes and 10 agent sessions running.

| Measure | Result | Method |
| --- | --- | --- |
| Physical footprint, window closed | 15 to 16 MB | `footprint -p <pid>` every 10 seconds for 2 minutes |
| Physical footprint, window open | 43 MB | `footprint -p <pid>` |
| CPU, window closed | 0.19 percent over 2 minutes | CPU time from `ps -o time` divided by wall time |
| CPU, window open, 5 second sampling | 0.84 percent over 2 minutes | CPU time from `ps -o time` divided by wall time |
| One sample | 50 ms for 858 processes | `headroom doctor` |
| Hook, state file fresh | 16 ms per call, including process start | median of 10 calls |
| Hook, direct sample | 38 ms per call | median of 5 calls with no state file |

The window-open measurement ran while memory crossed the hold line, so Headroom sampled every 5 seconds. The hook samples directly only when `state.json` is older than 60 seconds, which happens when the app is not running.

## Privacy

Everything stays on the Mac. Headroom makes no network requests beyond its own API on `127.0.0.1`. The HTTP API listens only on `127.0.0.1`, rejects requests whose Host header names another machine, and needs a token for every POST. The state, the settings, the token and the log are files in `~/Library/Application Support/Headroom` that only the person's account can read. Headroom reads process paths, arguments of interpreters such as node and python, and the working directories of agent sessions. The log holds process names, pids, session folder names, agent notes and the first 200 characters of each command the hook flags. It never holds file contents.

## License

Headroom is released under the MIT license. See [LICENSE](LICENSE).
