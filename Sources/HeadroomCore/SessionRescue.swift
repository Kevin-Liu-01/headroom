import Darwin
import Foundation

// Rescue: save the work, then clear the memory. For a session that has stopped working (stuck or not answering)
// while it holds a lot of memory or a CPU core, Headroom writes down everything the session was doing, stops its
// process, and leaves a recovery note the session receives when it next starts. The desktop app resumes the
// conversation from disk. Nothing the session finished is touched; what it was in the middle of is written down
// so it can pick it up again. See docs/incidents/2026-10-14-stuck-sessions.md.

public struct RescueLedger: Codable, Equatable, Sendable {
    public var written: Date
    public var reason: String
    public var pid: Int32
    public var sessionId: String
    public var title: String?
    public var cwd: String?
    public var inApp: Bool
    public var processGB: Double
    public var transcript: String?
    public var notes: [String]
    /// Messages enqueued and never delivered: the person's, other agents', other sessions' and task notices.
    public var unread: [QueuedMessage]
    public var subagentsWaiting: [WatchedSubagent]
    public var subagentsRecent: [WatchedSubagent]
    public var polls: [SessionPoll]
    /// Processes under the session that stop with it.
    public var children: [String]
    /// What the session is told when it next starts.
    public var resumeMessage: String
}

public struct RescueResult: Sendable {
    public var ledger: RescueLedger
    public var json: URL
    public var markdown: URL
    public var stopped: Bool
    public var freedGB: Double
}

