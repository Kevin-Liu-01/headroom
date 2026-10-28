import Darwin
import Foundation
import Testing
@testable import HeadroomCore

/// Synthetic process tables for leftovers. Every process belongs to uid 501, and the home folder is /Users/k.
enum Orphans {
    static let home = "/Users/k"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let hour: Double = 3600

    /// A process `age` seconds old. One whose parent is launchd counts as adopted unless `adopted` says otherwise;
    /// its process group is its own pid unless `pgid` says otherwise.
    static func proc(_ pid: Int32, _ ppid: Int32, _ path: String, age: Double, gb: Double = 0.05, args: [String]? = nil,
                     cwd: String? = nil, pgid: Int32? = nil, adopted: Bool? = true, cpu: Double? = 1,
                     at time: Date = now) -> Proc {
        Proc(pid: pid, ppid: ppid, name: (path as NSString).lastPathComponent, path: path,
             startTime: time.timeIntervalSince1970 - age, footprint: UInt64(gb * 1_073_741_824), cwd: cwd, args: args,
             uid: 501, cpuSeconds: cpu, pgid: pgid ?? pid, adopted: ppid == 1 ? adopted : nil)
    }

    static let launchd = Proc(pid: 1, ppid: 0, name: "launchd", path: "/sbin/launchd", footprint: 0, uid: 0)

    static func find(_ procs: [Proc], minAge: Double = 30 * 60, at time: Date = now) -> [Leftover] {
        let a = Attribution(procs: [launchd] + procs, bundleID: { _ in nil })
        return Leftovers.find(in: a, excluding: a.attribute().agentPids, now: time, minAge: minAge, uid: 501, home: home)
    }

    static let chromeApp = "/Users/k/.cache/puppeteer/chrome/mac_arm-151.0.7922.47/chrome-mac-arm64/Google Chrome for Testing.app"
    static let chrome = chromeApp + "/Contents/MacOS/Google Chrome for Testing"
    static let crashpad = chromeApp + "/Contents/Frameworks/Google Chrome for Testing Framework.framework/Versions/151.0.7922.47/Helpers/chrome_crashpad_handler"
    static let renderer = chromeApp + "/Contents/Frameworks/Google Chrome for Testing Framework.framework/Versions/151.0.7922.47/Helpers/Google Chrome for Testing Helper (Renderer).app/Contents/MacOS/Google Chrome for Testing Helper (Renderer)"
    static let node = "/Users/k/.nvm/versions/node/v24.22.1/bin/node"
    static let ugrepArgs = ["ugrep", "-G", "--ignore-files", "--hidden", "-I", "--exclude-dir=.git", "--line-buffered", "-v", #"^\s*$"#]
}

@Suite("Leftovers")
struct LeftoverTests {
    typealias O = Orphans

    @Test func anOrphanedTestBrowserTakesItsCrashHandlers() {
        let procs = [
            O.proc(19285, 1, O.chrome, age: 30 * O.hour, gb: 0.2,
                   args: [O.chrome, "--disable-background-networking", "--headless=new", "--hide-scrollbars", "about:blank",
                          "--user-data-dir=/var/folders/x/T/puppeteer_dev_chrome_profile-BJ0K0j"],
                   cwd: "/Users/k/cot-lanes/brand-ui"),
            // Chrome double-forks its two crash handlers, so launchd adopts them at once. Each has a group of its own.
            O.proc(19302, 1, O.crashpad, age: 30 * O.hour - 0.4, gb: 0.008, pgid: 19301),
            O.proc(19304, 1, O.crashpad, age: 30 * O.hour - 0.5, gb: 0.007, pgid: 19303),
            O.proc(19318, 19285, O.renderer, age: 30 * O.hour - 2, gb: 0.5, pgid: 19285),
            // A browser whose test runner still runs in a terminal: its handlers are adopted too, but they belong to
            // a live tree and are never an item of their own.
            O.proc(300, 1, "/Applications/Ghostty.app/Contents/MacOS/ghostty", age: 50 * O.hour, adopted: false),
            O.proc(301, 300, "/bin/zsh", age: 49 * O.hour),
            O.proc(77381, 301, O.node, age: 2 * O.hour, args: ["node", "tools/hud-overlap.browser.mjs"]),
            O.proc(77738, 77381, O.chrome, age: 2 * O.hour - 6, gb: 0.3),
            O.proc(77778, 1, O.crashpad, age: 2 * O.hour - 6.3, pgid: 77777),
            O.proc(77798, 1, O.crashpad, age: 2 * O.hour - 6.3, pgid: 77797),
        ]
        let items = O.find(procs)
        #expect(items.count == 1)
        let b = items.first
        #expect(b?.kind == .browser)
        #expect(b?.pid == 19285)
        #expect(b?.pids == [19285, 19302, 19304, 19318])
        #expect(b?.command == "Google Chrome for Testing --headless=new about:blank")
        #expect(b?.cwd == "/Users/k/cot-lanes/brand-ui")
        #expect(b?.gb == 0.715)
        #expect(b?.processes.map(\.name).contains("chrome_crashpad_handler") == true)
    }

