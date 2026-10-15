import Foundation

/// The PreToolUse handler for Bash, for Claude Code and for Codex.
///
/// Input is the hook JSON on stdin (tool_name, tool_input.command, cwd and the common fields); both agents send
/// the same fields for a Bash call. Output follows the PreToolUse schema: hookSpecificOutput with hookEventName
/// "PreToolUse", and either additionalContext alone (the command runs through the normal permission flow)
/// or, for Claude Code at critical, permissionDecision "ask" with permissionDecisionReason (the person decides).
/// Codex does not support "ask" in PreToolUse yet, so at critical the Codex output adds a systemMessage that the
/// person sees, and the command runs.
public enum Hook {
    public enum Agent: String, Sendable {
        case claudeCode = "claude-code", codex
    }

    public struct Decision: Equatable {
        public var advice: Advice
        public var match: HeavyClassifier.CommandMatch
        public var command: String
        public var output: [String: Any]

        public static func == (a: Decision, b: Decision) -> Bool {
            a.advice == b.advice && a.match == b.match && a.command == b.command
        }
    }

    /// Returns the command when the input is a Bash PreToolUse call, else nil.
    public static func bashCommand(from input: Data) -> (command: String, cwd: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        if let event = obj["hook_event_name"] as? String, event != "PreToolUse" { return nil }
        guard (obj["tool_name"] as? String) == "Bash",
              let toolInput = obj["tool_input"] as? [String: Any],
              let command = toolInput["command"] as? String else { return nil }
        return (command, obj["cwd"] as? String)
    }

