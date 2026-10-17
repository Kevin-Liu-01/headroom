import Foundation

/// Turns a snapshot into a level: ok, warning or critical. Headroom only shows the level; it never acts on it.
public enum Policy {
    public struct Evaluation: Equatable, Sendable {
        public var level: Level
        public var reasons: [Reason]
        /// Processes at or above one process step, with the step reached.
        public var bigProcesses: [(proc: ProcSummary, step: Int)]

        public static func == (a: Evaluation, b: Evaluation) -> Bool {
            a.level == b.level && a.reasons == b.reasons
                && a.bigProcesses.map { "\($0.proc.pid):\($0.step)" } == b.bigProcesses.map { "\($0.proc.pid):\($0.step)" }
        }
    }

    /// A session process averaging at least this much CPU over 10 minutes is stuck: a conversation that waits on
    /// the model or on tools uses a few percent. On 2026-10-14 two stuck sessions ran at 60 to 200 percent for
    /// hours and answered nothing, while idle sessions used 0 to 7 percent.
    public static let busySessionPercent: Double = 50

    /// GB held by the session processes themselves, the Claude Code or Codex binary of each session.
    public static func sessionProcessGB(_ s: Snapshot, _ app: AgentApp) -> Double {
        s.sessions(of: app).reduce(0) { $0 + ($1.processGB ?? 0) }
    }

    /// An app's total without its session processes: the app itself and the jobs, servers and browsers its
    /// agents started. The warning and critical lines measure this. A session process grows with its
    /// conversation and only a restart frees it, so counting it would keep the level up for as long as one
    /// session stays bloated. Free memory and pressure still count everything.
    public static func workGB(_ s: Snapshot, _ app: AgentApp) -> Double {
        max(0, Format.round2(s.total(app).totalGB - sessionProcessGB(s, app)))
    }

    /// Every agent's work: the agents' total without any session process.
    public static func agentsWorkGB(_ s: Snapshot) -> Double {
        max(0, Format.round2(s.agents.totalGB - sessionProcessGB(s, .claude) - sessionProcessGB(s, .codex)))
    }

    public static func evaluate(_ s: Snapshot, _ t: Thresholds) -> Evaluation {
        var reasons: [Reason] = []
        // The combined total first, then each app with its own lines.
        let claudeWork = workGB(s, .claude), codexWork = workGB(s, .codex)
        let totals: [(check: String, subject: String, gb: Double, work: Double, warning: Double, critical: Double)] = [
            ("agents", "The agents use", s.agents.totalGB, agentsWorkGB(s), t.agentsWarningGB, t.agentsCriticalGB),
            ("claude", "Claude uses", s.claude.totalGB, claudeWork, t.claudeWarningGB, t.claudeCriticalGB),
            ("codex", "Codex uses", s.codex.totalGB, codexWork, t.codexWarningGB, t.codexCriticalGB),
        ]
        for c in totals {
            var what = c.check == "agents" ? "\(c.subject) \(Format.gb(c.gb)) in total" : "\(c.subject) \(Format.gb(c.gb))"
            what += c.gb - c.work >= 1 ? ", \(Format.gb(c.work)) of it outside the sessions' own processes," : ","
            if c.work >= c.critical {
                reasons.append(Reason(check: c.check, level: .critical, message: "\(what) above the \(Format.gb(c.critical)) critical line."))
            } else if c.work >= c.warning {
                reasons.append(Reason(check: c.check, level: .warning, message: "\(what) above the \(Format.gb(c.warning)) warning line."))
            }
        }

        let free = Double(s.system.freePercent)
        if free < t.freeCriticalPercent {
            reasons.append(Reason(check: "free", level: .critical,
                                  message: "Free memory is \(s.system.freePercent) percent (\(Format.gb(s.system.freeGB))), below the \(Int(t.freeCriticalPercent)) percent critical line."))
        } else if free < t.freeWarningPercent {
            reasons.append(Reason(check: "free", level: .warning,
                                  message: "Free memory is \(s.system.freePercent) percent (\(Format.gb(s.system.freeGB))), below the \(Int(t.freeWarningPercent)) percent warning line."))
        }

        switch s.system.pressure {
        case .critical:
            reasons.append(Reason(check: "pressure", level: .critical, message: "The system reports critical memory pressure."))
        case .warning:
            // Above the free memory warning line, the system's warning is mostly the compressor holding idle
            // memory, such as a bloated session's, so it is a note.
            if free < t.freeWarningPercent {
                reasons.append(Reason(check: "pressure", level: .warning, message: "The system reports memory pressure."))
            } else {
                reasons.append(Reason(check: "pressure", level: .ok,
                                      message: "The system reports memory pressure, and \(s.system.freePercent) percent of memory is free."))
            }
        case .normal:
            break
        }

        // A bloated or busy session is a note: it does not raise the level.
        for x in s.sessions {
            let own = x.processGB ?? 0
            let stuck = (x.busyPercent ?? 0) >= Policy.busySessionPercent
            guard own >= t.processStepGB || stuck else { continue }
            var parts: [String] = []
            if own >= t.processStepGB { parts.append("holds \(Format.gb(own)) in its own \(x.app.name) process") }
            if stuck { parts.append("has kept \(Int(x.busyPercent ?? 0)) percent of a CPU core busy for 10 minutes, so it cannot answer") }
            reasons.append(Reason(check: "session", level: .ok,
                                  message: "Session \(x.label) \(parts.joined(separator: " and ")). Its conversation is saved on disk, and a restart of the session frees its memory."))
        }

        let level = reasons.map(\.level).max() ?? .ok
        var big: [(ProcSummary, Int)] = []
        for p in s.largest {
            let step = Int(p.gb / t.processStepGB)
            if step >= 1 { big.append((p, step)) }
        }
        return Evaluation(level: level, reasons: reasons, bigProcesses: big)
    }

