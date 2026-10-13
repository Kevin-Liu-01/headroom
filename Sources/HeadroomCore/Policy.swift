import Foundation

/// Turns a snapshot into advice. Headroom only advises; it never acts on its own.
public enum Policy {
    public struct Evaluation: Equatable, Sendable {
        public var advice: Advice
        public var reasons: [Reason]
        /// Processes at or above one process step, with the step reached.
        public var bigProcesses: [(proc: ProcSummary, step: Int)]

        public static func == (a: Evaluation, b: Evaluation) -> Bool {
            a.advice == b.advice && a.reasons == b.reasons
                && a.bigProcesses.map { "\($0.proc.pid):\($0.step)" } == b.bigProcesses.map { "\($0.proc.pid):\($0.step)" }
        }
    }

    public static func evaluate(_ s: Snapshot, _ t: Thresholds) -> Evaluation {
        var reasons: [Reason] = []
        let claude = s.claude.totalGB
        if claude >= t.claudeCriticalGB {
            reasons.append(Reason(check: "claude", level: .critical,
                                  message: "Claude uses \(Format.gb(claude)), above the \(Format.gb(t.claudeCriticalGB)) critical line."))
        } else if claude >= t.claudeWarningGB {
            reasons.append(Reason(check: "claude", level: .hold,
                                  message: "Claude uses \(Format.gb(claude)), above the \(Format.gb(t.claudeWarningGB)) warning line."))
        }

        let free = Double(s.system.freePercent)
        if free < t.freeCriticalPercent {
            reasons.append(Reason(check: "free", level: .critical,
                                  message: "Free memory is \(s.system.freePercent) percent (\(Format.gb(s.system.freeGB))), below the \(Int(t.freeCriticalPercent)) percent critical line."))
        } else if free < t.freeWarningPercent {
            reasons.append(Reason(check: "free", level: .hold,
                                  message: "Free memory is \(s.system.freePercent) percent (\(Format.gb(s.system.freeGB))), below the \(Int(t.freeWarningPercent)) percent warning line."))
        }

        switch s.system.pressure {
        case .critical:
            reasons.append(Reason(check: "pressure", level: .critical, message: "The system reports critical memory pressure."))
        case .warning:
            reasons.append(Reason(check: "pressure", level: .hold, message: "The system reports memory pressure."))
        case .normal:
            break
        }

        let advice = reasons.map(\.level).max() ?? .ok
        var big: [(ProcSummary, Int)] = []
        for p in s.largest {
            let step = Int(p.gb / t.processStepGB)
            if step >= 1 { big.append((p, step)) }
        }
        return Evaluation(advice: advice, reasons: reasons, bigProcesses: big)
    }

    public static func status(_ s: Snapshot, _ t: Thresholds, source: String,
                              requests: [AgentRequest] = [], notes: [AgentNote] = []) -> StatusDocument {
        let e = evaluate(s, t)
        return StatusDocument(source: source, updatedAt: s.time, advice: e.advice, reasons: e.reasons, snapshot: s,
                              thresholds: t, pendingRequests: requests, notes: notes)
    }

    /// Whether an agent may start a job that needs `gb` gigabytes now.
    /// A job is fine when the advice is ok, the free memory after it stays above the warning line,
    /// and the Claude total after it stays below the critical line.
    public static func canStart(gb: Double, label: String?, status: StatusDocument) -> CanStart {
        let s = status.snapshot
        let t = status.thresholds
        let free = s.system.freeGB
        func answer(_ ok: Bool, _ reason: String) -> CanStart {
            CanStart(ok: ok, advice: status.advice, reason: reason, freeGB: free, gb: gb, label: label)
        }
        if status.advice != .ok {
            let why = status.reasons.first?.message ?? ""
            return answer(false, "Advice is \(status.advice.rawValue). \(why) \(status.advice.guidance)")
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
        let claudeAfter = s.claude.totalGB + gb
        if claudeAfter >= t.claudeCriticalGB {
            return answer(false, "A job of \(Format.gb(gb)) would bring Claude to \(Format.gb(claudeAfter)), above the \(Format.gb(t.claudeCriticalGB)) critical line.")
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
        public var advice: Advice
        public var title: String
        public var body: String
    }

    /// The advice the person was last told about.
    public private(set) var announced: Advice = .ok
    public private(set) var lastAlertAt: Date?
    private var lowerStreak = 0
    private var processSteps: [String: Int] = [:]
    /// Samples a lower advice must hold before Headroom announces the improvement.
    public var settleSamples = 3

    public init() {}

    public mutating func step(_ status: StatusDocument, evaluation e: Policy.Evaluation, now: Date) -> [Alert] {
        var out: [Alert] = []
        let t = status.thresholds
        let s = status.snapshot
        let current = e.advice

        if current > announced {
            announced = current
            lowerStreak = 0
            lastAlertAt = now
            out.append(Alert(kind: .crossing, advice: current, title: title(current, s), body: body(status, e)))
        } else if current < announced {
            lowerStreak += 1
            if lowerStreak >= settleSamples {
                let was = announced
                announced = current
                lowerStreak = 0
                if current == .ok {
                    lastAlertAt = nil
                    out.append(Alert(kind: .recovery, advice: .ok, title: "Memory recovered",
                                     body: "Advice is back to ok after \(was.rawValue). Claude uses \(Format.gb(s.claude.totalGB)) and \(s.system.freePercent) percent of memory is free."))
                } else {
                    lastAlertAt = now
                    out.append(Alert(kind: .crossing, advice: current, title: title(current, s), body: body(status, e)))
                }
            }
        } else {
            lowerStreak = 0
            if current != .ok, let last = lastAlertAt, now.timeIntervalSince(last) >= t.repeatMinutes * 60 {
                lastAlertAt = now
                out.append(Alert(kind: .repeated, advice: current, title: title(current, s) + " (still)", body: body(status, e)))
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
                let state = current == .ok
                    ? "\(s.system.freePercent) percent of memory is still free."
                    : current.guidance
                out.append(Alert(kind: .process, advice: current,
                                 title: "\(p.name) uses \(Format.gb(p.gb))",
                                 body: "Process \(p.pid)\(owner) passed \(Format.gb(Double(step) * t.processStepGB)). \(state)"))
            }
        }
        processSteps = processSteps.filter { seen.contains($0.key) }
        return out
    }

    func title(_ a: Advice, _ s: Snapshot) -> String {
        switch a {
        case .critical: "Critical: Claude \(Format.gb(s.claude.totalGB)), \(s.system.freePercent)% free"
        case .hold: "Hold: Claude \(Format.gb(s.claude.totalGB)), \(s.system.freePercent)% free"
        case .ok: "Memory is fine"
        }
    }

    func body(_ status: StatusDocument, _ e: Policy.Evaluation) -> String {
        let s = status.snapshot
        var lines: [String] = []
        if let r = e.reasons.first { lines.append(r.message) }
        let sessions = s.sessions.prefix(3).map { "\($0.label) \(Format.gb($0.totalGB))" }
        if !sessions.isEmpty { lines.append("Sessions: " + sessions.joined(separator: ", ") + ".") }
        let procs = s.largest.prefix(3).map { p in "\(p.name)\(p.session.map { " (\($0))" } ?? "") \(Format.gb(p.gb))" }
        if !procs.isEmpty { lines.append("Processes: " + procs.joined(separator: ", ") + ".") }
        return lines.joined(separator: "\n")
    }
}
