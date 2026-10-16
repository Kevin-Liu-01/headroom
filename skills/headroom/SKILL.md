---
name: headroom
description: Check this Mac's memory before adding load, and respect what Headroom advises. Headroom is a macOS menu bar app with a `headroom` CLI. It reports how much memory the Claude and Codex apps and each agent session use, and it advises ok, hold or critical. Use before starting a build, a test run that opens browsers, a dev server, a headless browser, a local model run, a long ffmpeg encode, a container, more agents or a workflow. Also use when a Headroom hook message, an alert or the person mentions memory, hold or critical; to announce a heavy job; and to ask the person to pause, quit or resume a process you did not start. Also use at milestones to check your own session's health (`headroom session <pid>`), to save your work and hand off before your session freezes, and to clean up your own screenshots and outputs.
---

# Headroom

A Mac that runs many Claude Code and Codex sessions at once can run out of application memory, because the Claude and Codex apps own every process their sessions start. Headroom shows every agent the memory state so no agent adds load blindly. Agents never stop processes they did not start. Only Headroom's runaway guard stops processes on its own, and only processes whose memory spirals.

## Before heavy work

Heavy work is any of the following:

- A build: `next build`, `pnpm build`, `swift build` or `xcodebuild`.
- A test run that opens browsers.
- A dev server or a headless browser.
- A local model run with torch, MPS or MLX.
- An ffmpeg encode of more than a few seconds of video.
- docker.
- Starting more agents or a workflow.

1. Estimate the job's peak memory in GB, then run `headroom can-start --gb N --label <name>`. Exit 0 means start, and exit 1 means wait. The reason is printed.
2. When it says wait, run `headroom wait --gb N --timeout 30` or do lighter work first. Do not start the job anyway.
3. For a job of 4 GB or more, announce it: `headroom note "what the job is" --gb N --label <name>`. The person sees the note in the Headroom window.
4. Stop your own servers, browsers, watchers and background processes when their check is done.

## What the advice means

| Advice | When | What you do |
| --- | --- | --- |
| ok | No line is crossed. | Work normally. |
| hold | The work Claude or Codex agents started reaches its hold line, 47 percent of the Mac's memory (60 GB on a 128 GB Mac), free memory is below 30 percent, or macOS reports memory pressure while free memory is below 30 percent. | Start nothing new that is heavy. Finish or wait. |
| critical | The work Claude or Codex agents started reaches its critical line, 70 percent of the Mac's memory (90 GB on a 128 GB Mac), free memory is below 15 percent, or macOS reports critical pressure. | Start nothing heavy, stop your own heavy jobs, and tell the person. They may restart the Claude app, and all agent state is on disk. |

`headroom status` prints the advice, the Claude and Codex totals, free memory, every agent session with its working directory, and the heavy jobs. Codex runs in the ChatGPT app (bundle id com.openai.codex) and as `codex` CLI sessions. Headroom counts both, and each app's total includes its terminal sessions. `headroom status --json` gives the same data to a script.

The lines count the work agents start (builds, servers, browsers, model runs), not the sessions' own Claude Code and Codex processes. A bloated or stuck session gets a note in `headroom status` instead; it does not hold your work.

## Your own session's health: watch it, rescue yourself, clean up

Don't count on anyone rescuing your session. Unless automatic rescue is on, Headroom's guard reports a failing session but does not stop it, so look after your own. A session's process grows with its conversation, and only a fresh session frees it. On 2026-10-14 a coordinator session with fifteen subagents grew to 29 GB, with 3,700 images in a 1.8 GB conversation, and froze for hours. It answered nobody, and none of its subagents could move.

1. **Find your own session process.** Walk up from your shell with `ps -o pid=,ppid=,command= -p $$`, then each parent, until you reach the `claude` process. Never pick a process by its folder; several sessions often share one.
2. **Check yourself** at every milestone, and at least every 30–60 minutes: `headroom session <your pid>`. It shows your own process's memory, your conversation's size and image count, unread messages, subagents waiting on a tool, polling shells and health flags. Headroom's hook also warns you when a flag goes up.
3. **Act on the flags.**
   - **heavy** (conversation over 500 MB or 1,000 images) or **bloated** (own process over 16 GB): stop feeding the conversation.
     - Downscale screenshots before reading them: `sips -Z 1200 shot.png --out /tmp/shot-small.png`. Read only the region you need.
     - Have a subagent look at bulky images, logs and diffs and report back in a few lines.
     - Read files in ranges and cap command output (`| head`, `| tail`).
   - **polling**: stop loops whose result you no longer need. Wait with one background monitor, not many `until …; do sleep …; done` loops.
   - **busy** (your process keeps a CPU core busy): run fewer subagents at once.
4. **Rescue yourself before you freeze.** If you are bloated, or heavy and still growing, or your replies and tool results are slowing down, do this now, while you can still answer:
   1. Commit and push your work in progress.
   2. Write a handoff file, `HANDOFF-<date>.md`, in your repo or scratchpad. Include the goal, what is done, what is in flight, every subagent id with its task and last step, the unread messages, open questions, the exact next steps, and paths to everything.
   3. Tell the person in one short message: your session is at X GB with Y images, the handoff path, and the line that starts a fresh session: "Read <path> and continue."
   4. Keep making small progress until the person switches.
