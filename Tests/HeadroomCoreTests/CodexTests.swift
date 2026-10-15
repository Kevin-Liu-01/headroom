import Foundation
import Testing
@testable import HeadroomCore

/// A Mac with the Claude app, the Codex app (ChatGPT.app, com.openai.codex) and Codex sessions started from terminals.
enum CodexFixture {
    static let chatGPT = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    static let chatGPTHelper = "/Applications/ChatGPT.app/Contents/Frameworks/ChatGPT Helper (Renderer).app/Contents/MacOS/ChatGPT Helper (Renderer)"
    /// The agent binary inside the app, as the process table shows it.
    static let appCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    static let modeHost = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex-code-mode-host"
    static let npmCodex = "/Users/k/.npm-global/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex"
    static let brewCodex = "/opt/homebrew/Caskroom/codex/0.159.2/codex-aarch64-apple-darwin"

    static func bundleID(_ path: String) -> String? {
        switch path {
        case "/Applications/ChatGPT.app": "com.openai.codex"
        case "/Applications/Claude.app": "com.anthropic.claudefordesktop"
        default: nil
        }
    }

    static var tree: [Proc] {
        Fixture.tree + [
            Fixture.proc(400, 1, chatGPT, gb: 0.6),
            Fixture.proc(401, 400, chatGPTHelper, gb: 0.4),
            Fixture.proc(410, 400, appCodex, gb: 0.5, cwd: "/Users/k/code/api"),
            Fixture.proc(411, 410, "/opt/homebrew/bin/node", gb: 3.0, args: ["node", "/x/node_modules/vitest/vitest.mjs", "run"]),
            Fixture.proc(412, 410, modeHost, gb: 0.1),
            // A Codex session started from a terminal with the npm package, and one from Homebrew.
            Fixture.proc(420, 301, npmCodex, gb: 0.3, cwd: "/Users/k/code/mobile"),
            Fixture.proc(421, 420, "/usr/bin/xcodebuild", gb: 2.0),
            Fixture.proc(430, 301, brewCodex, gb: 0.2, cwd: "/Users/k/code/docs"),
        ]
    }

    static var result: Attribution.Result { Attribution(procs: tree, bundleID: bundleID).attribute() }
}

@Suite("Codex detection")
struct CodexDetectionTests {
    let r = CodexFixture.result

    @Test func codexSessionsAreCodexProcessesFromAnyInstall() {
        #expect(Attribution.isCodexSession(Fixture.proc(1, 0, CodexFixture.appCodex, gb: 0)))
        #expect(Attribution.isCodexSession(Fixture.proc(1, 0, CodexFixture.npmCodex, gb: 0)))
        #expect(Attribution.isCodexSession(Fixture.proc(1, 0, CodexFixture.brewCodex, gb: 0)))
        #expect(!Attribution.isCodexSession(Fixture.proc(1, 0, CodexFixture.modeHost, gb: 0)), "helpers are not sessions")
        #expect(!Attribution.isCodexSession(Fixture.proc(1, 0, CodexFixture.chatGPT, gb: 0)))
        #expect(Attribution.sessionApp(Fixture.proc(1, 0, Fixture.claudeCode, gb: 0)) == .claude)
        #expect(Attribution.sessionApp(Fixture.proc(1, 0, CodexFixture.npmCodex, gb: 0)) == .codex)
    }

    @Test func theCodexTotalIsTheAppTreeAndTheTerminalSessions() {
        #expect(r.codex.pid == 400)
        #expect(r.codex.processCount == 8)
        #expect(r.codex.totalGB == 7.1, "the app's 4.6 GB and the terminal sessions' 2.3 and 0.2 GB")
        #expect(r.codex.appGB == 4.6)
        #expect(r.codex.terminalGB == 2.5)
        #expect(r.claude.totalGB == 34.3)
    }

    @Test func eachAppsTotalIsTheSumOfItsSessionsAndItsOwnProcesses() {
        for app in AgentApp.allCases {
            let total = app == .claude ? r.claude : r.codex
            let sessions = r.sessions.filter { $0.app == app }.reduce(0) { $0 + $1.totalGB }
            #expect(total.totalGB >= sessions, "a band is never smaller than its rows")
        }
        #expect(Format.round2(r.claude.totalGB + r.codex.totalGB) == r.agents.totalGB)
    }

