# Two stuck agent sessions, and a rescue that lost no work

October 14, 2026. A 128 GB Mac running about a dozen Claude Code sessions in the Claude desktop app.

This is a full account of what happened, what was measured, what went wrong while fixing it and what Headroom
does about it now. Names of projects, sessions and people are left out; the numbers are as measured.

## Summary

Two long-running sessions stopped answering their person, and between them held 74 GB in their own processes.
Headroom reported "critical" because it counted that memory against every agent, so the agents that follow
Headroom's advice stopped starting work too. One session was frozen: nothing inside it had moved for hours. The
other was busy but alive. The frozen one was restarted after its in-flight work and undelivered messages were
written to disk, and it was told how to pick everything up again. It resumed its conversation and all fifteen of
its in-flight subagents within minutes, and its process went from 29 GB to 3 GB. No work was lost.

## What the person saw

- A coordinator session showed a turn running for 1 h 26 min that had produced 188 tokens, with "27 running
  tasks". Two messages typed into it waited behind that turn: a request, then "hello?".
- A research session had not replied since early afternoon.
- Other agents reported that Headroom said "critical" and held their work.

## What the numbers were

At the worst point:

| | Coordinator session | Research session |
|---|---|---|
| Own process footprint (Activity Monitor's number) | 22 to 29 GB | 52 to 59 GB |
| Growth over 10 minutes | +4.8 GB | +11.2 GB |
| CPU of the session process | 60 to 150 percent | 140 to 500 percent |
| Main conversation transcript | 1.8 GB, 232,000 lines | 37 MB |
| Images in the main transcript | 3,689 (1.37 GB, 75 percent of it) | few |
| Subagent and workflow transcripts on disk | 1,566 files, 14 GB | 459 files, 2 GB |
| Background tasks over the session's life | dozens | 718 |
| Session age | two days | two days |

The whole Mac: Claude's processes 106 GB, 52 percent of memory free, 52 GB compressed, swap 0.5 GB, macOS pressure
"warning". For comparison, the idle sessions on the same Mac used 0 to 8 CPU seconds in two minutes (0 to 7
percent of a core) and 0.2 to 0.9 GB each.

## Why Headroom said critical while half the memory was free

Headroom's hold and critical lines compared each agent app's total footprint with a line (Claude: hold at 80 GB,
critical at 100 GB on this Mac). The total included the two session processes' own memory. That memory was
mostly idle heap that macOS had compressed, so free memory stayed at 52 percent. Waiting does not shrink a
session's heap, so every agent that waited for "ok" would have waited until a person restarted those sessions.
The pressure "warning" added a hold of its own for the same reason: the compressor was holding the idle heaps.

## How the sessions were diagnosed

1. **Which process is which.** Every session runs one `claude` process, started by the desktop app with
   `--resume=<session id>`. That id names the session's live transcript,
   `~/.claude/projects/<escaped working directory>/<id>.jsonl`, and its folder of subagent transcripts.
   The working directory alone is not enough: several sessions shared one folder.
2. **Is it working or stuck?** A three-second `sample` of each process showed the main thread busy in every
   sample, deep in JIT-compiled JavaScript, never back in the event loop's `kevent` wait. The heap helper
   (garbage collector) threads were mostly waiting. So the busy thread was JavaScript work, not collection, and a
   process whose event loop never turns cannot read a message.
3. **When did it last do anything?** The transcript tail showed the coordinator's last step at 15:09: a browser
   `find` returned a result and the next model request was never sent. Everything after it was queue entries:
   task notifications, two subagents' reports, seven messages from another session and the person's messages.
4. **Are the subagents still working?** This decided the method. The newest subagent transcript lines in the
   coordinator were `tool_use` entries for commands such as `sed -n`, `head`, `date` and `git push`, issued 15 to
   103 minutes earlier with no result and no process running them. Subagents run inside the session's process,
   so a frozen main thread freezes all of them. In the research session, by contrast, workflow agents had written
   less than a minute earlier: it was busy, not frozen.
5. **What filled it.** The coordinator's transcript was three quarters images: screenshots and renders read into
   the conversation over two days. Its process had also hosted more than 1,500 subagent and workflow agents. The
   research session's main transcript was small; its memory came from 459 workflow and subagent runs inside one
   process and hundreds of background tasks.
6. **Polling.** Twelve background shells under the coordinator ran `until grep -q <marker> <log>; do sleep 30;
   done` loops, waiting for markers that two capture chains had stopped producing hours before (their logs last
   changed at 12:37 and 15:18). Each loop woke every 5 to 30 seconds.

## What was done, in order

1. The advice fix: the lines now measure each app's total without its session processes (the work its agents
   started), a pressure warning holds only when free memory is below its own hold line, and each bloated or busy
   session gets a note that does not raise the advice. Agents could start work again.
