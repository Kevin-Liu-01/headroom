import Darwin
import Foundation

// The runaway guard. Headroom's advice never acts on its own; the guard acts in one case only: a process, or one
// agent command's whole process tree, whose memory is spiralling faster than a person can click. On 2026-10-13 a
// `git grep` grew from 42.6 GB to 166 GB in about 55 seconds on a 128 GB Mac, roughly 2 GB a second. A 20 second
// sample cannot catch that, so the guard samples every process's physical footprint once a second.

/// When the guard stops something. Loaded from guard.json; a missing key keeps its default.
public struct GuardRules: Codable, Equatable, Sendable {
    /// False: the guard only logs what it would stop ("observe"). True: it stops it.
    public var armed: Bool
    public var intervalSeconds: Double
    /// The window over which growth is measured.
    public var windowSeconds: Double
    /// Rule "growth": a unit that has grown at least this fast through the whole window...
    public var growthGBPerSecond: Double
    /// ...and now holds at least this much. Below it, fast loads such as a 14 GB model are left alone.
    public var growthFloorGB: Double
    /// Rule "ceiling": a unit past this size that is still growing...
    public var ceilingGB: Double
    /// ...by at least this much a second over the window.
    public var ceilingGrowthGBPerSecond: Double
    /// Rule "leak": a unit past this size...
    public var leakFloorGB: Double
    /// ...that gained at least this much over the last `leakWindowSeconds`, growing all the way...
    public var leakGainGB: Double
    public var leakWindowSeconds: Double
    /// Rule "low-memory": when free memory falls below this percent, the fastest-growing unit...
    public var lowFreePercent: Double
    /// ...that holds at least this much...
    public var lowFreeMinGB: Double
    /// ...and grows at least this fast is stopped.
    public var lowFreeMinGrowthGBPerSecond: Double
    /// Seconds after a stop before the next one, so the numbers can settle.
    public var cooldownSeconds: Double
    /// Seconds between SIGTERM and SIGKILL.
    public var graceSeconds: Double

    public static let defaults = GuardRules(
        armed: false, intervalSeconds: 1, windowSeconds: 5, growthGBPerSecond: 1, growthFloorGB: 16,
        ceilingGB: 64, ceilingGrowthGBPerSecond: 0.1, leakFloorGB: 32, leakGainGB: 8, leakWindowSeconds: 120,
        lowFreePercent: 10, lowFreeMinGB: 2,
        lowFreeMinGrowthGBPerSecond: 0.05, cooldownSeconds: 2, graceSeconds: 1)

