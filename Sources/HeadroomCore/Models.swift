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

    public init(pid: Int32, ppid: Int32, name: String, path: String, startTime: Double = 0,
                footprint: UInt64, cwd: String? = nil, args: [String]? = nil, stopped: Bool = false, uid: UInt32 = 0) {
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
    }

    public var gb: Double { Double(footprint) / 1_073_741_824 }
}

public enum Advice: String, Codable, Sendable, Comparable {
    case ok, hold, critical

    var rank: Int {
        switch self {
        case .ok: 0
        case .hold: 1
        case .critical: 2
        }
    }

    public static func < (a: Advice, b: Advice) -> Bool { a.rank < b.rank }

    /// What agents and people should do at this advice level.
    public var guidance: String {
        switch self {
        case .ok:
            "Memory is fine. Agents may start heavy jobs."
        case .hold:
            "Hold: agents start nothing new that is heavy. Wait with `headroom wait --gb N` or run the job later."
        case .critical:
            "Critical: pause heavy jobs and restart Claude or Codex, whichever holds more memory. All agent state is on disk, so a restart of the app loses no work."
        }
    }

    public var title: String {
        switch self {
        case .ok: "OK"
        case .hold: "Hold"
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
    public var processCount: Int
    /// True when the session runs inside its desktop app, false when it was started from a terminal.
    public var inApp: Bool
    public var startTime: Double
    /// The change in GB over the last 10 minutes. Nil until Headroom has watched the session for 10 minutes.
    public var trendGB: Double?
    public var top: [ProcSummary]

    public var id: Int32 { pid }

    public init(pid: Int32, app: AgentApp = .claude, cwd: String?, label: String, totalGB: Double, processCount: Int,
                inApp: Bool, startTime: Double = 0, trendGB: Double? = nil, top: [ProcSummary]) {
        self.pid = pid
        self.app = app
        self.cwd = cwd
        self.label = label
        self.totalGB = totalGB
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
    /// Pause heavy jobs leaves these out; each still has its own Pause button.
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
    public var level: Advice
    public var message: String

    public init(check: String, level: Advice, message: String) {
        self.check = check
        self.level = level
        self.message = message
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
    }

    public static let defaults = Thresholds()

    /// The defaults for a new install on a Mac with `totalGB` of memory: hold at 47 percent of it and critical
    /// at 70 percent, rounded to 5 GB, for the agents, Claude and Codex lines. A 128 GB Mac gets 60 and 90 GB,
    /// and a 32 GB Mac gets 15 and 20 GB. The free memory lines stay at 30 and 15 percent.
    public static func scaled(toMemoryGB totalGB: Double) -> Thresholds {
        guard totalGB > 0 else { return Thresholds() }
        func round5(_ v: Double) -> Double { (v / 5).rounded() * 5 }
        let hold = max(5, round5(totalGB * 0.47))
        let critical = max(hold + 5, round5(totalGB * 0.70))
        var t = Thresholds()
        t.agentsWarningGB = hold
        t.agentsCriticalGB = critical
        t.claudeWarningGB = hold
        t.claudeCriticalGB = critical
        t.codexWarningGB = hold
        t.codexCriticalGB = critical
        return t
    }

    /// Clamps values into sane ranges and keeps each critical line beyond its hold line.
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

    /// The hold and critical lines of one agent app.
    public func lines(_ app: AgentApp) -> (warning: Double, critical: Double) {
        switch app {
        case .claude: (claudeWarningGB, claudeCriticalGB)
        case .codex: (codexWarningGB, codexCriticalGB)
        }
    }
}

public enum RequestAction: String, Codable, Sendable, CaseIterable {
    case pause, resume, quit, restartClaude = "restart-claude", restartCodex = "restart-codex"

    public var label: String {
        switch self {
        case .pause: "Pause"
        case .resume: "Resume"
        case .quit: "Quit"
        case .restartClaude: "Restart Claude"
        case .restartCodex: "Restart Codex"
        }
    }

    /// The app a restart action restarts. Nil for the actions that take a pid.
    public var restarts: AgentApp? {
        switch self {
        case .restartClaude: .claude
        case .restartCodex: .codex
        default: nil
        }
    }

    public static let names = "pause, resume, quit, restart-claude, restart-codex"
}

public enum RequestStatus: String, Codable, Sendable {
    case pending, approved, denied, failed, expired
}

/// An agent's request that a person approve an action.
public struct AgentRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var action: RequestAction
    public var pid: Int32?
    public var processName: String?
    /// The target process's start time when the request was made, so a reused pid is never signalled.
    public var processStart: Double?
    public var reason: String
    public var from: String?
    public var createdAt: Date
    public var status: RequestStatus
    public var decidedAt: Date?
    public var result: String?

    public init(id: String, action: RequestAction, pid: Int32?, processName: String?, processStart: Double? = nil, reason: String,
                from: String?, createdAt: Date, status: RequestStatus = .pending, decidedAt: Date? = nil, result: String? = nil) {
        self.processStart = processStart
        self.id = id
        self.action = action
        self.pid = pid
        self.processName = processName
        self.reason = reason
        self.from = from
        self.createdAt = createdAt
        self.status = status
        self.decidedAt = decidedAt
        self.result = result
    }
}

/// An agent's announcement of a heavy job.
public struct AgentNote: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var gb: Double?
    public var label: String?
    public var pid: Int32?
    public var from: String?
    public var time: Date

    public init(id: String, text: String, gb: Double?, label: String?, pid: Int32?, from: String?, time: Date) {
        self.id = id
        self.text = text
        self.gb = gb
        self.label = label
        self.pid = pid
        self.from = from
        self.time = time
    }
}

/// The document written to state.json and served at GET /v1/status.
public struct StatusDocument: Codable, Equatable, Sendable {
    /// 2 since Codex: snapshot.codex, snapshot.agents, session.app and session.inApp (was inClaudeApp).
    /// Each app's total counts that app's terminal sessions too; appGB is the part in the desktop app.
    public var version: Int = 2
    public var source: String
    public var updatedAt: Date
    public var advice: Advice
    public var guidance: String
    public var reasons: [Reason]
    public var snapshot: Snapshot
    public var thresholds: Thresholds
    public var pendingRequests: [AgentRequest]
    public var notes: [AgentNote]

    public init(source: String, updatedAt: Date, advice: Advice, reasons: [Reason], snapshot: Snapshot,
                thresholds: Thresholds, pendingRequests: [AgentRequest] = [], notes: [AgentNote] = []) {
        self.source = source
        self.updatedAt = updatedAt
        self.advice = advice
        self.guidance = advice.guidance
        self.reasons = reasons
        self.snapshot = snapshot
        self.thresholds = thresholds
        self.pendingRequests = pendingRequests
        self.notes = notes
    }
}

public struct CanStart: Codable, Equatable, Sendable {
    public var ok: Bool
    public var advice: Advice
    public var reason: String
    public var freeGB: Double
    public var gb: Double
    public var label: String?

    public init(ok: Bool, advice: Advice, reason: String, freeGB: Double, gb: Double, label: String?) {
        self.ok = ok
        self.advice = advice
        self.reason = reason
        self.freeGB = freeGB
        self.gb = gb
        self.label = label
    }
}
