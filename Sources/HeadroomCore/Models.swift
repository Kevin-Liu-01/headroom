import Foundation

/// One process as read from libproc.
public struct Proc: Codable, Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var path: String
    public var startTime: Double
    /// Physical footprint in bytes, the number Activity Monitor shows. Zero when unreadable.
    public var footprint: UInt64
    public var cwd: String?
    public var args: [String]?
    public var stopped: Bool
    public var uid: UInt32
    /// CPU time used so far, user plus system, in seconds. Nil when unreadable.
    public var cpuSeconds: Double?

    public init(pid: Int32, ppid: Int32, name: String, path: String, startTime: Double = 0,
                footprint: UInt64, cwd: String? = nil, args: [String]? = nil, stopped: Bool = false, uid: UInt32 = 0,
                cpuSeconds: Double? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.startTime = startTime
        self.footprint = footprint
        self.cwd = cwd
        self.args = args
        self.stopped = stopped
        self.uid = uid
        self.cpuSeconds = cpuSeconds
    }

    public var gb: Double { Double(footprint) / 1_073_741_824 }
}

/// How full memory is: ok, warning or critical. The worst line crossed sets it.
public enum Level: String, Codable, Sendable, Comparable, CaseIterable {
    case ok, warning, critical

    var rank: Int {
        switch self {
        case .ok: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }

    /// One sentence on what the level means.
    public var guidance: String {
        switch self {
        case .ok:
            "Memory is fine."
        case .warning:
            "Memory is high."
        case .critical:
            "Memory is critical. Close what you do not need, or restart the largest session, Claude or Codex; their conversations are saved on disk."
        }
    }

    public var title: String {
        switch self {
        case .ok: "OK"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

public enum Pressure: String, Codable, Sendable {
    case normal, warning, critical

    public init(sysctlLevel: Int) {
        switch sysctlLevel {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }
}

public struct SystemStats: Codable, Equatable, Sendable {
    public var totalGB: Double
    /// kern.memorystatus_level: the percentage of memory the kernel counts as available.
    public var freePercent: Int
    public var freeGB: Double
    public var swapUsedGB: Double
    public var swapTotalGB: Double
    public var compressedGB: Double
    public var pressure: Pressure

    public init(totalGB: Double, freePercent: Int, freeGB: Double, swapUsedGB: Double = 0,
                swapTotalGB: Double = 0, compressedGB: Double = 0, pressure: Pressure = .normal) {
        self.totalGB = totalGB
        self.freePercent = freePercent
        self.freeGB = freeGB
        self.swapUsedGB = swapUsedGB
        self.swapTotalGB = swapTotalGB
        self.compressedGB = compressedGB
        self.pressure = pressure
    }
}

public struct ProcSummary: Codable, Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var name: String
    public var gb: Double
    public var stopped: Bool
    /// The working directory label of the agent session that owns this process, if any.
    public var session: String?
    /// The agent app of that session, Claude or Codex.
    public var app: AgentApp?
    public var startTime: Double

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, gb: Double, stopped: Bool = false, session: String? = nil, app: AgentApp? = nil, startTime: Double = 0) {
        self.pid = pid
        self.name = name
        self.gb = gb
        self.stopped = stopped
        self.session = session
        self.app = app
        self.startTime = startTime
    }
}

/// The two agent apps Headroom watches. Each app owns the sessions it starts, and a session started
/// from a terminal belongs to the app whose agent it runs.
public enum AgentApp: String, Codable, Sendable, CaseIterable, Comparable {
    case claude, codex

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// The desktop app's bundle identifier. On macOS the Codex app is ChatGPT.app with the identifier com.openai.codex.
    public var bundleID: String {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        }
    }

    public static func < (a: AgentApp, b: AgentApp) -> Bool { a == .claude && b == .codex }
}

/// The memory of one agent app's agents, or of every agent process together.
public struct AgentTotal: Codable, Equatable, Sendable {
    /// The desktop app's main process. Nil when the app is not running, and for the combined total.
    public var pid: Int32?
    /// Every process of this app's agents, counted once: the desktop app's tree, the Codex app server, and the
    /// app's sessions started from terminals.
    public var totalGB: Double
    public var processCount: Int
    /// The part that runs in the desktop app (for Codex, also in its app server). The rest runs in terminals.
    public var appGB: Double?
    /// The Codex app server (`codex app-server`) that runs the app's threads, when one runs.
    public var hostPid: Int32?

    public static let zero = AgentTotal(pid: nil, totalGB: 0, processCount: 0)

    public init(pid: Int32?, totalGB: Double, processCount: Int, appGB: Double? = nil, hostPid: Int32? = nil) {
        self.pid = pid
        self.totalGB = totalGB
        self.processCount = processCount
        self.appGB = appGB
        self.hostPid = hostPid
    }

    /// The memory of the app's sessions started from terminals.
    public var terminalGB: Double { max(0, Format.round2(totalGB - (appGB ?? totalGB))) }

    /// True when the desktop app or its app server runs.
    public var appRunning: Bool { pid != nil || hostPid != nil }
}

public struct AgentSession: Codable, Equatable, Sendable, Identifiable {
    /// The session's process. A Codex app thread has no process of its own; its id is negative and stays the
    /// same for one app server and folder.
    public var pid: Int32
    /// Claude for a Claude Code process, Codex for a codex process or a Codex app thread.
    public var app: AgentApp
    public var cwd: String?
    public var label: String
    public var totalGB: Double
    /// The session's own Claude Code or Codex process, without its children. It grows with the conversation and
    /// only a restart of the session frees it. Nil for a Codex app thread, which has no process of its own.
    public var processGB: Double?
    /// CPU seconds the session's own process has used, for the busy measure. Nil for a Codex app thread.
    public var processCPUSeconds: Double?
    /// The session process's average CPU over the last 10 minutes, in percent of one core. A conversation that
    /// waits on the model or on tools uses a few percent; one that holds a core for 10 minutes cannot answer.
    /// Nil until Headroom has watched the session for 10 minutes.
    public var busyPercent: Double?
    public var processCount: Int
    /// True when the session runs inside its desktop app, false when it was started from a terminal.
    public var inApp: Bool
    public var startTime: Double
    /// The change in GB over the last 10 minutes. Nil until Headroom has watched the session for 10 minutes.
    public var trendGB: Double?
    public var top: [ProcSummary]

    public var id: Int32 { pid }

    public init(pid: Int32, app: AgentApp = .claude, cwd: String?, label: String, totalGB: Double, processGB: Double? = nil,
                processCPUSeconds: Double? = nil, busyPercent: Double? = nil,
                processCount: Int, inApp: Bool, startTime: Double = 0, trendGB: Double? = nil, top: [ProcSummary]) {
        self.pid = pid
        self.app = app
        self.cwd = cwd
        self.label = label
        self.totalGB = totalGB
        self.processGB = processGB
        self.processCPUSeconds = processCPUSeconds
        self.busyPercent = busyPercent
        self.processCount = processCount
        self.inApp = inApp
        self.startTime = startTime
        self.trendGB = trendGB
        self.top = top
    }
}

public struct AppTotal: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var totalGB: Double
    public var processCount: Int

    public var id: String { name }

    public init(name: String, totalGB: Double, processCount: Int) {
        self.name = name
        self.totalGB = totalGB
        self.processCount = processCount
    }
}

public enum HeavyKind: String, Codable, Sendable, CaseIterable {
    case browser, model, encoder, build, devServer = "dev-server", test, container

