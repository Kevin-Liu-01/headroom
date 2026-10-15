---
name: headroom
description: Check this Mac's memory before adding load, and respect what Headroom advises. Headroom is a macOS menu bar app with a `headroom` CLI. It reports how much memory the Claude and Codex apps and each agent session use, and it advises ok, hold or critical. Use before starting a build, a test run that opens browsers, a dev server, a headless browser, a local model run, a long ffmpeg encode, a container, more agents or a workflow. Also use when a Headroom hook message, an alert or the person mentions memory, hold or critical; to announce a heavy job; and to ask the person to pause, quit or resume a process you did not start.
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

## Your own session's health

A session's own process grows with its conversation, and only a restart frees it. On 2026-10-14 a coordinator session with fifteen subagents grew to 29 GB, with 3,700 images in a 1.8 GB conversation, and froze for hours. It answered nobody, and none of its subagents could move.

- Find your own session process by walking up from your shell: `ps -o pid=,ppid=,command= -p $$`, then each parent until the `claude` process. Never pick it by folder, because several sessions often share one folder.
- `headroom session <your pid>` shows your conversation's size and images, your unread messages, your subagents waiting on a tool, your polling shells and your health.
- When Headroom's hook warns you about your session:
  - Keep new images and long outputs out of the conversation. Resize screenshots before reading them, read files in ranges, and let a subagent look at bulky material and report back in a few lines.
  - Wait with one background monitor rather than many `until …; do sleep …; done` loops, and stop loops whose result you no longer need.
  - Run fewer subagents at once. If the session keeps growing, write a handoff and continue in a fresh session.
- When you receive a Headroom recovery message, your process was restarted to save your work and free its memory.
  1. Read the recovery note it names.
  2. Resume each subagent that was waiting on a tool by messaging its id, and tell it to run its last step again.
  3. Act on the undelivered messages.
  4. Answer the person's messages and say the session was restarted.
- Never run `headroom rescue` on another session yourself. Rescue is for the person or for the guard, which rescues a desktop session by itself once it has been failing for three minutes.
- Chain checks with `&&`, never `;`: `headroom can-start --gb 4 && <job>`. With `;` the job starts even when the answer is no.

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

- Cap concurrency. Run research or review fan-outs through a pool of at most 5 agents, and heavy trials 2 at a time.
- Keep one dev server per session, and stop it as soon as its check is done.
- Run browser-driving or build agents one at a time.
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