    /// Decides the hook output. Returns nil when the hook prints nothing and the command proceeds as usual.
    public static func decide(input: Data, agent: Agent = .claudeCode, status: () -> StatusDocument?) -> Decision? {
        guard let parsed = bashCommand(from: input),
              let match = HeavyClassifier.classify(command: parsed.command),
              let doc = status() else { return nil }
        let command = parsed.command
        let s = doc.snapshot
        let state = "\(Policy.totalsSentence(s)) \(s.system.freePercent) percent of memory is free (\(Format.gb(s.system.freeGB))), swap \(Format.gb(s.system.swapUsedGB)), pressure \(s.system.pressure.rawValue)."
        let reasons = doc.reasons.map(\.message).joined(separator: " ")
        let top = s.sessions.prefix(3).map { "\($0.app.name) \($0.label) \(Format.gb($0.totalGB))" }.joined(separator: ", ")
        switch doc.advice {
        case .ok:
            return nil
        case .hold:
            let context = """
            Headroom memory advice is hold. Headroom let this command run; it looks like \(match.what). \(state) \(reasons) \
            Largest agent sessions: \(top.isEmpty ? "none" : top). \
            Start nothing else that is heavy. Before the next heavy command, run `headroom wait --gb <estimated GB>`, \
            or leave that job for later. Announce a heavy job with `headroom note`.
            """
            return Decision(advice: .hold, match: match, command: command, output: [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "additionalContext": context,
                ],
            ])
        case .critical where agent == .codex:
            let context = """
            Headroom memory advice is critical. Headroom let this command run; it looks like \(match.what). \(state) \(reasons) \
            Largest agent sessions: \(top.isEmpty ? "none" : top). Start nothing else that is heavy. \
            Wait with `headroom wait --gb <estimated GB>` before the next heavy command, or leave it for later. \(Advice.critical.guidance)
            """
            return Decision(advice: .critical, match: match, command: command, output: [
                "systemMessage": "Headroom: memory is critical. \(reasons) An agent is running \(match.what).",
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "additionalContext": context,
                ],
            ])
        case .critical:
            let reason = "Headroom: memory is critical. This command looks like \(match.what). \(state) \(reasons) Allow it only if it is needed now."
            let context = """
            Headroom memory advice is critical. \(state) \(reasons) Largest agent sessions: \(top.isEmpty ? "none" : top). \
            The person was asked whether to run this command. If it is not urgent, do not retry it; \
            wait with `headroom wait --gb <estimated GB>` or leave it for later. \(Advice.critical.guidance)
            """
            return Decision(advice: .critical, match: match, command: command, output: [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "ask",
                    "permissionDecisionReason": reason,
                    "additionalContext": context,
                ],
            ])
        }
    }

    /// Serializes the output for stdout.
    public static func render(_ d: Decision) -> Data? {
        try? JSONSerialization.data(withJSONObject: d.output, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

// MARK: - Sessions: recovery notes and early warnings

extension Hook {
    /// The context Headroom adds for the calling session, on SessionStart, UserPromptSubmit or PreToolUse:
    /// a recovery note waiting since a rescue, given once, and a warning when the session is bloated, heavy, busy
    /// or polling, at most once every `warnMinutes`. Nil when there is nothing to add.
    public static func sessionContext(input: Data, paths: Paths, sessions: () -> SessionsDocument?,
                                      now: Date = Date(), warnMinutes: Double = 30) -> (event: String, context: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let id = obj["session_id"] as? String, !id.isEmpty else { return nil }
        let event = obj["hook_event_name"] as? String ?? "PreToolUse"
        guard ["SessionStart", "UserPromptSubmit", "PreToolUse"].contains(event) else { return nil }
        var parts: [String] = []
        if let pending = PendingRescue.take(sessionId: id, paths: paths) { parts.append(pending.message) }
        if let s = sessions()?.sessions.first(where: { $0.sessionId == id }), let warning = warning(for: s),
           warnDue(sessionId: id, paths: paths, now: now, minutes: warnMinutes) {
            parts.append(warning)
        }
        return parts.isEmpty ? nil : (event, parts.joined(separator: "\n\n"))
    }

    /// What to tell a session about its own health so it does not get worse, or nil when it is fine.
    public static func warning(for s: WatchedSession) -> String? {
        let f = Set(s.flags)
        guard !f.isDisjoint(with: [.bloated, .heavy, .busy, .polling]) else { return nil }
        var advice: [String] = []
        if f.contains(.heavy) || f.contains(.bloated) {
            advice.append("Keep new images and long outputs out of this conversation: resize screenshots before reading them, read files in ranges, and let a subagent look at bulky material and report back in a few lines.")
        }
        if f.contains(.polling) {
            advice.append("Stop polling loops whose result you no longer need, and wait with one background monitor instead of many sleep loops.")
        }
        if f.contains(.busy) || f.contains(.bloated) {
            advice.append("Keep fewer subagents running in this session at once. If it keeps growing, write a handoff and continue in a fresh session.")
        }
        return "Headroom: this session \(s.notes.joined(separator: ", ")). \(advice.joined(separator: " ")) A session that grows without limit stops answering; Headroom then rescues it, which saves its work but interrupts it."
    }

    static func warnDue(sessionId: String, paths: Paths, now: Date, minutes: Double) -> Bool {
        let url = paths.dir.appendingPathComponent("hook-warned.json")
        var seen = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] } ?? [:]
        let t = now.timeIntervalSince1970
        if let last = seen[sessionId], t - last < minutes * 60 { return false }
        seen[sessionId] = t
        seen = seen.filter { t - $0.value < 86_400 }
        paths.ensureDir()
        if let d = try? JSONSerialization.data(withJSONObject: seen) { try? d.write(to: url, options: .atomic) }
        return true
    }

    /// Adds session context to a hook's output, keeping any decision already in it.
    public static func merge(_ output: [String: Any]?, event: String, context: String) -> [String: Any] {
        var out = output ?? [:]
        var specific = out["hookSpecificOutput"] as? [String: Any] ?? ["hookEventName": event]
        let existing = specific["additionalContext"] as? String
        specific["additionalContext"] = existing.map { context + "\n\n" + $0 } ?? context
        out["hookSpecificOutput"] = specific
        return out
    }
}
