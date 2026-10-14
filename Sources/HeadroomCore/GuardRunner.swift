import Darwin
import Foundation

extension Paths {
    /// The guard's rules. A missing file or key keeps the default.
    public var guardRules: URL { dir.appendingPathComponent("guard.json") }
    /// What the running guard last saw, rewritten every few seconds.
    public var guardState: URL { dir.appendingPathComponent("guard-state.json") }
}

public enum GuardStore {
    public static func loadRules(paths: Paths) -> GuardRules {
        guard let data = try? Data(contentsOf: paths.guardRules),
              let r = try? JSONDecoder().decode(GuardRules.self, from: data) else { return .defaults }
        return r.validated()
    }

    public static func saveRules(_ r: GuardRules, paths: Paths) {
        paths.ensureDir()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(r) { try? data.write(to: paths.guardRules, options: .atomic) }
    }

    public static func readState(paths: Paths) -> GuardState? {
        guard let data = try? Data(contentsOf: paths.guardState) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(GuardState.self, from: data)
    }
}

public struct GuardGrower: Codable, Equatable, Sendable {
    public var pid: Int32
    public var kind: String
    public var name: String
    public var gb: Double
    public var rateGBPerSecond: Double
}

/// The running guard's view, for `headroom guard status` and the app.
public struct GuardState: Codable, Equatable, Sendable {
    public var pid: Int32
    public var armed: Bool
    public var startedAt: Date
    public var updatedAt: Date
    public var ticks: Int
    public var watching: Int
    public var freePercent: Int
    public var tickMilliseconds: Double
    public var stops: Int
    public var lastStop: String?
    public var fastest: [GuardGrower]

    /// True when the state was written recently enough that the guard is running.
    public func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) < 30 }
}

/// Samples once a second, asks the engine, and stops what it names: SIGTERM, then SIGKILL after the grace period.
/// Every decision is logged to events.jsonl as a "guard" event and shown as a notification.
public final class GuardRunner {
    let paths: Paths
    let sampler = Sampler()
    let engine: GuardEngine
    /// From `guard run --armed` or `--observe`; overrides the file.
    let forceArmed: Bool?
    private var pending: [Int32: (start: Double, at: Double)] = [:]
    private var rulesRead = -Double.infinity
    private var stateWritten = -Double.infinity
    private var lastNotice = -Double.infinity
    private var ticks = 0
    private var stops = 0
    private var lastStopText: String?
    private var lastTickMs = 0.0
    private let startedAt = Date()
    /// Shows a notification; tests replace it.
    var notifier: (String, String) -> Void = GuardRunner.notify

    public init(paths: Paths = Paths(), forceArmed: Bool? = nil) {
        self.paths = paths
        self.forceArmed = forceArmed
        var r = GuardStore.loadRules(paths: paths)
        if let forceArmed { r.armed = forceArmed }
        engine = GuardEngine(rules: r)
    }

