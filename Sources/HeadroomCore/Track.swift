import Foundation

// The long-term record. Every sample folds into the open minute; each finished minute is one line in
// history/<day>.jsonl, and each finished hour one line in history/hours.jsonl. Minutes are kept for
// `Track.keepMinuteDays` days and hours for good, so a year of hours is about 3 MB. Gaps, such as sleep or the
// app not running, stay gaps: nothing is filled in.

/// The lowest, average and highest value of one measure over a minute or longer, written as [min, avg, max].
public struct Span: Codable, Equatable, Sendable {
    public var min: Double
    public var avg: Double
    public var max: Double

    public init(min: Double, avg: Double, max: Double) {
        self.min = min
        self.avg = avg
        self.max = max
    }

    public init(_ value: Double) {
        self.init(min: value, avg: value, max: value)
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        min = try c.decode(Double.self)
        avg = try c.decode(Double.self)
        max = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(Format.round2(min))
        try c.encode(Format.round2(avg))
        try c.encode(Format.round2(max))
    }

    /// Both spans together, the averages weighted by their sample counts.
    func merged(_ o: Span, _ n: Int, _ m: Int) -> Span {
        let w = Double(n + m)
        return Span(min: Swift.min(min, o.min), avg: w > 0 ? (avg * Double(n) + o.avg * Double(m)) / w : avg, max: Swift.max(max, o.max))
    }
}

/// A session or a process among the largest at a peak.
public struct Holder: Codable, Equatable, Sendable, Hashable {
    public var name: String
    public var gb: Double
    /// The agent app of the session, or of the session that owns the process.
    public var app: AgentApp?
    /// For a process, the session that owns it, when one does.
    public var session: String?

    public init(name: String, gb: Double, app: AgentApp? = nil, session: String? = nil) {
        self.name = name
        self.gb = Format.round2(gb)
        self.app = app
        self.session = session
    }
}

/// One minute, one hour or any longer bucket of the record.
public struct Rollup: Codable, Equatable, Sendable, Identifiable {
    /// Seconds since 1970 at the start of the bucket.
    public var t: Double
    /// The bucket's length in seconds: 60 for a minute, 3600 for an hour.
    public var seconds: Double
    /// The samples it summarises.
    public var n: Int
    /// Every Claude and Codex agent process together.
    public var agents: Span
    public var claude: Span
    public var codex: Span
    /// Memory in use on the whole Mac, in GB: its memory less the free part.
    public var used: Span
    /// Free memory, in percent.
    public var free: Span
    /// The most swap and compressed memory, in GB.
    public var swap: Double
    public var compressed: Double
    /// The Mac's memory in GB.
    public var total: Double
    /// The worst level of any sample.
    public var level: Level
    /// Minutes with at least one sample, and of those the minutes spent at warning and at critical. A minute
    /// counts at its worst level.
    public var minutes: Int
    public var warningMinutes: Int
    public var criticalMinutes: Int
    /// When the agents' total peaked, and the largest sessions and processes at that moment.
    public var peakT: Double
    public var sessions: [Holder]
    public var processes: [Holder]

    public var id: Double { t }
    public var time: Date { Date(timeIntervalSince1970: t) }
    public var end: Double { t + seconds }
    public var peakTime: Date { Date(timeIntervalSince1970: peakT) }

    /// A bucket holding one sample.
    public init(sample s: Snapshot, level: Level, bucket: Double = 60) {
        let now = s.time.timeIntervalSince1970
        t = (now / bucket).rounded(.down) * bucket
        seconds = bucket
        n = 1
        agents = Span(s.agents.totalGB)
        claude = Span(s.claude.totalGB)
        codex = Span(s.codex.totalGB)
        used = Span(max(0, s.system.totalGB - s.system.freeGB))
        free = Span(Double(s.system.freePercent))
        swap = s.system.swapUsedGB
        compressed = s.system.compressedGB
        total = s.system.totalGB
        self.level = level
        minutes = 0
        warningMinutes = 0
        criticalMinutes = 0
        peakT = now.rounded()
        sessions = s.sessions.prefix(3).map { Holder(name: $0.label, gb: $0.totalGB, app: $0.app) }
        processes = s.largest.prefix(3).map { Holder(name: $0.name, gb: $0.gb, app: $0.app, session: $0.session) }
    }

