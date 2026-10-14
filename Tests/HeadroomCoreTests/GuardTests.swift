import Darwin
import Foundation
import Testing
@testable import HeadroomCore

@Suite("Runaway guard")
struct GuardTests {
    static let me: UInt32 = 501
    static let gib = 1_073_741_824.0

    static func bytes(_ gb: Double) -> UInt64 { UInt64(max(0, gb) * gib) }

    static func proc(_ pid: Int32, ppid: Int32 = 1000, name: String, path: String? = nil, gb: Double,
                     uid: UInt32 = me, start: Double = 100, args: [String]? = nil) -> Proc {
        Proc(pid: pid, ppid: ppid, name: name, path: path ?? "/opt/homebrew/bin/\(name)", startTime: start,
             footprint: bytes(gb), args: args, uid: uid)
    }

    /// A Claude Code session at pid 1000 under the Claude app at 900, so commands have an owner.
    static let session = proc(1000, ppid: 900, name: "claude",
                              path: "/Users/k/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude",
                              gb: 0.6, args: ["claude"])
    static let claudeApp = proc(900, ppid: 1, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude", gb: 1.2)

    static func engine(_ edit: (inout GuardRules) -> Void = { _ in }) -> GuardEngine {
        var r = GuardRules.defaults
        r.armed = true
        edit(&r)
        return GuardEngine(rules: r, myUid: me, myPid: 99_999)
    }

    /// Feeds one sample a second for `seconds` seconds; `procs(t)` builds the processes at second t.
    /// Returns the first decision and the second it came.
    static func run(_ e: GuardEngine, seconds: Int, free: (Int) -> Int = { _ in 80 },
                    _ procs: (Int) -> [Proc]) -> (decision: GuardDecision, at: Int)? {
        for t in 0...seconds {
            if let d = e.observe(time: Double(t), procs: [claudeApp, session] + procs(t), freePercent: free(t)) {
                return (d, t)
            }
        }
        return nil
    }

    // MARK: the cases it must catch

    @Test func stopsTonightsGitGrepEarly() {
        // 2026-10-13 23:55: git grep without -I, 18 threads, about 2 GB a second.
        let r = Self.run(Self.engine(), seconds: 90) { t in [Self.proc(81586, name: "git", gb: 2.2 * Double(t))] }
        #expect(r?.decision.rule == .growth)
        #expect(r?.decision.unit.root == 81586)
        // Stopped once it passes the 16 GB floor with a full window of growth, far from 128 GB.
        #expect((r?.at ?? 99) <= 9)
        #expect((r?.decision.unit.gb ?? 999) < 22)
    }

    @Test func stopsTheIncidentWhenFirstSeenAlreadyLarge() {
        // The guard starts while the process is already at 42.6 GB and climbing.
        let r = Self.run(Self.engine(), seconds: 60) { t in [Self.proc(81586, name: "git", gb: 42.6 + 2.2 * Double(t))] }
        #expect(r?.decision.rule == .growth)
        #expect((r?.at ?? 99) <= 5)
    }

    @Test func stopsAModelTrialThatClimbsToEightySeven() {
        // MiniMax-Remover on MPS, 2026-10-12: 0 to 87 GB in about 66 s.
        let r = Self.run(Self.engine(), seconds: 66) { t in [Self.proc(4242, name: "python3.12", gb: 1.32 * Double(t))] }
        #expect(r?.decision.rule == .growth)
        #expect((r?.decision.unit.gb ?? 999) < 24)
    }

    @Test func stopsSlowGrowthPastTheCeiling() {
        let r = Self.run(Self.engine(), seconds: 30) { t in [Self.proc(77, name: "node", gb: 70 + 0.2 * Double(t))] }
        #expect(r?.decision.rule == .ceiling)
    }

    @Test func stopsTheFastestGrowerWhenMemoryIsLow() {
        let r = Self.run(Self.engine(), seconds: 10, free: { _ in 7 }) { t in [
            Self.proc(10, name: "node", gb: 5 + 0.3 * Double(t)),
            Self.proc(11, name: "ffmpeg", gb: 3 + 0.1 * Double(t)),
            Self.proc(12, name: "java", gb: 40),
        ] }
        #expect(r?.decision.rule == .lowMemory)
        #expect(r?.decision.unit.root == 10)
    }

    @Test func stopsASwarmOfWorkersAsOneJob() {
        // One command an agent ran: a shell with 20 workers that each grow 0.1 GB a second.
        let r = Self.run(Self.engine(), seconds: 30) { t in
            [Self.proc(200, ppid: 1000, name: "zsh", path: "/bin/zsh", gb: 0.01)]
                + (0..<20).map { i in Self.proc(Int32(300 + i), ppid: 200, name: "node", gb: 0.5 + 0.1 * Double(t)) }
        }
        #expect(r?.decision.unit.kind == .job)
        #expect(r?.decision.unit.root == 200)
        #expect(r?.decision.unit.pids.count == 21)
        #expect(r?.decision.unit.pids.last == 200) // children first, the shell last
    }

    @Test func stopsOnlyTheRunawayInsideAnAgentsCommand() {
        // The agent's shell has run for a while; a new process inside it grows 4 GB a second. The shell's job has a
        // full window before the young process does, but only the process may be stopped.
        let r = Self.run(Self.engine(), seconds: 30) { t in
            var procs = [Self.proc(200, ppid: 1000, name: "zsh", path: "/bin/zsh", gb: 0.01)]
            if t >= 10 { procs.append(Self.proc(201, ppid: 200, name: "git", gb: 4 * Double(t - 10), start: 110)) }
            return procs
        }
        #expect(r?.decision.unit.kind == .process)
        #expect(r?.decision.unit.root == 201)
        #expect(r?.decision.unit.pids == [201])
    }

    @Test func stopsASlowLeakPastThirtyTwo() {
        // 2026-10-13: a selftest grew 44.6 GB in 10 minutes, about 0.1 GB a second, to 46 GB.
        let r = Self.run(Self.engine(), seconds: 600) { t in [Self.proc(63133, name: "node", gb: 0.1 * Double(t))] }
        #expect(r?.decision.rule == .leak)
        #expect((r?.decision.unit.gb ?? 999) < 34)
    }

    // MARK: the cases it must leave alone

    @Test func leavesAFastModelLoadBelowTheFloor() {
        // A 14 GB checkpoint read at 3.5 GB a second, then steady.
        #expect(Self.run(Self.engine(), seconds: 30) { t in [Self.proc(5, name: "python3", gb: min(14, 3.5 * Double(t)))] } == nil)
    }

    @Test func leavesASingleJumpThatThenHolds() {
        // A large process that maps 8 GB at once and then stays put is not spiralling.
        #expect(Self.run(Self.engine(), seconds: 20) { t in [Self.proc(6, name: "node", gb: t < 10 ? 30 : 38)] } == nil)
    }

    @Test func leavesALargeSteadyProcess() {
        #expect(Self.run(Self.engine(), seconds: 30) { _ in [Self.proc(7, name: "java", gb: 70)] } == nil)
    }

    @Test func leavesASlowBuild() {
        // A vite build that climbs to 9 GB over a minute.
        #expect(Self.run(Self.engine(), seconds: 60) { t in [Self.proc(8, name: "node", gb: 0.15 * Double(t))] } == nil)
    }

    @Test func leavesALargeDevServerThatCreepsUp() {
        // A dev server that creeps from 15 to 25 GB over ten minutes stays below the leak floor.
        #expect(Self.run(Self.engine(), seconds: 600) { t in [Self.proc(99517, name: "node", gb: 15 + Double(t) / 60)] } == nil)
    }

    @Test func leavesALargeProcessThatGrowsSlowerThanTheLeakLine() {
        // 40 GB growing 3 GB every two minutes is under the 8 GB line.
        #expect(Self.run(Self.engine(), seconds: 600) { t in [Self.proc(99, name: "java", gb: 40 + 0.025 * Double(t))] } == nil)
    }

    @Test func leavesLowMemoryAloneWhenNothingGrows() {
        #expect(Self.run(Self.engine(), seconds: 10, free: { _ in 5 }) { _ in [Self.proc(9, name: "java", gb: 50)] } == nil)
    }

    @Test(arguments: [
        ("Claude Helper (Renderer)", "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)", Int32(900)),
        ("claude", "/Users/k/Library/Application Support/Claude/claude-code/2.1/y/claude.app/Contents/MacOS/claude", Int32(900)),
        ("WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", Int32(1)),
        ("ChatGPT", "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", Int32(1)),
        ("codex", "/Applications/ChatGPT.app/Contents/Resources/CodexCLI.app/Contents/MacOS/codex", Int32(1)),
        ("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", Int32(1)),
        ("headroom", "/Users/k/.local/bin/headroom", Int32(1)),
    ])
    func neverStopsProtectedProcesses(name: String, path: String, ppid: Int32) {
        let r = Self.run(Self.engine(), seconds: 40, free: { _ in 3 }) { t in
            [Self.proc(50, ppid: ppid, name: name, path: path, gb: 3 * Double(t), args: [name])]
        }
        #expect(r == nil)
    }

    @Test func neverStopsAnotherUsersProcess() {
        let r = Self.run(Self.engine(), seconds: 30) { t in [Self.proc(51, name: "postgres", gb: 3 * Double(t), uid: 0)] }
        #expect(r == nil)
    }

    @Test func stopsClaudeCodesOwnSearchHelper() {
        // Claude Code runs searches as its own binary named ugrep; that helper may run away like any search.
        let r = Self.run(Self.engine(), seconds: 30) { t in [Self.proc(52, ppid: 1000, name: "claude",
            path: "/Users/k/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude",
            gb: 2 * Double(t), args: ["ugrep", "-r", "x"])] }
        #expect(r?.decision.unit.root == 52)
    }

    // MARK: gentle processes

    static func gentleEngine() -> GuardEngine { engine { $0.gentlePatterns = ["/scratchpad/i223"] } }

    @Test func stillStopsAGentleRunawayOnItsOwn() {
        // A deploy gate's receipt that really runs away is stopped, but alone.
        let r = Self.run(Self.gentleEngine(), seconds: 30) { t in
            [Self.proc(200, ppid: 1000, name: "zsh", path: "/bin/zsh", gb: 0.01, args: ["zsh", "/tmp/x/scratchpad/i223/gate.sh"]),
             Self.proc(201, ppid: 200, name: "node", gb: 2 * Double(t), args: ["node", "receipt.mjs"])]
        }
        #expect(r?.decision.unit.kind == .process)
        #expect(r?.decision.unit.root == 201)
    }

    @Test func neverStopsAJobWithAGentleProcessInIt() {
        // A gate's pool of 20 workers that each grow a little is not stopped as a job.
        let r = Self.run(Self.gentleEngine(), seconds: 30) { t in
            [Self.proc(200, ppid: 1000, name: "zsh", path: "/bin/zsh", gb: 0.01, args: ["zsh", "/tmp/x/scratchpad/i223/gate.sh"])]
                + (0..<20).map { i in Self.proc(Int32(300 + i), ppid: 200, name: "node", gb: 0.5 + 0.1 * Double(t)) }
        }
        #expect(r == nil)
    }

    @Test func lowMemorySkipsGentleProcesses() {
        let e = Self.engine { $0.gentlePatterns = ["/scratchpad/i224"] }
        let r = Self.run(e, seconds: 10, free: { _ in 7 }) { t in [
            Self.proc(10, name: "node", gb: 5 + 0.5 * Double(t), args: ["node", "/x/scratchpad/i224/pool.mjs"]),
            Self.proc(11, name: "ffmpeg", gb: 3 + 0.1 * Double(t)),
        ] }
        #expect(r?.decision.rule == .lowMemory)
        #expect(r?.decision.unit.root == 11)
    }

    @Test func matchesTheWorkingDirectory() {
        // A receipt started from the gate's folder, with nothing in its arguments, is gentle by its cwd.
        let e = Self.engine { $0.gentlePatterns = ["/scratchpad/i223"] }
        let r = Self.run(e, seconds: 10, free: { _ in 7 }) { t in [
            Proc(pid: 10, ppid: 1000, name: "node", path: "/opt/homebrew/bin/node", startTime: 100,
                 footprint: Self.bytes(5 + 0.5 * Double(t)), cwd: "/tmp/x/scratchpad/i223/run", args: ["node", "r.mjs"], uid: Self.me),
            Self.proc(11, name: "ffmpeg", gb: 3 + 0.1 * Double(t)),
        ] }
        #expect(r?.decision.unit.root == 11)
    }

    // MARK: bookkeeping

    @Test func waitsOutTheCooldownBetweenStops() {
        let e = Self.engine { $0.cooldownSeconds = 10 }
        var stops: [(Int32, Int)] = []
        for t in 0...40 {
            let procs = [Self.claudeApp, Self.session,
                         Self.proc(60, name: "git", gb: 2 * Double(t)),
                         Self.proc(61, name: "rg", gb: 2 * Double(t))]
            if let d = e.observe(time: Double(t), procs: procs, freePercent: 80, pending: Set(stops.map(\.0))) {
                stops.append((d.unit.root, t))
            }
        }
        #expect(stops.count == 2)
        #expect(stops.count == 2 && stops[1].1 - stops[0].1 >= 10)
    }

    @Test func aReusedPidStartsFresh() {
        // Pid 70 is a large steady process until second 10, then a new process takes the pid at 60 GB.
        let e = Self.engine()
        for t in 0...20 {
            let p = t < 10 ? Self.proc(70, name: "node", gb: 10, start: 100) : Self.proc(70, name: "node", gb: 60, start: 200)
            #expect(e.observe(time: Double(t), procs: [Self.claudeApp, Self.session, p], freePercent: 80) == nil)
        }
    }

    @Test func rulesKeepDefaultsForMissingKeys() throws {
        let r = try JSONDecoder().decode(GuardRules.self, from: Data(#"{"armed": true, "growthFloorGB": 24}"#.utf8))
        #expect(r.armed)
        #expect(r.growthFloorGB == 24)
        #expect(r.windowSeconds == GuardRules.defaults.windowSeconds)
        #expect(r.ceilingGB == 64)
        #expect(r.gentlePatterns.isEmpty)
    }

    @Test func rulesAreClamped() {
        var r = GuardRules.defaults
        r.intervalSeconds = 0
        r.windowSeconds = .infinity
        r.lowFreePercent = 99
        let v = r.validated()
        #expect(v.intervalSeconds == 0.25)
        #expect(v.windowSeconds == GuardRules.defaults.windowSeconds)
        #expect(v.lowFreePercent == 50)
    }

    @Test func runnerStopsARealProcessAndLogsIt() throws {
        // A real child process stands in for a runaway: the runner signals it and writes the event.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(dir: dir)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        let info = try #require(SystemProbe.bsdInfo(pid))
        let runner = GuardRunner(paths: paths, forceArmed: true)
        runner.notifier = { _, _ in }
        let unit = GuardUnit(kind: .process, key: GuardUnitKey(job: false, pid: pid, start: info.startTime), root: pid, rootStart: info.startTime, pids: [pid],
                             bytes: Self.bytes(20), name: "sleep")
        let d = GuardDecision(rule: .growth, unit: unit, rateGBPerSecond: 2, reason: "test")
        let p = Proc(pid: pid, ppid: getpid(), name: "sleep", path: "/bin/sleep", startTime: info.startTime,
                     footprint: Self.bytes(20), uid: getuid())
        runner.act(d, procs: [p], free: 50, now: 1)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
        let log = try String(contentsOf: paths.events, encoding: .utf8)
        #expect(log.contains("\"action\":\"stopped\""))
        #expect(log.contains("\"rule\":\"growth\""))
    }
}