    public init(armed: Bool, intervalSeconds: Double, windowSeconds: Double, growthGBPerSecond: Double,
                growthFloorGB: Double, ceilingGB: Double, ceilingGrowthGBPerSecond: Double, leakFloorGB: Double,
                leakGainGB: Double, leakWindowSeconds: Double, lowFreePercent: Double,
                lowFreeMinGB: Double, lowFreeMinGrowthGBPerSecond: Double, cooldownSeconds: Double, graceSeconds: Double) {
        self.armed = armed
        self.intervalSeconds = intervalSeconds
        self.windowSeconds = windowSeconds
        self.growthGBPerSecond = growthGBPerSecond
        self.growthFloorGB = growthFloorGB
        self.ceilingGB = ceilingGB
        self.ceilingGrowthGBPerSecond = ceilingGrowthGBPerSecond
        self.leakFloorGB = leakFloorGB
        self.leakGainGB = leakGainGB
        self.leakWindowSeconds = leakWindowSeconds
        self.lowFreePercent = lowFreePercent
        self.lowFreeMinGB = lowFreeMinGB
        self.lowFreeMinGrowthGBPerSecond = lowFreeMinGrowthGBPerSecond
        self.cooldownSeconds = cooldownSeconds
        self.graceSeconds = graceSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GuardRules.defaults
        armed = try c.decodeIfPresent(Bool.self, forKey: .armed) ?? d.armed
        intervalSeconds = try c.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? d.intervalSeconds
        windowSeconds = try c.decodeIfPresent(Double.self, forKey: .windowSeconds) ?? d.windowSeconds
        growthGBPerSecond = try c.decodeIfPresent(Double.self, forKey: .growthGBPerSecond) ?? d.growthGBPerSecond
        growthFloorGB = try c.decodeIfPresent(Double.self, forKey: .growthFloorGB) ?? d.growthFloorGB
        ceilingGB = try c.decodeIfPresent(Double.self, forKey: .ceilingGB) ?? d.ceilingGB
        ceilingGrowthGBPerSecond = try c.decodeIfPresent(Double.self, forKey: .ceilingGrowthGBPerSecond) ?? d.ceilingGrowthGBPerSecond
        leakFloorGB = try c.decodeIfPresent(Double.self, forKey: .leakFloorGB) ?? d.leakFloorGB
        leakGainGB = try c.decodeIfPresent(Double.self, forKey: .leakGainGB) ?? d.leakGainGB
        leakWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .leakWindowSeconds) ?? d.leakWindowSeconds
        lowFreePercent = try c.decodeIfPresent(Double.self, forKey: .lowFreePercent) ?? d.lowFreePercent
        lowFreeMinGB = try c.decodeIfPresent(Double.self, forKey: .lowFreeMinGB) ?? d.lowFreeMinGB
        lowFreeMinGrowthGBPerSecond = try c.decodeIfPresent(Double.self, forKey: .lowFreeMinGrowthGBPerSecond) ?? d.lowFreeMinGrowthGBPerSecond
        cooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .cooldownSeconds) ?? d.cooldownSeconds
        graceSeconds = try c.decodeIfPresent(Double.self, forKey: .graceSeconds) ?? d.graceSeconds
    }

    /// Clamps every value into a range where the guard still behaves sensibly.
    public func validated() -> GuardRules {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            v.isFinite ? min(max(v, lo), hi) : fallback
        }
        let d = GuardRules.defaults
        var r = self
        r.intervalSeconds = clamp(intervalSeconds, 0.25, 10, d.intervalSeconds)
        r.windowSeconds = clamp(windowSeconds, 2 * r.intervalSeconds, 120, d.windowSeconds)
        r.growthGBPerSecond = clamp(growthGBPerSecond, 0.05, 100, d.growthGBPerSecond)
        r.growthFloorGB = clamp(growthFloorGB, 0.5, 4096, d.growthFloorGB)
        r.ceilingGB = clamp(ceilingGB, 1, 4096, d.ceilingGB)
        r.ceilingGrowthGBPerSecond = clamp(ceilingGrowthGBPerSecond, 0.001, 100, d.ceilingGrowthGBPerSecond)
        r.leakFloorGB = clamp(leakFloorGB, 1, 4096, d.leakFloorGB)
        r.leakGainGB = clamp(leakGainGB, 0.5, 4096, d.leakGainGB)
        r.leakWindowSeconds = clamp(leakWindowSeconds, 30, 3600, d.leakWindowSeconds)
        r.lowFreePercent = clamp(lowFreePercent, 0, 50, d.lowFreePercent)
        r.lowFreeMinGB = clamp(lowFreeMinGB, 0.1, 4096, d.lowFreeMinGB)
        r.lowFreeMinGrowthGBPerSecond = clamp(lowFreeMinGrowthGBPerSecond, 0.001, 100, d.lowFreeMinGrowthGBPerSecond)
        r.cooldownSeconds = clamp(cooldownSeconds, 0, 600, d.cooldownSeconds)
        r.graceSeconds = clamp(graceSeconds, 0, 30, d.graceSeconds)
        return r
    }
}

/// Processes the guard never stops, whatever their memory does.
public enum GuardProtection {
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    static let systemNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer",
        "ControlCenter", "NotificationCenter", "coreaudiod", "mds", "mds_stores", "Spotlight",
    ]

    /// Why the process is never stopped, or nil when the guard may stop it.
    public static func reason(_ p: Proc, myUid: UInt32, myPid: Int32) -> String? {
        if p.pid <= 1 { return "launchd" }
        if p.pid == myPid { return "the guard itself" }
        if p.uid != myUid { return "another user's process" }
        if systemNames.contains(p.name) { return "a system process" }
        if systemPrefixes.contains(where: { p.path.hasPrefix($0) }) { return "a system process" }
        if p.path.contains("/Claude.app/") { return "the Claude app" }
        if Attribution.isAgentSession(p) { return "a Claude Code session" }
        if p.path.contains("/ChatGPT.app/") || p.path.contains("/Codex.app/") { return "the Codex app" }
        if Attribution.isCodexBinary(p) { return "a Codex session" }
        if p.path.contains("/Headroom.app/") || (p.path as NSString).lastPathComponent == "headroom" { return "Headroom" }
        if Attribution.isPersonApp(p) { return "an app the person opened" }
        return nil
    }
}

