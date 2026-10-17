import Foundation

/// Restarting a Claude Code session in the desktop app frees its own process's memory, which grows with the
/// conversation. The conversation is on disk and the app resumes the session on its next message, so a restart
/// loses nothing when the session is idle: its last turn ended, nothing waits in its queue, it set no timer, and
/// no subagent or shell of its is still working. This file decides that from the process table and the tail of
/// the session's conversation file, and stops the process when asked.
public enum SessionRestart {
    /// The answer for one session.
    public struct Check: Equatable, Sendable {
        /// True when a restart loses nothing.
        public var safe: Bool
        /// Why not, in a few words, such as "replied 3 min ago" or "2 messages are queued". Empty when safe.
        public var reason: String
        /// The session's own process and its start time, checked again before a stop.
        public var pid: Int32
        public var startTime: Double
        public var label: String
        public var gb: Double

        public init(safe: Bool, reason: String, pid: Int32, startTime: Double, label: String, gb: Double) {
            self.safe = safe
            self.reason = reason
            self.pid = pid
            self.startTime = startTime
            self.label = label
            self.gb = gb
        }
    }

    /// A session has to be this quiet before a restart: its last reply, its subagents' writes and its CPU.
    public static let quiet: TimeInterval = 10 * 60
    /// Its own process's average CPU over 10 minutes stays under this, in percent of one core.
    public static let idleCPUPercent: Double = 5
    /// Tools whose work outlives the turn that called them; a restart would cancel it.
    static let timerTools: Set<String> = ["ScheduleWakeup", "CronCreate", "Monitor", "RemoteTrigger"]

    /// The sessions Headroom recommends restarting: Claude Code sessions in the desktop app whose own process
    /// holds a process step or more. A Codex thread has no process of its own, and a terminal session would
    /// not come back on its own.
    public static func candidates(_ s: Snapshot, _ t: Thresholds) -> [AgentSession] {
        s.sessions.filter { $0.app == .claude && $0.inApp && $0.pid > 0 && ($0.processGB ?? 0) >= t.processStepGB }
    }

    // MARK: The conversation

    /// What the end of a conversation file says.
    public struct Tail: Equatable, Sendable {
        /// The last turn ended with a reply, and when.
        public var endedAt: Date?
        /// Messages enqueued after the last reply that were not taken.
        public var queued: Int
        /// Tools the last turn called that keep working after it, such as ScheduleWakeup.
        public var timers: [String]
        /// False when the tail held no turn at all.
        public var known: Bool
    }