    @Test func theAgentsTotalCountsEveryAgentProcessOnce() {
        // Claude 34.3 (app 33.6, terminal 0.7) + Codex 7.1 (app 4.6, terminals 2.3 and 0.2).
        #expect(r.agents.totalGB == 41.4)
        #expect(r.agents.processCount == 10 + 5 + 1 + 2 + 1)
        #expect(r.agents.pid == nil)
    }

    @Test func sessionsCarryTheirAppAndWhetherTheyRunInIt() {
        let by = Dictionary(uniqueKeysWithValues: r.sessions.map { ($0.label, $0) })
        #expect(by["api"]?.app == .codex)
        #expect(by["api"]?.inApp == true)
        #expect(by["api"]?.totalGB == 3.6, "codex-code-mode-host belongs to the app session")
        #expect(by["mobile"]?.app == .codex)
        #expect(by["mobile"]?.inApp == false, "a Codex session from a terminal still counts as Codex")
        #expect(by["mobile"]?.totalGB == 2.3)
        #expect(by["docs"]?.app == .codex)
        #expect(by["headroom"]?.app == .claude)
        #expect(by["ml-experiments"]?.app == .claude)
        #expect(by["ml-experiments"]?.inApp == false)
        #expect(r.sessions.filter { $0.app == .codex }.count == 3)
    }

    @Test func heavyJobsAreTaggedWithTheSessionThatOwnsThem() {
        let jobs = Dictionary(uniqueKeysWithValues: r.heavyJobs.map { ($0.pid, $0) })
        #expect(jobs[411]?.kind == .test)
        #expect(jobs[411]?.session == "api")
        #expect(jobs[411]?.app == .codex)
        #expect(jobs[421]?.app == .codex)
        #expect(jobs[421]?.session == "mobile")
        #expect(jobs[123]?.app == .claude)
        #expect(jobs[401] == nil, "the Codex app's own helpers are not jobs")
    }

    @Test func theCodexAppIsNotAnotherApp() {
        #expect(!r.apps.contains { $0.name == "ChatGPT" })
        #expect(!r.apps.contains { $0.name == "Claude" })
    }

    @Test func aChatGPTAppThatIsNotCodexIsNotCounted() {
        let r = Attribution(procs: CodexFixture.tree, bundleID: { _ in "com.openai.chat" }).attribute()
        #expect(r.codex.pid == nil)
        #expect(r.codex.appGB == 0)
        #expect(r.codex.totalGB == 6.1, "only the Codex sessions count: 3.6, 2.3 and 0.2 GB")
        #expect(r.sessions.first { $0.label == "api" }?.inApp == false)
    }

    @Test func theLiveRuleReadsTheBundleIdentifier() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-bundles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func app(_ name: String, _ id: String) throws -> String {
            let contents = dir.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: NSDictionary = ["CFBundleIdentifier": id, "CFBundleExecutable": name]
            plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
            return contents.appendingPathComponent("MacOS/\(name)").path
        }
        let codex = try app("ChatGPT", "com.openai.codex")
        let chat = try app("ChatGPT Classic", "com.openai.chat")
        let other = try app("Other", "com.openai.codex")
        let ids = BundleIDs()
        #expect(Attribution.isCodexApp(Fixture.proc(1, 0, codex, gb: 0), bundleID: ids.identifier))
        #expect(!Attribution.isCodexApp(Fixture.proc(1, 0, chat, gb: 0), bundleID: ids.identifier))
        #expect(!Attribution.isCodexApp(Fixture.proc(1, 0, other, gb: 0), bundleID: ids.identifier), "only ChatGPT and Codex bundles are read")
        #expect(!Attribution.isCodexApp(Fixture.proc(1, 0, codex + "/x", gb: 0), bundleID: ids.identifier))
        #expect(Attribution.mainBundle(of: CodexFixture.chatGPT) == "/Applications/ChatGPT.app")
        #expect(Attribution.mainBundle(of: CodexFixture.modeHost) == nil)
    }
}

/// The Codex app's threads run in a shared `codex app-server` daemon that launchd adopted, with terminal tools around it.
enum DaemonFixture {
    static let home = "/Users/k"
    static func code(_ name: String) -> String { "/Users/k/code/\(name)" }