/// Stable across samples: the kind, the top process's pid and its start time, so a reused pid starts fresh.
public struct GuardUnitKey: Hashable, Sendable {
    public var job: Bool
    public var pid: Int32
    public var start: Double
}

/// What the guard watches: one process, or the process tree of one command an agent ran.
public struct GuardUnit: Equatable, Sendable {
    public enum Kind: String, Sendable { case process, job }
    public var kind: Kind
    public var key: GuardUnitKey
    /// The process, or the job's top process.
    public var root: Int32
    public var rootStart: Double
    /// What a stop signals: the process, or every stoppable process in the job, children first.
    public var pids: [Int32]
    public var bytes: UInt64
    public var name: String

    public var gb: Double { Double(bytes) / SystemProbe.gib }
}

public struct GuardDecision: Equatable, Sendable {
    public enum Rule: String, Sendable { case growth, ceiling, leak, lowMemory = "low-memory" }
    public var rule: Rule
    public var unit: GuardUnit
    /// Growth over the window, in GB a second.
    public var rateGBPerSecond: Double
    public var reason: String
}

/// Decides what to stop from a stream of samples. Pure apart from its own history, so tests feed it traces.
public final class GuardEngine {
    public var rules: GuardRules
    let myUid: UInt32
    let myPid: Int32
    private var history: [GuardUnitKey: [(t: Double, bytes: UInt64)]] = [:]
    /// One sample every 10 seconds per unit over the leak window, for slow leaks.
    private var coarse: [GuardUnitKey: [(t: Double, bytes: UInt64)]] = [:]
    static let coarseStep = 10.0
    private var lastStop = -Double.infinity
    private var lastUnits: [GuardUnit] = []
    /// How many units the last sample held.
    public var watching: Int { lastUnits.count }
    /// Whether each process may be stopped and whether it is an agent session or app server, which only changes
    /// with the process itself, so the string checks run once per process instead of once a second.
    private var classes: [Int32: (start: Double, ppid: Int32, stoppable: Bool, owner: Bool)] = [:]

    public init(rules: GuardRules, myUid: UInt32 = getuid(), myPid: Int32 = getpid()) {
        self.rules = rules.validated()
        self.myUid = myUid
        self.myPid = myPid
    }

    /// The units in one sample: every stoppable process, and every agent command whose tree has two or more
    /// stoppable processes. A command is a direct child of a Claude Code session, a Codex session or a Codex
    /// app server.
    public func units(_ procs: [Proc]) -> [GuardUnit] {
        let tree = Attribution(procs: procs, bundleID: { _ in nil })
        var stoppable: [Int32: Proc] = [:]
        var owners: [Proc] = []
        var next: [Int32: (start: Double, ppid: Int32, stoppable: Bool, owner: Bool)] = [:]
        next.reserveCapacity(procs.count)
        for p in procs {
            var c = classes[p.pid]
            if c == nil || c!.start != p.startTime || c!.ppid != p.ppid {
                let owner = Attribution.isAgentSession(p) || Attribution.codexRole(p).map({ $0 == .session || $0 == .host }) == true
                c = (p.startTime, p.ppid, GuardProtection.reason(p, myUid: myUid, myPid: myPid) == nil, owner)
            }
            next[p.pid] = c
            if c!.stoppable { stoppable[p.pid] = p }
            if c!.owner { owners.append(p) }
        }
        classes = next
        var out: [GuardUnit] = []
        out.reserveCapacity(stoppable.count + 16)
        for p in stoppable.values where p.footprint > 0 {
            out.append(GuardUnit(kind: .process, key: GuardUnitKey(job: false, pid: p.pid, start: p.startTime), root: p.pid, rootStart: p.startTime,
                                 pids: [p.pid], bytes: p.footprint, name: p.name))
        }
        for owner in owners {
            for child in tree.children[owner.pid] ?? [] {
                guard let top = stoppable[child] else { continue }
                let members = tree.subtree(child).filter { stoppable[$0.pid] != nil }
                guard members.count >= 2 else { continue }
                let bytes = members.reduce(UInt64(0)) { $0 + $1.footprint }
                out.append(GuardUnit(kind: .job, key: GuardUnitKey(job: true, pid: top.pid, start: top.startTime), root: top.pid,
                                     rootStart: top.startTime, pids: members.map(\.pid).reversed(), bytes: bytes,
                                     name: "\(top.name) and \(members.count - 1) more"))
            }
        }
        return out
    }