2. The twelve polling shells were stopped by exact process id after checking each one's parent and command.
3. The person was asked before anything touched a session. Their concern was the subagents and
   sub-conversations inside each session.
4. The coordinator's main turn was interrupted from the desktop app (the same as pressing Stop). The process
   handled the interrupt, which showed its event loop still turned slowly, but it never started the next turn
   and no subagent moved.
5. **The recovery ledger** was written before the restart:
   - every subagent active in the last 8 hours: its id, its task, minutes since its last write, and its pending
     step if it was waiting on a tool (15 of 28 were);
   - every queued entry that was enqueued but never removed (19: the person's three messages, two subagent
     reports, seven messages from another session and seven task notifications), word for word;
   - a readable Markdown version with instructions in order.
6. The process received SIGTERM after a check that its arguments still named the same session. It exited in
   9 seconds. The desktop app started a new process for the session with the same `--resume` id.
7. A message to the session gave the recovery note's path and the order: resume each in-flight subagent by
   messaging its id, act on the undelivered messages, then answer the person.
8. Within five minutes the session had written 49 messages, 16 subagent transcripts had new entries, and its
   process held 3.2 GB at 15 percent CPU.

The research session was left alone because it was working. Its process exited by itself shortly afterwards at
59 GB; the desktop app relaunched it and it restarted its own workflows.

## What went wrong during the fix

- **The wrong process was taken for the fixing session's own.** The fixing agent assumed a 23 GB process in its
  own working directory was itself, and stopped twelve polling shells under it as "its own". They belonged to the
  coordinator. They were only watchers, the chains they watched kept running, and the coordinator was told to
  re-check those chains, but the assumption was wrong. The fix: find your own session process by walking up
  from your own shell (`$$`, then each parent), never by matching a folder.
- **A memory check was chained with `;` instead of `&&`.** `headroom can-start` said "no", and the next command
  started anyway. The job was small and memory recovered within a minute, but the check did nothing.
- **An automatic restart of idle sessions was proposed and dropped.** The person wanted conversations and turns
  kept, and a restart should never be the first answer. What remained is narrower: rescue only a session that
  has stopped working, after saving everything it was doing.

## What Headroom does now

- **Lines measure work.** A session's own process does not count toward the hold and critical lines. Free
  memory and pressure still count everything.
- **Session watch.** Every minute Headroom records, for each Claude Code session, its own memory and CPU, its
  transcript's size, image count and last write, its unread queue, its subagents (active, waiting on a tool,
  newest write) and its polling shells. The latest record and a two-day history are kept on disk, and
  `headroom sessions`, the API and the window show them.
- **Health.** A session is busy when its process keeps half a core for 10 minutes, bloated past a size,
  polling when it runs many sleep loops, and stuck when it has work pending and neither it nor any subagent has
  written for 20 minutes. Stuck and bloated together is a failure.
- **Rescue: save the work, clear the memory.** For a failed session, Headroom writes the recovery ledger, stops
  the session process, and leaves a recovery note that the session receives when it next starts. The guard does
  this by itself for failures when it is armed; `headroom rescue` does it on request, and `--dry-run` only
  writes the ledger.
- **Prevention.** Agents are warned before they make it worse: the hook tells a session when it is bloated, when
  its transcript is large or image-heavy, or when it runs many polling shells, and the skill tells agents to
  keep coordinators lean, use one monitor instead of many sleep loops, and read images at reduced size.