    /// "The agents use 58.9 GB (Claude 46.8 GB, Codex 12.1 GB)." for messages that name both apps.
    public static func totalsSentence(_ s: Snapshot) -> String {
        let apps = AgentApp.allCases.map { app in
            let t = s.total(app)
            return t.pid == nil && t.totalGB == 0 ? "\(app.name) not running" : "\(app.name) \(Format.gb(t.totalGB))"
        }
        return "The agents use \(Format.gb(s.agents.totalGB)) (\(apps.joined(separator: ", ")))."
    }

    public static func status(_ s: Snapshot, _ t: Thresholds, source: String) -> StatusDocument {
        let e = evaluate(s, t)
        return StatusDocument(source: source, updatedAt: s.time, level: e.level, reasons: e.reasons, snapshot: s, thresholds: t)
    }

    /// Whether a job that needs `gb` gigabytes fits now, for scripts that check before they start one.
    /// A job fits when the level is ok, the free memory after it stays above the warning line,
    /// and the agents' work after it stays below the agents' critical line.
    public static func canStart(gb: Double, label: String?, status: StatusDocument) -> CanStart {
        let s = status.snapshot
        let t = status.thresholds
        let free = s.system.freeGB
        func answer(_ ok: Bool, _ reason: String) -> CanStart {
            CanStart(ok: ok, level: status.level, reason: reason, freeGB: free, gb: gb, label: label)
        }
        if status.level != .ok {
            let why = status.reasons.first { $0.level == status.level }?.message ?? ""
            return answer(false, "Memory is at \(status.level.rawValue). \(why)")
        }
        let total = max(s.system.totalGB, 1)
        let after = free - gb
        let afterPct = after / total * 100
        if after <= 0 {
            return answer(false, "A job of \(Format.gb(gb)) needs more than the \(Format.gb(free)) that is free.")
        }
        if afterPct < t.freeWarningPercent {
            return answer(false, String(format: "A job of %@ would leave %@ free (%.0f percent), below the %.0f percent warning line.",
                                        Format.gb(gb), Format.gb(after), afterPct, t.freeWarningPercent))
        }
        let agentsAfter = agentsWorkGB(s) + gb
        if agentsAfter >= t.agentsCriticalGB {
            return answer(false, "A job of \(Format.gb(gb)) would bring the agents' work to \(Format.gb(agentsAfter)), above the \(Format.gb(t.agentsCriticalGB)) critical line.")
        }
        return answer(true, String(format: "%@ free. A job of %@ leaves %@ (%.0f percent).",
                                   Format.gb(free), Format.gb(gb), Format.gb(after), afterPct))
    }
}