    static var tree: [Proc] {
        [
            Fixture.proc(1, 0, "/sbin/launchd", gb: 0.01),
            Fixture.proc(500, 1, CodexFixture.chatGPT, gb: 0.7),
            Fixture.proc(501, 500, CodexFixture.chatGPTHelper, gb: 0.3),
            // The daemon, detached from the app, and the commands of two threads in two folders.
            Fixture.proc(600, 1, CodexFixture.appCodex, gb: 1.5, cwd: home, args: ["codex", "app-server", "--listen", "unix://"]),
            Fixture.proc(601, 600, "/bin/zsh", gb: 0.01, cwd: code("api")),
            Fixture.proc(602, 601, "/opt/homebrew/bin/node", gb: 3.0, cwd: code("api"), args: ["node", "/x/node_modules/vitest/vitest.mjs", "run"]),
            Fixture.proc(603, 600, "/bin/zsh", gb: 0.01, cwd: code("web")),
            Fixture.proc(604, 603, "/opt/homebrew/bin/node", gb: 2.0, args: ["node", "/x/node_modules/.bin/next", "dev"]),
            Fixture.proc(605, 600, CodexFixture.modeHost, gb: 0.2, cwd: home),
            // A plugin server that the daemon runs from inside the Codex home belongs to the app, not to a thread.
            Fixture.proc(606, 600, "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node", gb: 0.5,
                         cwd: "/Users/k/.codex/plugins/cache/openai-bundled/codex-app-tools/0.1.5", args: ["node", "./server.mjs"]),
            // A terminal with a proxy to the daemon, an MCP listing, the npm launcher and an exec run.
            Fixture.proc(700, 1, "/Applications/Ghostty.app/Contents/MacOS/ghostty", gb: 0.2),
            Fixture.proc(701, 700, "/bin/zsh", gb: 0.01),
            Fixture.proc(702, 701, CodexFixture.appCodex, gb: 0.02, args: ["codex", "app-server", "proxy"]),
            Fixture.proc(710, 701, "/opt/homebrew/bin/node", gb: 0.05,
                         args: ["node", "/Users/k/.npm-global/lib/node_modules/@openai/codex/bin/codex.js"]),
            Fixture.proc(711, 710, CodexFixture.npmCodex, gb: 0.4, cwd: code("mobile"), args: ["codex"]),
            Fixture.proc(712, 711, "/usr/bin/xcodebuild", gb: 2.0),
            Fixture.proc(720, 701, CodexFixture.appCodex, gb: 0.02, args: ["codex", "mcp", "list"]),
            Fixture.proc(730, 701, CodexFixture.brewCodex, gb: 0.3, cwd: code("docs"), args: ["codex", "-c", "model=o3", "exec", "fix the docs"]),
        ]
    }

    static var result: Attribution.Result { Attribution(procs: tree, bundleID: CodexFixture.bundleID, codexHome: "/Users/k/.codex").attribute() }
}

@Suite("Codex app server")
struct CodexAppServerTests {
    let r = DaemonFixture.result

    func role(_ args: [String]) -> Attribution.CodexRole? {
        Attribution.codexRole(Fixture.proc(9, 1, CodexFixture.appCodex, gb: 0, args: args))
    }

    @Test func theSubcommandSetsTheRole() {
        #expect(role(["codex"]) == .session)
        #expect(role(["codex", "fix the tests"]) == .session, "a prompt is not a subcommand")
        #expect(role(["codex", "-c", "model=o3", "exec", "x"]) == .session)
        #expect(role(["codex", "resume", "--last"]) == .session)
        #expect(role(["codex", "app-server"]) == .host)
        #expect(role(["codex", "-m", "o3", "app-server", "--listen", "unix://"]) == .host)
        #expect(role(["codex", "app-server", "proxy"]) == .helper)
        #expect(role(["codex", "app-server", "generate-ts"]) == .helper)
        #expect(role(["codex", "mcp", "list"]) == .helper)
        #expect(role(["codex", "login"]) == .helper)
        #expect(Attribution.codexRole(Fixture.proc(9, 1, CodexFixture.modeHost, gb: 0)) == nil)
    }