    struct Growth {
        /// Seconds the samples span.
        var span: Double
        /// Net growth over the span, in GB a second.
        var rate: Double
        /// Steps that grew at least half the growth rule's rate.
        var strongSteps: Int
        var steps: Int
    }

    func growth(_ samples: [(t: Double, bytes: UInt64)], now: Double) -> Growth? {
        let from = now - rules.windowSeconds - rules.intervalSeconds * 0.5
        guard let lo = samples.firstIndex(where: { $0.t >= from }) else { return nil }
        let w = samples[lo...]
        guard w.count >= 2, let first = w.first, let last = w.last, last.t > first.t else { return nil }
        let span = last.t - first.t
        let rate = (Double(last.bytes) - Double(first.bytes)) / SystemProbe.gib / span
        var strong = 0
        for i in (lo + 1)..<samples.endIndex {
            let dt = w[i].t - w[i - 1].t
            guard dt > 0 else { continue }
            let stepRate = (Double(w[i].bytes) - Double(w[i - 1].bytes)) / SystemProbe.gib / dt
            if stepRate >= 0.5 * rules.growthGBPerSecond { strong += 1 }
        }
        return Growth(span: span, rate: rate, strongSteps: strong, steps: w.count - 1)
    }

    /// Feeds one sample taken at `time` (seconds on a monotonic clock). Returns the unit to stop now, or nil.
    /// `pending` holds pids already being stopped; units that contain one are skipped.
    public func observe(time: Double, procs: [Proc], freePercent: Int, pending: Set<Int32> = []) -> GuardDecision? {
        let current = units(procs)
        lastUnits = current
        var seen = Set<GuardUnitKey>()
        let keep = rules.windowSeconds + 3 * rules.intervalSeconds
        for u in current {
            seen.insert(u.key)
            var h = history[u.key] ?? []
            h.append((time, u.bytes))
            if let cut = h.firstIndex(where: { $0.t >= time - keep }), cut > 0 { h.removeFirst(cut) }
            history[u.key] = h
            var c = coarse[u.key] ?? []
            if c.isEmpty || time - c.last!.t >= GuardEngine.coarseStep - 0.01 {
                c.append((time, u.bytes))
                if let cut = c.firstIndex(where: { $0.t >= time - rules.leakWindowSeconds - 2 * GuardEngine.coarseStep }), cut > 0 {
                    c.removeFirst(cut)
                }
                coarse[u.key] = c
            }
        }
        history = history.filter { seen.contains($0.key) }
        coarse = coarse.filter { seen.contains($0.key) }
        guard time - lastStop >= rules.cooldownSeconds else { return nil }

        var spiralling: [GuardDecision] = []
        var growers: [(GuardUnit, Double)] = []
        let fullWindow = rules.windowSeconds - rules.intervalSeconds * 0.5
        for u in current {
            if u.pids.contains(where: pending.contains) { continue }
            guard let h = history[u.key], let g = growth(h, now: time) else { continue }
            let gb = u.gb
            if g.span >= fullWindow {
                if gb >= rules.growthFloorGB, g.rate >= rules.growthGBPerSecond, g.strongSteps >= g.steps - 1 {
                    spiralling.append(GuardDecision(
                        rule: .growth, unit: u, rateGBPerSecond: g.rate,
                        reason: "grew \(Format.gb(g.rate * g.span)) in \(Int(g.span.rounded())) s to \(Format.gb(gb)), faster than \(Format.gb(rules.growthGBPerSecond)) a second"))
                } else if gb >= rules.ceilingGB, g.rate >= rules.ceilingGrowthGBPerSecond {
                    spiralling.append(GuardDecision(
                        rule: .ceiling, unit: u, rateGBPerSecond: g.rate,
                        reason: "holds \(Format.gb(gb)), past the \(Format.gb(rules.ceilingGB)) ceiling, and is still growing"))
                }
            }
            if gb >= rules.leakFloorGB, !spiralling.contains(where: { $0.unit.key == u.key }), let leak = leak(u.key, bytesNow: u.bytes, now: time) {
                spiralling.append(GuardDecision(
                    rule: .leak, unit: u, rateGBPerSecond: leak.gain / leak.span,
                    reason: "gained \(Format.gb(leak.gain)) in \(Int(leak.span / 60)) min to \(Format.gb(gb)) and is still climbing"))
            }
            if g.span >= 2 * rules.intervalSeconds - 0.01, gb >= rules.lowFreeMinGB, g.rate >= rules.lowFreeMinGrowthGBPerSecond {
                growers.append((u, g.rate))
            }
        }
        // A single process before a whole job, then the fastest grower.
        let pick = spiralling.min { a, b in
            if a.unit.kind != b.unit.kind { return a.unit.kind == .process }
            return a.rateGBPerSecond > b.rateGBPerSecond
        }
        var decision = pick
        if decision == nil, Double(freePercent) < rules.lowFreePercent,
           let (u, rate) = growers.max(by: { $0.1 < $1.1 }) {
            decision = GuardDecision(
                rule: .lowMemory, unit: u, rateGBPerSecond: rate,
                reason: "free memory is \(freePercent) percent, and it is the fastest grower at \(Format.gb(rate)) a second (\(Format.gb(u.gb)))")
        }
        if let d = decision, d.unit.kind == .job, let narrowed = narrow(d, current: current, now: time) {
            decision = narrowed
        }
        if let d = decision {
            lastStop = time
            history[d.unit.key] = nil
            coarse[d.unit.key] = nil
        }
        return decision
    }