/// Decides when to notify. Pure: it takes the evaluation and the time and returns the alerts to show.
public struct AlertEngine: Sendable {
    public enum Kind: String, Codable, Sendable {
        case crossing, repeated = "repeat", recovery, process
    }

    public struct Alert: Equatable, Sendable {
        public var kind: Kind
        public var level: Level
        public var title: String
        public var body: String
    }

    /// The level the person was last told about.
    public private(set) var announced: Level = .ok
    public private(set) var lastAlertAt: Date?
    private var lowerStreak = 0
    private var processSteps: [String: Int] = [:]
    /// Samples a lower level must hold before Headroom announces the improvement.
    public var settleSamples = 3

    public init() {}

    public mutating func step(_ status: StatusDocument, evaluation e: Policy.Evaluation, now: Date) -> [Alert] {
        var out: [Alert] = []
        let t = status.thresholds
        let s = status.snapshot
        let current = e.level

        if current > announced {
            announced = current
            lowerStreak = 0
            lastAlertAt = now
            out.append(Alert(kind: .crossing, level: current, title: title(current, s), body: body(status, e)))
        } else if current < announced {
            lowerStreak += 1
            if lowerStreak >= settleSamples {
                let was = announced
                announced = current
                lowerStreak = 0
                if current == .ok {
                    lastAlertAt = nil
                    out.append(Alert(kind: .recovery, level: .ok, title: "Memory recovered",
                                     body: "Memory is back to ok after \(was.rawValue). \(Policy.totalsSentence(s)) \(s.system.freePercent) percent of memory is free."))
                } else {
                    lastAlertAt = now
                    out.append(Alert(kind: .crossing, level: current, title: title(current, s), body: body(status, e)))
                }
            }
        } else {
            lowerStreak = 0
            if current != .ok, let last = lastAlertAt, now.timeIntervalSince(last) >= t.repeatMinutes * 60 {
                lastAlertAt = now
                out.append(Alert(kind: .repeated, level: current, title: title(current, s) + " (still)", body: body(status, e)))
            }
        }

        // Process steps: one alert each time a process crosses another step.
        var seen = Set<String>()
        for (p, step) in e.bigProcesses {
            let key = "\(p.pid):\(Int(p.startTime))"
            seen.insert(key)
            if step > (processSteps[key] ?? 0) {
                processSteps[key] = step
                let owner = p.session.map { " in session \($0)" } ?? ""
                let passed = Format.gb(Double(step) * t.processStepGB)
                let body: String
                if let x = s.sessions.first(where: { $0.pid == p.pid }) {
                    body = "Process \(p.pid) is session \(x.label)'s own \(x.app.name) process and passed \(passed). Restart the session to free it; its conversation is on disk."
                } else {
                    let state = current == .ok
                        ? "\(s.system.freePercent) percent of memory is still free."
                        : current.guidance
                    body = "Process \(p.pid)\(owner) passed \(passed). \(state)"
                }
                out.append(Alert(kind: .process, level: current, title: "\(p.name) uses \(Format.gb(p.gb))", body: body))
            }
        }
        processSteps = processSteps.filter { seen.contains($0.key) }
        return out
    }

    func title(_ a: Level, _ s: Snapshot) -> String {
        switch a {
        case .critical: "Critical: agents \(Format.gb(s.agents.totalGB)), \(s.system.freePercent)% free"
        case .warning: "Warning: agents \(Format.gb(s.agents.totalGB)), \(s.system.freePercent)% free"
        case .ok: "Memory is fine"
        }
    }

    func body(_ status: StatusDocument, _ e: Policy.Evaluation) -> String {
        let s = status.snapshot
        var lines: [String] = []
        if let r = e.reasons.first { lines.append(r.message) }
        let sessions = s.sessions.prefix(3).map { "\($0.app.name) \($0.label) \(Format.gb($0.totalGB))" }
        if !sessions.isEmpty { lines.append("Sessions: " + sessions.joined(separator: ", ") + ".") }
        let procs = s.largest.prefix(3).map { p in "\(p.name)\(p.session.map { " (\($0))" } ?? "") \(Format.gb(p.gb))" }
        if !procs.isEmpty { lines.append("Processes: " + procs.joined(separator: ", ") + ".") }
        return lines.joined(separator: "\n")
    }
}