    @Test func thePersonsGoogleChromeIsNeverALeftover() {
        let app = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let clone = "/private/var/folders/yl/x/X/com.google.Chrome.code_sign_clone/code_sign_clone.abc/Google Chrome.app.bundle/Contents/MacOS/Google Chrome"
        let handler = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/156.0/Helpers/chrome_crashpad_handler"
        // Without knowing who started them, the paths alone keep them out.
        let procs = [
            O.proc(85831, 1, app, age: 60 * O.hour, gb: 0.7, adopted: nil),
            O.proc(85969, 1, handler, age: 60 * O.hour - 1, pgid: 85968, adopted: true),
            O.proc(86000, 1, clone, age: 60 * O.hour, gb: 2, adopted: nil),
        ]
        #expect(O.find(procs).isEmpty)
    }

    @Test func headroomAndLaunchAgentsAreNeverLeftovers() {
        let headroom = "/Users/k/Applications/Headroom.app/Contents/MacOS/Headroom"
        let brief = [O.node, "--experimental-strip-types", "/Users/k/repos/wiki/apps/briefd/src/cli.ts", "serve", "--port", "4747"]
        let procs = [
            O.proc(79956, 1, headroom, age: 30 * O.hour, gb: 0.09, adopted: nil),
            // launchd started this node itself, as the launch agent biz.kevinliu.daily-brief.
            O.proc(1658, 1, O.node, age: 89 * O.hour, args: brief, adopted: false),
        ]
        #expect(O.find(procs).isEmpty)
        // The same node adopted after its parent ended is a leftover.
        var orphan = procs[1]
        orphan.adopted = true
        #expect(O.find([orphan]).map(\.pid) == [1658])
    }

    @Test func processesInsideTheAgentsTreesAreExcluded() {
        let codex = "/Users/k/.npm/lib/node_modules/@openai/codex/vendor/codex"
        let procs = [
            // The shared Codex app server that launchd adopts, with a thread's command under it.
            O.proc(5000, 1, codex, age: 40 * O.hour, gb: 0.3, args: ["codex", "app-server", "daemon"]),
            O.proc(5001, 5000, O.node, age: 2 * O.hour, args: ["node", "server.mjs"], cwd: "/Users/k/code/api"),
            // A Claude Code session from a terminal that closed, with its dev server.
            O.proc(6000, 1, Fixture.claudeCode, age: 5 * O.hour, gb: 1, args: ["claude"], cwd: "/Users/k/code/web"),
            O.proc(6001, 6000, O.node, age: 4 * O.hour, gb: 2, args: ["node", "next", "dev"]),
            // An adopted shell that started a session: the shell is a leftover, the session and its work are not.
            O.proc(7000, 1, "/bin/zsh", age: 3 * O.hour, args: ["/bin/zsh", "/Users/k/bin/agent.zsh"]),
            O.proc(7001, 7000, Fixture.claudeCode, age: 3 * O.hour, gb: 0.8, args: ["claude", "-p", "go"], cwd: "/Users/k/code/x"),
            O.proc(7002, 7001, O.node, age: 3 * O.hour, gb: 1.5, args: ["node", "mcp.js"]),
        ]
        let items = O.find(procs)
        #expect(items.map(\.pid) == [7000])
        #expect(items.first?.pids == [7000], "the session under the shell and its node stay with Claude")
        #expect(items.first?.kind == .process)
        #expect(items.first?.command == "zsh agent.zsh")
    }