    public init(t: Double, seconds: Double, n: Int, agents: Span, claude: Span, codex: Span, used: Span, free: Span,
                swap: Double, compressed: Double, total: Double, level: Level, minutes: Int = 0, warningMinutes: Int = 0,
                criticalMinutes: Int = 0, peakT: Double? = nil, sessions: [Holder] = [], processes: [Holder] = []) {
        self.t = t
        self.seconds = seconds
        self.n = n
        self.agents = agents
        self.claude = claude
        self.codex = codex
        self.used = used
        self.free = free
        self.swap = swap
        self.compressed = compressed
        self.total = total
        self.level = level
        self.minutes = minutes
        self.warningMinutes = warningMinutes
        self.criticalMinutes = criticalMinutes
        self.peakT = peakT ?? t
        self.sessions = sessions
        self.processes = processes
    }

    /// Folds another bucket's samples into this one. The peak, with its holders, is the larger of the two.
    public mutating func merge(_ o: Rollup) {
        if o.agents.max > agents.max || (o.agents.max == agents.max && sessions.isEmpty) {
            peakT = o.peakT
            sessions = o.sessions
            processes = o.processes
        }
        agents = agents.merged(o.agents, n, o.n)
        claude = claude.merged(o.claude, n, o.n)
        codex = codex.merged(o.codex, n, o.n)
        used = used.merged(o.used, n, o.n)
        free = free.merged(o.free, n, o.n)
        n += o.n
        swap = max(swap, o.swap)
        compressed = max(compressed, o.compressed)
        total = max(total, o.total)
        level = max(level, o.level)
        minutes += o.minutes
        warningMinutes += o.warningMinutes
        criticalMinutes += o.criticalMinutes
    }

    /// A finished minute counts once at its worst level.
    func finishedMinute() -> Rollup {
        var r = self
        r.minutes = 1
        r.warningMinutes = level == .warning ? 1 : 0
        r.criticalMinutes = level == .critical ? 1 : 0
        return r
    }

    /// The same bucket moved to a longer one starting at `t`.
    func rebucketed(_ t: Double, _ seconds: Double) -> Rollup {
        var r = self
        r.t = t
        r.seconds = seconds
        return r
    }
}

/// Reading and writing the record.
public enum Track {
    /// Minutes are kept this long; hours are kept for good.
    public static let keepMinuteDays = 90

    // MARK: Days

    /// The local day of a time, such as 2026-10-16.
    public static func day(_ t: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The start of a local day from its name.
    public static func dayStart(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The days that have a file of minutes, oldest first.
    public static func minuteDays(paths: Paths) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.track.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") && $0 != "hours.jsonl" }.map { String($0.dropLast(6)) }
            .filter { dayStart($0) != nil }.sorted()
    }

    // MARK: Files

    static func decodeLines(_ data: Data, keep: ((Data) -> Bool)? = nil) -> [Rollup] {
        let d = JSONDecoder()
        var out: [Rollup] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let bytes = Data(line)
            if let keep, !keep(bytes) { continue }
            if let r = try? d.decode(Rollup.self, from: bytes) { out.append(r) }
        }
        return out
    }