    /// Reads the JSON lines at the end of a conversation file. Pure, so tests can call it.
    public static func tail(_ data: Data) -> Tail {
        var endedAt: Date?
        var ended = false
        var known = false
        var queue: [String] = []
        var turnTools: [String] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = o["type"] as? String else { continue }
            let time = (o["timestamp"] as? String).flatMap(Format.parseISO)
            switch type {
            case "assistant":
                known = true
                let m = o["message"] as? [String: Any]
                for block in m?["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    if let name = block["name"] as? String { turnTools.append(name) }
                }
                if let stop = m?["stop_reason"] as? String, stop == "end_turn" || stop == "stop_sequence" {
                    ended = true
                    endedAt = time
                    // The queue counts again from the end of each turn: whatever waits now came in after it.
                    queue.removeAll()
                } else {
                    ended = false
                }
            case "user":
                known = true
                ended = false
                // A prompt starts a turn; a tool result continues one.
                let content = (o["message"] as? [String: Any])?["content"]
                let isResult = (content as? [[String: Any]])?.contains { $0["type"] as? String == "tool_result" } ?? false
                if !isResult { turnTools.removeAll() }
            case "queue-operation":
                let text = o["content"] as? String ?? ""
                switch o["operation"] as? String {
                case "enqueue": queue.append(text)
                case "dequeue":
                    // The session took the oldest message; the line carries no content.
                    if !queue.isEmpty { queue.removeFirst() }
                case "remove":
                    // A message taken mid-turn, named by its content. One whose enqueue lies before the tail
                    // matches nothing here.
                    if let i = queue.firstIndex(of: text) { queue.remove(at: i) }
                case "clear": queue.removeAll()
                default: break
                }
            default:
                continue
            }
        }
        return Tail(endedAt: ended ? endedAt : nil, queued: queue.count,
                    timers: Array(Set(turnTools.filter(timerTools.contains))).sorted(), known: known)
    }

    /// The session id the desktop app started the process with: --resume=<id>, --resume <id> or --session-id.
    public static func sessionID(_ args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            for flag in ["--resume", "--session-id"] {
                if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
                if a == flag, i + 1 < args.count { return args[i + 1] }
            }
        }
        return nil
    }

    /// The newest conversation file for a session id under ~/.claude/projects. A session that changed folder has
    /// one file per folder.
    public static func transcript(id: String, projects: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")) -> URL? {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
        var best: (URL, Date)?
        for d in dirs {
            let url = projects.appendingPathComponent(d).appendingPathComponent("\(id).jsonl")
            guard let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            if best == nil || m > best!.1 { best = (url, m) }
        }
        return best?.0
    }

    static func readTail(_ url: URL, bytes: UInt64 = 512 * 1024) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        guard var data = try? h.readToEnd() else { return nil }
        // Drop the first, partial line.
        if size > bytes, let nl = data.firstIndex(of: 0x0A) { data = data.suffix(from: data.index(after: nl)) }
        return data
    }

    /// The folder name Claude Code gives a working directory under ~/.claude/projects: every character that is
    /// not a letter or a digit becomes a dash.
    public static func projectFolder(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    /// A session started without --resume names its conversation file only inside the process. The file is then
    /// the one in its folder created since the process started, when there is exactly one.
    public static func transcript(cwd: String, since start: Double,
                                  projects: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")) -> URL? {
        let dir = projects.appendingPathComponent(projectFolder(cwd))
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
        let fresh = names.map { dir.appendingPathComponent($0) }.filter { url in
            guard let born = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date else { return false }
            return born.timeIntervalSince1970 >= start - 5
        }
        return fresh.count == 1 ? fresh[0] : nil
    }

    /// The newest write by any of the session's subagents, from <session>/subagents next to its conversation.
    static func newestSubagentWrite(transcript: URL) -> Date? {
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.compactMap { (try? fm.attributesOfItem(atPath: dir.appendingPathComponent($0).path))?[.modificationDate] as? Date }.max()
    }

    // MARK: The check

    static func ago(_ d: Date, _ now: Date) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        return m < 1 ? "just now" : "\(m) min ago"
    }

    /// Whether restarting `s` loses nothing now. `procs` is the process table of the same sample.
    public static func check(_ s: AgentSession, procs: [Proc], now: Date = Date(),
                             projects: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")) -> Check {
        let me = procs.first { $0.pid == s.pid }
        var c = Check(safe: false, reason: "", pid: s.pid, startTime: me?.startTime ?? s.startTime, label: s.label, gb: s.processGB ?? s.totalGB)
        func no(_ why: String) -> Check {
            c.reason = why
            return c
        }
        guard let me else { return no("its process is gone") }
        let url: URL?
        if let id = SessionRestart.sessionID(me.args ?? SystemProbe.args(s.pid) ?? []) {
            url = transcript(id: id, projects: projects)
        } else {
            url = s.cwd.flatMap { transcript(cwd: $0, since: me.startTime, projects: projects) }
        }
        guard let url, let data = readTail(url) else { return no("its conversation was not found") }
        let t = tail(data)
        guard t.known else { return no("its last turn was not found") }
        if t.queued > 0 { return no("\(t.queued) message\(t.queued == 1 ? " is" : "s are") queued") }
        guard let ended = t.endedAt else { return no("it is in the middle of a turn") }
        if now.timeIntervalSince(ended) < quiet { return no("it replied \(ago(ended, now))") }
        if !t.timers.isEmpty { return no("it set \(t.timers.joined(separator: ", "))") }
        if let w = newestSubagentWrite(transcript: url), now.timeIntervalSince(w) < quiet { return no("a subagent wrote \(ago(w, now))") }
        // Bash tool shells, in the foreground or the background, run from Claude Code's shell snapshots.
        var children: [Int32: [Proc]] = [:]
        for p in procs { children[p.ppid, default: []].append(p) }
        var stack = children[s.pid] ?? []
        while let p = stack.popLast() {
            if ["zsh", "bash", "sh"].contains(p.name), (p.args ?? SystemProbe.args(p.pid) ?? []).joined(separator: " ").contains("/.claude/shell-snapshots/") {
                return no("a shell of its is running")
            }
            stack += children[p.pid] ?? []
        }
        guard let busy = s.busyPercent else { return no("Headroom has watched it for less than 10 minutes") }
        if busy >= idleCPUPercent { return no("it used \(Int(busy)) percent of a CPU core over 10 minutes") }
        c.safe = true
        return c
    }

    // MARK: The restart

    /// Stops the session's own process: SIGTERM, then SIGKILL after `grace` seconds if it is still there. Checks
    /// first that the pid still names the same process. Blocks, so call it off the main thread. Returns an error.
    public static func stop(_ c: Check, grace: TimeInterval = 30) -> String? {
        guard let info = SystemProbe.bsdInfo(c.pid), info.uid == getuid() else { return "process \(c.pid) is gone" }
        guard info.startTime == c.startTime else { return "pid \(c.pid) is now another process" }
        guard let path = SystemProbe.path(c.pid), path.contains("claude-code/") else { return "process \(c.pid) is not a Claude Code session" }
        guard kill(c.pid, SIGTERM) == 0 else { return "could not signal process \(c.pid): \(String(cString: strerror(errno)))" }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            guard let now = SystemProbe.bsdInfo(c.pid), now.startTime == c.startTime else { return nil }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if let now = SystemProbe.bsdInfo(c.pid), now.startTime == c.startTime { kill(c.pid, SIGKILL) }
        return nil
    }
}