5. **Clean up after yourself as you go, without being asked.**
   - Delete your own screenshots, renders, traces and temporary files once you have used them. Keep only finals the person needs.
   - Before any large batch, run `df -h /System/Volumes/Data`. Under 30 GB free, prune your own outputs first: old screenshots, traces, and `.next` or `dist` folders in your own worktrees.
   - Never delete other sessions' files, and never empty the Trash.
6. **If you receive a Headroom recovery message,** someone rescued your session to free its memory. Read the recovery note it names, resume each subagent that was waiting on a tool by messaging its id, act on the undelivered messages, then answer the person's messages and say the session was restarted.
7. Never run `headroom rescue` on another session.
8. Chain checks with `&&`, never `;`: `headroom can-start --gb 4 && <job>`. With `;` the job starts even when the answer is no. Start as many jobs as can-start allows. Don't sit idle: when one thing waits, work on another.

## The runaway guard

The runaway guard is a background process (`headroom guard`) that samples every process once a second. When it is armed, it stops a process, or an agent's whole command, whose memory spirals:

- It grows 1 GB a second or more for 5 seconds and holds 16 GB or more.
- It holds more than 64 GB and is still growing.
- It holds more than 32 GB and gained 8 GB or more over 2 minutes, climbing all the way.
- Free memory is below 10 percent: the fastest-growing process of 2 GB or more.

It never stops the Claude or Codex apps, agent sessions, apps the person opened, system processes or other users' processes. When your command dies with exit code 143 (SIGTERM) or 137 (SIGKILL), run `headroom guard status` to see whether the guard stopped it and why. Fix the cause before you run it again; do not just retry.

## Keep bulk commands bounded

- Search for many literal strings with `rg -F -l -f patterns.txt`, or `git grep -I -F -f patterns.txt --threads 4`. Never build one huge `-E` alternation: on 2026-10-13 `git grep -l -E` with 130 names ORed together and no `-I` grew to 166 GB in under a minute.
- Always pass `-I` to `git grep` and `grep -r`, so binary files are skipped.
- Cap node with `--max-old-space-size=4096` (or `NODE_OPTIONS`) and give long scripts a timeout, so a leak fails in its own process. macOS does not enforce `ulimit -v`.
- Run a command of unknown cost on a small sample first.

## Never on your own

- Never stop processes with `pkill` or `killall` and a pattern. Record the PID when you start a process, check it with `ps -o pid,command -p <pid>`, and `kill <pid>`. On macOS, `pkill` stops reading options at the first pattern, so `pkill -f "x" -U 501` also matches every command line that contains "-U" or "501". On 2026-10-13 two such commands killed other sessions' multi-hour deploy gates and background waiters. If pkill is unavoidable, put every option first and run `pgrep -fl` with the same arguments before it.
- Do not kill, pause or quit a process that you did not start, even when Headroom shows it as the largest.
- To ask for it, run `headroom request --action pause|quit|resume|restart-claude|restart-codex --pid P --reason "one sentence"`. The person approves or denies it in the window. Add `--wait` to block until he answers.
- Your own process is yours to stop.

## Workflows and parallel agents

- There is no fixed cap on heavy jobs or agents. Check each heavy job with its own estimate, `headroom can-start --gb N && <job>`, and start as many as Headroom allows. Its lines already count what is running and how much memory is free.
- Stop each dev server, browser and watcher as soon as its check is done.
- In a torch environment on MPS, set `PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.35` and `PYTORCH_MPS_LOW_WATERMARK_RATIO=0.3`. That caps the MPS allocator near 37 GB, and a runaway model then fails in its own process.

## Commands

| Command | What it does |
| --- | --- |
| `headroom status [--json]` | The advice, the totals, the sessions and the heavy jobs |
| `headroom can-start --gb N [--label X]` | Exit 0 when a job of N GB may start now, 1 when not |
| `headroom wait --gb N [--timeout M]` | Wait until it may start. Exit 75 after M minutes. |
| `headroom note TEXT [--gb N] [--label X]` | Announce a heavy job to the person |
| `headroom sessions [--json]` | Every Claude Code session's own memory, CPU, conversation, unread messages, subagents, polls and health |
| `headroom session <pid, id or title>` | One session in full |
| `headroom request --action A --pid P --reason TEXT [--wait]` | Ask the person to approve an action |
| `headroom history [--json]` | The agents' memory over the last 60 minutes |
| `headroom events [--follow]` | The event log: samples, alerts, requests |
| `headroom doctor` | Check the app, the files, the API and the hook setup |
| `headroom guard status` | Whether the runaway guard runs, its rules, the fastest growers and its recent stops |
| `headroom guard set KEY=VALUE` | Change a guard limit (the person's call; ask before changing it) |

The same data is at `http://127.0.0.1:7341/v1/status` and `/v1/can-start?gb=N`. `headroom mcp` is a stdio MCP server with the tools status, can_start, note and request. `headroom install-hook --print` prints the Claude Code hook and the MCP configuration. The person decides whether to install them, so do not edit `~/.claude` or `~/.codex` configuration yourself.

If `headroom` is missing, read the same facts directly. Run `sysctl -n kern.memorystatus_level` for the percent of memory that is free, and `top -l 1 -o mem -n 10 -stats pid,mem,command` for the largest processes.

## Install

Copy this folder to `~/.claude/skills/headroom` for Claude Code, or to `~/.codex/skills/headroom` for Codex. Install the app and CLI from https://github.com/Kevin-Liu-01/headroom.
