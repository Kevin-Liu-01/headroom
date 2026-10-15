import Darwin
import Foundation

// Session watch. Every minute, for each Claude Code session: its own memory and CPU, its conversation (size,
// images, last reply, unread queue), its subagents (active, waiting on a tool, newest write) and its polling
// shells. The facts come from the process table and the files Claude Code writes, never from the session itself,
// so a frozen session is still described. See docs/incidents/2026-10-14-stuck-sessions.md for why.

/// A message enqueued in a session and not yet taken from its queue.
public struct QueuedMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case person, agent, session, task, other }
    public var time: Date?
    public var kind: Kind
    public var text: String
}

/// A tool call a session or subagent made that has no result yet.
public struct PendingTool: Codable, Equatable, Sendable {
    public var name: String
    public var what: String
    public var since: Date?
}

public struct WatchedSubagent: Codable, Equatable, Sendable {
    public var id: String
    public var task: String
    public var workflow: String?
    public var lastWrite: Date
    public var waiting: PendingTool?
}

/// A shell under a session that loops on `sleep` until something appears.
public struct SessionPoll: Codable, Equatable, Sendable {
    public var pid: Int32
    public var minutes: Int
    public var command: String
    /// The file it waits on, when the loop names one.
    public var watching: String?
    /// True when that file has not changed for two hours, or does not exist: the loop may never end.
    public var stale: Bool
}

public enum SessionFlag: String, Codable, Sendable, CaseIterable {
    /// Its own process keeps half a CPU core busy for 10 minutes.
    case busy
    /// Its own process holds at least the bloat line.
    case bloated
    /// Its conversation file is large or holds many images.
    case heavy
    /// It runs many polling shells, or one waiting on a file that stopped changing.
    case polling
    /// A message the person typed has waited for an answer.
    case notAnswering = "not-answering"
    /// It has work pending, and neither it nor any subagent has written for the stuck window.
    case stuck
    /// Stuck or not answering, and bloated or busy: the failure the rescue is for.
    case failing
}

public struct WatchedSession: Codable, Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var startTime: Double
    public var sessionId: String?
    public var title: String?
    public var cwd: String?
    /// True when the session runs inside the Claude desktop app, which resumes it from disk on the next message.
    public var inApp: Bool
    public var processGB: Double
    public var totalGB: Double
    public var trendGB: Double?
    public var busyPercent: Double?
    public var transcript: String?
    public var transcriptMB: Double?
    public var images: Int?
    public var lastReply: Date?
    public var lastWrite: Date?
    public var awaitingReply: Bool
    public var unread: [QueuedMessage]
    public var subagentsTotal: Int
    public var subagentsActive: Int
    public var subagentsWaiting: [WatchedSubagent]
    public var lastSubagentWrite: Date?
    public var polls: [SessionPoll]
    public var flags: [SessionFlag]
    public var notes: [String]

    public var id: Int32 { pid }
    public var label: String { title ?? (cwd.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)") }
    /// The newest sign that the session or one of its subagents did something.
    public var lastProgress: Date? { [lastReply, lastSubagentWrite].compactMap { $0 }.max() }
}

public struct SessionsDocument: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var sessions: [WatchedSession]
}

/// The lines session health is judged by. The rescue lines live in the guard's rules.
public struct SessionLines: Sendable {
    public var busyPercent: Double = 50
    public var bloatGB: Double = 16
    public var heavyTranscriptMB: Double = 500
    public var heavyImages = 1000
    public var manyPolls = 6
    public var stalePollHours: Double = 2
    public var stuckMinutes: Double = 20
    public var personWaitMinutes: Double = 30
    public var activeHours: Double = 8

    public init() {}
}

extension Paths {
    public var sessions: URL { dir.appendingPathComponent("sessions.json") }
    public var sessionsHistory: URL { dir.appendingPathComponent("sessions-history.jsonl") }
    var sessionsScan: URL { dir.appendingPathComponent("sessions-scan.json") }
    public var rescues: URL { dir.appendingPathComponent("rescues", isDirectory: true) }
    public var pendingRescues: URL { rescues.appendingPathComponent("pending", isDirectory: true) }
}

// MARK: - Reading Claude Code's files

