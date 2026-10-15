import Foundation

/// One point of the memory history: the totals of one sample.
public struct HistoryPoint: Codable, Equatable, Sendable {
    /// Seconds since 1970.
    public var t: Double
    public var agents: Double
    public var claude: Double
    public var codex: Double
    public var free: Int

    public init(t: Double, agents: Double, claude: Double, codex: Double, free: Int) {
        self.t = t
        self.agents = agents
        self.claude = claude
        self.codex = codex
        self.free = free
    }

    public init(_ s: Snapshot) {
        self.init(t: s.time.timeIntervalSince1970, agents: s.agents.totalGB, claude: s.claude.totalGB,
                  codex: s.codex.totalGB, free: s.system.freePercent)
    }

    public var time: Date { Date(timeIntervalSince1970: t) }
}

/// The last 60 minutes of samples. The app keeps them in memory and in history.jsonl, which it rewrites
/// after each sample, so the file never holds more than the window.
public struct History: Sendable {
    public static let window: TimeInterval = 60 * 60
    /// At the fastest sampling, one point every 2 seconds, the window holds 1800 points.
    public static let maxPoints = 1800

    public private(set) var points: [HistoryPoint] = []

    public init(points: [HistoryPoint] = []) {
        self.points = points.sorted { $0.t < $1.t }
        prune(now: self.points.last?.t ?? 0)
    }

    public mutating func append(_ p: HistoryPoint) {
        if let last = points.last, p.t <= last.t { points.removeAll { $0.t >= p.t } }
        points.append(p)
        prune(now: p.t)
    }

    mutating func prune(now: Double) {
        let cutoff = now - History.window
        if let first = points.firstIndex(where: { $0.t >= cutoff }), first > 0 { points.removeFirst(first) }
        if points.count > History.maxPoints { points.removeFirst(points.count - History.maxPoints) }
    }

    /// One point per minute, the last of each minute, for the CLI.
    public func perMinute() -> [HistoryPoint] {
        var out: [HistoryPoint] = []
        for p in points {
            if let last = out.last, Int(last.t / 60) == Int(p.t / 60) { out[out.count - 1] = p } else { out.append(p) }
        }
        return out
    }

    // MARK: File

    public static func read(paths: Paths, now: Date = Date()) -> History {
        guard let text = try? String(contentsOf: paths.history, encoding: .utf8) else { return History() }
        let d = JSONDecoder()
        let cutoff = now.timeIntervalSince1970 - window
        let pts = text.split(separator: "\n").compactMap { try? d.decode(HistoryPoint.self, from: Data($0.utf8)) }
            .filter { $0.t >= cutoff }
        return History(points: pts)
    }

    public func write(paths: Paths) {
        paths.ensureDir()
        var out = ""
        out.reserveCapacity(points.count * 72)
        for p in points {
            out += String(format: "{\"agents\":%.2f,\"claude\":%.2f,\"codex\":%.2f,\"free\":%d,\"t\":%.0f}\n",
                          p.agents, p.claude, p.codex, p.free, p.t)
        }
        try? Data(out.utf8).write(to: paths.history, options: .atomic)
        chmod(paths.history.path, 0o600)
    }
}

extension History {
    /// The change of a total over the last `span` seconds: the newest point minus the newest point at or before
    /// `span` seconds earlier. Nil until the history covers the span.
    public func change(over span: TimeInterval = SessionTrends.window, _ value: (HistoryPoint) -> Double) -> Double? {
        History.change(in: points, over: span, value)
    }

    /// The same for points sorted by time.
    public static func change(in points: [HistoryPoint], over span: TimeInterval = SessionTrends.window,
                              _ value: (HistoryPoint) -> Double) -> Double? {
        guard let last = points.last else { return nil }
        guard let then = points.last(where: { $0.t <= last.t - span + 1 }) else { return nil }
        return Format.round2(value(last) - value(then))
    }
}

/// Each session's memory and CPU over the last 10 minutes, in memory only. Gives the change beside each session
/// and how busy its own process has been.
public struct SessionTrends: Sendable {
    public static let window: TimeInterval = 10 * 60

    private var series: [String: [(t: Double, gb: Double, cpu: Double?)]] = [:]

    public init() {}

    static func key(_ s: AgentSession) -> String { "\(s.pid):\(Int(s.startTime))" }

    /// Records the sessions of a snapshot and sets each session's trendGB, the change since the newest sample
    /// at or before 10 minutes ago, and busyPercent, its own process's average CPU since then. A session watched
    /// for less than 10 minutes has neither yet.
    public mutating func apply(to snap: inout Snapshot) {
        let now = snap.time.timeIntervalSince1970
        let cutoff = now - SessionTrends.window + 1
        var live = Set<String>()
        for i in snap.sessions.indices {
            let k = SessionTrends.key(snap.sessions[i])
            live.insert(k)
            var list = series[k] ?? []
            list.append((now, snap.sessions[i].totalGB, snap.sessions[i].processCPUSeconds))
            // Keep one sample at or before the cutoff as the anchor and drop the older ones.
            while list.count >= 2, list[1].t <= cutoff { list.removeFirst() }
            series[k] = list
            if let first = list.first, first.t <= cutoff {
                snap.sessions[i].trendGB = Format.round2(snap.sessions[i].totalGB - first.gb)
                if let then = first.cpu, let cpu = snap.sessions[i].processCPUSeconds, cpu >= then, now > first.t {
                    snap.sessions[i].busyPercent = (100 * (cpu - then) / (now - first.t)).rounded()
                } else {
                    snap.sessions[i].busyPercent = nil
                }
            } else {
                snap.sessions[i].trendGB = nil
                snap.sessions[i].busyPercent = nil
            }
        }
        series = series.filter { live.contains($0.key) }
    }
}