    public var label: String {
        switch self {
        case .browser: "Browser"
        case .model: "Model run"
        case .encoder: "Encoder"
        case .build: "Build"
        case .devServer: "Dev server"
        case .test: "Test run"
        case .container: "Container"
        }
    }
}

public struct HeavyJob: Codable, Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var kind: HeavyKind
    public var name: String
    public var totalGB: Double
    public var processCount: Int
    public var session: String?
    /// The agent app of the session that owns the job.
    public var app: AgentApp?
    public var stopped: Bool
    public var startTime: Double
    /// True for an app the person opened from /Applications, such as their own Google Chrome.
    public var personApp: Bool?

    public var id: Int32 { pid }

    public init(pid: Int32, kind: HeavyKind, name: String, totalGB: Double, processCount: Int,
                session: String? = nil, app: AgentApp? = nil, stopped: Bool = false, startTime: Double = 0, personApp: Bool? = nil) {
        self.personApp = personApp
        self.app = app
        self.pid = pid
        self.kind = kind
        self.name = name
        self.totalGB = totalGB
        self.processCount = processCount
        self.session = session
        self.stopped = stopped
        self.startTime = startTime
    }
}

/// One sample of the whole machine, attributed to the agent apps, their sessions and other apps.
public struct Snapshot: Codable, Equatable, Sendable {
    public var time: Date
    public var system: SystemStats
    /// Every Claude agent process: the Claude app's tree and the Claude Code sessions started from terminals.
    public var claude: AgentTotal
    /// Every Codex agent process: the Codex app's tree (ChatGPT.app, com.openai.codex), its app server and the
    /// Codex sessions started from terminals.
    public var codex: AgentTotal
    /// Every agent process counted once. It equals the Claude total plus the Codex total.
    public var agents: AgentTotal
    public var sessions: [AgentSession]
    public var heavyJobs: [HeavyJob]
    public var apps: [AppTotal]
    public var largest: [ProcSummary]
    public var processCount: Int
    /// Processes whose footprint could not be read (other users, mostly root).
    public var unreadableCount: Int

