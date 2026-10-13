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
            "Critical: pause heavy jobs and restart Claude. All agent state is on disk, so a restart of the app loses no work."
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
    public var startTime: Double

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, gb: Double, stopped: Bool = false, session: String? = nil, startTime: Double = 0) {
        self.pid = pid
        self.name = name
        self.gb = gb
        self.stopped = stopped
        self.session = session
        self.startTime = startTime
    }
}

public struct ClaudeTotal: Codable, Equatable, Sendable {
    public var pid: Int32?
    public var totalGB: Double
    public var processCount: Int

    public init(pid: Int32?, totalGB: Double, processCount: Int) {
        self.pid = pid
        self.totalGB = totalGB
        self.processCount = processCount
    }
}

public struct AgentSession: Codable, Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var cwd: String?
    public var label: String
    public var totalGB: Double
    public var processCount: Int
    public var inClaudeApp: Bool
    public var top: [ProcSummary]

    public var id: Int32 { pid }

    public init(pid: Int32, cwd: String?, label: String, totalGB: Double, processCount: Int, inClaudeApp: Bool, top: [ProcSummary]) {
        self.pid = pid
        self.cwd = cwd
        self.label = label
        self.totalGB = totalGB
        self.processCount = processCount
        self.inClaudeApp = inClaudeApp
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
    public var stopped: Bool
    public var startTime: Double
    /// True for an app the person opened from /Applications, such as their own Google Chrome.
    /// Pause heavy jobs leaves these out; each still has its own Pause button.
    public var personApp: Bool?

    public var id: Int32 { pid }

    public init(pid: Int32, kind: HeavyKind, name: String, totalGB: Double, processCount: Int,
                session: String? = nil, stopped: Bool = false, startTime: Double = 0, personApp: Bool? = nil) {
        self.personApp = personApp
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

/// One sample of the whole machine, attributed to Claude, sessions and apps.
public struct Snapshot: Codable, Equatable, Sendable {
    public var time: Date
    public var system: SystemStats
    public var claude: ClaudeTotal
    public var sessions: [AgentSession]
    public var heavyJobs: [HeavyJob]
    public var apps: [AppTotal]
    public var largest: [ProcSummary]
    public var processCount: Int
    /// Processes whose footprint could not be read (other users, mostly root).
    public var unreadableCount: Int

    public init(time: Date, system: SystemStats, claude: ClaudeTotal, sessions: [AgentSession] = [],
                heavyJobs: [HeavyJob] = [], apps: [AppTotal] = [], largest: [ProcSummary] = [],
                processCount: Int = 0, unreadableCount: Int = 0) {
        self.time = time
        self.system = system
        self.claude = claude
        self.sessions = sessions
        self.heavyJobs = heavyJobs
        self.apps = apps
        self.largest = largest
        self.processCount = processCount
        self.unreadableCount = unreadableCount
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
    public var claudeWarningGB: Double = 40
    public var claudeCriticalGB: Double = 70
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

    /// Clamps values into sane ranges and keeps each critical line beyond its warning line.
    public func validated() -> Thresholds {
        var t = self
        t.claudeWarningGB = max(1, t.claudeWarningGB)
        t.claudeCriticalGB = max(t.claudeWarningGB, t.claudeCriticalGB)
        t.freeWarningPercent = min(95, max(1, t.freeWarningPercent))
        t.freeCriticalPercent = min(t.freeWarningPercent, max(0, t.freeCriticalPercent))
        t.processStepGB = max(1, t.processStepGB)
        t.sampleSeconds = min(600, max(5, t.sampleSeconds))
        t.lowSampleSeconds = min(t.sampleSeconds, max(2, t.lowSampleSeconds))
        t.repeatMinutes = max(1, t.repeatMinutes)
        return t
    }
}

public enum RequestAction: String, Codable, Sendable, CaseIterable {
    case pause, resume, quit, restartClaude = "restart-claude"

    public var label: String {
        switch self {
        case .pause: "Pause"
        case .resume: "Resume"
        case .quit: "Quit"
        case .restartClaude: "Restart Claude"
        }
    }
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
    public var version: Int = 1
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