    @Test func theDetachedDaemonCountsTowardCodexAndIsNotASession() {
        #expect(r.codex.pid == 500)
        #expect(r.codex.hostPid == 600)
        #expect(!r.sessions.contains { $0.pid == 600 })
        #expect(r.codexPids.contains(501))
        // ChatGPT 1.0 + daemon tree 7.22 (threads 3.01 and 2.01, its own 1.5, the mode host 0.2 and a plugin 0.5) + launcher session 2.45 + exec 0.3.
        #expect(r.codex.totalGB == 10.97)
        #expect(r.codex.appGB == 8.22)
        #expect(r.codex.terminalGB == 2.75)
        #expect(r.agents.totalGB == r.codex.totalGB)
    }

    @Test func theDaemonsThreadsAreSessionsByFolder() {
        let by = Dictionary(uniqueKeysWithValues: r.sessions.map { ($0.label, $0) })
        #expect(Set(by.keys) == ["api", "web", "mobile", "docs"], "a plugin server in the Codex home is not a thread")
        #expect(by["api"]?.totalGB == 3.01)
        #expect(by["api"]?.inApp == true, "the daemon runs the app's threads")
        #expect(by["api"]?.app == .codex)
        #expect((by["api"]?.pid ?? 0) < 0, "a thread has no process of its own")
        #expect(by["api"]?.pid == Attribution.threadID(host: 600, cwd: DaemonFixture.code("api")))
        #expect(by["web"]?.totalGB == 2.01)
        #expect(by["mobile"]?.pid == 711)
        #expect(by["mobile"]?.inApp == false)
        #expect(by["mobile"]?.totalGB == 2.45, "the npm launcher counts toward the session it starts")
        #expect(by["docs"]?.pid == 730)
    }

    @Test func jobsUnderTheDaemonAreTaggedWithTheirThread() {
        let jobs = Dictionary(uniqueKeysWithValues: r.heavyJobs.map { ($0.pid, $0) })
        #expect(jobs[602]?.session == "api")
        #expect(jobs[602]?.app == .codex)
        #expect(jobs[604]?.session == "web")
        #expect(jobs[712]?.session == "mobile")
    }

    @Test func helpersOutsideSessionsAreNotSessions() {
        #expect(!r.sessions.contains { $0.pid == 702 || $0.pid == 720 })
        let apps = Dictionary(uniqueKeysWithValues: r.apps.map { ($0.name, $0) })
        #expect(apps["Ghostty"]?.totalGB == 0.25, "the shell, the proxy and the MCP listing stay with the terminal")
        #expect(apps["codex"] == nil)
    }

    @Test func aDaemonWithoutTheAppStillCounts() {
        let r = Attribution(procs: DaemonFixture.tree.filter { $0.pid != 500 && $0.pid != 501 }, bundleID: CodexFixture.bundleID,
                            codexHome: "/Users/k/.codex").attribute()
        #expect(r.codex.pid == nil)
        #expect(r.codex.hostPid == 600)
        #expect(r.codex.appRunning)
        #expect(r.codex.totalGB == 9.97, "the daemon tree includes its plugin server")
    }
}

@Suite("Codex policy")
struct CodexPolicyTests {
    func snap(claude: Double, codex: Double, terminal: Double = 0, free: Int = 80) -> Snapshot {
        Snapshot(time: Date(timeIntervalSince1970: 1_800_000_000), system: Fixture.system(freePercent: free),
                 claude: AgentTotal(pid: 100, totalGB: claude, processCount: 10),
                 codex: AgentTotal(pid: 400, totalGB: codex, processCount: 5),
                 agents: AgentTotal(pid: nil, totalGB: claude + codex + terminal, processCount: 20))
    }

    @Test func eachAppAndTheCombinedTotalHaveLines() {
        let t = Thresholds.defaults
        #expect(t.codexWarningGB == 40 && t.codexCriticalGB == 70)
        #expect(t.agentsWarningGB == 40 && t.agentsCriticalGB == 70)
        #expect(Policy.evaluate(snap(claude: 10, codex: 10), t).advice == .ok)
        let combined = Policy.evaluate(snap(claude: 25, codex: 20), t)
        #expect(combined.advice == .hold)
        #expect(combined.reasons.map(\.check) == ["agents"])
        #expect(combined.reasons[0].message == "The agents use 45.0 GB in total, above the 40.0 GB hold line.")
        let codex = Policy.evaluate(snap(claude: 1, codex: 72), t)
        #expect(codex.advice == .critical)
        #expect(codex.reasons.map(\.check) == ["agents", "codex"])
        #expect(codex.reasons[1].message == "Codex uses 72.0 GB, above the 70.0 GB critical line.")
        #expect(Policy.evaluate(snap(claude: 1, codex: 1, terminal: 41), t).advice == .hold, "terminal sessions count")
    }