    public init(time: Date, system: SystemStats, claude: AgentTotal, codex: AgentTotal = .zero, agents: AgentTotal? = nil,
                sessions: [AgentSession] = [], heavyJobs: [HeavyJob] = [], apps: [AppTotal] = [], largest: [ProcSummary] = [],
                processCount: Int = 0, unreadableCount: Int = 0) {
        self.time = time
        self.system = system
        self.claude = claude
        self.codex = codex
        self.agents = agents ?? AgentTotal(pid: nil, totalGB: Format.round2(claude.totalGB + codex.totalGB),
                                           processCount: claude.processCount + codex.processCount)
        self.sessions = sessions
        self.heavyJobs = heavyJobs
        self.apps = apps
        self.largest = largest
        self.processCount = processCount
        self.unreadableCount = unreadableCount
    }

    public func total(_ app: AgentApp) -> AgentTotal {
        switch app {
        case .claude: claude
        case .codex: codex
        }
    }

    public func sessions(of app: AgentApp) -> [AgentSession] {
        sessions.filter { $0.app == app }
    }
}

public struct Reason: Codable, Equatable, Sendable {
    public var check: String
    public var level: Level
    public var message: String
    /// For a note about a session, the session's pid.
    public var pid: Int32?

    public init(check: String, level: Level, message: String, pid: Int32? = nil) {
        self.check = check
        self.level = level
        self.message = message
        self.pid = pid
    }
}

public struct Thresholds: Codable, Equatable, Sendable {
    /// Lines for every agent process together: both apps and the sessions started from terminals.
    public var agentsWarningGB: Double = 40
    public var agentsCriticalGB: Double = 70
    public var claudeWarningGB: Double = 40
    public var claudeCriticalGB: Double = 70
    public var codexWarningGB: Double = 40
    public var codexCriticalGB: Double = 70
    public var freeWarningPercent: Double = 30
    public var freeCriticalPercent: Double = 15
    public var processStepGB: Double = 16
    public var sampleSeconds: Double = 20
    public var lowSampleSeconds: Double = 5
    public var repeatMinutes: Double = 5
    /// Restart a desktop session whose own process holds a process step or more, once a restart loses nothing.
    public var restartIdleSessions = true

    public init() {}

    public init(from decoder: Decoder) throws {
        // Missing keys fall back to the defaults so an old settings file still loads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Thresholds.defaults
        agentsWarningGB = try c.decodeIfPresent(Double.self, forKey: .agentsWarningGB) ?? d.agentsWarningGB
        agentsCriticalGB = try c.decodeIfPresent(Double.self, forKey: .agentsCriticalGB) ?? d.agentsCriticalGB
        codexWarningGB = try c.decodeIfPresent(Double.self, forKey: .codexWarningGB) ?? d.codexWarningGB
        codexCriticalGB = try c.decodeIfPresent(Double.self, forKey: .codexCriticalGB) ?? d.codexCriticalGB
        claudeWarningGB = try c.decodeIfPresent(Double.self, forKey: .claudeWarningGB) ?? d.claudeWarningGB
        claudeCriticalGB = try c.decodeIfPresent(Double.self, forKey: .claudeCriticalGB) ?? d.claudeCriticalGB
        freeWarningPercent = try c.decodeIfPresent(Double.self, forKey: .freeWarningPercent) ?? d.freeWarningPercent
        freeCriticalPercent = try c.decodeIfPresent(Double.self, forKey: .freeCriticalPercent) ?? d.freeCriticalPercent
        processStepGB = try c.decodeIfPresent(Double.self, forKey: .processStepGB) ?? d.processStepGB
        sampleSeconds = try c.decodeIfPresent(Double.self, forKey: .sampleSeconds) ?? d.sampleSeconds
        lowSampleSeconds = try c.decodeIfPresent(Double.self, forKey: .lowSampleSeconds) ?? d.lowSampleSeconds
        repeatMinutes = try c.decodeIfPresent(Double.self, forKey: .repeatMinutes) ?? d.repeatMinutes
        restartIdleSessions = try c.decodeIfPresent(Bool.self, forKey: .restartIdleSessions) ?? d.restartIdleSessions
    }