    @Test func theAgeThresholdHoldsBackYoungLeftovers() {
        let procs = [
            O.proc(100, 1, O.node, age: 29 * 60, args: ["node", "a.mjs"]),
            O.proc(200, 1, O.node, age: 31 * 60, args: ["node", "b.mjs"]),
        ]
        #expect(O.find(procs).map(\.pid) == [200])
        #expect(Set(O.find(procs, minAge: 10 * 60).map(\.pid)) == [100, 200])
        #expect(O.find(procs, minAge: 60 * 60).isEmpty)
    }

    @Test func anOrphanedShellWithAUgrepChildIsASearch() {
        let wrapper = #"source /Users/k/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'cd ~/cot-lanes/band-260 && (tail -n +1 -F after3.log 2>/dev/null | grep --line-buffered -v "^\s*$" | cut -c1-600) & TP=$!' < /dev/null && pwd -P >| /tmp/claude-d104-cwd"#
        let procs = [
            // A Bash tool shell whose session ended: tail, the shell running grep, and cut share its process group.
            O.proc(19123, 1, "/usr/bin/tail", age: 8 * O.hour, gb: 0.0005, args: ["tail", "-n", "+1", "-F", "after3.log"], pgid: 19121),
            O.proc(19125, 1, "/bin/zsh", age: 8 * O.hour, gb: 0.0007, args: ["/bin/zsh", "-c", wrapper],
                   cwd: "/Users/k/cot-lanes/band-260", pgid: 19121),
            O.proc(19126, 1, "/usr/bin/cut", age: 8 * O.hour, gb: 0.0004, pgid: 19121),
            // Claude Code's grep is its own binary run as ugrep.
            O.proc(19127, 19125, Fixture.claudeCode, age: 8 * O.hour, gb: 0.0015, args: O.ugrepArgs, pgid: 19121),
            // A stuck ugrep with its tail, both adopted.
            O.proc(19706, 1, "/usr/bin/tail", age: 57 * O.hour, gb: 0.0005, pgid: 19705),
            O.proc(19709, 1, Fixture.claudeCode, age: 57 * O.hour, gb: 0.0011,
                   args: ["ugrep", "-G", "--ignore-files", "-I", "--line-buffered", "-E", "rc=|STOP|drift"],
                   cwd: "/Users/k/claude-of-tanks/.claude/worktrees/eager-wilson", pgid: 19705),
            // A tail -F with nothing of a kind beside it is not listed.
            O.proc(40142, 1, "/usr/bin/tail", age: 20 * O.hour, pgid: 40141),
        ]
        let items = O.find(procs)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.kind == .search })
        let shell = items.first { $0.pid == 19125 }
        #expect(shell?.pids == [19123, 19125, 19126, 19127])
        #expect(shell?.command == #"(tail -n +1 -F after3.log 2>/dev/null | grep --line-buffered -v "^\s*$" | cut -c1-600) & TP=$!"#)
        #expect(shell?.cwd == "/Users/k/cot-lanes/band-260")
        let search = items.first { $0.pid == 19709 }
        #expect(search?.pids == [19706, 19709])
        #expect(search?.command == "ugrep -G -I -E rc=|STOP|drift")
        #expect(search?.processes.map(\.name) == ["tail", "ugrep"])
        #expect(search?.gb == 0.0016)
        #expect(Format.gb(search?.gb ?? 0) == "1.6 MB")
    }

    @Test func shellsTakeTheKindOfWhatRunsUnderThem() {
        let procs = [
            // An agent's chain script between steps is still a leftover, so it does not come and go.
            O.proc(57369, 1, "/bin/zsh", age: 2 * O.hour, args: ["zsh", "/Users/k/cot-lanes/room-slices-260/census5.zsh"]),
            O.proc(91741, 57369, "/bin/sleep", age: 60, args: ["sleep", "120"]),
            O.proc(56879, 1, "/bin/zsh", age: 3 * O.hour, args: ["zsh", "/Users/k/shots/ui261-gallery.zsh", "--run"]),
            O.proc(56924, 56879, O.node, age: 3 * O.hour, args: ["node", "tools/capture-showcase.mjs"]),
            O.proc(87144, 56924, O.chrome, age: 120, gb: 0.4),
        ]
        let items = Dictionary(uniqueKeysWithValues: O.find(procs).map { ($0.pid, $0) })
        #expect(items[57369]?.kind == .process)
        #expect(items[57369]?.command == "zsh census5.zsh")
        #expect(items[57369]?.pids == [57369, 91741])
        #expect(items[56879]?.kind == .process, "the first process with a kind under the shell is the node script")
        #expect(items[56879]?.pids == [56879, 56924, 87144])
        #expect(items[56879]?.command == "zsh ui261-gallery.zsh --run")
    }

    @Test func devServersAndCommandsReadFromTheArguments() {
        func p(_ args: [String]) -> Proc { O.proc(10, 1, O.node, age: O.hour, args: args) }
        let pnpm = p(["node", "/Users/k/.nvm/versions/node/v24.22.1/bin/pnpm", "exec", "next", "dev", "--turbopack", "--port", "3049"])
        #expect(Leftovers.ownKind(pnpm) == .devServer)
        #expect(Leftovers.command(pnpm) == "node pnpm exec next dev --turbopack --port 3049")
        let preview = p([O.node, "/Users/k/cot-lanes/web/tools/vercel-static-preview.mjs", "--dist=/Users/k/x/leave261a/dist", "--port=59038"])
        #expect(Leftovers.ownKind(preview) == .devServer)
        #expect(Leftovers.command(preview) == "node vercel-static-preview.mjs --dist=dist --port=59038")
        #expect(Leftovers.ownKind(p(["node", "node_modules/vite/bin/vite.js", "--port", "5463", "--strictPort"])) == .devServer)
        #expect(Leftovers.ownKind(p(["node", "/Users/k/web/node_modules/.bin/vite", "build"])) == .process)
        #expect(Leftovers.ownKind(p(["node", "/Users/k/.nvm/versions/node/v24.22.1/bin/pnpm", "dev", "--port", "3542"])) == .devServer)
        // npm writes its command into its title.
        #expect(Leftovers.ownKind(p(["npm run dev"])) == .devServer)
        #expect(Leftovers.ownKind(p(["npm run build"])) == .process)
        #expect(Leftovers.command(p(["npm run typecheck"])) == "npm run typecheck")
        let sweep = p(["node", "--max-old-space-size=4096", "tools/gun-depression-sweep.mjs", "--ids=leo1a5"])
        #expect(Leftovers.ownKind(sweep) == .process)
        #expect(Leftovers.command(sweep) == "node gun-depression-sweep.mjs --ids=leo1a5")
        let py = O.proc(11, 1, "/opt/homebrew/bin/python3.12", age: O.hour, args: ["python3", "-m", "http.server", "8000"])
        #expect(Leftovers.ownKind(py) == .devServer)
        #expect(Leftovers.ownKind(O.proc(12, 1, "/opt/homebrew/bin/ffmpeg", age: O.hour, args: ["ffmpeg", "-i", "a.mov"])) == .process)
        #expect(Leftovers.ownKind(O.proc(13, 1, "/opt/homebrew/bin/tmux", age: O.hour, args: ["tmux", "new", "-s", "w"])) == nil)
        // Node work must run from the home folder, /opt/homebrew or /usr/local.
        let xcode = O.proc(14, 1, "/Applications/Xcode.app/Contents/Developer/usr/bin/node", age: O.hour, args: ["node", "x.js"])
        #expect(O.find([xcode]).isEmpty)
    }

    // MARK: Last active

    /// A snapshot at `t` seconds after `now` with the leftovers of `procs`.
    static func sample(_ procs: [Proc], at t: Double) -> Snapshot {
        var s = Fixture.snapshot(claudeGB: 0)
        s.time = O.now.addingTimeInterval(t)
        s.leftovers = O.find(procs, at: s.time)
        return s
    }

    @Test func lastActiveComesFromCPUGrowthAcrossSamples() {
        // Started two days before the first sample. A stuck ugrep uses about 0.03 s per 20 s; a browser with an
        // animated page uses about 0.9 s per 8 s.
        func procs(ugrep: Double, renderer: Double) -> [Proc] {
            [
                O.proc(19709, 1, Fixture.claudeCode, age: 48 * O.hour, gb: 0.001, args: O.ugrepArgs, cpu: ugrep),
                O.proc(21480, 1, O.chrome, age: 48 * O.hour, gb: 0.2, cpu: 79),
                O.proc(21592, 21480, O.renderer, age: 48 * O.hour, gb: 0.4, cpu: renderer),
            ]
        }
        var watch = LeftoverWatch()
        var s = LeftoverTests.sample(procs(ugrep: 286.00, renderer: 40), at: 0)
        watch.apply(to: &s, procs: procs(ugrep: 286.00, renderer: 40))
        #expect(s.leftovers.allSatisfy { $0.lastActive == nil && $0.watchedSince == O.now })
        #expect(s.leftovers.first { $0.pid == 19709 }?.activity(now: s.time)?.hasPrefix("Not active since Headroom started at ") == true)

        // 8 s later: the browser grew 0.9 s, past 1 percent of 8 s; the ugrep grew 0.012 s.
        let p2 = procs(ugrep: 286.012, renderer: 40.9)
        s = LeftoverTests.sample(p2, at: 8)
        watch.apply(to: &s, procs: p2)
        let at8 = O.now.addingTimeInterval(8)
        #expect(s.leftovers.first { $0.pid == 21480 }?.lastActive == at8)
        #expect(s.leftovers.first { $0.pid == 19709 }?.lastActive == nil)

        // 20 s after that: the ugrep grew 0.03 s, under the 0.2 s that 1 percent of 20 s needs; the browser idled.
        let p3 = procs(ugrep: 286.042, renderer: 40.9)
        s = LeftoverTests.sample(p3, at: 28)
        watch.apply(to: &s, procs: p3)
        #expect(s.leftovers.first { $0.pid == 19709 }?.lastActive == nil)
        #expect(s.leftovers.first { $0.pid == 21480 }?.lastActive == at8, "the browser keeps its last active sample")
        #expect(s.leftovers.first { $0.pid == 21480 }?.activity(now: O.now.addingTimeInterval(8 + 180)) == "Active 3 min ago")

        // A sample a second later is too short to judge and changes nothing.
        let p4 = procs(ugrep: 287, renderer: 40.9)
        s = LeftoverTests.sample(p4, at: 29)
        watch.apply(to: &s, procs: p4)
        #expect(s.leftovers.first { $0.pid == 19709 }?.lastActive == nil)
    }

    @Test func aProcessKeepsTheActivityItHadBeforeItWasLeftBehind() {
        // A dev server under a terminal shell works, then the shell exits and launchd adopts the server.
        func procs(cpu: Double, orphaned: Bool) -> [Proc] {
            var list = [O.proc(500, orphaned ? 1 : 400, O.node, age: 5 * O.hour, args: ["node", "vite.js"], cpu: cpu)]
            if !orphaned { list.append(O.proc(400, 300, "/bin/zsh", age: 6 * O.hour)) }
            return list
        }
        var watch = LeftoverWatch()
        for (t, cpu, orphaned) in [(0.0, 10.0, false), (20, 12, false), (40, 12, true)] {
            let p = procs(cpu: cpu, orphaned: orphaned)
            var s = LeftoverTests.sample(p, at: t)
            watch.apply(to: &s, procs: p)
            if orphaned {
                #expect(s.leftovers.map(\.pid) == [500])
                #expect(s.leftovers.first?.lastActive == O.now.addingTimeInterval(20))
            } else {
                #expect(s.leftovers.isEmpty)
            }
        }
    }

    @Test func anItemThatStartedAfterHeadroomIsIdleSinceItStarted() {
        let started = O.now.addingTimeInterval(-60)
        let item = Leftover(pid: 9, kind: .process, command: "node x.mjs", cwd: nil,
                            processes: [ProcSummary(pid: 9, name: "node", gb: 0.1, startTime: O.now.timeIntervalSince1970)],
                            startTime: O.now.timeIntervalSince1970, cpuSeconds: 1, watchedSince: O.now)
        #expect(item.activity(now: O.now.addingTimeInterval(3600))?.hasPrefix("Not active since it started at ") == true)
        var older = item
        older.startTime = started.timeIntervalSince1970 - 3600
        #expect(older.activity(now: O.now)?.hasPrefix("Not active since Headroom started at ") == true)
        older.watchedSince = nil
        #expect(older.activity(now: O.now) == nil, "a sample without the app has no activity")
        #expect(older.age(now: O.now) == "1 h 1 min")
    }

    // MARK: State and kills

    @Test func theStatusDocumentCarriesLeftoversAndOldStateStillLoads() throws {
        var s = Fixture.snapshot(claudeGB: 10)
        s.leftovers = [Leftover(pid: 19709, kind: .search, command: "ugrep -G -I -v ^x", cwd: "/Users/k/x",
                                processes: [ProcSummary(pid: 19709, name: "ugrep", gb: 0.0016, startTime: 1_799_000_000.25),
                                            ProcSummary(pid: 19706, name: "tail", gb: 0.0005, startTime: 1_799_000_000.25)],
                                startTime: 1_799_000_000.25, cpuSeconds: 286.5,
                                lastActive: Date(timeIntervalSince1970: 1_799_999_000), watchedSince: Date(timeIntervalSince1970: 1_799_990_000))]
        #expect(s.leftovers[0].pids == [19706, 19709])
        let doc = Policy.status(s, .defaults, source: "test")
        let json = JSON.string(doc)
        #expect(json.contains(#""leftovers":[{"#))
        let back = try JSON.decoder().decode(StatusDocument.self, from: Data(json.utf8))
        #expect(back == doc)
        #expect(back.snapshot.leftovers.first?.startTime == 1_799_000_000.25, "a kill compares start times exactly")
        // A state.json written by 2.1 has no leftovers key.
        var object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var snapshot = try #require(object["snapshot"] as? [String: Any])
        snapshot.removeValue(forKey: "leftovers")
        object["snapshot"] = snapshot
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSON.decoder().decode(StatusDocument.self, from: old).snapshot.leftovers.isEmpty)
    }

    @Test func theAgeIsASetting() throws {
        #expect(Thresholds.defaults.leftoverMinutes == 30)
        let t = try JSON.decoder().decode(Thresholds.self, from: Data(#"{"leftoverMinutes": 90}"#.utf8))
        #expect(t.leftoverMinutes == 90)
        var bad = Thresholds()
        bad.leftoverMinutes = 0
        #expect(bad.validated().leftoverMinutes == 1)
    }

    @Test func aKillSignalsOnlyTheSameProcess() throws {
        // Signal 0 checks a process without touching it.
        let me = getpid()
        let info = try #require(SystemProbe.bsdInfo(me))
        let mine = Leftover(pid: me, kind: .process, command: "test", cwd: nil,
                            processes: [ProcSummary(pid: me, name: "test", gb: 0, startTime: info.startTime)],
                            startTime: info.startTime, cpuSeconds: 0)
        #expect(Leftovers.send(0, to: mine) == [me])
        // The same pid with another start time is another process now, and is left alone.
        var reused = mine
        reused.processes[0].startTime = info.startTime - 100
        #expect(Leftovers.send(0, to: reused).isEmpty)
    }

    @Test func launchdStartedItselfIsReadFromTheKernel() {
        // Finder, or any app, is started by launchd; this test process is not.
        #expect(SystemProbe.startedByLaunchd(getpid()) != true)
    }
}