public enum SessionFiles {
    /// Claude Code keeps a session's files under the projects folder, named by the working directory with every
    /// character other than a letter or digit turned into a dash.
    public static func projectsDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    public static func escape(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    /// The session id a desktop or `--resume` session runs, from its arguments.
    public static func sessionId(args: [String]?) -> String? {
        guard let args else { return nil }
        for (i, a) in args.enumerated() {
            if a.hasPrefix("--resume=") { return String(a.dropFirst(9)) }
            if a.hasPrefix("--session-id=") { return String(a.dropFirst(13)) }
            if (a == "--resume" || a == "-r" || a == "--session-id"), i + 1 < args.count, !args[i + 1].hasPrefix("-") { return args[i + 1] }
        }
        return nil
    }

    /// The transcript for a session id: under the working directory's folder, or found by name in any folder.
    /// The transcript for a session id: the newest file with that name in any project folder. A session that
    /// changes folder keeps writing under the folder it started in, and an older copy can sit under the new one.
    public static func transcript(sessionId: String, cwd: String?, projects: URL = projectsDir(), dirs: [URL]? = nil) -> URL? {
        let fm = FileManager.default
        let all = dirs ?? (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        var best: (URL, Date)?
        for d in all {
            let u = d.appendingPathComponent("\(sessionId).jsonl")
            guard let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { continue }
            if best == nil || m > best!.1 { best = (u, m) }
        }
        return best?.0
    }

    /// Up to `bytes` from the end of a file, starting at a line boundary.
    public static func tail(_ url: URL, bytes: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard var data = try? h.readToEnd() else { return nil }
        if start > 0, let nl = data.firstIndex(of: 0x0A) { data = data.subdata(in: data.index(after: nl)..<data.endIndex) }
        return data
    }

    static func lines(_ data: Data) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for chunk in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any] { out.append(obj) }
        }
        return out
    }

    static func date(_ obj: [String: Any]) -> Date? {
        (obj["timestamp"] as? String).flatMap(Format.parseISO)
    }

    static func kind(of text: String) -> QueuedMessage.Kind {
        let t = text.drop { $0 == " " || $0 == "\n" }
        if t.hasPrefix("<agent-message") { return .agent }
        if t.hasPrefix("<cross-session-message") { return .session }
        if t.hasPrefix("<task-notification") { return .task }
        if t.hasPrefix("<") { return .other }
        return .person
    }

    /// What the end of a conversation says: when it last replied, whether a reply is owed, and what waits in
    /// its queue. A queued entry counts as unread when it was enqueued and no later entry removed the same text.
    public static func readConversation(_ data: Data) -> (lastReply: Date?, awaitingReply: Bool, unread: [QueuedMessage], pending: PendingTool?) {
        var lastReply: Date?
        var lastAsk: Date?
        var queue: [QueuedMessage] = []
        var uses: [String: PendingTool] = [:]
        var order: [String] = []
        for obj in lines(data) {
            let type = obj["type"] as? String
            let at = date(obj)
            if type == "queue-operation" {
                let text = queuedText(obj["content"])
                switch obj["operation"] as? String {
                case "enqueue":
                    queue.append(QueuedMessage(time: at, kind: kind(of: text), text: text))
                case "dequeue":
                    if !queue.isEmpty { queue.removeFirst() }
                case "remove":
                    // A message sent with an image is enqueued without its text and removed by it.
                    if let i = queue.firstIndex(where: { $0.text == text }) ?? queue.firstIndex(where: { $0.text.isEmpty }) {
                        queue.remove(at: i)
                    }
                default:
                    break
                }
                continue
            }
            let content = (obj["message"] as? [String: Any])?["content"]
            if type == "assistant" {
                lastReply = at ?? lastReply
                for b in content as? [[String: Any]] ?? [] where b["type"] as? String == "tool_use" {
                    let id = b["id"] as? String ?? UUID().uuidString
                    uses[id] = pendingTool(b, at: at)
                    order.append(id)
                }
            } else if type == "user" {
                if let s = content as? String, kind(of: s) == .person { lastAsk = at ?? lastAsk }
                for b in content as? [[String: Any]] ?? [] {
                    if b["type"] as? String == "tool_result", let id = b["tool_use_id"] as? String {
                        uses[id] = nil
                        lastAsk = at ?? lastAsk
                    } else if b["type"] as? String == "text", let s = b["text"] as? String, kind(of: s) == .person {
                        lastAsk = at ?? lastAsk
                    }
                }
            }
        }
        let awaiting: Bool = {
            guard let ask = lastAsk else { return false }
            guard let reply = lastReply else { return true }
            return ask > reply
        }()
        let pending = order.reversed().lazy.compactMap { uses[$0] }.first
        // Anything queued before the last reply reached the session one way or another.
        let unread = queue.filter { m in
            guard let reply = lastReply else { return true }
            return (m.time ?? .distantFuture) > reply
        }
        return (lastReply, awaiting, unread, pending)
    }

    /// A queued entry's text, from a string or from text blocks; an image is noted, not copied.
    static func queuedText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in blocks {
            if b["type"] as? String == "text", let t = b["text"] as? String { parts.append(t) }
            if b["type"] as? String == "image" { parts.append("[image]") }
        }
        return parts.joined(separator: "\n")
    }

    static func pendingTool(_ b: [String: Any], at: Date?) -> PendingTool {
        let name = b["name"] as? String ?? "tool"
        let input = b["input"] as? [String: Any] ?? [:]
        let what = (input["description"] as? String) ?? (input["command"] as? String) ?? (input["prompt"] as? String) ?? ""
        return PendingTool(name: name, what: String(what.prefix(200)), since: at)
    }

    /// Counts image blocks in a byte range, for an incremental count over a growing transcript.
    public static func countImages(_ data: Data) -> Int {
        data.withUnsafeBytes { countImages(UnsafeRawBufferPointer(rebasing: $0[...])) }
    }

    static let imageNeedle = Array(#""type":"image""#.utf8)

    static func countImages(_ raw: UnsafeRawBufferPointer) -> Int {
        guard var p = raw.baseAddress else { return 0 }
        var left = raw.count
        var count = 0
        imageNeedle.withUnsafeBytes { needle in
            while left >= needle.count, let hit = memmem(p, left, needle.baseAddress, needle.count) {
                let step = p.distance(to: UnsafeRawPointer(hit)) + needle.count
                count += 1
                p += step
                left -= step
            }
        }
        return count
    }

    /// Every subagent and workflow agent transcript of a session, with its last write.
    public static func subagentFiles(sessionDir: URL) -> [(url: URL, modified: Date)] {
        let root = sessionDir.appendingPathComponent("subagents")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, Date)] = []
        for case let u as URL in e where u.pathExtension == "jsonl" && !u.lastPathComponent.hasPrefix("journal") {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            out.append((u, m))
        }
        return out
    }

    /// A subagent's task from its meta file, or from its first prompt.
    public static func subagentTask(_ url: URL) -> String {
        let meta = url.deletingPathExtension().appendingPathExtension("meta.json")
        if let d = try? Data(contentsOf: meta), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let s = obj["description"] as? String, !s.isEmpty { return s }
        return ""
    }

    public static func title(sessionDir: URL) -> String? {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent("custom-title.json")),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (obj["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Polling shells

public enum PollFinder {
    static let shells: Set<String> = ["zsh", "bash", "sh", "dash"]

    /// Long-lived shells under a session whose script loops on sleep.
    public static func polls(under root: Int32, procs: [Proc], args: (Int32) -> [String]?, now: Date,
                             minMinutes: Double = 10, staleHours: Double = 2) -> [SessionPoll] {
        var children: [Int32: [Proc]] = [:]
        for p in procs { children[p.ppid, default: []].append(p) }
        var out: [SessionPoll] = []
        var stack = children[root] ?? []
        let boot = now.timeIntervalSince1970
        while let p = stack.popLast() {
            stack.append(contentsOf: children[p.pid] ?? [])
            guard shells.contains(p.name) else { continue }
            let minutes = (boot - p.startTime) / 60
            guard minutes >= minMinutes, let a = args(p.pid) else { continue }
            let script = a.joined(separator: " ")
            guard script.contains("sleep"), script.contains("until ") || script.contains("while ") else { continue }
            let watched = watchedFile(script)
            var stale = false
            if let w = watched {
                let m = (try? FileManager.default.attributesOfItem(atPath: w)[.modificationDate]) as? Date
                stale = m.map { now.timeIntervalSince($0) > staleHours * 3600 } ?? true
            }
            out.append(SessionPoll(pid: p.pid, minutes: Int(minutes), command: loopText(script), watching: watched, stale: stale))
        }
        return out.sorted { $0.minutes > $1.minutes }
    }

    /// The loop itself, without the shell setup Claude Code puts before it.
    static func loopText(_ script: String) -> String {
        for key in ["until ", "while "] {
            if let r = script.range(of: key) { return String(script[r.lowerBound...].prefix(240)) }
        }
        return String(script.prefix(240))
    }

    /// The first absolute path in the loop's condition, with any shell variable expanded from a plain assignment.
    static func watchedFile(_ script: String) -> String? {
        let loop = loopText(script)
        var vars: [String: String] = [:]
        let assign = try? NSRegularExpression(pattern: #"(?:^|[;\s])([A-Z_][A-Z0-9_]*)=([^\s;]+)"#)
        let ns = script as NSString
        for m in assign?.matches(in: script, range: NSRange(location: 0, length: ns.length)) ?? [] {
            vars[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        let pathRe = try? NSRegularExpression(pattern: #"(\$[A-Z_][A-Z0-9_]*|\$\{[A-Z_][A-Z0-9_]*\})?(/[^\s'";)|&]+)"#)
        let condition = loop.components(separatedBy: "; do").first ?? loop
        let cn = condition as NSString
        for m in pathRe?.matches(in: condition, range: NSRange(location: 0, length: cn.length)) ?? [] {
            var path = cn.substring(with: m.range(at: 2))
            if m.range(at: 1).location != NSNotFound {
                let v = cn.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "${}"))
                guard let base = vars[v] else { continue }
                path = base + path
            }
            if path.hasPrefix("/dev/") || path.hasPrefix("/bin/") || path.hasPrefix("/usr/") { continue }
            return path
        }
        return nil
    }
}

// MARK: - Health

public enum SessionHealth {
    static func span(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 120 { return "\(m) minutes" }
        if m < 2880 { return "\(m / 60) hours" }
        return "\(m / 1440) days"
    }

    public static func judge(_ s: inout WatchedSession, lines: SessionLines = SessionLines(), now: Date) {
        var flags: [SessionFlag] = []
        var notes: [String] = []
        let busy = (s.busyPercent ?? 0) >= lines.busyPercent
        if busy { flags.append(.busy); notes.append("keeps \(Int(s.busyPercent ?? 0)) percent of a CPU core busy") }
        let bloated = s.processGB >= lines.bloatGB
        if bloated { flags.append(.bloated); notes.append("holds \(Format.gb(s.processGB)) in its own process") }
        if (s.transcriptMB ?? 0) >= lines.heavyTranscriptMB || (s.images ?? 0) >= lines.heavyImages {
            flags.append(.heavy)
            notes.append("has a \(Int(s.transcriptMB ?? 0)) MB conversation with \(s.images ?? 0) images")
        }
        let stalePolls = s.polls.filter(\.stale).count
        if s.polls.count >= lines.manyPolls || stalePolls > 0 {
            flags.append(.polling)
            notes.append("runs \(s.polls.count) polling shells" + (stalePolls > 0 ? ", \(stalePolls) waiting on files that stopped changing" : ""))
        }
        let personWaiting = s.unread.filter { $0.kind == .person }.compactMap(\.time).min()
        if let t = personWaiting, now.timeIntervalSince(t) >= lines.personWaitMinutes * 60 {
            flags.append(.notAnswering)
            notes.append("has not answered a message sent \(span(now.timeIntervalSince(t))) ago")
        }
        let hasWork = !s.unread.isEmpty || s.awaitingReply || !s.subagentsWaiting.isEmpty
        let idle = s.lastProgress.map { now.timeIntervalSince($0) } ?? .infinity
        if hasWork, idle >= lines.stuckMinutes * 60 {
            flags.append(.stuck)
            notes.append("has work pending and nothing in it has moved for \(idle.isFinite ? span(idle) : "as long as Headroom has watched")")
        }
        if (flags.contains(.stuck) || flags.contains(.notAnswering)) && (bloated || busy) { flags.append(.failing) }
        s.flags = flags
        s.notes = notes
    }

    /// One sentence for a person: "Session x holds 29.0 GB in its own process and has not answered ...".
    public static func sentence(_ s: WatchedSession) -> String {
        guard !s.notes.isEmpty else { return "Session \(s.label) is fine." }
        var text = "Session \(s.label) " + s.notes.joined(separator: ", ")
        if s.flags.contains(.failing) { text += ". It has stopped working; a rescue saves its work and frees its memory" }
        return text + "."
    }
}

// MARK: - The watcher

/// Scans the sessions once a minute and keeps what it needs between scans: each session's CPU and memory over
/// 10 minutes, and each transcript's image count so far, read incrementally.
public final class SessionWatcher {
    public var lines = SessionLines()
    let paths: Paths
    let projects: URL
    var argsOf: (Int32) -> [String]? = SystemProbe.args
    var cwdOf: (Int32) -> String? = SystemProbe.cwd
    private var samples: [String: [(t: Double, gb: Double, cpu: Double?)]] = [:]
    private var imageScan: [String: (offset: UInt64, count: Int)] = [:]
    private var historyWritten = -Double.infinity

    public init(paths: Paths = Paths(), projects: URL = SessionFiles.projectsDir()) {
        self.paths = paths
        self.projects = projects
        loadScanState()
    }

    public func scan(procs: [Proc], now: Date = Date()) -> SessionsDocument {
        let me = getuid()
        var children: [Int32: [Proc]] = [:]
        var byPid: [Int32: Proc] = [:]
        for p in procs {
            children[p.ppid, default: []].append(p)
            byPid[p.pid] = p
        }
        func subtreeGB(_ pid: Int32) -> Double {
            var total = 0.0
            var stack = [pid]
            var seen = Set<Int32>()
            while let next = stack.popLast() {
                guard seen.insert(next).inserted, let p = byPid[next] else { continue }
                total += p.gb
                stack.append(contentsOf: (children[next] ?? []).map(\.pid))
            }
            return total
        }
        func inDesktopApp(_ p: Proc) -> Bool {
            var cur = byPid[p.ppid]
            var hops = 0
            while let c = cur, hops < 12 {
                if c.path.contains("/Claude.app/") { return true }
                cur = byPid[c.ppid]
                hops += 1
            }
            return false
        }

        var out: [WatchedSession] = []
        var live = Set<String>()
        let t = now.timeIntervalSince1970
        let projectDirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for p in procs where p.uid == me && Attribution.isAgentSession(p) {
            let key = "\(p.pid):\(Int(p.startTime))"
            live.insert(key)
            var list = samples[key] ?? []
            list.append((t, p.gb, p.cpuSeconds))
            while list.count >= 2, list[1].t <= t - SessionTrends.window + 1 { list.removeFirst() }
            samples[key] = list
            var trend: Double?, busy: Double?
            if let first = list.first, first.t <= t - SessionTrends.window + 1 {
                trend = Format.round2(p.gb - first.gb)
                if let c0 = first.cpu, let c1 = p.cpuSeconds, c1 >= c0, t > first.t { busy = (100 * (c1 - c0) / (t - first.t)).rounded() }
            }
            let cwd = p.cwd ?? cwdOf(p.pid)
            let id = SessionFiles.sessionId(args: p.args ?? argsOf(p.pid))
            var s = WatchedSession(
                pid: p.pid, startTime: p.startTime, sessionId: id, title: nil, cwd: cwd, inApp: inDesktopApp(p),
                processGB: Format.round2(p.gb), totalGB: Format.round2(subtreeGB(p.pid)), trendGB: trend, busyPercent: busy,
                transcript: nil, transcriptMB: nil, images: nil, lastReply: nil, lastWrite: nil, awaitingReply: false,
                unread: [], subagentsTotal: 0, subagentsActive: 0, subagentsWaiting: [], lastSubagentWrite: nil,
                polls: PollFinder.polls(under: p.pid, procs: procs, args: argsOf, now: now, staleHours: lines.stalePollHours),
                flags: [], notes: [])
            if let id, let url = SessionFiles.transcript(sessionId: id, cwd: cwd, projects: projects, dirs: projectDirs) {
                describe(&s, transcript: url, now: now)
            }
            SessionHealth.judge(&s, lines: lines, now: now)
            out.append(s)
        }
        samples = samples.filter { live.contains($0.key) }
        out.sort { $0.processGB > $1.processGB }
        let doc = SessionsDocument(updatedAt: now, sessions: out)
        save(doc, now: now)
        return doc
    }

    func describe(_ s: inout WatchedSession, transcript url: URL, now: Date) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        s.transcript = url.path
        s.transcriptMB = Format.round2(Double(size) / 1_048_576)
        s.lastWrite = attrs?[.modificationDate] as? Date
        s.images = images(in: url, size: size)
        if let data = SessionFiles.tail(url, bytes: 512 << 10) {
            let c = SessionFiles.readConversation(data)
            s.lastReply = c.lastReply
            s.awaitingReply = c.awaitingReply
            s.unread = c.unread.map { QueuedMessage(time: $0.time, kind: $0.kind, text: String($0.text.prefix(600))) }
        }
        let dir = url.deletingPathExtension()
        s.title = SessionFiles.title(sessionDir: dir)
        let files = SessionFiles.subagentFiles(sessionDir: dir)
        s.subagentsTotal = files.count
        let active = files.filter { now.timeIntervalSince($0.modified) <= lines.activeHours * 3600 }
        s.subagentsActive = active.count
        s.lastSubagentWrite = active.map(\.modified).max()
        var waiting: [WatchedSubagent] = []
        for f in active {
            guard let data = SessionFiles.tail(f.url, bytes: 96 << 10) else { continue }
            let c = SessionFiles.readConversation(data)
            guard let pending = c.pending else { continue }
            let workflow = f.url.deletingLastPathComponent().lastPathComponent
            waiting.append(WatchedSubagent(
                id: String(f.url.deletingPathExtension().lastPathComponent.dropFirst("agent-".count)),
                task: SessionFiles.subagentTask(f.url), workflow: workflow.hasPrefix("wf_") ? workflow : nil,
                lastWrite: f.modified, waiting: pending))
        }
        s.subagentsWaiting = waiting.sorted { $0.lastWrite < $1.lastWrite }
    }

    /// Images in a transcript, counted once and then only in what was appended since.
    func images(in url: URL, size: UInt64) -> Int? {
        var state = imageScan[url.path] ?? (0, 0)
        if size < state.offset { state = (0, 0) }
        guard size > state.offset, let h = try? FileHandle(forReadingFrom: url) else { return state.offset > 0 ? state.count : nil }
        defer { try? h.close() }
        try? h.seek(toOffset: state.offset)
        var offset = state.offset
        var count = state.count
        // Whole lines only, in 8 MB reads, so a match is never split between reads.
        while offset < size {
            let used: Int = autoreleasepool {
                guard let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty else { return 0 }
                let end = chunk.lastIndex(of: 0x0A).map { chunk.distance(from: chunk.startIndex, to: $0) + 1 } ?? chunk.count
                count += chunk.withUnsafeBytes { SessionFiles.countImages(UnsafeRawBufferPointer(rebasing: $0[0..<end])) }
                return end
            }
            guard used > 0 else { break }
            offset += UInt64(used)
            try? h.seek(toOffset: offset)
        }
        imageScan[url.path] = (offset, count)
        return count
    }

    // MARK: Files

    struct ScanState: Codable { var path: String; var offset: UInt64; var count: Int }

    func loadScanState() {
        guard let d = try? Data(contentsOf: paths.sessionsScan),
              let list = try? JSONDecoder().decode([ScanState].self, from: d) else { return }
        for s in list { imageScan[s.path] = (s.offset, s.count) }
    }

    func save(_ doc: SessionsDocument, now: Date) {
        paths.ensureDir()
        if let data = try? JSON.encoder(pretty: true).encode(doc) { try? data.write(to: paths.sessions, options: .atomic) }
        let state = imageScan.map { ScanState(path: $0.key, offset: $0.value.offset, count: $0.value.count) }
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: paths.sessionsScan, options: .atomic) }
        // One history row per session a minute, kept for two days.
        let t = now.timeIntervalSince1970
        guard t - historyWritten >= 55 else { return }
        historyWritten = t
        var rows = Data()
        for s in doc.sessions {
            let row: [String: Any] = [
                "time": Format.iso(now), "pid": Int(s.pid), "session": s.sessionId ?? "", "title": s.title ?? "",
                "gb": s.processGB, "totalGB": s.totalGB, "busy": s.busyPercent ?? -1, "transcriptMB": s.transcriptMB ?? -1,
                "images": s.images ?? -1, "unread": s.unread.count, "waiting": s.subagentsWaiting.count,
                "polls": s.polls.count, "flags": s.flags.map(\.rawValue),
            ]
            if let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) {
                rows.append(line)
                rows.append(0x0A)
            }
        }
        Store.appendRaw(rows, to: paths.sessionsHistory, keepSeconds: 2 * 86_400, now: now)
    }

    public static func read(paths: Paths = Paths()) -> SessionsDocument? {
        guard let d = try? Data(contentsOf: paths.sessions) else { return nil }
        return try? JSON.decoder().decode(SessionsDocument.self, from: d)
    }
}
