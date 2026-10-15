import Foundation
import Testing
@testable import HeadroomCore

@Suite("Session watch and rescue")
struct SessionWatchTests {
    static func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    static func t(_ minute: Int) -> String { "2026-10-14T22:\(String(format: "%02d", minute)):00.000Z" }

    static func assistant(_ minute: Int, tool: (id: String, name: String, command: String)? = nil) -> String {
        var content: [[String: Any]] = [["type": "text", "text": "working"]]
        if let tool { content.append(["type": "tool_use", "id": tool.id, "name": tool.name, "input": ["command": tool.command, "description": "Run \(tool.command)"]]) }
        return line(["type": "assistant", "timestamp": t(minute), "message": ["content": content]])
    }

    static func result(_ minute: Int, id: String) -> String {
        line(["type": "user", "timestamp": t(minute), "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }

    static func queue(_ minute: Int, _ op: String, _ content: Any? = nil) -> String {
        var o: [String: Any] = ["type": "queue-operation", "operation": op, "timestamp": t(minute)]
        if let content { o["content"] = content }
        return line(o)
    }

    // MARK: conversations

    @Test func aFrozenConversationKeepsWhatArrivedAfterItsLastReply() {
        // The coordinator: a browser step returned at 22:09, nothing replied after, and messages piled up.
        let text = [
            Self.queue(1, "enqueue", "old notice delivered mid-turn"),
            Self.assistant(5, tool: (id: "t1", name: "find", command: "find menu")),
            Self.result(9, id: "t1"),
            Self.queue(16, "enqueue", "<agent-message from=\"a1\">\nreport</agent-message>"),
            Self.queue(23, "enqueue", "<task-notification>\nmonitor</task-notification>"),
            Self.queue(23, "remove", "<task-notification>\nmonitor</task-notification>"),
            Self.queue(32, "enqueue", "make missile trails better"),
            Self.queue(48, "enqueue", "hello?"),
        ].joined(separator: "\n")
        let c = SessionFiles.readConversation(Data(text.utf8))
        #expect(c.lastReply == Format.parseISO(Self.t(5)))
        #expect(c.awaitingReply, "a tool result came back and no reply followed")
        #expect(c.unread.map(\.kind) == [.agent, .person, .person])
        #expect(c.unread.last?.text == "hello?")
        #expect(c.pending == nil, "its last tool call has a result")
    }

    @Test func dequeueAndImageMessagesLeaveTheQueue() {
        let text = [
            Self.assistant(1),
            Self.queue(2, "enqueue", [["type": "text", "text": "look at this"], ["type": "image", "source": [:]]]),
            Self.queue(3, "enqueue"),
            Self.queue(3, "dequeue"),
            Self.queue(4, "enqueue", "with a screenshot"),
        ].joined(separator: "\n")
        var c = SessionFiles.readConversation(Data(text.utf8))
        #expect(c.unread.map(\.text) == ["", "with a screenshot"], "dequeue takes the oldest entry, as Claude Code's queue does")
        let blocks = SessionFiles.readConversation(Data([Self.assistant(1), Self.queue(2, "enqueue", [["type": "text", "text": "look at this"], ["type": "image", "source": [:]]])].joined(separator: "\n").utf8))
        #expect(blocks.unread.map(\.text) == ["look at this\n[image]"], "text blocks are kept and an image is noted")
        // A message sent with an image is enqueued without text and removed by its text.
        let removed = text + "\n" + Self.queue(5, "enqueue") + "\n" + Self.queue(6, "remove", "typed with an image")
        c = SessionFiles.readConversation(Data(removed.utf8))
        #expect(c.unread.count == 2)
    }

    @Test func aSubagentWaitingOnAToolIsFound() {
        let text = [Self.assistant(1, tool: (id: "a", name: "Bash", command: "date")), Self.result(2, id: "a"),
                    Self.assistant(3, tool: (id: "b", name: "Bash", command: "sed -n 1,5p f"))].joined(separator: "\n")
        let c = SessionFiles.readConversation(Data(text.utf8))
        #expect(c.pending?.name == "Bash")
        #expect(c.pending?.what == "Run sed -n 1,5p f")
        #expect(c.pending?.since == Format.parseISO(Self.t(3)))
    }

    @Test func imagesAreCountedAcrossReads() {
        let one = #"{"type":"user","message":{"content":[{"type":"image","source":{}}]}}"#
        let data = Data(Array(repeating: one, count: 1000).joined(separator: "\n").utf8)
        #expect(SessionFiles.countImages(data) == 1000)
        #expect(SessionFiles.countImages(Data()) == 0)
    }

    @Test func sessionIdsComeFromTheArguments() {
        #expect(SessionFiles.sessionId(args: ["claude", "--output-format", "stream-json", "--resume=abc-123"]) == "abc-123")
        #expect(SessionFiles.sessionId(args: ["claude", "--resume", "def"]) == "def")
        #expect(SessionFiles.sessionId(args: ["claude", "-p", "hi"]) == nil)
        #expect(SessionFiles.escape("/Users/k/.codex/worktrees/x_1") == "-Users-k--codex-worktrees-x-1")
    }

    @Test func theNewestCopyOfATranscriptWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hr-projects-\(UUID().uuidString)")
        let a = root.appendingPathComponent("-old-folder"), b = root.appendingPathComponent("-new-folder")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: b.appendingPathComponent("s1.jsonl"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: b.appendingPathComponent("s1.jsonl").path)
        try Data("live".utf8).write(to: a.appendingPathComponent("s1.jsonl"))
        #expect(SessionFiles.transcript(sessionId: "s1", cwd: "/new/folder", projects: root)?.deletingLastPathComponent().lastPathComponent == "-old-folder")
    }

    // MARK: polls

    @Test func aPollNamesTheFileItWaitsOn() {
        let script = #"SP=/tmp/sp; until grep -qE "block exit|failed" $SP/perf/chain.out; do sleep 30; done; tail -3 $SP/perf/chain.out"#
        #expect(PollFinder.watchedFile(script) == "/tmp/sp/perf/chain.out")
        #expect(PollFinder.watchedFile("until [ -s /var/tmp/run1.log ]; do sleep 5; done") == "/var/tmp/run1.log")
        #expect(PollFinder.loopText("export X=1 && eval 'until true; do sleep 1; done'").hasPrefix("until true"))
    }

    // MARK: health

    static func session(gb: Double = 0.4, busy: Double? = nil, reply: Int? = 5, unread: [QueuedMessage] = [],
                        waiting: [WatchedSubagent] = [], subagentWrite: Int? = nil, mb: Double = 30, images: Int = 10) -> WatchedSession {
        func at(_ m: Int?) -> Date? { m.flatMap { Format.parseISO(t($0)) } }
        return WatchedSession(pid: 42, startTime: 1, sessionId: "s1", title: "coordinator", cwd: "/x", inApp: true,
                              processGB: gb, totalGB: gb, trendGB: nil, busyPercent: busy, transcript: nil, transcriptMB: mb,
                              images: images, lastReply: at(reply), lastWrite: nil, awaitingReply: false, unread: unread,
                              subagentsTotal: waiting.count, subagentsActive: waiting.count, subagentsWaiting: waiting,
                              lastSubagentWrite: at(subagentWrite), polls: [], flags: [], notes: [])
    }

    @Test func theFrozenCoordinatorIsFailing() {
        let wait = WatchedSubagent(id: "a1", task: "Garages", workflow: nil, lastWrite: Format.parseISO(Self.t(10))!,
                                   waiting: PendingTool(name: "Bash", what: "git push", since: nil))
        var s = Self.session(gb: 29, busy: 120, reply: 9, unread: [QueuedMessage(time: Format.parseISO(Self.t(32)), kind: .person, text: "hello?")],
                             waiting: [wait], subagentWrite: 10, mb: 1734, images: 3706)
        SessionHealth.judge(&s, now: Format.parseISO("2026-10-14T23:30:00.000Z")!)
        #expect(Set(s.flags) == [.busy, .bloated, .heavy, .notAnswering, .stuck, .failing])
        #expect(SessionHealth.sentence(s).contains("It has stopped working"))
    }

    @Test func aBusySessionThatKeepsWritingIsNotStuck() {
        // The research session: five cores busy, but its workflow agents wrote a minute ago.
        var s = Self.session(gb: 52, busy: 199, reply: 5, waiting: [], subagentWrite: 59)
        SessionHealth.judge(&s, now: Format.parseISO("2026-10-14T23:00:00.000Z")!)
        #expect(!s.flags.contains(.stuck) && !s.flags.contains(.failing))
        #expect(s.flags.contains(.bloated) && s.flags.contains(.busy))
    }

    @Test func anIdleSessionIsFine() {
        var s = Self.session(reply: 5)
        SessionHealth.judge(&s, now: Format.parseISO("2026-10-15T09:00:00.000Z")!)
        #expect(s.flags.isEmpty)
        #expect(SessionHealth.sentence(s) == "Session coordinator is fine.")
    }

    // MARK: rescue

    @Test func aDryRunWritesTheLedgerAndNoteWithoutStopping() throws {
        let paths = Fixture.tempPaths()
        let projects = paths.dir.appendingPathComponent("projects/-x")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("s1.jsonl")
        try Data([Self.assistant(5), Self.queue(30, "enqueue", "hello?"),
                  Self.queue(31, "enqueue", "<agent-message from=\"a1\">done</agent-message>")].joined(separator: "\n").utf8).write(to: transcript)
        let lane = projects.appendingPathComponent("s1/subagents/agent-a1.jsonl")
        try Data(Self.assistant(20, tool: (id: "x", name: "Bash", command: "head -30 f")).utf8).write(to: lane)
        try Data(#"{"description":"Garages: redesign all ten"}"#.utf8).write(to: projects.appendingPathComponent("s1/subagents/agent-a1.meta.json"))
        var s = Self.session(gb: 29)
        s.transcript = transcript.path
        let r = try SessionRescue.rescue(s, procs: [], paths: paths, reason: "it stopped working", stop: false)
        #expect(!r.stopped)
        #expect(r.ledger.unread.map(\.kind) == [.person, .agent])
        #expect(r.ledger.subagentsWaiting.map(\.task) == ["Garages: redesign all ten"])
        let md = try String(contentsOf: r.markdown, encoding: .utf8)
        #expect(md.contains("hello?") && md.contains("a1") && md.contains("Do these in order"))
        #expect(r.ledger.resumeMessage.contains(r.markdown.path))
        #expect(!FileManager.default.fileExists(atPath: paths.pendingRescues.appendingPathComponent("s1.json").path), "a dry run leaves no note to deliver")
    }

    @Test func aRecoveryNoteIsDeliveredOnceThroughTheHook() throws {
        let paths = Fixture.tempPaths()
        try FileManager.default.createDirectory(at: paths.pendingRescues, withIntermediateDirectories: true)
        let pending = PendingRescue(sessionId: "s1", note: "/tmp/note.md", ledger: "/tmp/l.json", written: Date(), message: "Read /tmp/note.md first.")
        try JSON.encoder().encode(pending).write(to: paths.pendingRescues.appendingPathComponent("s1.json"))
        let input = Data(#"{"hook_event_name":"SessionStart","session_id":"s1","source":"resume"}"#.utf8)
        let first = Hook.sessionContext(input: input, paths: paths, sessions: { nil })
        #expect(first?.event == "SessionStart")
        #expect(first?.context == "Read /tmp/note.md first.")
        #expect(Hook.sessionContext(input: input, paths: paths, sessions: { nil }) == nil, "given once")
        let merged = Hook.merge(nil, event: "SessionStart", context: "x")
        #expect((merged["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String == "SessionStart")
    }

    @Test func aBloatedSessionIsWarnedAtMostEveryHalfHour() {
        let paths = Fixture.tempPaths()
        var s = Self.session(gb: 20, mb: 900, images: 2400)
        SessionHealth.judge(&s, now: Date())
        let doc = SessionsDocument(updatedAt: Date(), sessions: [s])
        let input = Data(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Read"}"#.utf8)
        let now = Date()
        let w = Hook.sessionContext(input: input, paths: paths, sessions: { doc }, now: now)
        #expect(w?.context.contains("resize screenshots") == true)
        #expect(Hook.sessionContext(input: input, paths: paths, sessions: { doc }, now: now.addingTimeInterval(600)) == nil)
        #expect(Hook.sessionContext(input: input, paths: paths, sessions: { doc }, now: now.addingTimeInterval(1900)) != nil)
    }
}