public enum SessionRescue {
    /// Writes the ledger and, unless `stop` is false, stops the session process. Refuses when the process no
    /// longer runs the same session.
    public static func rescue(_ s: WatchedSession, procs: [Proc], paths: Paths, reason: String, stop: Bool,
                              now: Date = Date(), activeHours: Double = 8) throws -> RescueResult {
        guard let id = s.sessionId else { throw RescueError.noSession(s.pid) }
        let stamp = stampFormatter.string(from: now)
        try FileManager.default.createDirectory(at: paths.pendingRescues, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let base = paths.rescues.appendingPathComponent("\(id)-\(stamp)")
        let json = base.appendingPathExtension("json")
        let md = base.appendingPathExtension("md")
        let ledger = makeLedger(s, sessionId: id, procs: procs, reason: reason, note: md.path, now: now, activeHours: activeHours)
        try JSON.encoder(pretty: true).encode(ledger).write(to: json, options: .atomic)
        try Data(markdown(ledger, json: json).utf8).write(to: md, options: .atomic)

        var stopped = false
        var freed = 0.0
        if stop {
            guard stillSameSession(s, sessionId: id) else { throw RescueError.changed(s.pid) }
            // The note goes in place first, so the session finds it however it restarts.
            let pending = PendingRescue(sessionId: id, note: md.path, ledger: json.path, written: now, message: ledger.resumeMessage)
            try JSON.encoder(pretty: true).encode(pending).write(to: paths.pendingRescues.appendingPathComponent("\(id).json"), options: .atomic)
            stopped = terminate(s.pid, startTime: s.startTime)
            freed = stopped ? s.processGB : 0
        }
        Store.appendEvent("rescue", [
            "action": stop ? (stopped ? "stopped" : "stop-failed") : "ledger", "pid": Int(s.pid), "session": id,
            "title": s.title ?? "", "gb": s.processGB, "reason": reason, "unread": ledger.unread.count,
            "waiting": ledger.subagentsWaiting.count, "ledger": json.path,
        ], paths: paths, now: now)
        return RescueResult(ledger: ledger, json: json, markdown: md, stopped: stopped, freedGB: freed)
    }

    public enum RescueError: Error, CustomStringConvertible {
        case noSession(Int32), changed(Int32)
        public var description: String {
            switch self {
            case .noSession(let p): "process \(p) runs no session Headroom can identify, so its work cannot be saved"
            case .changed(let p): "process \(p) no longer runs the same session; nothing was stopped"
            }
        }
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func makeLedger(_ s: WatchedSession, sessionId: String, procs: [Proc], reason: String, note: String, now: Date,
                           activeHours: Double) -> RescueLedger {
        var unread = s.unread
        var waiting = s.subagentsWaiting
        var recent: [WatchedSubagent] = []
        if let path = s.transcript {
            let url = URL(fileURLWithPath: path)
            // A deeper read than the watch makes, so long-queued messages are kept in full.
            if let data = SessionFiles.tail(url, bytes: 48 << 20) { unread = SessionFiles.readConversation(data).unread }
            let dir = url.deletingPathExtension()
            waiting = []
            for f in SessionFiles.subagentFiles(sessionDir: dir) where now.timeIntervalSince(f.modified) <= activeHours * 3600 {
                let agent = String(f.url.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
                let workflow = f.url.deletingLastPathComponent().lastPathComponent
                let pending = SessionFiles.tail(f.url, bytes: 256 << 10).flatMap { SessionFiles.readConversation($0).pending }
                let entry = WatchedSubagent(id: agent, task: SessionFiles.subagentTask(f.url),
                                            workflow: workflow.hasPrefix("wf_") ? workflow : nil, lastWrite: f.modified, waiting: pending)
                if pending != nil { waiting.append(entry) } else { recent.append(entry) }
            }
            waiting.sort { $0.lastWrite < $1.lastWrite }
            recent.sort { $0.lastWrite > $1.lastWrite }
        }
        var children: [String] = []
        var byParent: [Int32: [Proc]] = [:]
        for p in procs { byParent[p.ppid, default: []].append(p) }
        var stack = byParent[s.pid] ?? []
        while let p = stack.popLast() {
            stack.append(contentsOf: byParent[p.pid] ?? [])
            let cmd = (p.args ?? SystemProbe.args(p.pid) ?? [p.name]).joined(separator: " ")
            children.append("\(p.pid) \(String(cmd.prefix(200)))")
        }
        let person = unread.filter { $0.kind == .person }.count
        let message = """
        Headroom restarted this session's process because it had stopped working: \(reason). \
        Your conversation and every subagent transcript are on disk. Before anything else, read the recovery note at \
        \(note) and follow it: resume the \(waiting.count) subagents that were waiting on a tool \
        by messaging their ids, act on the \(unread.count - person) undelivered agent, session and task messages, then \
        answer the person's \(person) unread message\(person == 1 ? "" : "s") and tell them you were restarted.
        """
        return RescueLedger(written: now, reason: reason, pid: s.pid, sessionId: sessionId, title: s.title, cwd: s.cwd,
                            inApp: s.inApp, processGB: s.processGB, transcript: s.transcript, notes: s.notes,
                            unread: unread, subagentsWaiting: waiting, subagentsRecent: recent, polls: s.polls,
                            children: children, resumeMessage: message)
    }

    /// The note for the session: what happened, what to do in order, and everything it needs word for word.
    public static func markdown(_ l: RescueLedger, json: URL) -> String {
        var md: [String] = []
        md.append("# Recovery note: Headroom restarted this session")
        md.append("")
        md.append("Written \(Format.iso(l.written)). The session process (pid \(l.pid)) had stopped working: \(l.reason). It held \(Format.gb(l.processGB)) in its own process. Headroom wrote down what it was doing, then stopped it to free that memory. The conversation, every subagent transcript and every file on disk are untouched. Processes that ran under the session stopped with it and are listed below.")
        md.append("")
        md.append("Do these in order:")
        md.append("")
        md.append("1. Resume each subagent below that was waiting on a tool, by messaging its id. Its last step never finished, so tell it to run or check that step again.")
        md.append("2. Read the undelivered messages from other agents, other sessions and tasks, and act on them.")
        md.append("3. Answer the person's messages, which are copied word for word below, and tell them the session was restarted.")
        md.append("4. Start again any polling or background job below that is still needed, with one monitor rather than many sleep loops.")
        md.append("")
        let person = l.unread.filter { $0.kind == .person }
        md.append("## The person's unread messages (\(person.count))")
        md.append("")
        if person.isEmpty { md.append("None.") }
        for m in person {
            md.append("- \(m.time.map(Format.iso) ?? "unknown time"):")
            md.append("")
            md.append(fence(m.text))
            md.append("")
        }
        md.append("## Subagents waiting on a tool (\(l.subagentsWaiting.count))")
        md.append("")
        if l.subagentsWaiting.isEmpty {
            md.append("None.")
        } else {
            md.append("| agent id | task | last write | waiting on |")
            md.append("|---|---|---|---|")
            for a in l.subagentsWaiting {
                let w = a.waiting.map { "\($0.name): \($0.what)" } ?? ""
                md.append("| \(a.id) | \(cell(a.task))\(a.workflow.map { " (\($0))" } ?? "") | \(Format.iso(a.lastWrite)) | \(cell(w)) |")
            }
        }
        md.append("")
        md.append("## Other subagents active in the last hours (\(l.subagentsRecent.count))")
        md.append("")
        if l.subagentsRecent.isEmpty { md.append("None.") }
        for a in l.subagentsRecent.prefix(60) {
            md.append("- \(a.id): \(a.task.isEmpty ? "(no description)" : a.task)\(a.workflow.map { " (\($0))" } ?? ""), last write \(Format.iso(a.lastWrite))")
        }
        md.append("")
        md.append("## Polling shells and processes that stopped with the session")
        md.append("")
        if l.polls.isEmpty && l.children.isEmpty { md.append("None.") }
        for p in l.polls {
            md.append("- poll, \(p.minutes) min old\(p.watching.map { ", waiting on \($0)" } ?? "")\(p.stale ? " (that file had stopped changing)" : ""): `\(p.command.replacingOccurrences(of: "`", with: "'"))`")
        }
        for c in l.children where !l.polls.contains(where: { c.hasPrefix("\($0.pid) ") }) {
            md.append("- `\(c.replacingOccurrences(of: "`", with: "'"))`")
        }
        md.append("")
        let others = l.unread.filter { $0.kind != .person }
        md.append("## Undelivered messages from agents, sessions and tasks (\(others.count))")
        md.append("")
        if others.isEmpty { md.append("None.") }
        for m in others {
            md.append("### \(m.kind.rawValue), \(m.time.map(Format.iso) ?? "unknown time")")
            md.append("")
            md.append(fence(m.text))
            md.append("")
        }
        md.append("Machine-readable copy: `\(json.path)`")
        return md.joined(separator: "\n") + "\n"
    }

    static func fence(_ text: String) -> String {
        let ticks = text.contains("```") ? "````" : "```"
        return "\(ticks)\n\(text)\n\(ticks)"
    }

    static func cell(_ text: String) -> String {
        String(text.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ").prefix(200))
    }

    /// True when the pid still runs the session it ran when it was judged.
    static func stillSameSession(_ s: WatchedSession, sessionId: String) -> Bool {
        guard let info = SystemProbe.bsdInfo(s.pid), abs(info.startTime - s.startTime) < 1 else { return false }
        return SessionFiles.sessionId(args: SystemProbe.args(s.pid)) == sessionId
    }

    /// SIGTERM, then SIGKILL after 30 seconds. True once the process is gone.
    static func terminate(_ pid: Int32, startTime: Double) -> Bool {
        func alive() -> Bool { SystemProbe.bsdInfo(pid).map { abs($0.startTime - startTime) < 1 } ?? false }
        guard alive() else { return true }
        kill(pid, SIGTERM)
        for _ in 0..<60 {
            usleep(500_000)
            if !alive() { return true }
        }
        kill(pid, SIGKILL)
        usleep(500_000)
        return !alive()
    }
}

/// A recovery note waiting for its session to start again.
public struct PendingRescue: Codable, Equatable, Sendable {
    public var sessionId: String
    public var note: String
    public var ledger: String
    public var written: Date
    public var message: String

    /// The pending note for a session, if one waits. Taking it moves it to delivered/ so it is given once.
    public static func take(sessionId: String, paths: Paths) -> PendingRescue? {
        let url = paths.pendingRescues.appendingPathComponent("\(sessionId).json")
        guard let d = try? Data(contentsOf: url), let p = try? JSON.decoder().decode(PendingRescue.self, from: d) else { return nil }
        let done = paths.rescues.appendingPathComponent("delivered", isDirectory: true)
        try? FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        let target = done.appendingPathComponent("\(sessionId)-\(Int(Date().timeIntervalSince1970)).json")
        if (try? FileManager.default.moveItem(at: url, to: target)) == nil { try? FileManager.default.removeItem(at: url) }
        return p
    }
}
