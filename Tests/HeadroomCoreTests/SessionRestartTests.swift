import Foundation
import Testing
@testable import HeadroomCore

@Suite("Session restart")
struct SessionRestartTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func iso(_ minutesAgo: Double) -> String { Format.iso(now.addingTimeInterval(-minutesAgo * 60)) }

    static func assistant(_ stop: String, _ minutesAgo: Double, tools: [String] = []) -> String {
        let blocks = tools.map { #"{"type":"tool_use","id":"t","name":"\#($0)","input":{}}"# } + [#"{"type":"text","text":"ok"}"#]
        return #"{"type":"assistant","timestamp":"\#(iso(minutesAgo))","message":{"role":"assistant","stop_reason":"\#(stop)","content":[\#(blocks.joined(separator: ","))]}}"#
    }

    static func prompt(_ minutesAgo: Double) -> String {
        #"{"type":"user","timestamp":"\#(iso(minutesAgo))","message":{"role":"user","content":"do it"}}"#
    }

    static func result(_ minutesAgo: Double) -> String {
        #"{"type":"user","timestamp":"\#(iso(minutesAgo))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"done"}]}}"#
    }

    static func queue(_ op: String, _ text: String?, _ minutesAgo: Double) -> String {
        #"{"type":"queue-operation","operation":"\#(op)","timestamp":"\#(iso(minutesAgo))"\#(text.map { #","content":"\#($0)""# } ?? "")}"#
    }

    static func tail(_ lines: [String]) -> SessionRestart.Tail {
        SessionRestart.tail(Data(lines.joined(separator: "\n").utf8))
    }

    @Test func anEndedTurnWithNothingQueuedIsIdle() {
        let t = SessionRestartTests.tail([
            SessionRestartTests.prompt(30), SessionRestartTests.assistant("tool_use", 29, tools: ["Bash"]),
            SessionRestartTests.result(28), SessionRestartTests.assistant("end_turn", 27),
            #"{"type":"system","subtype":"stop_hook_summary"}"#, #"{"type":"last-prompt"}"#,
        ])
        #expect(t.known && t.queued == 0 && t.timers.isEmpty)
        #expect(t.endedAt == SessionRestartTests.now.addingTimeInterval(-27 * 60))
    }

    @Test func aTurnInProgressIsNotIdle() {
        #expect(SessionRestartTests.tail([SessionRestartTests.assistant("end_turn", 30), SessionRestartTests.prompt(2)]).endedAt == nil)
        #expect(SessionRestartTests.tail([SessionRestartTests.prompt(5), SessionRestartTests.assistant("tool_use", 4)]).endedAt == nil)
        #expect(!SessionRestartTests.tail([#"{"type":"last-prompt"}"#]).known)
    }

    @Test func messagesQueuedAfterTheTurnCountUntilTaken() {
        let s = SessionRestartTests.self
        #expect(s.tail([s.assistant("end_turn", 30), s.queue("enqueue", "a", 20), s.queue("enqueue", "b", 19)]).queued == 2)
        // remove names its message; dequeue takes the oldest and carries no content.
        #expect(s.tail([s.assistant("end_turn", 30), s.queue("enqueue", "a", 20), s.queue("enqueue", "b", 19),
                        s.queue("remove", "b", 18), s.queue("dequeue", nil, 17)]).queued == 0)
        // A remove for a message enqueued before the tail takes nothing else.
        #expect(s.tail([s.assistant("end_turn", 30), s.queue("enqueue", "a", 20), s.queue("remove", "zzz", 18)]).queued == 1)
        // Messages handled before the turn ended are not waiting.
        #expect(s.tail([s.queue("enqueue", "a", 40), s.prompt(39), s.assistant("end_turn", 30)]).queued == 0)
    }

    @Test func timersSetInTheLastTurnKeepItAlive() {
        let s = SessionRestartTests.self
        let t = s.tail([s.prompt(40), s.assistant("tool_use", 39, tools: ["ScheduleWakeup"]), s.result(39), s.assistant("end_turn", 38)])
        #expect(t.timers == ["ScheduleWakeup"])
        // A timer from an earlier turn has done its work by the next prompt.
        #expect(s.tail([s.assistant("tool_use", 90, tools: ["Monitor"]), s.result(89), s.assistant("end_turn", 88),
                        s.prompt(40), s.assistant("end_turn", 38)]).timers.isEmpty)
    }

    @Test func theSessionIDComesFromTheResumeArgument() {
        #expect(SessionRestart.sessionID(["claude", "--verbose", "--resume=79c55030-426e", "--model=x"]) == "79c55030-426e")
        #expect(SessionRestart.sessionID(["claude", "--session-id", "abc"]) == "abc")
        #expect(SessionRestart.sessionID(["claude", "--verbose"]) == nil)
    }

    @Test func projectFoldersReplaceEveryOtherCharacterWithADash() {
        #expect(SessionRestart.projectFolder("/Users/k/.codex/worktrees/cot-restore") == "-Users-k--codex-worktrees-cot-restore")
        #expect(SessionRestart.projectFolder("/Users/k/Library/Application Support/Claude") == "-Users-k-Library-Application-Support-Claude")
    }

    // MARK: The whole check

    static func setUp(_ lines: [String], subagentMinutesAgo: Double? = nil) throws -> (URL, [Proc], AgentSession) {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-restart-\(UUID().uuidString)")
        let dir = projects.appendingPathComponent("-Users-k-code-web-app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("abc.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        if let m = subagentMinutesAgo {
            let sub = dir.appendingPathComponent("abc/subagents")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let f = sub.appendingPathComponent("agent-1.jsonl")
            try Data("{}\n".utf8).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-m * 60)], ofItemAtPath: f.path)
        }
        let procs = [
            Fixture.proc(500, 400, Fixture.claudeCode, gb: 18, cwd: "/Users/k/code/web-app", args: ["claude", "--resume=abc"]),
            Fixture.proc(501, 500, "/usr/local/bin/node", gb: 0.2, args: ["node", "mcp-server.js"]),
        ]
        let session = AgentSession(pid: 500, cwd: "/Users/k/code/web-app", label: "web-app", totalGB: 18.2, processGB: 18,
                                   busyPercent: 1, processCount: 2, inApp: true, startTime: 500, top: [])
        return (projects, procs, session)
    }

    @Test func anIdleSessionIsSafeAndABusyOneSaysWhy() throws {
        let s = SessionRestartTests.self
        let (projects, procs, session) = try s.setUp([s.prompt(40), s.assistant("end_turn", 30)])
        let ok = SessionRestart.check(session, procs: procs, now: s.now, projects: projects)
        #expect(ok.safe, "\(ok.reason)")
        #expect(ok.gb == 18 && ok.startTime == 500)

        var busy = session
        busy.busyPercent = 60
        #expect(SessionRestart.check(busy, procs: procs, now: s.now, projects: projects).reason.contains("60 percent"))
        busy.busyPercent = nil
        #expect(SessionRestart.check(busy, procs: procs, now: s.now, projects: projects).reason.contains("less than 10 minutes"))

        // A Bash tool shell still running under the session.
        let shell = Fixture.proc(502, 500, "/bin/zsh", gb: 0.01, args: ["/bin/zsh", "-c", "source /Users/k/.claude/shell-snapshots/snapshot-zsh-1.sh && sleep 600"])
        #expect(SessionRestart.check(session, procs: procs + [shell], now: s.now, projects: projects).reason == "a shell of its is running")
    }

    @Test func aRecentReplyOrSubagentWaits() throws {
        let s = SessionRestartTests.self
        let (p1, procs, session) = try s.setUp([s.prompt(6), s.assistant("end_turn", 4)])
        #expect(SessionRestart.check(session, procs: procs, now: s.now, projects: p1).reason == "it replied 4 min ago")
        let (p2, _, _) = try s.setUp([s.prompt(40), s.assistant("end_turn", 30)], subagentMinutesAgo: 2)
        #expect(SessionRestart.check(session, procs: procs, now: s.now, projects: p2).reason == "a subagent wrote 2 min ago")
    }

    @Test func onlyBloatedDesktopClaudeSessionsAreRecommended() {
        func session(_ pid: Int32, _ app: AgentApp, own: Double?, inApp: Bool) -> AgentSession {
            AgentSession(pid: pid, app: app, cwd: "/x", label: "s\(pid)", totalGB: 20, processGB: own, processCount: 1, inApp: inApp, top: [])
        }
        var snap = Fixture.snapshot(claudeGB: 60)
        snap.sessions = [session(1, .claude, own: 17, inApp: true), session(2, .claude, own: 17, inApp: false),
                         session(3, .claude, own: 3, inApp: true), session(-4, .codex, own: nil, inApp: true),
                         session(5, .codex, own: 20, inApp: true)]
        #expect(SessionRestart.candidates(snap, .defaults).map(\.pid) == [1])
        #expect(Policy.evaluate(snap, .defaults).reasons.filter { $0.check == "session" }.compactMap(\.pid).contains(1))
    }
}