    @Test func theAdviceIsTheWorstOfTheLines() {
        var t = Thresholds.defaults
        t.codexWarningGB = 5
        t.codexCriticalGB = 8
        let e = Policy.evaluate(snap(claude: 1, codex: 9), t)
        #expect(e.advice == .critical)
        #expect(e.reasons.map(\.check) == ["codex"])
    }

    @Test func oldSettingsFilesGetTheCodexDefaults() throws {
        let t = try JSON.decoder().decode(Thresholds.self, from: Data(#"{"claudeWarningGB": 33, "claudeCriticalGB": 60}"#.utf8))
        #expect(t.claudeWarningGB == 33)
        #expect(t.codexWarningGB == 40)
        #expect(t.agentsCriticalGB == 70)
        var bad = Thresholds()
        bad.codexWarningGB = 50
        bad.codexCriticalGB = 20
        #expect(bad.validated().codexCriticalGB == 50)
    }

    @Test func canStartChecksTheAgentsTotal() {
        let doc = Policy.status(snap(claude: 20, codex: 15, free: 90), .defaults, source: "test")
        let r = Policy.canStart(gb: 40, label: nil, status: doc)
        #expect(!r.ok)
        #expect(r.reason.contains("would bring the agents' work to 75.0 GB"))
    }

    @Test func messagesNameBothApps() {
        let s = snap(claude: 30, codex: 15)
        #expect(Policy.totalsSentence(s) == "The agents use 45.0 GB (Claude 30.0 GB, Codex 15.0 GB).")
        var engine = AlertEngine()
        let doc = Policy.status(s, .defaults, source: "test")
        let alerts = engine.step(doc, evaluation: Policy.evaluate(s, .defaults), now: Date())
        #expect(alerts.first?.title == "Hold: agents 45.0 GB, 80% free")
    }

    @Test func restartCodexNeedsNoPid() {
        let hub = Hub(paths: Fixture.tempPaths())
        let router = APIRouter(hub: hub, token: "t")
        let req = HTTPRequest(method: "POST", path: "/v1/requests", headers: ["host": "127.0.0.1", "authorization": "Bearer t"],
                              body: Data(#"{"action":"restart-codex","reason":"Codex is at 80 GB"}"#.utf8))
        #expect(router.handle(req).status == 201)
        #expect(hub.pending.first?.action == .restartCodex)
        #expect(RequestAction.restartCodex.restarts == .codex)
    }

    @Test func theStatusDocumentNamesBothApps() throws {
        let doc = Policy.status(snap(claude: 30, codex: 15), .defaults, source: "test")
        let json = JSON.string(doc)
        #expect(json.contains(#""codex":{"#))
        #expect(json.contains(#""agents":{"#))
        #expect(json.contains(#""version":2"#))
        #expect(try JSON.decoder().decode(StatusDocument.self, from: Data(json.utf8)) == doc)
    }
}

@Suite("Codex hook")
struct CodexHookTests {
    func output(_ command: String, _ status: StatusDocument) -> [String: Any]? {
        guard let d = Hook.decide(input: Fixture.hookInput(command), agent: .codex, status: { status }),
              let data = Hook.render(d) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test func holdAddsContextOnly() throws {
        let out = try #require(output("pnpm build", Fixture.status(claudeGB: 45)))
        #expect(out.keys.sorted() == ["hookSpecificOutput"])
        let h = try #require(out["hookSpecificOutput"] as? [String: Any])
        #expect(h["permissionDecision"] == nil)
        #expect((h["additionalContext"] as? String)?.contains("headroom wait --gb") == true)
    }

    @Test func criticalTellsThePersonAndNeverAsks() throws {
        // Codex parses "ask" but does not support it yet, so the hook never returns it.
        let out = try #require(output("ffmpeg -i a.mov b.mp4", Fixture.status(claudeGB: 90)))
        let h = try #require(out["hookSpecificOutput"] as? [String: Any])
        #expect(h["hookEventName"] as? String == "PreToolUse")
        #expect(h["permissionDecision"] == nil)
        #expect(h["permissionDecisionReason"] == nil)
        #expect((out["systemMessage"] as? String)?.contains("critical") == true)
        #expect((h["additionalContext"] as? String)?.contains("an encode") == true)
    }

    @Test func okAndLightCommandsPrintNothing() {
        #expect(output("ffmpeg -i a b", Fixture.status(claudeGB: 5)) == nil)
        #expect(output("ls", Fixture.status(claudeGB: 90)) == nil)
    }
}

@Suite("History and trends")
struct HistoryTests {
    func point(_ t: Double, _ gb: Double) -> HistoryPoint {
        HistoryPoint(t: t, agents: gb, claude: gb, codex: 0, free: 70)
    }

    @Test func historyKeepsTheLastHour() {
        var h = History()
        for i in 0..<400 { h.append(point(Double(i) * 20, Double(i))) }
        #expect(h.points.count == 181, "an hour at 20 s is 180 intervals")
        #expect(h.points.first?.t == Double(399 * 20 - 3600))
        #expect(h.points.last?.agents == 399)
        #expect(h.perMinute().count == 61)
    }

    @Test func appChangeIsTheChangeOverTenMinutesOfHistory() {
        var h = History()
        for i in 0..<20 { h.append(point(Double(i) * 60, 30 + Double(i))) }
        #expect(h.change { $0.agents } == 10, "19 minus 9 minutes in")
        #expect(History(points: Array(h.points.prefix(5))).change { $0.agents } == nil, "4 minutes is not enough")
    }

    @Test func historyRoundTripsThroughItsFile() {
        let paths = Fixture.tempPaths()
        let now = Date()
        var h = History()
        for i in 0..<10 { h.append(point(now.timeIntervalSince1970 - Double(10 - i) * 30, 40 + Double(i) / 3)) }
        h.write(paths: paths)
        let back = History.read(paths: paths, now: now)
        #expect(back.points.count == 10)
        #expect(back.points.last?.agents == 43)
        #expect(History.read(paths: paths, now: now.addingTimeInterval(7200)).points.isEmpty, "old points are dropped")
    }

    @Test func sessionTrendIsTheChangeOverTenMinutes() {
        var trends = SessionTrends()
        func snap(_ seconds: Double, _ gb: Double) -> Snapshot {
            var s = Fixture.snapshot(claudeGB: gb)
            s.time = Date(timeIntervalSince1970: 1_800_000_000 + seconds)
            s.sessions = [AgentSession(pid: 7, cwd: "/x/api", label: "api", totalGB: gb, processCount: 2, inApp: true, startTime: 5, top: [])]
            return s
        }
        var s = snap(0, 2)
        trends.apply(to: &s)
        #expect(s.sessions[0].trendGB == nil, "no change before 10 minutes of history")
        s = snap(300, 3)
        trends.apply(to: &s)
        #expect(s.sessions[0].trendGB == nil, "5 minutes is not yet 10")
        s = snap(600, 5)
        trends.apply(to: &s)
        #expect(s.sessions[0].trendGB == 3)
        s = snap(900, 4.5)
        trends.apply(to: &s)
        #expect(s.sessions[0].trendGB == 1.5, "the anchor is the sample from 300 s, 10 minutes before")
    }

    @Test func sessionBusyIsItsProcessCPUOverTenMinutes() {
        var trends = SessionTrends()
        func snap(_ seconds: Double, cpu: Double?) -> Snapshot {
            var s = Fixture.snapshot(claudeGB: 1)
            s.time = Date(timeIntervalSince1970: 1_800_000_000 + seconds)
            s.sessions = [AgentSession(pid: 7, cwd: "/x/api", label: "api", totalGB: 1, processGB: 0.5, processCPUSeconds: cpu,
                                       processCount: 2, inApp: true, startTime: 5, top: [])]
            return s
        }
        var s = snap(0, cpu: 100)
        trends.apply(to: &s)
        #expect(s.sessions[0].busyPercent == nil)
        // A stuck session: 1.5 cores for 10 minutes.
        s = snap(600, cpu: 100 + 900)
        trends.apply(to: &s)
        #expect(s.sessions[0].busyPercent == 150)
        // An unreadable CPU time gives no busy measure rather than a wrong one.
        s = snap(620, cpu: nil)
        trends.apply(to: &s)
        #expect(s.sessions[0].busyPercent == nil)
    }
}