    static func append(_ rollups: [Rollup], to url: URL, paths: Paths) {
        guard !rollups.isEmpty else { return }
        paths.ensureDir()
        try? FileManager.default.createDirectory(at: paths.track, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for r in rollups {
            guard let line = try? e.encode(r) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Sorts by time and folds rollups that share a start, such as a minute written twice across a restart.
    /// A folded minute still counts once at its worst level.
    static func normalized(_ list: [Rollup]) -> [Rollup] {
        var out: [Rollup] = []
        for r in list.sorted(by: { $0.t < $1.t }) {
            if let last = out.last, last.t == r.t, last.seconds == r.seconds {
                out[out.count - 1].merge(r)
                if r.seconds == 60 { out[out.count - 1] = out[out.count - 1].finishedMinute() }
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// The minutes that start in [from, to). `onlyRaised` decodes only minutes at warning or critical.
    public static func minutes(paths: Paths, from: Double, to: Double, onlyRaised: Bool = false) -> [Rollup] {
        var out: [Rollup] = []
        let ok = Data(#""level":"ok""#.utf8)
        let first = day(from), last = day(to)
        for d in minuteDays(paths: paths) where d >= first && d <= last {
            guard let data = try? Data(contentsOf: paths.minutes(day: d)) else { continue }
            out += decodeLines(data, keep: onlyRaised ? { $0.range(of: ok) == nil } : nil).filter { $0.t >= from && $0.t < to }
        }
        return normalized(out)
    }

    /// The hours that start in [from, to): the written hours, then hours rolled up from minutes for any hour not
    /// written yet, including the open one.
    public static func hours(paths: Paths, from: Double, to: Double) -> [Rollup] {
        var out: [Rollup] = []
        if let data = try? Data(contentsOf: paths.hours) {
            out = decodeLines(data).filter { $0.t >= from && $0.t < to }
        }
        let written = lastHour(paths: paths) ?? -Double.infinity
        let rest = max(from, written + 3600)
        if rest < to {
            out += rollUp(minutes(paths: paths, from: rest, to: to), seconds: 3600)
        }
        return normalized(out)
    }

    /// The start of the last hour in hours.jsonl, read from the file's tail.
    static func lastHour(paths: Paths) -> Double? {
        guard let h = try? FileHandle(forReadingFrom: paths.hours) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        try? h.seek(toOffset: size > 8192 ? size - 8192 : 0)
        guard let tail = try? h.readToEnd() else { return nil }
        return decodeLines(tail).map(\.t).max()
    }

    /// Folds rollups into aligned buckets of `seconds`. Minutes rolled into hours count their warning and
    /// critical minutes; buckets with no samples are left out, so gaps stay gaps.
    public static func rollUp(_ list: [Rollup], seconds: Double) -> [Rollup] {
        var out: [Rollup] = []
        for r in list.sorted(by: { $0.t < $1.t }) {
            let start = (r.t / seconds).rounded(.down) * seconds
            if let last = out.last, last.t == start {
                out[out.count - 1].merge(r)
            } else {
                out.append(r.rebucketed(start, seconds))
            }
        }
        return out
    }

    /// All rollups merged into one, or nil when there are none.
    public static func total(_ list: [Rollup]) -> Rollup? {
        guard var first = list.first else { return nil }
        for r in list.dropFirst() { first.merge(r) }
        return first
    }

    // MARK: Ranges

    /// The rollups behind a chart of [from, to): minutes for up to 7 days, hours beyond, folded into at most
    /// `maxPoints` buckets.
    public static func series(paths: Paths, from: Double, to: Double, maxPoints: Int = 720) -> [Rollup] {
        let span = max(60, to - from)
        let base: Double = span <= 7 * 86_400 ? 60 : 3600
        let raw = base == 60 ? minutes(paths: paths, from: from, to: to) : hours(paths: paths, from: from, to: to)
        let steps: [Double] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400, 172_800, 604_800]
        let want = span / Double(max(1, maxPoints))
        let bucket = steps.first { $0 >= base && $0 >= want } ?? 604_800
        return bucket == base ? raw : rollUp(raw, seconds: bucket)
    }

    /// The earliest time the record holds.
    public static func firstTime(paths: Paths) -> Double? {
        var first: Double?
        if let h = try? FileHandle(forReadingFrom: paths.hours) {
            defer { try? h.close() }
            if let head = try? h.read(upToCount: 4096) { first = decodeLines(head).first?.t }
        }
        if let d = minuteDays(paths: paths).first, let data = try? Data(contentsOf: paths.minutes(day: d)),
           let t = decodeLines(data.prefix(4096)).first?.t {
            first = min(first ?? t, t)
        }
        return first
    }

    // MARK: Summaries

    /// One local day: its hours merged.
    public struct Day: Equatable, Sendable, Identifiable {
        public var day: String
        public var start: Date
        public var rollup: Rollup
        public var id: String { day }
    }

    /// The days of [from, to), newest first.
    public static func daySummaries(paths: Paths, from: Double, to: Double) -> [Day] {
        daySummaries(of: hours(paths: paths, from: from, to: to))
    }

    /// Hours, or any shorter buckets, merged by local day, newest first.
    public static func daySummaries(of list: [Rollup]) -> [Day] {
        var byDay: [String: Rollup] = [:]
        for h in list {
            let d = day(h.t)
            if byDay[d] == nil {
                byDay[d] = h.rebucketed(dayStart(d)?.timeIntervalSince1970 ?? h.t, 86_400)
            } else {
                byDay[d]!.merge(h)
            }
        }
        return byDay.compactMap { d, r in dayStart(d).map { Day(day: d, start: $0, rollup: r) } }
            .sorted { $0.start > $1.start }
    }

    /// A stretch of minutes at warning or critical. Dips back to ok shorter than `Track.episodeGap` belong to it.
    public struct Episode: Equatable, Sendable, Identifiable {
        public var rollup: Rollup
        public var start: Date { rollup.time }
        public var end: Date { Date(timeIntervalSince1970: rollup.end) }
        public var id: Double { rollup.t }
        /// Minutes at warning or critical; the rollup's span also counts the short dips inside.
        public var raisedMinutes: Int { rollup.warningMinutes + rollup.criticalMinutes }
    }

    public static let episodeGap: Double = 5 * 60

    /// The episodes of [from, to), newest first. They need minutes, so they reach back `keepMinuteDays` at most.
    public static func episodes(paths: Paths, from: Double, to: Double) -> [Episode] {
        episodes(in: minutes(paths: paths, from: from, to: to, onlyRaised: true))
    }

    /// The episodes in a list of minutes, newest first. Minutes at ok are skipped.
    public static func episodes(in raised: [Rollup]) -> [Episode] {
        var out: [Rollup] = []
        for m in raised where m.level != .ok {
            if var last = out.last, m.t - last.end <= episodeGap {
                let end = m.end
                last.merge(m)
                last.seconds = end - last.t
                out[out.count - 1] = last
            } else {
                out.append(m)
            }
        }
        return out.reversed().map { Episode(rollup: $0) }
    }

    /// A session's place in a range: its largest total, and how long it was among the three largest.
    public struct SessionRank: Equatable, Sendable, Identifiable {
        public var name: String
        public var app: AgentApp?
        public var peakGB: Double
        public var peakT: Double
        public var seconds: Double
        public var id: String { "\(app?.rawValue ?? "-")/\(name)" }
    }

    /// The sessions that held the most in the given rollups, largest peak first.
    public static func sessionRanks(_ list: [Rollup], limit: Int = 8) -> [SessionRank] {
        var ranks: [String: SessionRank] = [:]
        for r in list {
            for h in r.sessions {
                let key = "\(h.app?.rawValue ?? "-")/\(h.name)"
                var e = ranks[key] ?? SessionRank(name: h.name, app: h.app, peakGB: 0, peakT: r.peakT, seconds: 0)
                if h.gb > e.peakGB {
                    e.peakGB = h.gb
                    e.peakT = r.peakT
                }
                e.seconds += r.seconds
                ranks[key] = e
            }
        }
        return ranks.values.sorted { $0.peakGB > $1.peakGB }.prefix(limit).map { $0 }
    }

    // MARK: Version 1

    /// Version 1 logged a summary of every sample to events.jsonl, rotated to events.1.jsonl at 10 MB. Builds
    /// minutes and hours from those samples for the time before the record began, once, so the history starts
    /// with what version 1 saw. Returns the number of minutes written.
    @discardableResult
    public static func importVersion1(paths: Paths, totalGB: Double, now: Date = Date()) -> Int {
        let marker = paths.track.appendingPathComponent(".imported-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return 0 }
        // Only the time before the first minute the record holds, so nothing is counted twice.
        let first = minuteDays(paths: paths).first.flatMap { d in
            decodeLines((try? Data(contentsOf: paths.minutes(day: d))) ?? Data()).map(\.t).min()
        }
        let cutoff = first ?? now.timeIntervalSince1970
        let tag = Data(#""type":"sample""#.utf8)
        var samples: [Rollup] = []
        for name in ["events.1.jsonl", "events.jsonl"] {
            guard let data = try? Data(contentsOf: paths.dir.appendingPathComponent(name)) else { continue }
            for line in data.split(separator: 0x0A) {
                let bytes = Data(line)
                guard bytes.range(of: tag) != nil,
                      let o = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let time = (o["time"] as? String).flatMap(Format.parseISO) else { continue }
                let t = time.timeIntervalSince1970
                guard t < cutoff else { continue }
                if let r = version1Sample(o, t: t, totalGB: totalGB) { samples.append(r) }
            }
        }
        let minutes = rollUp(samples, seconds: 60).map { $0.finishedMinute() }
        var byDay: [String: [Rollup]] = [:]
        for m in minutes { byDay[day(m.t), default: []].append(m) }
        for (d, list) in byDay.sorted(by: { $0.key < $1.key }) { append(list, to: paths.minutes(day: d), paths: paths) }
        // Whole hours only before the hour the record began in: that hour is rolled up from all its minutes later.
        let open = (min(cutoff, now.timeIntervalSince1970) / 3600).rounded(.down) * 3600
        append(rollUp(minutes, seconds: 3600).filter { $0.t < open }, to: paths.hours, paths: paths)
        try? FileManager.default.createDirectory(at: paths.track, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data("\(minutes.count) minutes from version 1's log\n".utf8).write(to: marker)
        return minutes.count
    }

    /// One version 1 sample line as a single-sample minute. Version 1.0 logged no agents' total, only Claude's.
    static func version1Sample(_ o: [String: Any], t: Double, totalGB: Double) -> Rollup? {
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        guard let claude = num("claudeGB"), let free = num("freePercent") else { return nil }
        let codex = num("codexGB") ?? 0
        let agents = num("agentsGB") ?? claude + codex
        let freeGB = num("freeGB") ?? totalGB * free / 100
        let level: Level = switch o["advice"] as? String {
        case "critical": .critical
        case "hold": .warning
        default: .ok
        }
        let sessions = (o["sessions"] as? [[String: Any]] ?? []).compactMap { s -> Holder? in
            guard let label = s["label"] as? String else { return nil }
            return Holder(name: label, gb: (s["gb"] as? NSNumber)?.doubleValue ?? 0,
                          app: (s["app"] as? String).flatMap(AgentApp.init(rawValue:)) ?? .claude)
        }
        let processes = (o["largest"] as? [[String: Any]] ?? []).compactMap { p -> Holder? in
            guard let name = p["name"] as? String else { return nil }
            return Holder(name: name, gb: (p["gb"] as? NSNumber)?.doubleValue ?? 0)
        }
        return Rollup(t: (t / 60).rounded(.down) * 60, seconds: 60, n: 1, agents: Span(agents), claude: Span(claude),
                      codex: Span(codex), used: Span(max(0, totalGB - freeGB)), free: Span(free),
                      swap: num("swapUsedGB") ?? 0, compressed: num("compressedGB") ?? 0, total: totalGB, level: level,
                      peakT: t.rounded(), sessions: sessions, processes: processes)
    }

    // MARK: Retention

    /// Deletes the files of minutes older than `keepMinuteDays`. Hours stay.
    public static func prune(paths: Paths, now: Date = Date()) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -keepMinuteDays, to: Calendar.current.startOfDay(for: now)) else { return }
        for d in minuteDays(paths: paths) {
            if let start = dayStart(d), start < cutoff {
                try? FileManager.default.removeItem(at: paths.minutes(day: d))
            }
        }
    }
}

/// Keeps the open minute and the open hour as samples arrive, and writes each when it ends. The app owns one
/// and calls it from its sampling queue only.
public final class Recorder: @unchecked Sendable {
    public let paths: Paths
    private var minute: Rollup?
    private var hour: Rollup?
    private var lastPrunedDay: String?

    /// Resumes the hour in progress from the minutes already written, and writes any finished hours that are
    /// missing from hours.jsonl, such as the last hour before the app quit.
    public init(paths: Paths, now: Date = Date()) {
        self.paths = paths
        let t = now.timeIntervalSince1970
        let hourStart = (t / 3600).rounded(.down) * 3600
        let written = Track.lastHour(paths: paths)
        // Minutes are kept for days, so a gap longer than that has nothing left to roll up.
        let from = max(written.map { $0 + 3600 } ?? -Double.infinity, t - Double(Track.keepMinuteDays) * 86_400)
        if from < hourStart {
            let missing = Track.rollUp(Track.minutes(paths: paths, from: from, to: hourStart), seconds: 3600)
            Track.append(missing, to: paths.hours, paths: paths)
        }
        hour = Track.total(Track.minutes(paths: paths, from: hourStart, to: t + 60).filter { $0.t < (t / 60).rounded(.down) * 60 })?
            .rebucketed(hourStart, 3600)
    }

    /// Adds one sample. Returns true when it closed a minute, which is then on disk.
    @discardableResult
    public func record(_ s: Snapshot, level: Level) -> Bool {
        let one = Rollup(sample: s, level: level)
        if var m = minute, m.t == one.t {
            m.merge(one)
            minute = m
            return false
        }
        var closed = false
        if let m = minute {
            close(m)
            closed = true
        }
        minute = one
        return closed
    }

    /// Writes the open minute now, for a clean quit. A later sample in the same minute starts it again, and
    /// readers fold the two lines into one.
    public func flush() {
        guard let m = minute else { return }
        close(m)
        minute = nil
    }

    private func close(_ m: Rollup) {
        let done = m.finishedMinute()
        Track.append([done], to: paths.minutes(day: Track.day(done.t)), paths: paths)
        let hourStart = (done.t / 3600).rounded(.down) * 3600
        if var h = hour, h.t == hourStart {
            h.merge(done)
            hour = h
        } else {
            if let h = hour, h.t < hourStart { Track.append([h], to: paths.hours, paths: paths) }
            hour = done.rebucketed(hourStart, 3600)
        }
        let today = Track.day(done.t)
        if lastPrunedDay != today {
            lastPrunedDay = today
            Track.prune(paths: paths, now: done.time)
        }
    }
}