    public static let defaults = Thresholds()

    /// The defaults for a new install on a Mac with `totalGB` of memory: warning at 47 percent of it and critical
    /// at 70 percent, rounded to 5 GB, for the agents, Claude and Codex lines. A 128 GB Mac gets 60 and 90 GB,
    /// and a 32 GB Mac gets 15 and 20 GB. The free memory lines stay at 30 and 15 percent.
    public static func scaled(toMemoryGB totalGB: Double) -> Thresholds {
        guard totalGB > 0 else { return Thresholds() }
        func round5(_ v: Double) -> Double { (v / 5).rounded() * 5 }
        let warning = max(5, round5(totalGB * 0.47))
        let critical = max(warning + 5, round5(totalGB * 0.70))
        var t = Thresholds()
        t.agentsWarningGB = warning
        t.agentsCriticalGB = critical
        t.claudeWarningGB = warning
        t.claudeCriticalGB = critical
        t.codexWarningGB = warning
        t.codexCriticalGB = critical
        return t
    }

    /// Clamps values into sane ranges and keeps each critical line beyond its warning line.
    public func validated() -> Thresholds {
        var t = self
        t.agentsWarningGB = max(1, t.agentsWarningGB)
        t.agentsCriticalGB = max(t.agentsWarningGB, t.agentsCriticalGB)
        t.claudeWarningGB = max(1, t.claudeWarningGB)
        t.claudeCriticalGB = max(t.claudeWarningGB, t.claudeCriticalGB)
        t.codexWarningGB = max(1, t.codexWarningGB)
        t.codexCriticalGB = max(t.codexWarningGB, t.codexCriticalGB)
        t.freeWarningPercent = min(95, max(1, t.freeWarningPercent))
        t.freeCriticalPercent = min(t.freeWarningPercent, max(0, t.freeCriticalPercent))
        t.processStepGB = max(1, t.processStepGB)
        t.sampleSeconds = min(600, max(5, t.sampleSeconds))
        t.lowSampleSeconds = min(t.sampleSeconds, max(2, t.lowSampleSeconds))
        t.repeatMinutes = max(1, t.repeatMinutes)
        return t
    }

    /// The warning and critical lines of one agent app.
    public func lines(_ app: AgentApp) -> (warning: Double, critical: Double) {
        switch app {
        case .claude: (claudeWarningGB, claudeCriticalGB)
        case .codex: (codexWarningGB, codexCriticalGB)
        }
    }
}

/// The document written to state.json after every sample and printed by `headroom status --json`.
public struct StatusDocument: Codable, Equatable, Sendable {
    /// 3 since the viewer: `advice` became `level` (ok, warning, critical), and the agent requests and notes left.
    public var version: Int = 3
    public var source: String
    public var updatedAt: Date
    public var level: Level
    public var guidance: String
    public var reasons: [Reason]
    public var snapshot: Snapshot
    public var thresholds: Thresholds

    public init(source: String, updatedAt: Date, level: Level, reasons: [Reason], snapshot: Snapshot, thresholds: Thresholds) {
        self.source = source
        self.updatedAt = updatedAt
        self.level = level
        self.guidance = level.guidance
        self.reasons = reasons
        self.snapshot = snapshot
        self.thresholds = thresholds
    }
}

/// The answer of `headroom can-start`, a read-only check for scripts that start large jobs.
public struct CanStart: Codable, Equatable, Sendable {
    public var ok: Bool
    public var level: Level
    public var reason: String
    public var freeGB: Double
    public var gb: Double
    public var label: String?

    public init(ok: Bool, level: Level, reason: String, freeGB: Double, gb: Double, label: String?) {
        self.ok = ok
        self.level = level
        self.reason = reason
        self.freeGB = freeGB
        self.gb = gb
        self.label = label
    }
}