    public func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        Store.appendEvent("guard", ["action": "start", "armed": engine.rules.armed, "pid": Int(getpid())], paths: paths)
        while true {
            let t0 = ProcessInfo.processInfo.systemUptime
            tick(now: t0)
            let spent = ProcessInfo.processInfo.systemUptime - t0
            lastTickMs = spent * 1000
            let rest = max(0.05, engine.rules.intervalSeconds - spent)
            usleep(useconds_t(rest * 1_000_000))
        }
    }

    public func tick(now: Double) {
        if now - rulesRead >= 10 {
            var r = GuardStore.loadRules(paths: paths)
            if let forceArmed { r.armed = forceArmed }
            if r.armed != engine.rules.armed {
                Store.appendEvent("guard", ["action": r.armed ? "armed" : "observing", "pid": Int(getpid())], paths: paths)
            }
            engine.rules = r.validated()
            rulesRead = now
        }
        escalate(now: now)
        let procs = sampler.readProcesses()
        let free = SystemProbe.freeLevel()
        if let d = engine.observe(time: now, procs: procs, freePercent: free, pending: Set(pending.keys)) {
            act(d, procs: procs, free: free, now: now)
        }
        ticks += 1
        if now - stateWritten >= 5 {
            writeState(free: free, now: now)
            stateWritten = now
        }
    }

    /// SIGKILL for whatever is still alive a grace period after its SIGTERM.
    func escalate(now: Double) {
        for (pid, p) in pending {
            guard let info = SystemProbe.bsdInfo(pid), abs(info.startTime - p.start) < 1 else {
                pending[pid] = nil
                continue
            }
            guard now - p.at >= engine.rules.graceSeconds else { continue }
            let ok = kill(pid, SIGKILL) == 0
            Store.appendEvent("guard", ["action": "killed", "pid": Int(pid), "process": info.name, "ok": ok], paths: paths)
            pending[pid] = nil
        }
    }

    func act(_ d: GuardDecision, procs: [Proc], free: Int, now: Double) {
        var byPid: [Int32: Proc] = [:]
        for p in procs { byPid[p.pid] = p }
        let owner = GuardRunner.ownerText(d.unit.root, procs: procs)
        let argv = SystemProbe.args(d.unit.root)?.joined(separator: " ")
        let command = String((argv ?? byPid[d.unit.root]?.path ?? d.unit.name).prefix(400))
        let armed = engine.rules.armed
        var signalled: [Int] = []
        var errors: [String] = []
        if armed {
            for pid in d.unit.pids {
                guard let p = byPid[pid], let info = SystemProbe.bsdInfo(pid), abs(info.startTime - p.startTime) < 1 else { continue }
                if kill(pid, SIGTERM) == 0 {
                    signalled.append(Int(pid))
                    pending[pid] = (p.startTime, now)
                } else {
                    errors.append("\(pid): \(String(cString: strerror(errno)))")
                }
            }
            stops += 1
        }
        let what = d.unit.kind == .job ? "job \(d.unit.name)" : d.unit.name
        lastStopText = "\(armed ? "Stopped" : "Would stop") \(what) (pid \(d.unit.root), \(Format.gb(d.unit.gb))): \(d.reason). \(owner)."
        Store.appendEvent("guard", [
            "action": armed ? "stopped" : "would-stop", "rule": d.rule.rawValue, "kind": d.unit.kind.rawValue,
            "pid": Int(d.unit.root), "process": d.unit.name, "gb": Format.round2(d.unit.gb),
            "rateGBPerSecond": Format.round2(d.rateGBPerSecond), "reason": d.reason, "owner": owner,
            "command": command, "freePercent": free, "pids": d.unit.pids.map { Int($0) }, "signalled": signalled,
            "errors": errors,
        ], paths: paths)
        // Every stop is announced; in observe mode at most one notice every five minutes.
        if armed || now - lastNotice >= 300 {
            lastNotice = now
            let title = armed ? "Headroom stopped a runaway" : "Headroom would stop a runaway"
            notifier(title, "\(what), \(Format.gb(d.unit.gb)), \(Format.gb(d.rateGBPerSecond))/s. \(owner).")
        }
    }

    /// "Claude Code session in ~/repos/x (pid 123)", or what the process runs under when no agent owns it.
    public static func ownerText(_ pid: Int32, procs: [Proc]) -> String {
        let a = Attribution(procs: procs, bundleID: { _ in nil })
        switch a.owners()[pid] {
        case .session(let s)?:
            let p = a.byPid[s]
            let app = p.flatMap(Attribution.sessionApp)?.name ?? "Agent"
            return "\(app) session in \(Format.shortPath(p?.cwd ?? "?")) (pid \(s))"
        case .thread(let host, let cwd)?:
            return "Codex thread in \(Format.shortPath(cwd)) (app server \(host))"
        case .host(let host)?:
            return "Codex app server \(host)"
        case nil:
            if let top = a.topAncestor(pid), top.pid != pid { return "No agent session; it runs under \(Attribution.appName(for: top))" }
            return "No agent session"
        }
    }

    static func notify(_ title: String, _ body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Basso\""]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func writeState(free: Int, now: Double) {
        let fastest = engine.fastest(limit: 5, now: now).map {
            GuardGrower(pid: $0.unit.root, kind: $0.unit.kind.rawValue, name: $0.unit.name,
                        gb: Format.round2($0.unit.gb), rateGBPerSecond: Format.round2($0.rate))
        }
        let state = GuardState(pid: getpid(), armed: engine.rules.armed, startedAt: startedAt, updatedAt: Date(),
                               ticks: ticks, watching: engine.watching, freePercent: free,
                               tickMilliseconds: Format.round2(lastTickMs), stops: stops, lastStop: lastStopText,
                               fastest: fastest)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        paths.ensureDir()
        if let data = try? enc.encode(state) { try? data.write(to: paths.guardState, options: .atomic) }
    }
}
