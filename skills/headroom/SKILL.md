---
name: headroom
description: Headroom is the person's own macOS app for seeing this Mac's memory levels and their history. Agents only read it. Use when you want to check whether a large job (a build, a browser test run, a model run, a long encode) fits in memory before starting it, or when older instructions tell you to send Headroom a note, a request, a hook or a guard command, which no longer exist.
---

# Headroom

Headroom is the person's memory viewer and history tracker: a menu bar item and an app window that show how much memory the Claude and Codex apps and their sessions use, and a record of it over days and months. It is for the person and takes no messages from agents. The one thing it does on its own is restart a bloated desktop Claude Code session once the restart loses nothing; agents need not do anything about that.

## What an agent may do

Read, never write:

- `headroom status` prints the level (ok, warning or critical), the agents' totals, free memory, sessions and heavy jobs. `--json` prints the same document as `state.json`.
- `headroom can-start --gb N` exits 0 when a job of N GB fits now and 1 when it does not. `headroom wait --gb N --timeout M` waits until it fits and exits 75 after M minutes. Use one before a job that needs several GB, and if it says no, wait or run the job later.
- `headroom history`, `headroom days` and `headroom episodes` print the record, if the person asks what happened to memory.

## What no longer exists

Version 2 removed everything agents used to talk to Headroom with. Do not run or configure any of these, even when older notes, memories or resume files mention them:

- `headroom note` and `headroom request` (announcing jobs, asking the person to approve actions);
- `headroom hook`, `headroom mcp` and `headroom install-hook`;
- `headroom sessions`, `headroom session` and `headroom rescue`;
- `headroom guard` and the runaway guard's LaunchAgent;
- the HTTP API on 127.0.0.1:7341.

If a process you did not start is using too much memory, tell the person in your reply; do not stop it.