    /// A slow leak: the unit gained at least `leakGainGB` over the leak window, with most 10-second steps up.
    func leak(_ key: GuardUnitKey, bytesNow: UInt64, now: Double) -> (gain: Double, span: Double)? {
        guard let c = coarse[key], c.count >= 3 else { return nil }
        let from = now - rules.leakWindowSeconds - GuardEngine.coarseStep * 0.5
        guard let lo = c.firstIndex(where: { $0.t >= from }) else { return nil }
        let span = now - c[lo].t
        guard span >= rules.leakWindowSeconds * 0.75 else { return nil }
        let gain = (Double(bytesNow) - Double(c[lo].bytes)) / SystemProbe.gib
        guard gain >= rules.leakGainGB else { return nil }
        var up = 0, steps = 0
        for i in (lo + 1)..<c.endIndex {
            steps += 1
            if c[i].bytes > c[i - 1].bytes { up += 1 }
        }
        guard steps >= 2, Double(up) >= 0.8 * Double(steps) else { return nil }
        return (gain, span)
    }

    /// GB a process gained over the window: from its first sample in the window, or from nothing when it started
    /// inside the window.
    func windowGain(_ key: GuardUnitKey, now: Double) -> Double? {
        guard let h = history[key], let last = h.last else { return nil }
        let from = now - rules.windowSeconds - rules.intervalSeconds * 0.5
        guard let first = h.first(where: { $0.t >= from }) else { return nil }
        let bornInWindow = h.first!.t > from + rules.intervalSeconds
        let base = bornInWindow ? 0 : Double(first.bytes)
        return (Double(last.bytes) - base) / SystemProbe.gib
    }

    /// When one process accounts for most of a job's growth, stop that process alone, not the shell and its
    /// siblings around it. A swarm of many growing workers stays a job.
    func narrow(_ d: GuardDecision, current: [GuardUnit], now: Double) -> GuardDecision? {
        guard let jobGain = windowGain(d.unit.key, now: now), jobGain > 0 else { return nil }
        var best: (unit: GuardUnit, gain: Double)?
        for u in current where u.kind == .process && d.unit.pids.contains(u.root) {
            guard let g = windowGain(u.key, now: now) else { continue }
            if best == nil || g > best!.gain { best = (u, g) }
        }
        guard let b = best, b.gain >= 0.7 * jobGain else { return nil }
        return GuardDecision(rule: d.rule, unit: b.unit, rateGBPerSecond: b.gain / rules.windowSeconds,
                             reason: d.reason + "; \(b.unit.name) alone gained \(Format.gb(b.gain)) of the job's \(Format.gb(jobGain))")
    }

    /// The units that grew fastest over the window in the last sample, for the status file.
    public func fastest(limit: Int, now: Double) -> [(unit: GuardUnit, rate: Double)] {
        var out: [(unit: GuardUnit, rate: Double)] = []
        for u in lastUnits {
            guard let h = history[u.key], let g = growth(h, now: now), g.rate > 0.01 else { continue }
            out.append((u, g.rate))
        }
        return Array(out.sorted { $0.rate > $1.rate }.prefix(limit))
    }
}
